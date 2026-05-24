#!/bin/bash
# Показать состояние ssh-агента и список загруженных ключей.
# Вызывается из Makefile `agent-status`. Получает через env: AGENT_ENV.

: "${AGENT_ENV:?AGENT_ENV не задан (должен прийти из environments.mk)}"

if [ ! -f "$AGENT_ENV" ]; then
    echo "$AGENT_ENV нет — agent не запускался в этом проекте"
    exit 0
fi

. "./$AGENT_ENV"
echo "SSH_AUTH_SOCK=$SSH_AUTH_SOCK"
echo "SSH_AGENT_PID=$SSH_AGENT_PID"
if [ -S "$SSH_AUTH_SOCK" ] && kill -0 "$SSH_AGENT_PID" 2>/dev/null; then
    echo "Состояние: жив"
    ssh-add -l
else
    echo "Состояние: МЁРТВ (выполните 'make agent-up')"
fi
