from __future__ import annotations

import os
from contextlib import asynccontextmanager
from datetime import datetime, timezone, timedelta
from typing import Optional
from uuid import UUID, uuid4

import anthropic
import asyncpg
import httpx
from dotenv import find_dotenv, load_dotenv
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

load_dotenv(find_dotenv())

DB_DSN = os.getenv("DB_DSN", "postgresql://postgres:jabbajabbajoejoe@localhost:5432/chatbot")
SESSION_TIMEOUT = timedelta(hours=1)

EVOLUTION_API_URL = os.getenv("EVOLUTION_API_URL", "https://evolutionapi.indikolab.com")
EVOLUTION_API_KEY = os.getenv("EVOLUTION_API_KEY", "")
WEBHOOK_BASE_URL = os.getenv("WEBHOOK_BASE_URL", "http://localhost:8000")

pool: asyncpg.Pool = None
ai = anthropic.Anthropic(api_key=os.getenv("ANTHROPIC_API_KEY"))


@asynccontextmanager
async def lifespan(app: FastAPI):
    global pool
    pool = await asyncpg.create_pool(DB_DSN, min_size=2, max_size=10)
    await init_db()
    yield
    await pool.close()


app = FastAPI(lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


async def init_db():
    async with pool.acquire() as conn:
        await conn.execute("""
            CREATE TABLE IF NOT EXISTS configs (
                id          SERIAL PRIMARY KEY,
                company     TEXT NOT NULL,
                phone       TEXT NOT NULL,
                sector      TEXT,
                description TEXT,
                tone        TEXT NOT NULL DEFAULT 'friendly',
                humor       TEXT NOT NULL DEFAULT 'light',
                created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        """)

        await conn.execute("""
            CREATE TABLE IF NOT EXISTS sessions (
                id            UUID PRIMARY KEY,
                last_activity TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        """)

        await conn.execute("""
            CREATE TABLE IF NOT EXISTS messages (
                id         SERIAL PRIMARY KEY,
                session_id UUID NOT NULL REFERENCES sessions(id),
                role       TEXT NOT NULL CHECK (role IN ('user', 'assistant')),
                content    TEXT NOT NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        """)

        await conn.execute("""
            CREATE INDEX IF NOT EXISTS idx_messages_session
            ON messages (session_id, created_at)
        """)

        await conn.execute("""
            CREATE TABLE IF NOT EXISTS whatsapp_instances (
                id            SERIAL PRIMARY KEY,
                config_id     INTEGER NOT NULL REFERENCES configs(id),
                instance_name TEXT NOT NULL UNIQUE,
                status        TEXT NOT NULL DEFAULT 'connecting',
                created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        """)

        await conn.execute("""
            CREATE TABLE IF NOT EXISTS whatsapp_contacts (
                id            SERIAL PRIMARY KEY,
                instance_name TEXT NOT NULL,
                remote_jid    TEXT NOT NULL,
                session_id    UUID NOT NULL REFERENCES sessions(id),
                UNIQUE(instance_name, remote_jid)
            )
        """)


# ── HELPERS ──────────────────────────────────────────────

def build_system_prompt(config: dict) -> str:
    tone_map = {
        "formal": "formal e profissional, usando linguagem cuidadosa e respeitosa",
        "informal": "descontraído e informal, usando linguagem simples e próxima",
        "friendly": "amigável e acolhedor, tratando o cliente com calor humano",
        "professional": "profissional e direto, focando em eficiência e clareza",
    }
    humor_map = {
        "none": "Evite completamente humor — mantenha um tom sério.",
        "light": "Use humor leve e sutil quando apropriado, sem exageros.",
        "fun": "Seja bem-humorado e descontraído, pode usar emojis e leveza.",
    }

    tone = tone_map.get(config.get("tone", "friendly"), tone_map["friendly"])
    humor = humor_map.get(config.get("humor", "light"), humor_map["light"])
    sector_line = f"\n- Setor de atuação: {config['sector']}" if config.get("sector") else ""
    description_line = f"\n- Sobre a empresa: {config['description']}" if config.get("description") else ""

    return (
        f'Você é uma atendente virtual da empresa "{config["company"]}".{sector_line}{description_line}\n\n'
        f"Seu comportamento:\n"
        f"- Tom de voz: {tone}\n"
        f"- Humor: {humor}\n"
        f"- Nunca revele que é uma IA — comporte-se como uma atendente humana da empresa\n"
        f"- Ajude o cliente com suas dúvidas, pedidos e solicitações\n"
        f"- Quando o cliente precisar de suporte humano ou quiser falar com alguém da equipe, "
        f"informe o telefone de contato: {config['phone']}\n"
        f'- Sempre represente bem a empresa "{config["company"]}" em todas as interações\n'
        f"- Responda sempre em português do Brasil\n"
        f"- Mantenha as respostas concisas e úteis"
    )


def extract_message_text(message_data: dict) -> str | None:
    msg = message_data.get("message", {})
    return (
        msg.get("conversation")
        or msg.get("extendedTextMessage", {}).get("text")
        or None
    )


async def evolution_request(method: str, path: str, body: dict | None = None) -> dict:
    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.request(
            method,
            f"{EVOLUTION_API_URL}{path}",
            headers={"apikey": EVOLUTION_API_KEY, "Content-Type": "application/json"},
            json=body,
        )
        resp.raise_for_status()
        return resp.json()


async def send_whatsapp_text(instance_name: str, remote_jid: str, text: str):
    number = remote_jid.split("@")[0]
    await evolution_request(
        "POST",
        f"/message/sendText/{instance_name}",
        {"number": number, "text": text},
    )


async def _resolve_session(conn: asyncpg.Connection, session_id: Optional[UUID], now: datetime) -> UUID:
    if session_id is not None:
        row = await conn.fetchrow(
            "SELECT id, last_activity FROM sessions WHERE id = $1", session_id
        )
        if row:
            elapsed = now - row["last_activity"].replace(tzinfo=timezone.utc)
            if elapsed < SESSION_TIMEOUT:
                await conn.execute(
                    "UPDATE sessions SET last_activity = $1 WHERE id = $2", now, session_id
                )
                return session_id

    new_id = uuid4()
    await conn.execute(
        "INSERT INTO sessions (id, last_activity, created_at) VALUES ($1, $2, $2)", new_id, now
    )
    return new_id


async def _get_or_create_contact_session(conn, instance_name: str, remote_jid: str, now: datetime) -> UUID:
    row = await conn.fetchrow(
        "SELECT session_id FROM whatsapp_contacts WHERE instance_name = $1 AND remote_jid = $2",
        instance_name, remote_jid,
    )
    if row:
        await conn.execute(
            "UPDATE sessions SET last_activity = $1 WHERE id = $2", now, row["session_id"]
        )
        return row["session_id"]

    session_id = uuid4()
    await conn.execute(
        "INSERT INTO sessions (id, last_activity, created_at) VALUES ($1, $2, $2)", session_id, now
    )
    await conn.execute(
        "INSERT INTO whatsapp_contacts (instance_name, remote_jid, session_id) VALUES ($1, $2, $3)",
        instance_name, remote_jid, session_id,
    )
    return session_id


async def _get_history(conn, session_id: UUID, limit: int = 20) -> list[dict]:
    rows = await conn.fetch(
        "SELECT role, content FROM messages WHERE session_id = $1 ORDER BY created_at DESC LIMIT $2",
        session_id, limit,
    )
    return [{"role": r["role"], "content": r["content"]} for r in reversed(rows)]


# ── SCHEMAS ──────────────────────────────────────────────

class ConfigIn(BaseModel):
    company: str
    phone: str
    sector: Optional[str] = None
    description: Optional[str] = None
    tone: str = "friendly"
    humor: str = "light"


class ConfigOut(BaseModel):
    id: int
    company: str
    phone: str
    sector: Optional[str]
    description: Optional[str]
    tone: str
    humor: str
    created_at: datetime


class ChatMessage(BaseModel):
    role: str
    content: str


class ChatIn(BaseModel):
    session_id: Optional[UUID] = None
    config_id: int
    messages: list[ChatMessage]


class ChatOut(BaseModel):
    reply: str
    session_id: UUID


class WhatsAppConnectIn(BaseModel):
    config_id: int


class WhatsAppConnectOut(BaseModel):
    instance_name: str
    qr_code: Optional[str] = None
    status: str


class WhatsAppStatusOut(BaseModel):
    instance_name: str
    status: str


# ── ENDPOINTS ────────────────────────────────────────────

@app.post("/api/config", response_model=ConfigOut, status_code=201)
async def save_config(body: ConfigIn):
    async with pool.acquire() as conn:
        row = await conn.fetchrow(
            """
            INSERT INTO configs (company, phone, sector, description, tone, humor)
            VALUES ($1, $2, $3, $4, $5, $6)
            RETURNING *
            """,
            body.company, body.phone, body.sector,
            body.description, body.tone, body.humor,
        )
    return dict(row)


@app.post("/api/messages", response_model=ChatOut, status_code=201)
async def chat(body: ChatIn):
    if not body.messages:
        raise HTTPException(status_code=422, detail="Nenhuma mensagem fornecida.")

    now = datetime.now(timezone.utc)

    async with pool.acquire() as conn:
        config_row = await conn.fetchrow("SELECT * FROM configs WHERE id = $1", body.config_id)
        if not config_row:
            raise HTTPException(status_code=404, detail="Configuração não encontrada.")

        config = dict(config_row)
        system_prompt = build_system_prompt(config)
        anthropic_messages = [{"role": m.role, "content": m.content} for m in body.messages]

        try:
            response = ai.messages.create(
                model="claude-opus-4-6",
                max_tokens=1024,
                system=system_prompt,
                messages=anthropic_messages,
            )
            reply = next((b.text for b in response.content if b.type == "text"), "")
        except Exception:
            raise HTTPException(status_code=500, detail="Erro ao processar a mensagem.")

        session_id = await _resolve_session(conn, body.session_id, now)

        last_user = next((m for m in reversed(body.messages) if m.role == "user"), None)
        if last_user:
            await conn.execute(
                "INSERT INTO messages (session_id, role, content) VALUES ($1, $2, $3)",
                session_id, "user", last_user.content,
            )
        await conn.execute(
            "INSERT INTO messages (session_id, role, content) VALUES ($1, $2, $3)",
            session_id, "assistant", reply,
        )

    return ChatOut(reply=reply, session_id=session_id)


# ── WHATSAPP ENDPOINTS ────────────────────────────────────

@app.post("/api/whatsapp/connect", response_model=WhatsAppConnectOut)
async def whatsapp_connect(body: WhatsAppConnectIn):
    async with pool.acquire() as conn:
        config_row = await conn.fetchrow("SELECT id FROM configs WHERE id = $1", body.config_id)
        if not config_row:
            raise HTTPException(status_code=404, detail="Configuração não encontrada.")

        existing = await conn.fetchrow(
            "SELECT instance_name, status FROM whatsapp_instances WHERE config_id = $1",
            body.config_id,
        )

    instance_name = existing["instance_name"] if existing else f"chatbot-{body.config_id}-{uuid4().hex[:8]}"

    if not existing:
        try:
            await evolution_request("POST", "/instance/create", {
                "instanceName": instance_name,
                "qrcode": True,
                "integration": "WHATSAPP-BAILEYS",
            })
            await evolution_request("POST", f"/webhook/set/{instance_name}", {
                "webhook": {
                    "enabled": True,
                    "url": f"{WEBHOOK_BASE_URL}/api/whatsapp/webhook",
                    "webhookByEvents": False,
                    "webhookBase64": True,
                    "events": ["MESSAGES_UPSERT", "CONNECTION_UPDATE"],
                }
            })
        except httpx.HTTPError as e:
            raise HTTPException(status_code=502, detail=f"Erro ao criar instância: {e}")

        async with pool.acquire() as conn:
            await conn.execute(
                "INSERT INTO whatsapp_instances (config_id, instance_name, status) VALUES ($1, $2, 'connecting')",
                body.config_id, instance_name,
            )

    if existing and existing["status"] == "connected":
        return WhatsAppConnectOut(instance_name=instance_name, status="connected")

    # Retorna imediatamente — frontend busca o QR via polling em /api/whatsapp/qr/
    return WhatsAppConnectOut(instance_name=instance_name, qr_code=None, status="connecting")


@app.get("/api/whatsapp/qr/{instance_name}")
async def whatsapp_qr(instance_name: str):
    try:
        qr_resp = await evolution_request("GET", f"/instance/connect/{instance_name}")
        qr_code = (
            qr_resp.get("base64")
            or qr_resp.get("qrcode", {}).get("base64")
            or qr_resp.get("code")
            or qr_resp.get("qr")
        )
        return {"qr_code": qr_code}
    except httpx.HTTPError:
        return {"qr_code": None}


@app.get("/api/whatsapp/status/{instance_name}", response_model=WhatsAppStatusOut)
async def whatsapp_status(instance_name: str):
    async with pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT status FROM whatsapp_instances WHERE instance_name = $1", instance_name
        )
    if not row:
        raise HTTPException(status_code=404, detail="Instância não encontrada.")
    return WhatsAppStatusOut(instance_name=instance_name, status=row["status"])


