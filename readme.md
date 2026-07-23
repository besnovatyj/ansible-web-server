# Yii2-cms — деплой на прод (Ansible)

Развёртывание на чистый Ubuntu Server 24.04 LTS (без Docker): настройка сервера
(`provision`) + выкладка приложения (`deploy`). Запускать из каталога `ansible/`
на Linux/WSL2-контроллере. `make help` — список всех целей.

Правила именования плейбуков/целей:

- номер = позиция в порядке запуска (шаг 10 — место для вставки), цель make = имя плейбука без `.yml`;
- `verify` без номера — повторяемая проверка, запускается в любой момент;
- префикс `optional-` = резерв: не входит в комбинированные цели и в `syntax-check`.

---

## 1. Один раз на контроллере

```bash
make init-ansible     # ansible-core, sshpass (нужен для 20-bootstrap-access), pexpect, nano
make galaxy-install   # коллекции community.mysql, community.crypto
```

---

## 2. Конфигурация перед первым запуском

| Файл                                     | Что задать                                                                                                                                  |
|------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------|
| `.env`                                   | `DOMAIN=<домен>` — ⚠ вручную синхронизировать с `domain_name` (make не читает yaml)                                                         |
| `inventory/hosts.yml`                    | `ansible_host:` — IP сервера (файл в .gitignore; при отсутствии скопировать из `hosts.yml.example`)                                         |
| `inventory/group_vars/all/main.yml`      | `domain_name` (= `DOMAIN`), `time_zone`; поддомены — в `app_hosts` (main/adm/files, из них собираются nginx-vhosts и `/run/secrets/*_HOST`) |
| `inventory/group_vars/all/webserver.yml` | `mysql_db_name`, `mysql_db_user`, `certbot_email`; воркеры очередей: `queue_workers_count` + лимиты RAM/CPU                                 |
| `inventory/group_vars/all/ssh.yml`       | `server_users` (аккаунты на сервере), `target_ssh_port`                                                                                     |
| `environments.mk`                        | `AGENT_KEYS` — ⚠ по строке на каждый ключ из `server_users` + emergency                                                                     |
| Секреты                                  | см. раздел 3                                                                                                                                |

