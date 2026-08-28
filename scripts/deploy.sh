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

echo ""
echo "[1/4] Baixando nova imagem..."

PULL_SUCCESS=false

for attempt in $(seq 1 "$PULL_RETRIES"); do

    echo "[INFO] Tentativa $attempt/$PULL_RETRIES..."

    if docker compose pull "$SERVICE_NAME"; then
        PULL_SUCCESS=true
        echo "[INFO] Nova imagem baixada com sucesso."
        break
    fi

    if [ "$attempt" -lt "$PULL_RETRIES" ]; then
        echo "[AVISO] Falha no download."
        echo "[INFO] Tentando novamente em ${PULL_WAIT}s..."
        sleep "$PULL_WAIT"
    fi

done

# Se as 3 tentativas falharem, não mexe no container atual.
if [ "$PULL_SUCCESS" = false ]; then
    echo ""
    echo "[ERRO] Não foi possível baixar a nova imagem."
    echo "[ERRO] Deploy cancelado."
    echo "[INFO] A versão atual permanece em execução."
    exit 1
fi

# ─────────────────────────────────────────────────────────────
# 2/4 — Sobe a nova versão
# ─────────────────────────────────────────────────────────────

echo ""
echo "[2/4] Iniciando nova versão..."

if ! docker compose up -d "$SERVICE_NAME"; then

    echo "[ERRO] Falha ao iniciar a nova versão."

    if [ "$PREVIOUS" != "none" ]; then

        echo "[ROLLBACK] Revertendo para: $PREVIOUS"

        docker compose down || true

        if IMAGE="$PREVIOUS" docker compose up -d "$SERVICE_NAME"; then
            echo "[ROLLBACK] Container anterior iniciado."
        else
            echo "[ERRO CRÍTICO] Não foi possível iniciar a versão anterior."
            exit 1
        fi

    else
        echo "[AVISO] Não existe imagem anterior para rollback."
    fi

    exit 1
fi

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
