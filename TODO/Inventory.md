# Руководство по файлу `hosts.yml` в директории `inventory`

Этот документ описывает структуру и использование файла `hosts.yml` в директории `inventory/` для Ansible. Он служит
справочником для определения хостов, групп и параметров подключения, чтобы управлять серверами с помощью Ansible.

## Назначение файла `hosts.yml`

Файл `hosts.yml` — это основной файл инвентаризации Ansible. Он определяет:

- **Хосты**: Отдельные серверы или машины, которыми нужно управлять.
- **Группы**: Логические группы хостов (например, `webservers` для веб-серверов или `dbservers` для баз данных).
- **Параметры подключения**: Детали, такие как IP-адреса, пользователи SSH, порты и методы аутентификации.
- **Переменные**: Специфичные для хостов или групп переменные для настройки выполнения плейбуков.

Ansible автоматически загружает `hosts.yml` из директории `inventory/`, если используется стандартная структура проекта,
что избавляет от необходимости указывать `inventory = ./inventory/` в `ansible.cfg`.

## Структура файла `hosts.yml`

Файл `hosts.yml` использует формат YAML и имеет иерархическую структуру. Вот общий пример с пояснениями:

```yaml
---
all:
    vars:
        ansible_connection: ssh
        ansible_port: 22
        default_timezone: UTC
    children:
        webservers:
            hosts:
                web1:
                    ansible_host: 192.168.1.101
                    ansible_user: admin
                    ansible_ssh_private_key_file: /path/to/ssh_keys/id_web1
                web2:
                    ansible_host: 192.168.1.102
                    ansible_user: admin
                    ansible_ssh_private_key_file: /path/to/ssh_keys/id_web2
            vars:
                web_root: /var/www/html
                nginx_port: 80
        dbservers:
            hosts:
                db1:
                    ansible_host: 192.168.1.201
                    ansible_user: dbadmin
                    ansible_ssh_private_key_file: /path/to/ssh_keys/id_db1
            vars:
                mysql_version: 8.0
                db_backup_dir: /var/backups/mysql
        staging:
            hosts:
                stage1:
                    ansible_host: 192.168.2.101
                    ansible_user: stageuser
                    ansible_ssh_private_key_file: /path/to/ssh_keys/id_stage1
            vars:
                environment: staging
```

### Разбор структуры

1. **`all`**:
    - Корневая группа, включающая **все хосты** в inventory. Все группы и хосты автоматически входят в `all`.
    - Используется для задания глобальных переменных, которые применяются ко всем хостам, если не переопределены.
    - **Пример**:
      ```yaml
      all:
        vars:
          default_timezone: UTC
      ```
      Переменная `default_timezone` будет доступна всем хостам.

2. **`vars`**:
    - Определяет переменные на уровне группы или хоста.
    - Может быть указано на уровне `all`, конкретной группы (например, `webservers`) или хоста (например, `web1`).
    - **Пример**: `nginx_port: 80` в группе `webservers` задаёт порт для всех веб-серверов.

3. **`children`**:
    - Определяет подгруппы внутри группы (например, `webservers`, `dbservers` внутри `all`).
    - Позволяет создавать иерархию групп для логической организации.
    - **Пример**: Хосты в группе `webservers` наследуют переменные из `all` и `webservers`.

4. **`hosts`**:
    - Список конкретных хостов в группе.
    - Каждый хост имеет уникальное имя (алиас, например, `web1`), которое используется в плейбуках.
    - Для каждого хоста указываются параметры подключения:
        - `ansible_host`: IP-адрес или DNS-имя сервера.
        - `ansible_user`: Пользователь для SSH-подключения.
        - `ansible_port`: Порт SSH (по умолчанию 22).
        - `ansible_connection`: Тип соединения (обычно `ssh`, но может быть `docker`, `winrm` и т.д.).
        - `ansible_ssh_private_key_file`: Путь к файлу SSH-ключа.
        - `ansible_password`: Пароль для SSH (не рекомендуется, лучше использовать ключи или Ansible Vault).
    - **Пример**:
      ```yaml
      web1:
        ansible_host: 192.168.1.101
        ansible_user: admin
      ```

5. **Группы групп**:
    - Можно создавать группы, включающие другие группы:
      ```yaml
      all:
        children:
          prod:
            children:
              webservers:
                hosts:
                  web1: { ansible_host: 192.168.1.101 }
              dbservers:
                hosts:
                  db1: { ansible_host: 192.168.1.201 }
      ```
      Здесь `prod` — это группа, включающая `webservers` и `dbservers`.

## Где и что указывать

### Обязательные параметры

- **Имя хоста**: Уникальный алиас (например, `web1`), используемый в плейбуках.
- **ansible_host**: IP-адрес или DNS-имя сервера.
- **ansible_user**: Пользователь для подключения (например, `admin`, `root`).
- **ansible_connection**: Обычно `ssh` для Linux-серверов.

### Рекомендуемые параметры