Прочее в `group_vars/all/` обычно не трогается: `security.yml` — fail2ban
(тайминги, включённость jail'ов), `vault.yml` — маппинг `vault_*` → публичные
имена (единственное место, где vault-переменные становятся конфигом).

**Новый человек на сервере** = блок в `server_users` (ssh.yml) + пара
`vault_user_<name>_password` / `vault_user_<name>_passphrase` в секретах +
строка в `AGENT_KEYS` (environments.mk).

---

## 3. Секреты (Ansible Vault)

1. Пароль vault → `secrets/!vault_pass.txt` (образец — `!vault_pass.txt.example`; путь прописан в ansible.cfg).
2. `cp secrets/secrets.yml.example secrets/secrets.yml`, заполнить:

| Переменная                                                  | Что это                                                                 |
|-------------------------------------------------------------|-------------------------------------------------------------------------|
| `vault_root_password`                                       | пароль root от провайдера — нужен только 20-bootstrap-access            |
| `vault_ssh_key_passphrase`                                  | passphrase emergency-ключа root (только для ручного аварийного входа)   |
| `vault_user_ansible_passphrase`                             | passphrase automation-ключа (им ходит Ansible через ssh-agent)          |
| `vault_user_<name>_password` / `_passphrase`                | на каждого `type: human` из `server_users`                              |
| `vault_mysql_root_password`, `vault_mysql_db_user_password` | MySQL                                                                   |
| `vault_redis_password`                                      | Redis (`requirepass`)                                                   |
| `vault_altcha_hmac_key`                                     | `openssl rand -hex 32`; ⚠ менять НЕЛЬЗЯ после прода — сбросит challenge |

3. `make vault-encrypt` → зашифрованный `inventory/group_vars/all/secrets`.
   Правка позже: `make vault-edit`, просмотр: `make vault-view`.

---

## 4. SSH-ключи и ssh-agent

Все ключи защищены passphrase и лежат в `~/.ssh/<домен>/` (генерирует
`10-local-init`): `key_<домен>_<user>` на каждого из `server_users` +
`key_<домен>_emergency_root`.

```bash
make agent-up      # спросит passphrase всех ключей — один раз за сессию
make agent-status  # агент жив? какие ключи заряжены?
make agent-down    # убить агент, удалить .agent.env
```

Любая remote-цель поднимет агент сама (`agent-up` — их зависимость, повторные
вызовы no-op). Вручную нужен только если хочется ввести passphrase заранее.

---

## 5. Настройка сервера

```bash
make provision   # = 10 → 20 → 30 → 40 → 50 → 60 → verify, обычно целиком
```

| Цель                  | Что делает                                                                                                             |
|-----------------------|------------------------------------------------------------------------------------------------------------------------|
| `10-local-init`       | локально: генерация ключей + known_hosts (агент не нужен)                                                              |
| `20-bootstrap-access` | юзеры + доставка ключей по паролю root — ЕДИНСТВЕННЫЙ парольный заход; идемпотентен (если ключ уже работает — пропуск) |
| `30-server-base`      | ОС: apt, локали, swap, systemd                                                                                         |
| `40-server-access`    | journald для SSH + verify входов всех ключей                                                                           |
| `50-server-security`  | UFW, sshd hardening (пароль отключается ЗДЕСЬ), unattended-upgrades, fail2ban                                          |
| `60-webserver`        | Redis, Memcached, MySQL, Nginx, PHP + composer, секреты приложения в `/run/secrets`                                    |

---

## 6. Выкладка приложения

```bash
make deploy      # = 70-release → 80-certbot → 90-queue → verify (канон первого прогона)
```

Чаще запускается по шагам:

| Цель                 | Что делает / когда                                                                                                                        |
|----------------------|-------------------------------------------------------------------------------------------------------------------------------------------|
| `70-release`         | git clone/pull из GitHub + composer install + php init; **это же — каждая последующая выкладка**                                          |
| `70-release-db`      | то же + импорт `mysql_dump/dump.sql` — ⚠ РАЗРУШИТЕЛЬНО, перезаписывает БД                                                                 |
| `80-certbot`         | сертификаты Let's Encrypt. Предусловие: DNS **всех** доменов (main, www, adm, files) указывает на сервер — pre-flight проверит каждый сам |
| `80-certbot-staging` | выпуск против staging CA — отладка DNS/пайплайна без расхода прод-квот (сертификат недоверенный)                                          |
| `80-certbot-force`   | принудительный боевой перевыпуск — разово ПОСЛЕ staging-теста                                                                             |
| `90-queue`           | systemd-воркеры yii-queue@N; строго после `70-release` (pre-flight проверит)                                                              |
| `verify`             | комплексная проверка: SSH/sshd-политика, сервисы, PHP-модули, UFW/fail2ban, HTTP(S)-probe. До certbot отсутствие HTTPS прогон не валит    |

---

## 7. Сразу после первого успешного прогона

Заархивировать в KeePass (две копии базы в разных местах):

- приватные ключи из `~/.ssh/<домен>/` (вложениями) + их passphrase;
- все `vault_*` из secrets.yml + пароль vault (`!vault_pass.txt`).

Подключение клиентов (Kitty/WinSCP/HeidiSQL): human-ключ, имя `type: human`,
порт `target_ssh_port`; MySQL — через SSH-туннель на `127.0.0.1:3306`.
Automation-ключом руками не ходить; SSH по паролю отключён с 50-server-security.

---

## 8. Эксплуатация на сервере

- CMS-команды — от `www-data` (только он читает секреты `/run/secrets`):
  `sudo -u www-data php yii Modman/modules/install <Module>`
- После CLI-установки модуля сбросить OPcache: `sudo systemctl reload php8.4-fpm`
  (прод живёт с `validate_timestamps=0`; из админки модуль сбрасывает кэш сам).

---

## 9. Утилиты

```bash
make help            # все цели (нумерация = порядок запуска)
make syntax-check    # синтаксис плейбуков (optional-* намеренно вне проверки)
make inventory-graph # дерево inventory
```

Резерв: `make optional-data-transfer` (rsync-деплой вместо release),
`make optional-docker`. Лог всех прогонов — `logs/ansible.log` (не в git,
чистить вручную по мере роста).
