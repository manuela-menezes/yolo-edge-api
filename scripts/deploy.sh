#!/bin/bash

# scripts/deploy.sh
# Executa no Raspberry Pi via SSH pelo pipeline de CI/CD.
# Faz pull da nova imagem, reinicia o serviço e valida o health check.
# Em caso de falha, reverte para a imagem anterior automaticamente.

set -euo pipefail

# ─────────────────────────────────────────────────────────────
# Configurações
# ─────────────────────────────────────────────────────────────

DEPLOY_PATH="${DEPLOY_PATH:-$HOME/yolo-edge-api}"

HEALTH_URL="http://localhost:8000/health"

HEALTH_RETRIES=6
HEALTH_WAIT=10

PULL_RETRIES=3
PULL_WAIT=10

SERVICE_NAME="yolo-api"

echo "========================================"
echo " Deploy — $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"

cd "$DEPLOY_PATH"

# ─────────────────────────────────────────────────────────────
# Salva a imagem atual para possível rollback
# ─────────────────────────────────────────────────────────────

PREVIOUS=$(
    docker inspect "$SERVICE_NAME" \
        --format '{{.Config.Image}}' \
        2>/dev/null || echo "none"
)

echo "[INFO] Imagem atual: $PREVIOUS"

# ─────────────────────────────────────────────────────────────
# 1/4 — Baixa a nova imagem
# ─────────────────────────────────────────────────────────────

echo "[1/4] Baixando nova imagem..."
docker compose pull
python3 -m dvc pull models/yolo-epi.pt

# ─────────────────────────────────────────────────────────────
# 2/4 — Sobe a nova versão
# ─────────────────────────────────────────────────────────────

echo "[2/4] Iniciando nova versão..."
docker compose up -d --build

# ─────────────────────────────────────────────────────────────
# 3/4 — Aguarda o serviço estabilizar
# ─────────────────────────────────────────────────────────────

echo ""
echo "[3/4] Aguardando health check ($((HEALTH_RETRIES * HEALTH_WAIT))s max)..."

SUCCESS=false

for i in $(seq 1 "$HEALTH_RETRIES"); do

    sleep "$HEALTH_WAIT"

    if curl -sf "$HEALTH_URL" > /dev/null 2>&1; then
        SUCCESS=true
        break
    fi

    echo "  Tentativa $i/$HEALTH_RETRIES falhou, aguardando..."

done

# ─────────────────────────────────────────────────────────────
# 4/4 — Avalia resultado
# ─────────────────────────────────────────────────────────────

if [ "$SUCCESS" = true ]; then

    echo "[4/4] Health check OK"

    NEW=$(
        docker inspect "$SERVICE_NAME" \
            --format '{{.Config.Image}}' \
            2>/dev/null || echo "unknown"
    )

    echo ""
    echo "========================================"
    echo "[OK] Deploy bem-sucedido"
    echo "[INFO] Imagem: $NEW"
    echo "========================================"

    exit 0

fi

# ─────────────────────────────────────────────────────────────
# Health check falhou → rollback
# ─────────────────────────────────────────────────────────────

echo ""
echo "[ERRO] Health check falhou após $((HEALTH_RETRIES * HEALTH_WAIT))s"

echo ""
echo "[INFO] Últimos logs do serviço:"
docker compose logs --tail=50 "$SERVICE_NAME" || true

if [ "$PREVIOUS" = "none" ]; then

    echo "[AVISO] Sem imagem anterior para rollback."
    exit 1

fi

echo ""
echo "[ROLLBACK] Revertendo para: $PREVIOUS"

docker compose down || true

# Inicia explicitamente a imagem anterior.
if ! IMAGE="$PREVIOUS" docker compose up -d "$SERVICE_NAME"; then

    echo "[ERRO CRÍTICO] Falha ao iniciar a imagem anterior."
    exit 1

fi

echo "[ROLLBACK] Versão anterior iniciada."
echo "[ROLLBACK] Validando health check..."

ROLLBACK_SUCCESS=false

for i in $(seq 1 "$HEALTH_RETRIES"); do

    sleep "$HEALTH_WAIT"

    if curl -sf "$HEALTH_URL" > /dev/null 2>&1; then
        ROLLBACK_SUCCESS=true
        break
    fi

    echo "  Rollback health check $i/$HEALTH_RETRIES falhou."

done

if [ "$ROLLBACK_SUCCESS" = true ]; then

    echo ""
    echo "========================================"
    echo "[ERRO] Deploy falhou."
    echo "[OK] Rollback concluído com sucesso."
    echo "[INFO] Imagem restaurada: $PREVIOUS"
    echo "========================================"

else

    echo ""
    echo "========================================"
    echo "[ERRO CRÍTICO]"
    echo "Deploy falhou e o rollback não passou no health check."
    echo "========================================"

    exit 1

fi

exit 1
