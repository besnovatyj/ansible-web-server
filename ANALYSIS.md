# Анализ и план реструктуризации Ansible-проекта

> Дата анализа: 2026-05-07
> Проект: LEMP-стек (Nginx, PHP 8.4, MySQL, Redis, Memcached) на Ubuntu 24.04 LTS, 2 GB RAM

---

## Содержание

1. [Введение](#1-введение)
2. [Текущая архитектура](#2-текущая-архитектура)
3. [Обнаруженные проблемы](#3-обнаруженные-проблемы)
    - 3.1 [SSH и аутентификация (КРИТИЧНО)](#31-ssh-и-аутентификация-критично)
    - 3.2 [Безопасность](#32-безопасность)
    - 3.3 [Архитектура плейбуков и переменных](#33-архитектура-плейбуков-и-переменных)
    - 3.4 [Незавершённые компоненты](#34-незавершённые-компоненты)
4. [Решение проблемы SSH с passphrase](#4-решение-проблемы-ssh-с-passphrase)
5. [Предлагаемая архитектура](#5-предлагаемая-архитектура)
    - 5.1 [Новая структура каталогов](#51-новая-структура-каталогов)
    - 5.2 [Этапы развёртывания (Stages)](#52-этапы-развёртывания-stages)
    - 5.3 [Разделение переменных](#53-разделение-переменных)
    - 5.4 [Обновлённый Makefile](#54-обновлённый-makefile)
6. [Исправления безопасности](#6-исправления-безопасности)
7. [Чек-лист миграции](#7-чек-лист-миграции)
8. [Ответы на вопросы из TODO](#8-ответы-на-вопросы-из-todo)

---

## 1. Введение

Данный документ — результат подробного аудита всего Ansible-проекта: каждого файла, шаблона, роли, плейбука и
конфигурации. Цель — выявить проблемы, предложить логичное разделение на независимые процессы и дать конкретный план
реструктуризации.

**Главные боли**, которые решаем:

- Всё намешано в кучу — нет чётких границ между процессами
- Ansible не работает с SSH-ключами с парольной фразой (passphrase)
- Хочется, чтобы каждый этап настройки можно было запускать независимо
- Нужно логическое разделение: базовая настройка, веб-сервер, создание sudo-пользователя, переключение на авторизацию по
  ключу

---

## 2. Текущая архитектура

### 2.1 Дерево файлов

```
ansible/
├── ansible.cfg                         # Конфигурация Ansible
├── environments.sh                     # EDITOR=nano, ANSIBLE_CONFIG
├── Makefile                            # Make-команды
├── inventory/
│   ├── hosts.yml                       # Инвентарь (1 сервер в группе "site")
│   └── hosts.yml.example
├── group_vars/
│   └── global.yml                      # ВСЕ переменные в одном файле (130 строк)
├── secrets/
│   ├── !vault_pass.txt                 # Пароль от vault (gitignored)
│   ├── secrets.yml                     # Секреты незашифрованные (gitignored)
│   └── secrets.vault                   # Зашифрованные секреты
├── playbooks/
│   ├── local-init.yml                  # Генерация SSH-ключей + known_hosts
│   ├── remote-base.yml                 # APT, locales, swap, systemd, UFW, fail2ban
│   ├── remote-security.yml             # Sudo-пользователь, SSH-ключи root, SSH hardening
│   ├── remote-webserver.yml            # Redis, Memcached, MySQL, Nginx, PHP, apt_clean
│   ├── remote-test.yml                 # Тест SSH-подключения
│   └── remote-test-security.yml        # Тест безопасности SSH
├── roles/
│   ├── system/
│   │   ├── apt_update/                 # Обновление пакетов (security only)
│   │   ├── apt_clean/                  # Очистка apt
│   │   ├── locales_hostname_timezone/  # Локали, hostname, timezone
│   │   ├── swap/                       # Создание swap 2 GB
│   │   ├── systemd/                    # Лимиты journald (100M + 50M)
│   │   ├── ufw/                        # Фаервол (22, 80, 443)
│   │   ├── fail2ban/                   # IPS с 11 jail-конфигурациями
│   │   ├── app_armor/                  # MAC-профили для сервисов
│   │   ├── ssh_generate_local_keys/    # Генерация ed25519-ключей (обычный + аварийный)
│   │   ├── ssh_add_remote_host_to_known_hosts/
│   │   ├── ssh_remote_root_keys/       # Деплой ключа на root
│   │   ├── ssh_remote_security/        # Hardening sshd_config
│   │   ├── ssh_logs_journald/          # SSH → journald
│   │   └── user_sudo_add_new/          # Создание sudo-пользователя
│   ├── web-server/
│   │   ├── redis/                      # Redis (127.0.0.1, 128MB, allkeys-lru)
│   │   ├── memcached/                  # Memcached (64MB, localhost)
│   │   ├── mysql/                      # MySQL (install + secure + setup)
│   │   ├── nginx/                      # Nginx (3 server block: frontend, backend, static)
│   │   ├── php/                        # PHP 8.4 (21 модуль, FPM pool, OPcache)
│   │   ├── certbot/                    # Let's Encrypt (закомментирован)
│   │   ├── data_transfer/              # rsync + mysql dump import
│   │   └── queue/systemd/              # Yii2 queue workers
│   └── tests/                          # Тестовые роли
├── logs/
│   └── ansible.log
└── TODO/                               # Документация и заметки
```

### 2.2 Плейбуки и их обязанности

| Плейбук                    | Что делает                        | Подключается как | Роли                                                                            |
|----------------------------|-----------------------------------|------------------|---------------------------------------------------------------------------------|
| `local-init.yml`           | Генерация ключей, known_hosts     | localhost        | ssh_generate_local_keys, ssh_add_remote_host_to_known_hosts                     |
| `remote-base.yml`          | ОС + безопасность (UFW, fail2ban) | root + become    | apt_update, locales_hostname_timezone, swap, systemd, ufw, fail2ban             |
| `remote-security.yml`      | Пользователь + SSH hardening      | root + become    | user_sudo_add_new, ssh_remote_root_keys, ssh_remote_security, ssh_logs_journald |
| `remote-webserver.yml`     | LEMP-стек + очистка               | root             | redis, memcached, mysql, nginx, php, apt_clean                                  |
| `remote-test.yml`          | Тест SSH                          | root             | tests                                                                           |
| `remote-test-security.yml` | Тест SSH с пользователями         | root             | (нет ролей, inline tasks)                                                       |

### 2.3 Makefile workflow

```makefile
full-deploy: local-init remote-base remote-webserver   # <-- remote-security НЕ включён!
```

Другие цели запускаются отдельно: `remote-security`, `remote-test`, `remote-test-security`.

### 2.4 Организация переменных

Все 130 строк переменных находятся в одном файле `group_vars/global.yml`, который подключается через `vars_files` в
каждом плейбуке вручную. Там всё вместе: SSH-настройки, fail2ban jails, PHP-модули, MySQL-пароли, email для Certbot.

---

## 3. Обнаруженные проблемы

### 3.1 SSH и аутентификация (КРИТИЧНО)

#### 3.1.1 Проблема с passphrase

**Файл**: `group_vars/global.yml:28`
**Суть**: Переменная `ssh_key_passphrase` используется для генерации ключей в `ssh_generate_local_keys`. Ansible (через
paramiko или openssh) **не умеет** интерактивно вводить passphrase при подключении. Без запущенного `ssh-agent`
подключение по ключу с passphrase **невозможно**.

Это подтверждается записью в `TODO/000-PLAN.MD:16-18`:
> *"Ansible имеет проблемы с запуском команд при аутентификации по ключу с passphrase"*

#### 3.1.2 Аварийный ключ генерируется, но НЕ деплоится

**Файл**: `roles/system/ssh_remote_root_keys/tasks/main.yml:13`
**Суть**: Задача "Copy SSH public key for root" копирует `ordinary_pubkey_path` (обычный ключ) на root. Аварийный ключ (
`emergency_pubkey_path`) генерируется локально, но **никогда не попадает на сервер**. Весь смысл аварийного ключа
утрачен.

```yaml
# Текущее состояние (БАГИ):
-   name: Copy SSH public key for root
    authorized_key:
        user: root
        key: "{{ lookup('file', ordinary_pubkey_path) }}"   # <-- Должен быть emergency_pubkey_path!
```

#### 3.1.3 Риск полной блокировки сервера (Lockout)

**Файл**: `roles/system/ssh_remote_security/tasks/main.yml`
**Суть**: Роль отключает пароль (`PasswordAuthentication no`) и ограничивает root до ключей (
`PermitRootLogin prohibit-password`), **не проверив** что ключевая аутентификация реально работает. Последовательность:

1. `user_sudo_add_new` — создаёт пользователя, копирует ключ
2. `ssh_remote_root_keys` — копирует ключ root (неправильный!)
3. `ssh_remote_security` — **отключает пароль** ← если шаги 1-2 не сработали = LOCKOUT
4. `ssh_logs_journald` — уже не важно, доступ потерян

Нигде в `remote-security.yml` нет `assert`-задачи, которая бы проверила SSH-подключение по ключу перед отключением
пароля.

#### 3.1.4 Тесты SSH сломаны

**Файл**: `roles/tests/tasks/new_user_ssh.yml`
**Суть**: Используется `wait_for_connection` с `delegate_to: localhost`, что тестирует подключение к **localhost**, а не
к удалённому серверу через SSH с указанным пользователем.

#### 3.1.5 `full-deploy` пропускает настройку безопасности

**Файл**: `Makefile:19`
**Суть**: Цель `full-deploy` запускает `local-init`, `remote-base`, `remote-webserver`, но **не включает**
`remote-security`. После "полного деплоя" сервер остаётся с активной парольной аутентификацией и без SSH hardening.

---

### 3.2 Безопасность

#### 3.2.1 Redis без пароля

**Файл**: `roles/web-server/redis/templates/redis.conf.j2`
**Суть**: В шаблоне конфигурации Redis нет директивы `requirepass`. Redis доступен любому процессу на localhost без
аутентификации. Даже при `bind 127.0.0.1` это создаёт риск lateral movement — любая скомпрометированная служба на
сервере получит полный доступ к Redis.

#### 3.2.2 Права доступа 7777 на директории

**Файл**: `roles/web-server/data_transfer/tasks/main.yml:21`
**Суть**: `mode: '7777'` — это полные права на чтение/запись/исполнение для **всех пользователей** + setuid + setgid +
sticky bit. Любой процесс на сервере может модифицировать веб-файлы. Должно быть максимум `0755` (или `0775` с
правильной группой).

#### 3.2.3 Нет HTTPS-редиректа

**Файл**: `roles/web-server/nginx/templates/site.tmp.j2`
**Суть**: Nginx слушает только порт 80. Нет `return 301 https://$host$request_uri`. Роль Certbot закомментирована во
всех плейбуках. Весь трафик идёт в открытом виде.

#### 3.2.4 AppArmor: опасные deny-правила

**Файл**: `roles/system/app_armor/templates/usr.sbin.nginx.j2:17`
**Суть**: Профили содержат `deny /etc/passwd r`, что ломает `getpwuid()` — стандартный системный вызов при переключении
пользователей (root → www-data). Профили сразу применяются в режиме `enforce` без предварительного тестирования в
`complain`.

#### 3.2.5 PHP: отсутствуют критические настройки безопасности

**Файлы**: `roles/web-server/php/tasks/main.yml`, `roles/web-server/php/files/conf.d/`
**Суть**: Не настроены:

- `disable_functions` — не заблокированы `system`, `exec`, `shell_exec`, `passthru`, `phpinfo`
- `open_basedir` — PHP может читать любые файлы на сервере
- `allow_url_fopen` — разрешён по умолчанию (RFI-вектор)
- OPcache и APCu установлены, но **явно не включены** (нет `opcache.enable=1`, `apcu.enable=1`)

#### 3.2.6 Fail2ban vs PHP-FPM: несовпадение логов

**Файлы**: `roles/web-server/php/tasks/main.yml:61` и `roles/system/fail2ban/templates/jail.local.j2:94`
**Суть**: PHP настроен на логирование в syslog (`error_log = syslog`), но jail `[php-fpm]` ищет логи в файле
`/var/log/php8.4-fpm.log` с `backend = polling`. Файл всегда пуст → fail2ban никогда не обнаружит PHP-атаки.

#### 3.2.7 MySQL: сломана логика удаления remote root

**Файл**: `roles/web-server/mysql/tasks/mysql_secure_installation.yml`
**Суть**: Цикл удаления remote root-аккаунтов использует `when: item != 'localhost'`, но `item` — это словарь
`{ host: "..." }`, а не строка. Условие не работает как ожидается, и опасный аккаунт `root@%` может остаться.

---

### 3.3 Архитектура плейбуков и переменных

#### 3.3.1 `remote_user: root` везде

Все remote-плейбуки подключаются как `root`. Даже после создания sudo-пользователя в `remote-security.yml`, последующие
плейбуки продолжают работать от root. Это:

- Противоречит самой идее создания sudo-пользователя
- Не позволяет протестировать реальный сценарий использования

#### 3.3.2 Нет pre-flight валидации

Ни один плейбук не проверяет, что vault-переменные (`vault_ssh_key_passphrase`, `vault_root_password`,
`vault_mysql_root_password`, `vault_mysql_db_user_password`) определены и не пусты. Если vault не расшифрован или
переменная отсутствует — задачи падают в середине выполнения, оставляя сервер в частично настроенном состоянии.

#### 3.3.3 Смешанные обязанности

- `remote-base.yml` = настройка ОС (locales, swap, systemd) **+** инструменты безопасности (UFW, fail2ban)
- `remote-security.yml` = создание пользователя **+** деплой ключей **+** SSH hardening **+** логирование SSH
- `remote-webserver.yml` = установка LEMP **+** очистка apt

Каждый плейбук делает слишком много разнородных вещей. Если нужно только установить UFW — приходится запускать весь
`remote-base.yml`, который ещё и создаёт swap, и обновляет пакеты.

#### 3.3.4 Монолитный `global.yml`

Все 130 строк переменных в одном файле. При этом файл подключается через `vars_files` вручную в каждом плейбуке, вместо
стандартного `group_vars/all/` (Ansible автоматически загружает файлы из этой директории).

**Проблемы:**

- Редактирование PHP-настроек рискует сломать SSH-конфигурацию (всё в одном файле)
- Нет разделения по зонам ответственности
- При добавлении нового сервера нужно дублировать весь файл

#### 3.3.5 Непоследовательное именование переменных

- `DOMAIN_NAME` — CAPS_SNAKE
- `php-version` — kebab-case (проблема: в Jinja2 дефис — оператор вычитания)
- `new_user` — snake_case
- `banTime` — camelCase
- `jailsEnableStatus` — camelCase

Рекомендуется: единый стиль `snake_case` для всех переменных.

---

### 3.4 Незавершённые компоненты

| Компонент               | Статус                      | Проблема                                                                    |
|-------------------------|-----------------------------|-----------------------------------------------------------------------------|
| **Certbot**             | Роль есть, закомментирована | Нет проверки существования сертификата (rate limit risk)                    |
| **AppArmor**            | Роль есть, закомментирована | Опасные deny-правила, нет режима complain                                   |
| **Docker**              | Плейбук `docker.yml`        | Устаревший: Ubuntu Jammy вместо Noble, Docker Compose 1.25 (актуально 2.x)  |
| **Queue workers**       | Роль `queue/systemd`        | Нет плейбука, хардкод 2 воркеров, нет лимитов ресурсов                      |
| **Data transfer**       | Роль `data_transfer`        | Хардкод путей Windows (`/mnt/a/openserver/...`), `mode: 7777`, нет плейбука |
| **Nginx gzip**          | Не настроен                 | Нет сжатия, трафик передаётся несжатым                                      |
| **Nginx rate limiting** | Не настроен                 | Нет `limit_req_zone`, fail2ban обнаруживает, но не предотвращает            |
| **Backup стратегия**    | Не реализована              | Нет mysqldump, нет бэкапа конфигов, нет off-site хранения                   |
| **Мониторинг**          | Не реализован               | Нет алертинга, нет OOM-защиты, нет проверки диска                           |

---

## 4. Решение проблемы SSH с passphrase

### 4.1 Почему не работает

Ansible использует для SSH-подключений либо библиотеку `paramiko` (Python), либо нативный `openssh`. В обоих случаях:

- **paramiko** не поддерживает интерактивный ввод passphrase
- **openssh** (через `ssh -o ControlMaster`) может использовать passphrase, но **только** если ключ уже загружен в
  `ssh-agent`
- Ansible **не** запускает `ssh-agent` и **не** вводит passphrase автоматически

Итого: если ключ защищён passphrase, а `ssh-agent` не запущен — Ansible не может подключиться.

### 4.2 Рекомендуемая стратегия (из `TODO/000-PLAN.MD`)

Двухфазный подход:

**Фаза A: ключи БЕЗ passphrase**

1. Генерируем SSH-ключи без парольной фразы (`ssh_key_passphrase: ""`)
2. Деплоим ключи на сервер
3. Настраиваем весь сервер (base → access → security → webserver)
4. Тестируем что всё работает

**Фаза B: миграция на passphrase (опционально)**

1. Регенерируем ключи с passphrase
2. Передеплоим публичные ключи
3. Тестируем через `ssh-agent` + `ssh-add`
4. Документируем workflow: перед работой с Ansible всегда запускать `ssh-agent`

### 4.3 Альтернатива: автоматический `ssh-agent`

Можно добавить в `environments.sh` или в Makefile:

```bash
# Запуск ssh-agent если не запущен
if [ -z "$SSH_AUTH_SOCK" ]; then
    eval $(ssh-agent -s)
fi

# Добавление ключа (запросит passphrase один раз)
ssh-add ~/.ssh/key_domain.zone 2>/dev/null
```

Или в `ansible.cfg`:

```ini
[ssh_connection]
ssh_args = -o ControlMaster=auto -o ControlPersist=300s -o ConnectTimeout=30 -o AddKeysToAgent=yes
```

Параметр `AddKeysToAgent=yes` автоматически добавит ключ в агент после первого ввода passphrase.

### 4.4 Хранение ключей в проекте вместо HOME

Из `TODO/000-PLAN.MD:26`:
> *"Подумать об использовании ключа не из HOME директории, так как ключи хочу хранить в проектах, а не глобально"*

**Вариант**: хранить ключи в `ansible/secrets/ssh/`:

```
ansible/secrets/
├── ssh/
│   ├── key_domain.zone              # private key
│   ├── key_domain.zone.pub          # public key
│   ├── key_domain.zone_emergency    # emergency private
│   └── key_domain.zone_emergency.pub
├── !vault_pass.txt
└── secrets.vault
```

Обязательно добавить в `.gitignore`:

```
/secrets/ssh/
```

И обновить переменные:

```yaml
local_ssh_keys_dir: "{{ playbook_dir }}/../secrets/ssh"
```

**Плюсы:** ключи привязаны к проекту, не засоряют `~/.ssh`
**Минусы:** нужно следить за безопасностью директории; при нескольких проектах — ключи разбросаны

---

## 5. Предлагаемая архитектура

### 5.1 Новая структура каталогов

```
ansible/
├── ansible.cfg
├── environments.sh
├── Makefile
├── inventory/
│   ├── hosts.yml
│   └── hosts.yml.example
├── group_vars/
│   └── all/                            # Ansible автоматически загружает всё из all/
│       ├── main.yml                    # Домен, IP, пути, локали, timezone
│       ├── ssh.yml                     # SSH-ключи, пользователи, порты
│       ├── security.yml                # Fail2ban, UFW, AppArmor
│       ├── webserver.yml               # PHP, MySQL, Nginx, Redis, Memcached
│       └── vault.yml                   # Только маппинг vault_* переменных
├── secrets/
│   ├── ssh/                            # SSH-ключи (gitignored)
│   ├── !vault_pass.txt
│   └── secrets.vault
├── playbooks/
│   ├── stage-0-local-init.yml          # Локально: ключи + known_hosts
│   ├── stage-1-server-base.yml         # ОС: apt, locales, swap, systemd
│   ├── stage-2-server-access.yml       # Доступ: sudo user, деплой ключей, ТЕСТ
│   ├── stage-3-server-security.yml     # Безопасность: UFW, fail2ban, SSH hardening
│   ├── stage-4-webserver.yml           # LEMP: Redis, Memcached, MySQL, Nginx, PHP
│   ├── stage-5-webserver-extras.yml    # Extras: Certbot, queue, data transfer
│   ├── stage-6-verification.yml        # Тесты всех сервисов
│   └── stage-7-key-hardening.yml       # Опционально: миграция на passphrase
├── roles/
│   ├── system/                         # Без изменений (существующие роли)
│   ├── web-server/                     # Без изменений (существующие роли)
│   └── verification/                   # Новые роли для тестирования
│       ├── check_ssh/
│       ├── check_services/
│       └── check_security/
├── logs/
└── TODO/
```

**Ключевое изменение**: `group_vars/all/` вместо `group_vars/global.yml`. Ansible автоматически загружает все файлы из
`group_vars/all/` для всех хостов, поэтому **не нужно** указывать `vars_files` в каждом плейбуке. Останется только
`vars_files: [../secrets/secrets.vault]`.

### 5.2 Этапы развёртывания (Stages)

Каждый этап — **самостоятельный**, может быть запущен независимо. Но есть логический порядок зависимостей:

```
Stage 0 (local)  ─→  Stage 1 (OS)  ─→  Stage 2 (access)  ─→  Stage 3 (security)
                                                                      │
                                                               Stage 4 (webserver)
                                                                      │
                                                               Stage 5 (extras)
                                                                      │
                                                               Stage 6 (verification)
                                                                      │
                                                               Stage 7 (key hardening)
```

#### Stage 0: local-init (localhost)

**Цель**: Подготовить локальную машину для работы с сервером.

| # | Роль                                 | Что делает                                                     |
|---|--------------------------------------|----------------------------------------------------------------|
| 1 | `ssh_generate_local_keys`            | Генерация SSH-ключей (ordinary + emergency) **без passphrase** |
| 2 | `ssh_add_remote_host_to_known_hosts` | Добавление ECDSA-отпечатка сервера в known_hosts               |

**assert-проверки:**

- Vault расшифрован и переменные определены
- Ключи созданы и имеют правильные права (0600 / 0644)

---

#### Stage 1: server-base (remote, root)

**Цель**: Базовая настройка ОС. Чистая конфигурация без инструментов безопасности.

| # | Роль                        | Что делает                              |
|---|-----------------------------|-----------------------------------------|
| 1 | `apt_update`                | Обновление security-патчей              |
| 2 | `locales_hostname_timezone` | Локали, hostname, timezone              |
| 3 | `swap`                      | Создание swap (размер через переменную) |
| 4 | `systemd`                   | Лимиты journald                         |

**assert-проверки:**

- Swap активен (`swapon -s`)
- Локаль установлена
- Timezone корректен

---

#### Stage 2: server-access (remote, root)

**Цель**: Настройка пользовательского доступа. **Без отключения пароля!**

| # | Роль                           | Что делает                                                 |
|---|--------------------------------|------------------------------------------------------------|
| 1 | `user_sudo_add_new`            | Создание sudo-пользователя                                 |
| 2 | `ssh_remote_root_keys`         | Деплой **аварийного** ключа на root (ИСПРАВИТЬ!)           |
| 3 | `ssh_remote_user_keys` (новая) | Деплой обычного ключа на sudo-пользователя                 |
| 4 | `ssh_logs_journald`            | Логирование SSH в journald                                 |
| 5 | **assert: test SSH**           | Проверка подключения по ключу для root И sudo-пользователя |

**КРИТИЧНО**: Добавить задачу, которая проверяет SSH-подключение по ключу **до** перехода к Stage 3.

Пример assert-задачи:

```yaml
-   name: Verify SSH key login for new user
    delegate_to: localhost
    command: >
        ssh -i {{ ordinary_key_path }} -o BatchMode=yes -o StrictHostKeyChecking=no
        -p {{ target_ssh_port }} {{ new_user }}@{{ target_host }} "echo OK"
    register: ssh_test
    changed_when: false
    failed_when: "'OK' not in ssh_test.stdout"

-   name: Assert SSH key authentication works
    assert:
        that:
            - ssh_test.rc == 0
        fail_msg: "SSH key authentication FAILED! Do NOT proceed to security hardening."
```

---

#### Stage 3: server-security (remote, root)

**Цель**: Hardening. Запускать **только после** успешного Stage 2.

| # | Роль                      | Что делает                                                  |
|---|---------------------------|-------------------------------------------------------------|
| 1 | **pre-check**             | assert: SSH-ключи работают (повторная проверка)             |
| 2 | `ufw`                     | Фаервол                                                     |
| 3 | `fail2ban`                | IPS (fail2ban sshd jail включать **после** проверки ключей) |
| 4 | `ssh_remote_security`     | Отключение пароля, hardening ciphers/MACs/Kex               |
| 5 | **post-check**            | Проверка что SSH по ключу всё ещё работает после hardening  |
| 6 | `app_armor` (опционально) | MAC-профили в режиме **complain** сначала                   |

**assert-проверки:**

- UFW active
- fail2ban running
- SSH подключение работает после hardening

---

#### Stage 4: webserver (remote, sudo user + become)

**Цель**: Установка LEMP-стека. **Использует sudo-пользователя** вместо root.

| # | Роль        | Что делает                          |
|---|-------------|-------------------------------------|
| 1 | `redis`     | Redis **с паролем** (`requirepass`) |
| 2 | `memcached` | Memcached                           |
| 3 | `mysql`     | MySQL (install + secure + setup)    |
| 4 | `nginx`     | Nginx (3 server block)              |
| 5 | `php`       | PHP 8.4 + модули + FPM pool         |
| 6 | `apt_clean` | Очистка                             |

**assert-проверки:**

- Все сервисы running: redis, memcached, mysql, nginx, php-fpm
- Порты открыты: 80, 443
- PHP-FPM socket существует

---

#### Stage 5: webserver-extras (remote, sudo user + become)

**Цель**: Дополнительные компоненты. Полностью опционален.

| # | Роль            | Что делает                                         |
|---|-----------------|----------------------------------------------------|
| 1 | `certbot`       | SSL-сертификат (с проверкой существования!)        |
| 2 | `queue/systemd` | Queue workers (с лимитами ресурсов)                |
| 3 | `data_transfer` | Синхронизация файлов и БД (с нормальными правами!) |

---

#### Stage 6: verification (remote, sudo user)

**Цель**: Комплексная проверка всего сервера.

- SSH: подключение root (аварийный ключ), подключение sudo user (обычный ключ)
- Сервисы: nginx, php-fpm, mysql, redis, memcached — status, listening ports
- Безопасность: UFW rules, fail2ban jails, sshd_config settings
- Web: HTTP response на порту 80 (и 443 если Certbot)
- PHP: `php -m` — все модули установлены, OPcache/APCu включены

---

#### Stage 7: key-hardening (опционально)

**Цель**: Миграция SSH-ключей на passphrase. Запускать **только после** полной настройки.

1. Регенерация ключей с passphrase (бэкап старых)
2. Деплой новых публичных ключей на сервер
3. Проверка подключения через `ssh-agent`
4. Обновление `environments.sh` с запуском ssh-agent

---

### 5.3 Разделение переменных

Каждый файл из текущего `global.yml` разносится так:

#### `group_vars/all/main.yml`

```yaml
# Основные параметры сервера
domain_name: domain.zone
host_ip: "{{ hostvars[groups['site'][0]]['ansible_host'] }}"
web_root: "/var/www"
locale_primary: ru_RU.UTF-8
locale_secondary: en_US.UTF-8
time_zone: UTC
```

#### `group_vars/all/ssh.yml`

```yaml
# SSH-конфигурация
local_home_path: "{{ lookup('env', 'HOME') }}"
force_key_regen: false
ssh_known_hosts_path: "{{ local_home_path }}/.ssh/known_hosts"
ssh_key_type: "ed25519"
ssh_key_size: 0
ssh_key_passphrase: "{{ vault_ssh_key_passphrase }}"
target_ssh_port: 22

# Пути к ключам
local_ssh_keys_dir: "{{ local_home_path }}/.ssh"
ordinary_key_path: "{{ local_ssh_keys_dir }}/key_{{ domain_name }}"
ordinary_pubkey_path: "{{ ordinary_key_path }}.pub"
emergency_key_path: "{{ local_ssh_keys_dir }}/key_{{ domain_name }}_emergency_root"
emergency_pubkey_path: "{{ emergency_key_path }}.pub"

# Подключение
target_host: "{{ hostvars[groups['site'][0]]['ansible_host'] }}"
target_user: "{{ hostvars[groups['site'][0]]['ansible_user'] }}"
site_ansible_user: root
site_ansible_password: "{{ vault_root_password }}"
site_ansible_key: ~
new_user: "bes"
```

#### `group_vars/all/security.yml`

```yaml
# Fail2ban
ban_time: 3600
find_time: 600
max_retry: 5
jails_enable_status:
    sshd: true
    nginx_http_auth: true
    nginx_limit_req: false
    nginx_botsearch: true
    nginx_bad_request: true
    nginx_forbidden: true
    php_url_fopen: true
    vsftpd: false
    mysqld_auth: false
    traefik_auth: false
    recidive: true
    sendmail_auth: false
    sendmail_reject: false
    php_fpm: false
    redis_auth: false
```

#### `group_vars/all/webserver.yml`

```yaml
# PHP
php_version: "8.4"    # snake_case вместо kebab-case!
php_modules:
    - "php{{ php_version }}-fpm"
    - "php{{ php_version }}-cli"
    # ... все остальные модули

# MySQL
mysql_db_name: mysql_db_name
mysql_db_user: mysql_db_user
mysql_db_user_password: "{{ vault_mysql_db_user_password }}"
mysql_root_password: "{{ vault_mysql_root_password }}"

# Redis
redis_password: "{{ vault_redis_password }}"   # НОВАЯ переменная!

# Certbot
certbot_email: 'name@domain.zone'
```

#### `group_vars/all/vault.yml`

```yaml
# Маппинг vault-переменных (загружаются из secrets.vault)
# Этот файл не содержит значений — только ссылки.
# Все реальные значения хранятся зашифрованными в secrets/secrets.vault
```

> **Примечание**: `vault.yml` в данном случае не нужен как отдельный файл, если vault-переменные (`vault_*`) загружаются
> напрямую через `vars_files: [secrets.vault]`. Но если вы хотите иметь слой маппинга (например,
`redis_password: "{{ vault_redis_password }}"`) — это делается прямо в `webserver.yml`, `ssh.yml` и т.д.

### 5.4 Обновлённый Makefile

```makefile
include environments.sh
SHELL := /bin/bash
.ONESHELL:

# =============================================================================
# Этапы развёртывания (независимые, но логически последовательные)
# =============================================================================

stage-0:  ## Локально: генерация SSH-ключей + known_hosts
	ansible-playbook playbooks/stage-0-local-init.yml

stage-1:  ## ОС: apt, locales, swap, systemd
	ansible-playbook -i inventory/hosts.yml playbooks/stage-1-server-base.yml

stage-2:  ## Доступ: sudo user, деплой ключей, тест SSH
	ansible-playbook -i inventory/hosts.yml playbooks/stage-2-server-access.yml

stage-3:  ## Безопасность: UFW, fail2ban, SSH hardening
	ansible-playbook -i inventory/hosts.yml playbooks/stage-3-server-security.yml

stage-4:  ## LEMP: Redis, Memcached, MySQL, Nginx, PHP
	ansible-playbook -i inventory/hosts.yml playbooks/stage-4-webserver.yml

stage-5:  ## Extras: Certbot, queue workers, data transfer
	ansible-playbook -i inventory/hosts.yml playbooks/stage-5-webserver-extras.yml

stage-6:  ## Проверка: тесты всех сервисов
	ansible-playbook -i inventory/hosts.yml playbooks/stage-6-verification.yml

stage-7:  ## Опционально: миграция ключей на passphrase
	ansible-playbook playbooks/stage-7-key-hardening.yml

# =============================================================================
# Комбинированные цели
# =============================================================================

full-deploy: stage-0 stage-1 stage-2 stage-3 stage-4 stage-6  ## Полный деплой
full-deploy-with-extras: stage-0 stage-1 stage-2 stage-3 stage-4 stage-5 stage-6

# =============================================================================
# Vault
# =============================================================================

vault-encrypt:
	ansible-vault encrypt ./secrets/secrets.yml --output ./secrets/secrets.vault
vault-create:
	ansible-vault create ./secrets/secrets.vault
vault-edit:
	ansible-vault edit ./secrets/secrets.vault
vault-view:
	ansible-vault view ./secrets/secrets.vault

# =============================================================================
# Инициализация
# =============================================================================

init-ansible:
	sudo apt update
	sudo apt install -y ansible-core python3-pexpect nano
	sudo update-alternatives --set editor /bin/nano

galaxy-install:
	ansible-galaxy collection install community.mysql community.crypto

# =============================================================================
# Утилиты
# =============================================================================

syntax-check:
	@for f in playbooks/stage-*.yml; do \
		echo "Checking $$f..."; \
		ansible-playbook $$f --syntax-check; \
	done

inventory-graph:
	ansible-inventory --graph

help:  ## Показать доступные команды
	@grep -E '^[a-zA-Z0-9_-]+:.*?##' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-25s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
```

---

## 6. Исправления безопасности

### Приоритет: КРИТИЧНО (до продакшена)

| # | Проблема                          | Файл                                     | Исправление                                                |
|---|-----------------------------------|------------------------------------------|------------------------------------------------------------|
| 1 | Аварийный ключ не деплоится       | `ssh_remote_root_keys/tasks/main.yml:13` | Заменить `ordinary_pubkey_path` на `emergency_pubkey_path` |
| 2 | Нет проверки SSH перед hardening  | `remote-security.yml`                    | Добавить assert-задачу тестирования SSH по ключу           |
| 3 | Redis без пароля                  | `redis/templates/redis.conf.j2`          | Добавить `requirepass {{ redis_password }}`                |
| 4 | Права 7777                        | `data_transfer/tasks/main.yml:21`        | Заменить `mode: '7777'` на `mode: '0755'` (или `0775`)     |
| 5 | `full-deploy` пропускает security | `Makefile:19`                            | Добавить `remote-security` в цепочку                       |

### Приоритет: ВЫСОКИЙ

| #  | Проблема                  | Файл                                        | Исправление                                                                    |
|----|---------------------------|---------------------------------------------|--------------------------------------------------------------------------------|
| 6  | PHP disable_functions     | `php/files/conf.d/security.ini`             | Добавить `disable_functions = system,exec,shell_exec,passthru,proc_open,popen` |
| 7  | PHP open_basedir          | Новый файл `php/files/conf.d/basedir.ini`   | `open_basedir = /var/www/:/tmp/:/usr/share/php/`                               |
| 8  | AppArmor deny /etc/passwd | `app_armor/templates/*.j2`                  | Убрать `deny /etc/passwd r`, запускать в `complain` mode                       |
| 9  | Fail2ban + PHP-FPM лог    | `fail2ban/templates/jail.local.j2:94`       | Изменить `backend = systemd` для `[php-fpm]`                                   |
| 10 | MySQL remote root         | `mysql/tasks/mysql_secure_installation.yml` | Исправить условие: `when: item.host != 'localhost'`                            |
| 11 | Нет HTTPS-редиректа       | `nginx/templates/site.tmp.j2`               | Добавить `return 301 https://$host$request_uri` (после Certbot)                |

### Приоритет: СРЕДНИЙ

| #  | Проблема                      | Исправление                                                       |
|----|-------------------------------|-------------------------------------------------------------------|
| 12 | OPcache/APCu не включены явно | Добавить `opcache.enable=1`, `apcu.enable=1` в conf.d             |
| 13 | Нет gzip в Nginx              | Добавить `gzip on; gzip_types text/plain text/css ...`            |
| 14 | Нет rate limiting в Nginx     | Добавить `limit_req_zone`                                         |
| 15 | Swap размер хардкод           | Вынести в переменную                                              |
| 16 | Queue workers без лимитов     | Добавить `MemoryLimit`, `CPUQuota`, `RestartSec=5` в systemd unit |
| 17 | Pre-flight валидация vault    | Добавить `assert` в начало каждого stage                          |

### Приоритет: НИЗКИЙ

| #  | Проблема                      | Исправление                                   |
|----|-------------------------------|-----------------------------------------------|
| 18 | `php-version` → `php_version` | Переименовать (kebab-case → snake_case)       |
| 19 | Docker роль устаревшая        | Обновить до Noble + Docker Compose v2         |
| 20 | Нет бэкап стратегии           | Добавить роль mysqldump + cron                |
| 21 | Нет мониторинга               | Добавить проверку OOM, дискового пространства |

---

## 7. Чек-лист миграции

Пошаговый план перехода на новую архитектуру:

- [ ] **1. Создать `group_vars/all/`** — перенести переменные из `global.yml` в 4 файла (`main.yml`, `ssh.yml`,
  `security.yml`, `webserver.yml`). Переименовать переменные в единый `snake_case`
- [ ] **2. Обновить ссылки в ролях** — заменить `php-version` → `php_version`, `DOMAIN_NAME` → `domain_name`,
  `banTime` → `ban_time` и т.д. во всех шаблонах и задачах
- [ ] **3. Убрать `vars_files: global.yml`** из всех плейбуков (оставить только `vars_files: secrets.vault`)
- [ ] **4. Исправить баг аварийного ключа** — `ssh_remote_root_keys/tasks/main.yml:13`: `ordinary_pubkey_path` →
  `emergency_pubkey_path`
- [ ] **5. Добавить assert-задачи** тестирования SSH-подключения в роль `user_sudo_add_new` или в отдельную роль
- [ ] **6. Создать новые stage-плейбуки** по схеме из раздела 5.2
- [ ] **7. Добавить `requirepass`** в `redis.conf.j2`, создать vault-переменную `vault_redis_password`
- [ ] **8. Исправить `mode: '7777'`** → `mode: '0755'` в `data_transfer`
- [ ] **9. Обновить Makefile** по схеме из раздела 5.4
- [ ] **10. Протестировать** каждый stage отдельно на чистом сервере
- [ ] **11. Применить исправления безопасности** из раздела 6 (по приоритету)
- [ ] **12. Обновить документацию** — удалить устаревшие TODO, обновить README

---

## 8. Ответы на вопросы из TODO

### 8.1 `gather_facts: no` — где добавить и ускорит ли?

**Из `TODO/000-PLAN.MD:30`:**
> *"Спросить у AI где можно добавить `gather_facts: no`. И ускорит ли это выполнение чего-либо?"*

**Ответ:**

`gather_facts: yes` (по умолчанию) собирает информацию о сервере (~1-3 секунды). Отключить можно, если роли **не
используют** переменные `ansible_*`:

| Плейбук                  | Можно отключить?  | Причина                                                           |
|--------------------------|-------------------|-------------------------------------------------------------------|
| `local-init`             | Да, уже без facts | localhost, `gather_facts: no` по умолчанию                        |
| `stage-1 (base)`         | **Нет**           | `locales_hostname_timezone` использует `ansible_hostname`         |
| `stage-2 (access)`       | **Нет**           | `user_sudo_add_new` может использовать `ansible_env`              |
| `stage-3 (security)`     | Можно             | Все параметры берутся из переменных, не из facts                  |
| `stage-4 (webserver)`    | **Нет**           | Шаблоны MySQL/Nginx используют `ansible_fqdn`, `ansible_hostname` |
| `stage-6 (verification)` | Можно             | Тесты не зависят от facts                                         |

**Ускорение**: 1-3 секунды на плейбук. При одном сервере — незначительно. При 10+ серверах — заметно.

**Рекомендация**: оставить `gather_facts: yes` по умолчанию, отключать только в stage-3 и stage-6.

### 8.2 Хранение ключей в проекте

Подробно описано в разделе [4.4](#44-хранение-ключей-в-проекте-вместо-home).

Краткий ответ: можно хранить в `ansible/secrets/ssh/`, обязательно добавить в `.gitignore`. Обновить переменную
`local_ssh_keys_dir`.

---

## Приложение: Положительные стороны текущего проекта

Не всё плохо — вот что сделано **хорошо**:

- **SSH hardening** — хороший выбор шифров (aes256-ctr, chacha20-poly1305), MAC (hmac-sha2-512), KexAlgorithms (
  curve25519-sha256), HostKeyAlgorithms (ssh-ed25519)
- **Многоуровневая защита** — UFW + Fail2ban + AppArmor (три слоя)
- **Логирование через journald** — единый подход для всех сервисов (Nginx, SSH, PHP, MySQL, Redis)
- **Vault для секретов** — правильный подход к управлению паролями
- **Оптимизация под 2 GB RAM** — адекватные настройки MySQL (innodb_buffer_pool_size=256M), PHP-FPM (max_children=5),
  Redis (maxmemory=128MB)
- **Подробные комментарии** на русском языке — код читаемый и понятный
- **Два типа SSH-ключей** — идея с аварийным ключом для root правильная (нужно только исправить деплой)
- **Fail2ban с прогрессивным баном** — `bantime.factor=2` (экспоненциальное увеличение бана)
