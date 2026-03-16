#!/bin/bash
# ─────────────────────────────────────────────────────────────
# Setup inicial do servidor — rode UMA VEZ como root
# Uso: bash setup.sh SEU_REPO_GIT
# Ex:  bash setup.sh https://github.com/brunobaring/chatbot-builder.git
# ─────────────────────────────────────────────────────────────
set -e

REPO_URL=${1:?"Informe a URL do repositório git como primeiro argumento"}
PROD_DIR="/var/www/chatbot-prod"
DEV_DIR="/var/www/chatbot-dev"

echo "━━━ 1/10  Atualizando pacotes ━━━"
apt update && apt upgrade -y
apt install -y git curl

echo "━━━ 2/10  Instalando Node.js 20 ━━━"
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

echo "━━━ 3/10  Instalando PM2 ━━━"
npm install -g pm2

echo "━━━ 4/10  Instalando Python 3.12 ━━━"
apt install -y python3.12 python3.12-venv python3-pip

echo "━━━ 5/10  Instalando PostgreSQL ━━━"
apt install -y postgresql postgresql-contrib
systemctl enable --now postgresql

echo "(as entradas não aparecem no terminal)"
read -rsp "Senha para o usuário postgres do banco: " DB_PASS; echo

sudo -u postgres psql -c "ALTER USER postgres PASSWORD '${DB_PASS}';"
sudo -u postgres psql -c "CREATE DATABASE chatbot;"  2>/dev/null || echo "banco chatbot já existe, continuando..."
sudo -u postgres psql -c "CREATE DATABASE evolution;" 2>/dev/null || echo "banco evolution já existe, continuando..."

# Permite conexão local com senha
sed -i "s|^local   all             all                                     peer|local   all             all                                     md5|" /etc/postgresql/*/main/pg_hba.conf
systemctl restart postgresql

echo "━━━ 6/10  Instalando Docker ━━━"
curl -fsSL https://get.docker.com | bash -
systemctl enable --now docker

echo "━━━ 7/10  Instalando Evolution API via Docker ━━━"
read -rsp "EVOLUTION_API_KEY (chave de acesso da Evolution API): " EVOLUTION_API_KEY; echo

docker rm -f evolution-api 2>/dev/null || true

docker run -d \
  --name evolution-api \
  --restart always \
  --network host \
  -e SERVER_URL=https://evolutionapi.indikolab.com \
  -e SERVER_PORT=8080 \
  -e AUTHENTICATION_TYPE=apikey \
  -e AUTHENTICATION_API_KEY="${EVOLUTION_API_KEY}" \
  -e DATABASE_ENABLED=true \
  -e DATABASE_PROVIDER=postgresql \
  -e DATABASE_CONNECTION_URI="postgresql://postgres:${DB_PASS}@localhost:5432/evolution" \
  -e DATABASE_CONNECTION_CLIENT_NAME=evolution_api \
  -e LOG_LEVEL=ERROR \
  -v evolution_instances:/evolution/instances \
  atendai/evolution-api:latest

echo "━━━ 8/10  Instalando Nginx e Certbot ━━━"
apt install -y nginx certbot python3-certbot-nginx

echo "━━━ 9/10  Clonando e configurando o chatbot ━━━"
rm -rf "$PROD_DIR" "$DEV_DIR"
mkdir -p /var/www
git clone "$REPO_URL" "$PROD_DIR"
git clone "$REPO_URL" "$DEV_DIR"

cd "$PROD_DIR" && git checkout main
cd "$DEV_DIR"  && git checkout dev 2>/dev/null || git checkout -b dev

# Dependências Node.js
cd "$PROD_DIR" && npm install --omit=dev
cd "$DEV_DIR"  && npm install

# Dependências Python
cd "$PROD_DIR/api" && python3.12 -m venv .venv && .venv/bin/pip install -r requirements.txt
cd "$DEV_DIR/api"  && python3.12 -m venv .venv && .venv/bin/pip install -r requirements.txt

echo "(as entradas não aparecem no terminal)"
read -rsp "ANTHROPIC_API_KEY: " ANTHROPIC_API_KEY; echo

cat > "$PROD_DIR/.env" <<ENV
PORT=3000
FASTAPI_URL=http://127.0.0.1:8000
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
DB_DSN=postgresql://postgres:${DB_PASS}@localhost:5432/chatbot
EVOLUTION_API_URL=https://evolutionapi.indikolab.com
EVOLUTION_API_KEY=${EVOLUTION_API_KEY}
WEBHOOK_BASE_URL=https://chatbot.indikolab.com
ENV

cat > "$DEV_DIR/.env" <<ENV
PORT=3001
FASTAPI_URL=http://127.0.0.1:8001
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
DB_DSN=postgresql://postgres:${DB_PASS}@localhost:5432/chatbot
EVOLUTION_API_URL=https://evolutionapi.indikolab.com
EVOLUTION_API_KEY=${EVOLUTION_API_KEY}
WEBHOOK_BASE_URL=https://chatbot-dev.indikolab.com
ENV

chmod 600 "$PROD_DIR/.env" "$DEV_DIR/.env"
unset ANTHROPIC_API_KEY EVOLUTION_API_KEY DB_PASS

echo "━━━ 10/10  Configurando serviços ━━━"

# Systemd — FastAPI prod
cat > /etc/systemd/system/chatbot-api-prod.service <<SERVICE
[Unit]
Description=Chatbot FastAPI (prod)
After=network.target postgresql.service

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
After=network.target postgresql.service

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

# Nginx
sed -i 's/# server_tokens off;/server_tokens off;/' /etc/nginx/nginx.conf
cp "$PROD_DIR/deploy/nginx.conf" /etc/nginx/sites-available/chatbot
ln -sf /etc/nginx/sites-available/chatbot /etc/nginx/sites-enabled/chatbot
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# SSL — chatbot (prod + dev)
certbot --nginx \
  -d chatbot.indikolab.com \
  -d chatbot-dev.indikolab.com \
  --non-interactive --agree-tos -m admin@indikolab.com

# SSL — Evolution API (requer DNS apontando para este servidor)
certbot --nginx \
  -d evolutionapi.indikolab.com \
  --non-interactive --agree-tos -m admin@indikolab.com

# PM2 — Node.js
cd "$PROD_DIR"
pm2 start ecosystem.config.cjs
pm2 save
pm2 startup systemd -u root --hp /root | tail -1 | sed 's/^\$ //' | bash

echo ""
echo "✅ Setup completo!"
echo "   Chatbot prod:  https://chatbot.indikolab.com"
echo "   Chatbot dev:   https://chatbot-dev.indikolab.com"
echo "   Evolution API: https://evolutionapi.indikolab.com"
echo ""
echo "Logs:"
echo "   docker logs evolution-api -f        (Evolution API)"
echo "   pm2 logs                            (Node.js)"
echo "   journalctl -u chatbot-api-prod -f   (FastAPI prod)"
echo "   journalctl -u chatbot-api-dev -f    (FastAPI dev)"