- **ansible_ssh_private_key_file**: Путь к SSH-ключу. Храните ключи в безопасном месте (например, на защищённом носителе
  или в Ansible Vault).
- **ansible_port**: Указывайте, если SSH-порт отличается от 22.
- **vars**: Задавайте переменные на уровне группы или хоста для настройки (например, пути, версии ПО).

### Необязательные параметры

- **ansible_password**: Используйте только для временных тестов или если ключи недоступны. Лучше хранить в зашифрованном
  виде с Ansible Vault.
- **ansible_become**: Укажите `true`, если задачи требуют повышения привилегий (sudo).
- **ansible_become_user**: Пользователь для `become` (по умолчанию `root`).
- **ansible_become_method**: Метод повышения привилегий (обычно `sudo`).

### Где хранить переменные

- **В `hosts.yml`**: Указывайте только параметры подключения (`ansible_host`, `ansible_user`) и минимальные переменные,
  специфичные для хоста или группы.
- **В `group_vars/`**: Храните общие переменные для групп (например, `group_vars/webservers.yml`).
- **В `host_vars/`**: Храните переменные для конкретных хостов (например, `host_vars/web1.yml`).
- **В Ansible Vault**: Храните чувствительные данные (пароли, ключи) в зашифрованных файлах, например,
  `group_vars/webservers/secrets.yml`.

## Рекомендации по использованию

1. **Используйте SSH-ключи**:
    - Вместо `ansible_password` указывайте `ansible_ssh_private_key_file`. Это безопаснее.
    - Пример:
      ```yaml
      ansible_ssh_private_key_file: /path/to/ssh_keys/id_web1
      ```

2. **Избегайте паролей в `hosts.yml`**:
    - Хранение паролей (например, `ansible_password: secret`) небезопасно. Используйте Ansible Vault:
      ```yaml
      # group_vars/webservers/secrets.yml
      ansible_password: "{{ vault_ansible_password }}"
      ```
      Укажите путь к файлу пароля Vault в `ansible.cfg`:
      ```ini
      [defaults]
      vault_password_file = ./vaults/vault_pass.txt
      ```

3. **Организуйте группы логически**:
    - Создавайте группы по функциональности (например, `webservers`, `dbservers`) или среде (`prod`, `staging`).
    - Используйте иерархию для упрощения управления:
      ```yaml
      all:
        children:
          prod:
            children:
              webservers: ...
          staging:
            children:
              webservers: ...
      ```

4. **Минимизируйте переменные в `hosts.yml`**:
    - Переносите сложные переменные в `group_vars/` или `host_vars/` для лучшей читаемости.
    - Пример: Вместо задания `web_root` в `hosts.yml`, поместите его в `group_vars/webservers.yml`.

5. **Проверяйте inventory**:
    - Используйте команду для проверки структуры:
      ```bash
      ansible-inventory --list
      ```
    - Это покажет группы, хосты и подхваченные переменные.

6. **Стандартная структура**:
    - Храните `hosts.yml` в `inventory/hosts.yml`, так как это дефолтный путь для Ansible.
    - Создайте `inventory/group_vars/` и `inventory/host_vars/` для переменных:
      ```
      inventory/
      ├── hosts.yml
      ├── group_vars/
      │   ├── all.yml
      │   ├── webservers.yml
      │   ├── dbservers.yml
      │   └── secrets.yml  # Зашифрованные данные
      ├── host_vars/
      │   ├── web1.yml
      │   └── db1.yml
      ```

## Пример использования в плейбуке

```yaml
---
-   hosts: webservers
    roles:
        - nginx
        - php
-   hosts: dbservers
    roles:
        - mysql
```

Этот плейбук применит роли `nginx` и `php` к хостам `web1` и `web2`, а роль `mysql` — к `db1`. Переменные из
`group_vars/webservers.yml` и `group_vars/dbservers.yml` будут автоматически загружены.

## Полезные команды

- Проверка inventory:
  ```bash
  ansible-inventory --list
  ```
- Проверка подключения к хостам:
  ```bash
  ansible all -m ping
  ```
- Проверка переменных для хоста:
  ```bash
  ansible -m debug -a "var=web_root" web1
  ```
- Тестовый запуск плейбука:
  ```bash
  ansible-playbook playbooks/site.yml --check
  ```

## Замечания по безопасности

- **Не храните пароли в открытом виде**: Используйте Ansible Vault для секретов.
- **Ограничьте доступ к ключам**: Храните SSH-ключи в безопасной директории с правами `600`.
- **Используйте `become` для повышения привилегий**: Настройте `ansible_become: true` и `ansible_become_user: root` в
  `hosts.yml` или `group_vars`.

## Дополнительные ресурсы

- [Официальная документация Ansible: Inventory](https://docs.ansible.com/ansible/latest/user_guide/intro_inventory.html)
- [Best Practices для инвентаризации](https://docs.ansible.com/ansible/latest/user_guide/playbooks_best_practices.html)
- [Ansible Vault для защиты данных](https://docs.ansible.com/ansible/latest/user_guide/vault.html)
