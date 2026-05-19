include environments.sh
SHELL := /bin/bash
# Директива .ONESHELL: указывает make выполнять все команды в рецепте одной цели в одной оболочке, а не в отдельных оболочках для каждой строки. По умолчанию каждая строка в рецепте Makefile выполняется в новой сессии оболочки, из-за чего переменные окружения, установленные в одной строке, не сохраняются для следующей.
# TODO - Кажется, в разрезе использования Makefile из под wsl2 всё равно не актуально
.ONESHELL:
# Уровни логирования `-v`, `-vv`, `-vvv`, `-vvvv`,

# =============================================================================
# Stage-цели
# =============================================================================
stage-0:  ## Локально: SSH-ключи + known_hosts
	ansible-playbook -i inventory/hosts.yml playbooks/stage-0-local-init.yml

stage-1b: ## Bootstrap: юзеры + ключи по паролю root (ЕДИНСТВЕННЫЙ заход по паролю; нужен sshpass)
	ansible-playbook -i inventory/hosts.yml playbooks/stage-1b-bootstrap-keys.yml

stage-1:  ## ОС: apt, locales, swap, systemd
	ansible-playbook -i inventory/hosts.yml playbooks/stage-1-server-base.yml

stage-2:  ## Доступ: sudo user, деплой ключей, journald, verify (тест SSH)
	ansible-playbook -i inventory/hosts.yml playbooks/stage-2-server-access.yml

stage-3:  ## Безопасность: UFW, sshd hardening, fail2ban
	ansible-playbook -i inventory/hosts.yml playbooks/stage-3-server-security.yml

stage-4:  ## LEMP: Redis, Memcached, MySQL, Nginx, PHP
	ansible-playbook -i inventory/hosts.yml playbooks/stage-4-webserver.yml

stage-5a: ## Certbot (только после Stage 4 + настройки DNS)
	ansible-playbook -i inventory/hosts.yml playbooks/stage-5a-certbot.yml

stage-5b: ## Queue workers (только после деплоя исходников)
	ansible-playbook -i inventory/hosts.yml playbooks/stage-5b-queue.yml

stage-5c: ## (РЕЗЕРВ) data_transfer
	ansible-playbook -i inventory/hosts.yml playbooks/stage-5c-data-transfer.yml

stage-6:  ## Verification
	ansible-playbook -i inventory/hosts.yml playbooks/stage-6-verification.yml

docker-install: ## (РЕЗЕРВ) Установка Docker
	ansible-playbook -i inventory/hosts.yml playbooks/optional-docker.yml

# =============================================================================
# Комбинированные цели
# =============================================================================
# Порядок: bootstrap (stage-1b) — ПЕРВЫЙ remote-заход; после него Ansible
# ходит automation-пользователем по ключу.
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
