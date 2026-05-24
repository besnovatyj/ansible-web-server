# Конфигурация Makefile-проекта. Включается в Makefile через `include`.
# Здесь — только переменные, шапочные комментарии и .PHONY-декларация; рецепты
# и поведенческие настройки make (SHELL, .ONESHELL, .DEFAULT_GOAL) — в Makefile.
# (Раньше файл назывался environments.sh — был дуал-форматом shell+make; больше
# не source-ится из shell, синтаксис чисто make-овский: `:=`, `$(...)` и т.д.)

# =============================================================================
# Shell-окружение для процессов, порождаемых make
# =============================================================================
# `export VAR` в make делает переменную видимой всем дочерним процессам recipe.
# EDITOR — для `make vault-edit`. ANSIBLE_CONFIG — указывает на наш ansible.cfg
# (вместо поиска в стандартных местах).
export EDITOR          := nano
export ANSIBLE_CONFIG  := ./ansible.cfg

# =============================================================================
# ssh-agent (для passphrase-ключей: ВСЕ ключи проекта)
# =============================================================================
# Зачем: Ansible не умеет вводить passphrase у ssh-ключей. Раньше это
# обходилось ролью verify_authorized_key (косвенная проверка через fingerprint
# в authorized_keys + shell-разбор sshd -T). Теперь — ssh-agent: один раз за
# сессию `make agent-up` спрашивает passphrase у каждого ключа, кладёт
# разлоченные приватки в свой кэш; ansible-playbook видит сокет через
# SSH_AUTH_SOCK и использует агента для подписи (через IdentitiesOnly=yes +
# -i KEY клиент матчит KEY по fingerprint в агенте).
#
# Состояние агента живёт в $(AGENT_ENV) рядом с Makefile (в .gitignore). Каждая
# stage-цель сама делает `. ./$(AGENT_ENV) && ansible-playbook ...` через
# обёртку $(PLAY) — иначе make запускает каждую строку рецепта в свежей shell
# и SSH_AUTH_SOCK теряется. Только stage-0 (локально, ключей ещё нет) от
# агента не зависит; stage-1b зависит, потому что после bootstrap'а ему надо
# подключиться automation-юзером (по ключу с passphrase) для verify_ssh.
#
# Список ключей в $(AGENT_KEYS) держим на уровне Makefile-конфига, не из
# инвентаря: чтение ansible-inventory в каждом рецепте дорого и хрупко
# (yaml + vault). Стоимость синхронизации с group_vars/all/ssh.yml: один
# список из трёх путей. DOMAIN приходит из .env (см. Makefile).
SSH_KEYS_DIR    := $(HOME)/.ssh/$(DOMAIN)
AGENT_ENV       := .agent.env
# Все ключи защищены passphrase. Добавление нового пользователя в server_users
# (ssh.yml) = +1 строка сюда.
AGENT_KEYS      := \
    $(SSH_KEYS_DIR)/key_$(DOMAIN)_ansible \
    $(SSH_KEYS_DIR)/key_$(DOMAIN)_bes \
    $(SSH_KEYS_DIR)/key_$(DOMAIN)_emergency_root

# Обёртка для всех remote-стадий: сначала подцепляет SSH_AUTH_SOCK из
# .agent.env, потом запускает ansible-playbook. `.ONESHELL` + single shell:
# `. ./$(AGENT_ENV)` экспортирует переменные на оставшуюся часть recipe.
PLAY            := . ./$(AGENT_ENV) && ansible-playbook -i inventory/hosts.yml

# Экспортируем переменные в окружение дочерних процессов (scripts/*.sh
# читают их как обычные $AGENT_ENV / $AGENT_KEYS).
export AGENT_ENV
export AGENT_KEYS

# =============================================================================
# .PHONY (цели, не соответствующие реальным файлам)
# =============================================================================
.PHONY: agent-up agent-down agent-status \
        stage-0 stage-1b stage-1 stage-2 stage-3 stage-4 \
        stage-5a stage-5b stage-5c stage-6 \
        full-deploy docker-install \
        vault-encrypt vault-create vault-edit vault-view \
        init-ansible galaxy-install syntax-check inventory-graph help
