#!/bin/bash
# ─────────────────────────────────────────────────────────────
# Setup inicial do servidor — rode UMA VEZ como root
# Uso: bash setup.sh SEU_REPO_GIT
# Ex:  bash setup.sh https://github.com/usuario/chatbot-builder.git
# ─────────────────────────────────────────────────────────────
set -e

REPO_URL=${1:?"Informe a URL do repositório git como primeiro argumento"}
PROD_DIR="/var/www/chatbot-prod"
DEV_DIR="/var/www/chatbot-dev"

echo "━━━ 1/9  Atualizando pacotes ━━━"
apt update && apt upgrade -y

echo "━━━ 2/9  Instalando Node.js 20 ━━━"
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

echo "━━━ 3/9  Instalando PM2 ━━━"
npm install -g pm2

echo "━━━ 4/9  Instalando Python 3.12 e ferramentas ━━━"
apt install -y python3.12 python3.12-venv python3-pip

echo "━━━ 5/9  Instalando Nginx e Certbot ━━━"
apt install -y nginx certbot python3-certbot-nginx

echo "━━━ 6/9  Clonando repositório ━━━"
mkdir -p /var/www
git clone "$REPO_URL" "$PROD_DIR"
git clone "$REPO_URL" "$DEV_DIR"

# Checkout das branches
cd "$PROD_DIR" && git checkout main
cd "$DEV_DIR"  && git checkout dev 2>/dev/null || git checkout -b dev

echo "━━━ 7/9  Instalando dependências ━━━"
# Node.js — prod
cd "$PROD_DIR" && npm install --omit=dev

# Node.js — dev
cd "$DEV_DIR" && npm install

# Python — prod
cd "$PROD_DIR/api"
python3.12 -m venv .venv
.venv/bin/pip install -r requirements.txt

# Python — dev
cd "$DEV_DIR/api"
python3.12 -m venv .venv
.venv/bin/pip install -r requirements.txt

echo "━━━ 8/9  Coletando credenciais ━━━"
echo "(as entradas não aparecem no terminal)"
echo ""

read -rsp "ANTHROPIC_API_KEY: "      ANTHROPIC_API_KEY;   echo
read -rsp "EVOLUTION_API_KEY: "      EVOLUTION_API_KEY;   echo
read -rsp "Senha do banco (DB): "    DB_DSN;             echo

# Grava prod
cat > "$PROD_DIR/.env" <<ENV
PORT=3000
FASTAPI_URL=http://127.0.0.1:8000
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
DB_DSN=${DB_DSN}
EVOLUTION_API_URL=https://evolutionapi.indikolab.com
EVOLUTION_API_KEY=${EVOLUTION_API_KEY}
WEBHOOK_BASE_URL=https://chatbot.indikolab.com
ENV

# Grava dev (mesmas chaves, portas e webhook diferentes)
cat > "$DEV_DIR/.env" <<ENV
PORT=3001
FASTAPI_URL=http://127.0.0.1:8001
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
DB_DSN=${DB_DSN}
EVOLUTION_API_URL=https://evolutionapi.indikolab.com
EVOLUTION_API_KEY=${EVOLUTION_API_KEY}
WEBHOOK_BASE_URL=https://chatbot-dev.indikolab.com
ENV

# Protege os arquivos — só root lê
chmod 600 "$PROD_DIR/.env" "$DEV_DIR/.env"

# Limpa as variáveis da memória do processo
unset ANTHROPIC_API_KEY EVOLUTION_API_KEY DB_DSN

echo "━━━ 9/9  Configurando serviços ━━━"

# Systemd — FastAPI prod
cat > /etc/systemd/system/chatbot-api-prod.service <<SERVICE
[Unit]
Description=Chatbot FastAPI (prod)
After=network.target

[Service]
Type=simple
WorkingDirectory=$PROD_DIR/api
ExecStart=$PROD_DIR/api/.venv/bin/uvicorn main:app --host 127.0.0.1 --port 8000
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE

# Systemd — FastAPI dev
cat > /etc/systemd/system/chatbot-api-dev.service <<SERVICE
[Unit]
Description=Chatbot FastAPI (dev)
After=network.target

[Service]
Type=simple
WorkingDirectory=$DEV_DIR/api
ExecStart=$DEV_DIR/api/.venv/bin/uvicorn main:app --host 127.0.0.1 --port 8001 --reload
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now chatbot-api-prod chatbot-api-dev

# Nginx — oculta versão do servidor
sed -i 's/# server_tokens off;/server_tokens off;/' /etc/nginx/nginx.conf

cp /var/www/chatbot-prod/deploy/nginx.conf /etc/nginx/sites-available/chatbot
ln -sf /etc/nginx/sites-available/chatbot /etc/nginx/sites-enabled/chatbot
rm -f /etc/nginx/sites-enabled/default   # remove a página padrão do Nginx
nginx -t && systemctl reload nginx

# SSL — prod e dev
certbot --nginx -d chatbot.indikolab.com -d chatbot-dev.indikolab.com --non-interactive --agree-tos -m admin@indikolab.com

# PM2 — Node.js
cd "$PROD_DIR"
pm2 start ecosystem.config.cjs
pm2 save
pm2 startup systemd -u root --hp /root | tail -1 | bash

echo ""
echo "✅ Setup completo!"
echo "   Prod:  https://chatbot.indikolab.com"
echo "   Dev:   https://chatbot-dev.indikolab.com"
echo ""
echo "Logs:"
echo "   pm2 logs chatbot-prod"
echo "   journalctl -u chatbot-api-prod -f"