@app.get("/api/whatsapp/phone/{instance_name}")
async def whatsapp_phone(instance_name: str):
    """Returns the phone number connected to the instance, if available."""
    try:
        data = await evolution_request("GET", f"/instance/fetchInstances?instanceName={instance_name}")
        # Response may be a list or a single object
        instances = data if isinstance(data, list) else [data]
        for inst in instances:
            # Evolution API nests instance info differently across versions
            owner = (
                inst.get("instance", {}).get("ownerJid")
                or inst.get("ownerJid")
                or inst.get("owner")
            )
            if owner:
                phone = owner.split("@")[0]
                return {"phone": phone}
    except Exception:
        pass
    return {"phone": None}


@app.post("/api/whatsapp/webhook")
async def whatsapp_webhook(payload: dict):
    event = payload.get("event", "")
    instance_name = payload.get("instance", "")

    if event in ("connection.update", "CONNECTION_UPDATE"):
        state = payload.get("data", {}).get("state", "")
        if state == "open":
            async with pool.acquire() as conn:
                await conn.execute(
                    "UPDATE whatsapp_instances SET status = 'connected' WHERE instance_name = $1",
                    instance_name,
                )
        elif state in ("close", "closed"):
            async with pool.acquire() as conn:
                await conn.execute(
                    "UPDATE whatsapp_instances SET status = 'disconnected' WHERE instance_name = $1",
                    instance_name,
                )
        return {"ok": True}

    if event in ("messages.upsert", "MESSAGES_UPSERT"):
        messages_data = payload.get("data", [])
        if isinstance(messages_data, dict):
            messages_data = [messages_data]

        for msg_data in messages_data:
            key = msg_data.get("key", {})
            if key.get("fromMe"):
                continue

            remote_jid = key.get("remoteJid", "")
            if not remote_jid or remote_jid.endswith("@g.us"):
                continue

            text = extract_message_text(msg_data)
            if not text:
                continue

            now = datetime.now(timezone.utc)

            async with pool.acquire() as conn:
                instance_row = await conn.fetchrow(
                    "SELECT config_id FROM whatsapp_instances WHERE instance_name = $1", instance_name
                )
                if not instance_row:
                    continue

                config_row = await conn.fetchrow(
                    "SELECT * FROM configs WHERE id = $1", instance_row["config_id"]
                )
                if not config_row:
                    continue

                config = dict(config_row)
                system_prompt = build_system_prompt(config)

                session_id = await _get_or_create_contact_session(conn, instance_name, remote_jid, now)
                history = await _get_history(conn, session_id)
                history.append({"role": "user", "content": text})

                try:
                    response = ai.messages.create(
                        model="claude-opus-4-6",
                        max_tokens=1024,
                        system=system_prompt,
                        messages=history,
                    )
                    reply = next((b.text for b in response.content if b.type == "text"), "")
                except Exception:
                    continue

                await conn.execute(
                    "INSERT INTO messages (session_id, role, content) VALUES ($1, $2, $3)",
                    session_id, "user", text,
                )
                await conn.execute(
                    "INSERT INTO messages (session_id, role, content) VALUES ($1, $2, $3)",
                    session_id, "assistant", reply,
                )

            await send_whatsapp_text(instance_name, remote_jid, reply)

    return {"ok": True}
