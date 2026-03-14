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
EVOLUTION_DIR="/opt/evolution-api"

echo "━━━ 1/11  Atualizando pacotes ━━━"
apt update && apt upgrade -y

echo "━━━ 2/11  Instalando Node.js 20 ━━━"
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

echo "━━━ 3/11  Instalando PM2 ━━━"
npm install -g pm2

echo "━━━ 4/11  Instalando Python 3.12 e ferramentas ━━━"
apt install -y python3.12 python3.12-venv python3-pip

echo "━━━ 5/11  Instalando PostgreSQL ━━━"
apt install -y postgresql postgresql-contrib

systemctl enable --now postgresql

echo "(as entradas não aparecem no terminal)"
read -rsp "Senha para o usuário postgres do banco: " DB_PASS; echo

sudo -u postgres psql -c "ALTER USER postgres PASSWORD '${DB_PASS}';"
sudo -u postgres psql -c "CREATE DATABASE chatbot;" 2>/dev/null || echo "banco chatbot já existe, continuando..."
sudo -u postgres psql -c "CREATE DATABASE evolution;" 2>/dev/null || echo "banco evolution já existe, continuando..."

# Permite conexão local com senha
sed -i "s|^local   all             all                                     peer|local   all             all                                     md5|" /etc/postgresql/*/main/pg_hba.conf
systemctl restart postgresql

echo "━━━ 6/11  Instalando Nginx e Certbot ━━━"
apt install -y nginx certbot python3-certbot-nginx

echo "━━━ 7/11  Instalando Evolution API ━━━"
apt install -y git

rm -rf "$EVOLUTION_DIR"
git clone https://github.com/EvolutionAPI/evolution-api.git "$EVOLUTION_DIR"
cd "$EVOLUTION_DIR"
npm install
cp .env.example .env

read -rsp "EVOLUTION_API_KEY (chave de acesso da Evolution API): " EVOLUTION_API_KEY; echo

cat > "$EVOLUTION_DIR/.env" <<ENV
SERVER_URL=https://evolutionapi.indikolab.com
SERVER_PORT=8080

AUTHENTICATION_TYPE=apikey
AUTHENTICATION_API_KEY=${EVOLUTION_API_KEY}

DATABASE_ENABLED=true
DATABASE_PROVIDER=postgresql
DATABASE_CONNECTION_URI=postgresql://postgres:${DB_PASS}@localhost:5432/evolution
DATABASE_CONNECTION_CLIENT_NAME=evolution_api

LOG_LEVEL=ERROR
ENV

chmod 600 "$EVOLUTION_DIR/.env"
npm run build
pm2 start dist/main.js --name evolution-api
pm2 save

echo "━━━ 8/11  Clonando repositório do chatbot ━━━"
mkdir -p /var/www
git clone "$REPO_URL" "$PROD_DIR"
git clone "$REPO_URL" "$DEV_DIR"

cd "$PROD_DIR" && git checkout main
cd "$DEV_DIR"  && git checkout dev 2>/dev/null || git checkout -b dev

echo "━━━ 9/11  Instalando dependências do chatbot ━━━"
cd "$PROD_DIR" && npm install --omit=dev
cd "$DEV_DIR"  && npm install

cd "$PROD_DIR/api"
python3.12 -m venv .venv
.venv/bin/pip install -r requirements.txt

cd "$DEV_DIR/api"
python3.12 -m venv .venv
.venv/bin/pip install -r requirements.txt

echo "━━━ 10/11  Coletando credenciais do chatbot ━━━"
echo "(as entradas não aparecem no terminal)"
echo ""

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

echo "━━━ 11/11  Configurando serviços ━━━"

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

# SSL
certbot --nginx \
  -d chatbot.indikolab.com \
  -d chatbot-dev.indikolab.com \
  -d evolutionapi.indikolab.com \
  --non-interactive --agree-tos -m admin@indikolab.com

# PM2 — Node.js
cd "$PROD_DIR"
pm2 start ecosystem.config.cjs
pm2 save
pm2 startup systemd -u root --hp /root | tail -1 | bash

echo ""
echo "✅ Setup completo!"
echo "   Chatbot prod:  https://chatbot.indikolab.com"
echo "   Chatbot dev:   https://chatbot-dev.indikolab.com"
echo "   Evolution API: https://evolutionapi.indikolab.com"
echo ""
echo "Logs:"
echo "   pm2 logs                        (Node.js + Evolution API)"
echo "   journalctl -u chatbot-api-prod -f   (FastAPI prod)"
echo "   journalctl -u chatbot-api-dev -f    (FastAPI dev)"
