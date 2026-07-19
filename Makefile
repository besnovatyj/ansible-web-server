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
# Цели-плейбуки
# =============================================================================
# Правило именования: цель = имя плейбука без .yml. Номер = позиция в порядке
# запуска (шаг 10 оставляет место для вставки новых этапов без перенумерации).
# `verify` без номера — не этап, а повторяемая проверка (запускается когда
# угодно). Префикс `optional-` = резерв: не входит в комбинированные цели и в
# syntax-check (имеет право быть нерабочим).
10-local-init:  ## Локально: SSH-ключи + known_hosts (агент не нужен — ключей ещё нет)
	ansible-playbook -i inventory/hosts.yml playbooks/10-local-init.yml

20-bootstrap-access: agent-up ## Bootstrap: юзеры + ключи по паролю root (ЕДИНСТВЕННЫЙ заход по паролю; нужен sshpass)
	$(PLAY) playbooks/20-bootstrap-access.yml

30-server-base: agent-up ## ОС: apt, locales, swap, systemd
	$(PLAY) playbooks/30-server-base.yml

40-server-access: agent-up ## Доступ: journald для SSH, verify входов root + server_users (тест SSH)
	$(PLAY) playbooks/40-server-access.yml

50-server-security: agent-up ## Безопасность: UFW, sshd hardening, unattended-upgrades, fail2ban
	$(PLAY) playbooks/50-server-security.yml

60-webserver: agent-up ## LEMP: Redis, Memcached, MySQL, Nginx, PHP + composer, app_secrets
	$(PLAY) playbooks/60-webserver.yml

70-release: agent-up ## Релиз приложения из GitHub: git + composer install + init (после 60-webserver)
	$(PLAY) playbooks/70-release.yml

70-release-db: agent-up ## Релиз + импорт дампа БД из mysql_dump/dump.sql (РАЗРУШИТЕЛЬНО: перезаписывает БД)
	$(PLAY) playbooks/70-release.yml -e release_import_db=true

80-certbot: agent-up ## Certbot (после 60-webserver + настройки DNS)
	$(PLAY) playbooks/80-certbot.yml

80-certbot-staging: agent-up ## Certbot против STAGING CA (отладка DNS/пайплайна, сертификат недоверенный)
	$(PLAY) playbooks/80-certbot.yml -e certbot_staging=true

80-certbot-force: agent-up ## Certbot: принудительный перевыпуск (боевой запуск ПОСЛЕ staging-теста)
	$(PLAY) playbooks/80-certbot.yml -e certbot_force_renewal=true

90-queue: agent-up ## Queue workers (только после 70-release — нужны исходники на сервере)
	$(PLAY) playbooks/90-queue.yml

verify: agent-up ## Комплексная проверка сервера (повторяемая, запускается в любой момент)
	$(PLAY) playbooks/verify.yml

optional-data-transfer: agent-up ## (РЕЗЕРВ) rsync-деплой исходников вместо 70-release
	$(PLAY) playbooks/optional-data-transfer.yml

optional-docker: agent-up ## (РЕЗЕРВ) Установка Docker
	$(PLAY) playbooks/optional-docker.yml

# =============================================================================
# Комбинированные цели (фазы жизненного цикла)
# =============================================================================
# provision — настройка чистого сервера, обычно запускается ЦЕЛИКОМ.
# Порядок: bootstrap (20) — ПЕРВЫЙ remote-заход; после него Ansible ходит
# automation-пользователем по ключу. agent-up каждая цель зацепит сама —
# ssh-add ключей произойдёт один раз (повторные вызовы no-op).
provision: 10-local-init 20-bootstrap-access 30-server-base 40-server-access 50-server-security 60-webserver verify

# deploy — первый вывод приложения (код → TLS → очереди → проверка).
# В отличие от provision чаще запускается ПО ШАГАМ: 70-release — многократно
# (каждая выкладка), 80-certbot — единожды/редко, 90-queue — после release.
# Комбинированная цель фиксирует канонический порядок первого прогона.
deploy: 70-release 80-certbot 90-queue verify

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
# optional-*.yml намеренно вне проверки: резервные плейбуки имеют право быть
# нерабочими, пока не используются.
syntax-check:
	@for f in playbooks/[0-9]*.yml playbooks/verify.yml; do \
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
