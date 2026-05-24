#!/bin/bash
# Остановить ssh-agent и удалить $AGENT_ENV.
# Вызывается из Makefile `agent-down`. Получает через env: AGENT_ENV.
set -e

: "${AGENT_ENV:?AGENT_ENV не задан (должен прийти из environments.mk)}"

if [ -f "$AGENT_ENV" ]; then
    . "./$AGENT_ENV" && ssh-agent -k >/dev/null 2>&1 || true
    rm -f "$AGENT_ENV"
    echo "ssh-agent остановлен"
fi
