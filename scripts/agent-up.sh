#!/bin/bash
# Поднять ssh-agent и зарядить ключи с passphrase. Идемпотентно: переиспользует
# живой агент, ssh-add'ит только недостающие ключи.
#
# Вызывается из Makefile `agent-up`. Получает через env:
#   AGENT_ENV   — путь к файлу с SSH_AUTH_SOCK/SSH_AGENT_PID
#   AGENT_KEYS  — список путей к приватным ключам (через пробел)
#
# Зачем вообще: Ansible не умеет вводить passphrase у ssh-ключей. Раньше это
# обходилось ролью verify_authorized_key (косвенная проверка через fingerprint
# в authorized_keys + shell-разбор sshd -T). Теперь — ssh-agent: один раз за
# сессию `make agent-up` спрашивает passphrase у каждого ключа, кладёт
# разлоченные приватки в свой кэш; ansible-playbook видит сокет через
# SSH_AUTH_SOCK и использует агента для подписи (через IdentitiesOnly=yes +
# -i KEY клиент матчит KEY по fingerprint в агенте).
set -e

: "${AGENT_ENV:?AGENT_ENV не задан (должен прийти из environments.mk)}"
: "${AGENT_KEYS:?AGENT_KEYS не задан (должен прийти из environments.mk)}"

# Переиспользуем существующий агент, если он жив.
if [ -f "$AGENT_ENV" ]; then
    . "./$AGENT_ENV"
    if [ -n "$SSH_AGENT_PID" ] && kill -0 "$SSH_AGENT_PID" 2>/dev/null && [ -S "$SSH_AUTH_SOCK" ]; then
        : # агент жив — ничего не делаем
    else
        echo "ssh-agent из $AGENT_ENV мёртв — пересоздаю"
        rm -f "$AGENT_ENV"
    fi
fi

if [ ! -f "$AGENT_ENV" ]; then
    # ssh-agent -s печатает в Bourne-формате:
    #   SSH_AUTH_SOCK=/tmp/.../agent.PID; export SSH_AUTH_SOCK;
    #   SSH_AGENT_PID=PID; export SSH_AGENT_PID;
    #   echo Agent pid PID;
    # Сохраняем как есть, только убираем итоговый `echo` (он не нужен при
    # source-инге). Сами `export VAR;` критичны — без export ansible-playbook
    # (дочерний процесс) не увидит SSH_AUTH_SOCK.
    ssh-agent -s | grep -v '^echo ' > "$AGENT_ENV"
    echo "ssh-agent поднят, env → $AGENT_ENV"
fi

. "./$AGENT_ENV"
loaded="$(ssh-add -l 2>/dev/null || true)"
for k in $AGENT_KEYS; do
    if [ ! -f "$k.pub" ]; then
        echo "FAIL: $k.pub не найден — сгенерируйте ключи (make stage-0)"
        exit 1
    fi
    fp="$(ssh-keygen -lf "$k.pub" | awk '{print $2}')"
    if echo "$loaded" | grep -qF "$fp"; then
        echo "ssh-agent: $k уже загружен"
    else
        echo "ssh-add $k:"
        ssh-add "$k"
    fi
done
