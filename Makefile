include environments.sh
SHELL := /bin/bash
# Директива .ONESHELL: указывает make выполнять все команды в рецепте одной цели в одной оболочке, а не в отдельных оболочках для каждой строки. По умолчанию каждая строка в рецепте Makefile выполняется в новой сессии оболочки, из-за чего переменные окружения, установленные в одной строке, не сохраняются для следующей.
# TODO - Кажется, в разрезе использования Makefile из под wsl2 всё равно не актуально
.ONESHELL:
# Уровни логирования `-v`, `-vv`, `-vvv`, `-vvvv`,

# =============================================================================
# ssh-agent (для passphrase-ключей: bes, emergency_root)
# =============================================================================
# Зачем: Ansible не умеет вводить passphrase у ssh-ключей. Раньше это
# обходилось ролью verify_authorized_key (косвенная проверка через fingerprint
# в authorized_keys + shell-разбор sshd -T). Теперь — ssh-agent: один раз за
# сессию подписки `make agent-up` спрашивает passphrase, кладёт разлоченные
# ключи в свой кэш; ansible-playbook видит сокет через SSH_AUTH_SOCK и
# использует агента для подписи.
#
# Состояние агента живёт в $(AGENT_ENV) рядом с Makefile (в .gitignore). Каждая
# stage-цель сама делает `. ./$(AGENT_ENV) && ansible-playbook ...` через
# обёртку $(PLAY) — иначе make запускает каждую строку рецепта в свежей shell
# и SSH_AUTH_SOCK теряется. Stage-0 (локально) и stage-1b (bootstrap по
# паролю root) от агента не зависят.
#
# Список ключей в $(AGENT_KEYS) держим на уровне Makefile, не из инвентаря:
# чтение ansible-inventory в каждом рецепте дорого и хрупко (yaml + vault).
# Стоимость синхронизации с group_vars/all/ssh.yml: один список из двух
# путей. domain_name дублирован сюда же как DOMAIN.
DOMAIN          := bes-v.ru
SSH_KEYS_DIR    := $(HOME)/.ssh/$(DOMAIN)
AGENT_ENV       := .agent.env
# Только ключи с passphrase. automation-ключ (`ansible`) — без passphrase, в
# Phase 1 ему агент не нужен; Phase 2 (passphrase для ansible) добавит его сюда.
AGENT_KEYS      := \
    $(SSH_KEYS_DIR)/key_$(DOMAIN)_bes \
    $(SSH_KEYS_DIR)/key_$(DOMAIN)_emergency_root

# Обёртка для всех remote-стадий: сначала подцепляет SSH_AUTH_SOCK из
# .agent.env, потом запускает ansible-playbook. `.ONESHELL` + single shell:
# `. ./$(AGENT_ENV)` экспортирует переменные на оставшуюся часть recipe.
PLAY            := . ./$(AGENT_ENV) && ansible-playbook -i inventory/hosts.yml

.PHONY: agent-up agent-down agent-status \
        stage-0 stage-1b stage-1 stage-2 stage-3 stage-4 \
        stage-5a stage-5b stage-5c stage-6 \
        full-deploy docker-install \
        vault-encrypt vault-create vault-edit vault-view \
        init-ansible galaxy-install syntax-check inventory-graph help

agent-up: ## Поднять ssh-agent и зарядить ключи с passphrase (prompt 1 раз/сессию)
	@set -e
	# Переиспользуем существующий агент, если он жив.
	if [ -f $(AGENT_ENV) ]; then
	    . ./$(AGENT_ENV)
	    if [ -n "$$SSH_AGENT_PID" ] && kill -0 $$SSH_AGENT_PID 2>/dev/null && [ -S "$$SSH_AUTH_SOCK" ]; then
	        : # агент жив — ничего не делаем
	    else
	        echo "ssh-agent из $(AGENT_ENV) мёртв — пересоздаю"
	        rm -f $(AGENT_ENV)
	    fi
	fi
	if [ ! -f $(AGENT_ENV) ]; then
	    # ssh-agent -s печатает в Bourne-формате:
	    #   SSH_AUTH_SOCK=/tmp/.../agent.PID; export SSH_AUTH_SOCK;
	    #   SSH_AGENT_PID=PID; export SSH_AGENT_PID;
	    #   echo Agent pid PID;
	    # Сохраняем как есть, только убираем итоговый `echo` (он не нужен при
	    # source-инге). Сами `export VAR;` критичны — без export ansible-
	    # playbook (дочерний процесс) не увидит SSH_AUTH_SOCK.
	    ssh-agent -s | grep -v '^echo ' > $(AGENT_ENV)
	    echo "ssh-agent поднят, env → $(AGENT_ENV)"
	fi
	. ./$(AGENT_ENV)
	loaded="$$(ssh-add -l 2>/dev/null || true)"
	for k in $(AGENT_KEYS); do
	    if [ ! -f "$$k.pub" ]; then
	        echo "FAIL: $$k.pub не найден — сгенерируйте ключи (make stage-0)"
	        exit 1
	    fi
	    fp="$$(ssh-keygen -lf $$k.pub | awk '{print $$2}')"
	    if echo "$$loaded" | grep -qF "$$fp"; then
	        echo "ssh-agent: $$k уже загружен"
	    else
	        echo "ssh-add $$k:"
	        ssh-add $$k
	    fi
	done

