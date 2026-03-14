#!/bin/bash
# ─────────────────────────────────────────────────────────────
# Atualiza prod ou dev com o código mais recente do git
# Uso: bash update.sh prod|dev
# ─────────────────────────────────────────────────────────────
set -e

ENV=${1:?"Informe o ambiente: prod ou dev"}

if [ "$ENV" = "prod" ]; then
    DIR="/var/www/chatbot-prod"
    NODE_APP="chatbot-prod"
    API_SVC="chatbot-api-prod"
    BRANCH="main"
elif [ "$ENV" = "dev" ]; then
    DIR="/var/www/chatbot-dev"
    NODE_APP="chatbot-dev"
    API_SVC="chatbot-api-dev"
    BRANCH="dev"
else
    echo "Ambiente inválido. Use: prod ou dev"
    exit 1
fi

echo "━━━ Atualizando $ENV ($BRANCH) ━━━"

cd "$DIR"
git fetch origin
git checkout "$BRANCH"
git pull origin "$BRANCH"

echo "── Instalando dependências Node.js ──"
npm install --omit=dev

echo "── Instalando dependências Python ──"
cd "$DIR/api"
.venv/bin/pip install -r requirements.txt -q

echo "── Reiniciando serviços ──"
pm2 restart "$NODE_APP"
systemctl restart "$API_SVC"

echo ""
echo "✅ $ENV atualizado com sucesso!"
pm2 status "$NODE_APP"
systemctl is-active "$API_SVC" && echo "FastAPI: ativo"
