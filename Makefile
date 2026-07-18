include .env             # ← проектные настройки, правьте под свой проект (DOMAIN и т.д.)
include environments.mk  # инфра make-конфига: paths, exports, .PHONY
SHELL := /bin/bash
# .ONESHELL: - все строки одного рецепта в одной shell сессии (по умолчанию каждая строка в новой сессии). Если надо задать переменную окружения в первой команде рецепта и чтобы она была доступна во второй команде рецепта.
# TODO - Кажется, в разрезе использования Makefile из под wsl2 всё равно не актуально
.ONESHELL:
# Уровни логирования `-v`, `-vv`, `-vvv`, `-vvvv`,

# =============================================================================
# ssh-agent (логика в scripts/agent-*.sh; переменные/архитектура — environments.mk)
# =============================================================================
agent-up: ## Поднять ssh-agent и зарядить ключи с passphrase (prompt 1 раз/сессию)
	@bash scripts/agent-up.sh

agent-down: ## Остановить ssh-agent и удалить $(AGENT_ENV)
	@bash scripts/agent-down.sh

agent-status: ## Показать состояние агента и список загруженных ключей
	@bash scripts/agent-status.sh

# =============================================================================
# Stage-цели
# =============================================================================
stage-0:  ## Локально: SSH-ключи + known_hosts (агент не нужен — ключей ещё нет)
	ansible-playbook -i inventory/hosts.yml playbooks/stage-0-local-init.yml

stage-1b: agent-up ## Bootstrap: юзеры + ключи по паролю root (ЕДИНСТВЕННЫЙ заход по паролю; нужен sshpass)
	$(PLAY) playbooks/stage-1b-bootstrap-keys.yml

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

stage-5a-staging: agent-up ## Certbot против STAGING CA (отладка DNS/пайплайна, сертификат недоверенный)
	$(PLAY) playbooks/stage-5a-certbot.yml -e certbot_staging=true

stage-5a-force: agent-up ## Certbot: принудительный перевыпуск (боевой запуск ПОСЛЕ staging-теста)
	$(PLAY) playbooks/stage-5a-certbot.yml -e certbot_force_renewal=true

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