agent-down: ## Остановить ssh-agent и удалить $(AGENT_ENV)
	@set -e
	if [ -f $(AGENT_ENV) ]; then
	    . ./$(AGENT_ENV) && ssh-agent -k >/dev/null 2>&1 || true
	    rm -f $(AGENT_ENV)
	    echo "ssh-agent остановлен"
	fi

agent-status: ## Показать состояние агента и список загруженных ключей
	@if [ ! -f $(AGENT_ENV) ]; then
	    echo "$(AGENT_ENV) нет — agent не запускался в этом проекте"
	    exit 0
	fi
	. ./$(AGENT_ENV)
	echo "SSH_AUTH_SOCK=$$SSH_AUTH_SOCK"
	echo "SSH_AGENT_PID=$$SSH_AGENT_PID"
	if [ -S "$$SSH_AUTH_SOCK" ] && kill -0 $$SSH_AGENT_PID 2>/dev/null; then
	    echo "Состояние: жив"
	    ssh-add -l
	else
	    echo "Состояние: МЁРТВ (выполните 'make agent-up')"
	fi

# =============================================================================
# Stage-цели
# =============================================================================
stage-0:  ## Локально: SSH-ключи + known_hosts (агент не нужен)
	ansible-playbook -i inventory/hosts.yml playbooks/stage-0-local-init.yml

stage-1b: ## Bootstrap: юзеры + ключи по паролю root (ЕДИНСТВЕННЫЙ заход по паролю; нужен sshpass)
	ansible-playbook -i inventory/hosts.yml playbooks/stage-1b-bootstrap-keys.yml

stage-1: agent-up ## ОС: apt, locales, swap, systemd
	$(PLAY) playbooks/stage-1-server-base.yml

stage-2: agent-up ## Доступ: sudo user, деплой ключей, journald, verify (тест SSH)
	$(PLAY) playbooks/stage-2-server-access.yml

stage-3: agent-up ## Безопасность: UFW, sshd hardening, fail2ban
	$(PLAY) playbooks/stage-3-server-security.yml

stage-4: agent-up ## LEMP: Redis, Memcached, MySQL, Nginx, PHP
	$(PLAY) playbooks/stage-4-webserver.yml

stage-5a: agent-up ## Certbot (только после Stage 4 + настройки DNS)
	$(PLAY) playbooks/stage-5a-certbot.yml

stage-5b: agent-up ## Queue workers (только после деплоя исходников)
	$(PLAY) playbooks/stage-5b-queue.yml

stage-5c: agent-up ## (РЕЗЕРВ) data_transfer
	$(PLAY) playbooks/stage-5c-data-transfer.yml

stage-6: agent-up ## Verification
	$(PLAY) playbooks/stage-6-verification.yml

docker-install: agent-up ## (РЕЗЕРВ) Установка Docker
	$(PLAY) playbooks/optional-docker.yml

# =============================================================================
# Комбинированные цели
# =============================================================================
# Порядок: bootstrap (stage-1b) — ПЕРВЫЙ remote-заход; после него Ansible
# ходит automation-пользователем по ключу. agent-up каждый stage-* зацепит
# сам — ssh-add ключей произойдёт один раз (повторные вызовы no-op).
full-deploy: stage-0 stage-1b stage-1 stage-2 stage-3 stage-4 stage-6

# =============================================================================
# Vault
# =============================================================================
vault-encrypt: # Шифрует из файла в Ansible Vault
	ansible-vault encrypt ./secrets/secrets.yml --output ./inventory/group_vars/all/secrets
vault-create: # Создание хранилища Ansible Vault
	ansible-vault create ./inventory/group_vars/all/secrets
vault-edit: # Редактирование данных в хранилище Ansible Vault
	ansible-vault edit ./inventory/group_vars/all/secrets
vault-view: # Просмотр данных в хранилище Ansible Vault
	ansible-vault view ./inventory/group_vars/all/secrets

# =============================================================================
# Инициализация контроллера
# =============================================================================
init-ansible:
	sudo apt update
	sudo apt install -y ansible-core python3-pexpect nano sshpass
	sudo ansible-galaxy collection install community.mysql --upgrade
	sudo update-alternatives --set editor /bin/nano # Устанавливает nano редактором по-умолчанию для всей системы.

galaxy-install:
	ansible-galaxy collection install community.mysql community.crypto

# =============================================================================
# Утилиты
# =============================================================================
syntax-check:
	@for f in playbooks/stage-*.yml; do \
		echo "Checking $$f..."; \
		ansible-playbook -i inventory/hosts.yml $$f --syntax-check -vvvv; \
	done

# Выводит иерархию групп и хостов в виде текстового дерева
inventory-graph:
	ansible-inventory -i inventory/hosts.yml --graph -vvvv

help:  ## Показать список команд
	@grep -E '^[a-zA-Z0-9_-]+:.*?##' $(MAKEFILE_LIST) | sort \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-18s\033[0m %s\n", $$1, $$2}'

# =============================================================================
# Для справки
# =============================================================================
#demo:
# dry-run. Симуляция выполнения, требуется подключение
	#ansible-playbook playbooks/00000000.yml --check -vvvv
# Выводит полную структуру в формате JSON, включая переменные и метаданные, что более подходит для программной обработки или детального анализа.
	#ansible-inventory --list -vvvv

.DEFAULT_GOAL := help
