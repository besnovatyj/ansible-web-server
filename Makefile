include environments.sh
SHELL := /bin/bash
# Директива .ONESHELL: указывает make выполнять все команды в рецепте одной цели в одной оболочке, а не в отдельных оболочках для каждой строки. По умолчанию каждая строка в рецепте Makefile выполняется в новой сессии оболочки, из-за чего переменные окружения, установленные в одной строке, не сохраняются для следующей.
.ONESHELL:
# Уровни логирования `-v`, `-vv`, `-vvv`, `-vvvv`,

# =============================================================================
# Все команды в куче.
# =============================================================================
local-init:
	ansible-playbook playbooks/local-init.yml #-vv

remote-base:
	ansible-playbook -i inventory/hosts.yml playbooks/remote-base.yml #-vv

remote-webserver:
	ansible-playbook -i inventory/hosts.yml playbooks/remote-webserver.yml #-vv

full-deploy: local-init remote-base remote-webserver

remote-transfer-data:
	ansible-playbook -i inventory/hosts.yml playbooks/transfer-data.yml -v

remote-queue-configure:
	ansible-playbook -i inventory/hosts.yml playbooks/queue-configure.yml -v

remote-test:
	ansible-playbook -i inventory/hosts.yml playbooks/test-server.yml -v

remote-security:
	ansible-playbook -i inventory/hosts.yml playbooks/remote-security.yml -v

remote-test-security:
	ansible-playbook -i inventory/hosts.yml playbooks/remote-test-security.yml -v

# =============================================================================
# Команды шифрования
# =============================================================================
vault-encrypt: # Шифрует из файла в Ansible Vault
	ansible-vault encrypt ./group_vars/all/secrets.yml --output ./group_vars/all/secrets.vault
vault-create: # Создание хранилища Ansible Vault
	ansible-vault create ./group_vars/all/secrets.vault
vault-edit: # Редактирование данных в хранилище Ansible Vault
	ansible-vault edit ./group_vars/all/secrets.vault
vault-view: # Просмотр данных в хранилище Ansible Vault
	ansible-vault view ./group_vars/all/secrets.vault

# =============================================================================
# Глобальные настройки перед работой с Ansible
# =============================================================================
init-ansible-and-other:
	sudo apt update
	sudo apt install -y ansible-core
	sudo apt install -y nano
	sudo apt install -y python3-pexpect
	sudo update-alternatives --set editor /bin/nano # Устанавливает nano редактором по-умолчанию для всей системы.

galaxy-mysql-crypto:
	ansible-galaxy collection install community.mysql
	ansible-galaxy collection install community.crypto

# =============================================================================
# Образцы команд проверки
# =============================================================================
syntax-check:
# Проверка синтаксиса
	ansible-playbook playbooks/00000000.yml --syntax-check -vvvv
# dry-run. Симуляция выполнения, требуется подключение
	ansible-playbook playbooks/00000000.yml --check -vvvv
# Выводит иерархию групп и хостов в виде текстового дерева, удобного для визуального восприятия.
	ansible-inventory --graph -vvvv
# Выводит полную структуру в формате JSON, включая переменные и метаданные, что более подходит для программной обработки или детального анализа.
	ansible-inventory --list -vvvv
