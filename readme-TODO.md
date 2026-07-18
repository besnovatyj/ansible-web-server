## Исходные данные

Сервер с 2 Гб оперативной памяти.  
Устанавливаем только стабильные версии (данные на 2026-05-24).
Текущая версия ОС: `ubuntu server 24.04.3 lts`.

| Название                                                  | Версия                    | Источник                                                  |
|-----------------------------------------------------------|---------------------------|-----------------------------------------------------------|
| Ubuntu                                                    | 24.04 LTS (Noble Numbat)  | https://packages.ubuntu.com/                              |
| Nginx                                                     | 1.24.0-2ubuntu7.x         | репозиторий Ubuntu                                        |
| PHP (+ FPM, CLI, расширения)                              | 8.4                       | PPA `ondrej/php` (см. `roles/web-server/php`)             |
| MySQL                                                     | 8.4 LTS                   | официальный репозиторий Oracle (`repo.mysql.com/apt/...`) |
| Redis                                                     | 7.0.x                     | репозиторий Ubuntu                                        |
| memcached                                                 | 1.6.x                     | репозиторий Ubuntu                                        |
| fail2ban                                                  | 1.0.2-3                   | предустановлен в Ubuntu 24.04                             |
| Certbot Let's Encrypt client + Nginx plugin               | 2.x                       | репозиторий Ubuntu                                        |

NB: fail2ban версии 1.0.2 предустановлен в `ubuntu server 24.04.3 lts`. На репозиториях Ubuntu свежее нет; ставить из stretch/PPA не стали — версия достаточная.

🔥TODO: Переделать на сервер с 2Гб RAM.

Для сервера с 1 ГБ RAM, playbook включает оптимизации (Это поможет избежать OOM (out-of-memory) ошибок):

- уменьшение worker-процессов в Nginx (до 1-2)
- ограничение пула PHP-FPM max_children=5
- настройку MySQL на низкое потребление innodb_buffer_pool_size=128M
- Redis сmaxmemory=256MB и eviction-policy.

---

## Структура make-проекта (после рефакторинга 2026-05-24)

```
ansible/
  .env                        ← проектные настройки (DOMAIN), правится под свой проект
  environments.mk             ← инфра make-конфига: paths, exports, .PHONY
  Makefile                    ← рецепты-однострочники
  scripts/
    agent-up.sh               ← поднять ssh-agent, ssh-add ключи (prompt 1 раз/сессию)
    agent-down.sh             ← убить агент, удалить .agent.env
    agent-status.sh           ← состояние агента + список ключей
  ansible.cfg                 ← global SSH-параметры, vault_password_file, log_path
  playbooks/                  ← stage-0…6 и optional-docker
  roles/                      ← system/* и web-server/*
  inventory/
    hosts.yml                 ← один сервер, IP, ssh-параметры
    group_vars/all/
      main.yml, security.yml, ssh.yml, webserver.yml, vault.yml, secrets (encrypted)
  secrets/
    secrets.yml               ← plaintext-шаблон (gitignored), source для vault-encrypt
    !vault_pass.txt           ← пароль Ansible Vault (gitignored)
  TODO/
    000-AUDIT.md              ← сквозной аудит проекта
    000-NOTES.MD              ← решения по аудиту
    001-PERF-ANALYSIS.md      ← анализ таймингов + план ускорения
    Readme.md                 ← этот файл
```

### `.env` (правится под свой проект)

```
DOMAIN=bes-v.ru
```

Подключается в Makefile через `include .env` первой строкой. Формат — `KEY=value` без кавычек (make трактует кавычки как часть значения). **Дублирует** `domain_name` из `inventory/group_vars/all/main.yml` — синхронизировать руками при смене домена (make не умеет читать yaml).

### `scripts/`

Логика ssh-agent вынесена из Makefile в отдельные `.sh`-файлы (чтобы Makefile содержал только «что → чем», а не shell-эскейпы с `$$`). Скрипты получают `AGENT_ENV` и `AGENT_KEYS` через `export` в `environments.mk`.

---

## Актуальный порядок (2026-05-24, см. `000-AUDIT.md`)

> Эта секция — авторитетная. Список «Общий план» ниже оставлен как история.

### Что задать руками (всего три места)

1. **`.env`** → `DOMAIN=<свой-домен>`
2. **`inventory/hosts.yml`** → `ansible_host: <IP сервера>`
3. **Секреты.** Plaintext-шаблон — `secrets/secrets.yml`; рабочие значения Ansible подхватывает из зашифрованного `inventory/group_vars/all/secrets` (см. комментарий в `group_vars/all/vault.yml`). Заполнить и зашифровать (`make vault-encrypt`, пароль — `secrets/!vault_pass.txt`):
   - `vault_root_password` — пароль root от провайдера (нужен ТОЛЬКО stage-1b);
   - `vault_ssh_key_passphrase` — passphrase для emergency-ключа root;
   - `vault_user_ansible_passphrase` — passphrase для automation-ключа (Ansible ходит этим ключом, разлочивается через `make agent-up`);
   - `vault_user_<name>_password` / `vault_user_<name>_passphrase` — на каждого `type: human` из `server_users` (`group_vars/all/ssh.yml`);
   - `vault_mysql_*`, `vault_redis_password` — пароли БД и кэшей.

Новый человек = +1 блок в `server_users` + пара `vault_user_*` в `secrets.yml` + 1 строка в `AGENT_KEYS` (файл `environments.mk`).

Также **синхронно с `inventory/group_vars/all/main.yml`** должны меняться:
- `domain_name` ↔ `DOMAIN` в `.env`;
- `host_ip` (вычисляется из `ansible_host`).

### Зависимости контроллера

#### `sshpass`

`stage-1b` (единственный заход по паролю root) использует парольную SSH-аутентификацию, для которой Ansible требует `sshpass` на машине-контроллере:

```bash
sudo apt-get install -y sshpass     # Debian/Ubuntu
```

Без `sshpass` stage-1b упадёт с `to use the 'ssh' connection type with passwords, you must install the sshpass program`. Установка `make init-ansible` ставит это сама.

#### `ssh-agent` (новое: после Phase 2)

**ВСЕ ssh-ключи проекта защищены passphrase**, включая automation-ключ Ansible. Ansible не умеет вводить passphrase сам, поэтому ключи разлочиваются один раз за сессию через **ssh-agent на контроллере**:

```bash
make agent-up      # спросит passphrase у automation, bes, emergency_root (3 ввода)
make agent-status  # проверить, что агент жив и ключи заряжены
make agent-down    # убить агент, удалить .agent.env
```

`agent-up` идемпотентен: при повторном вызове, если агент жив и ключи уже заряжены — no-op (без prompt-ов). Все `stage-*` цели зависят от `agent-up` и автоматически его поднимут.

Состояние агента живёт в `.agent.env` рядом с Makefile (в `.gitignore`, per-сессия).

Подробнее — `memory: project_ansible_ssh_agent_makefile.md` или комментарий в `environments.mk`.

### Запуск

Цели — в `ansible/Makefile` (запускать из директории `ansible/`):

```bash
make full-deploy            # stage-0 → stage-1b → stage-1 → 2 → 3 → 4 → 6
                            # ssh-agent поднимется автоматически (prompt 3 раза за сессию)
# или по стадиям:
make stage-0                # генерация ключей локально (агент не нужен)
make stage-1b               # bootstrap: юзеры + ключи по паролю root + verify automation
make stage-1                # OS base: apt update, locales, swap, systemd
make stage-2 stage-3 stage-4 stage-5a stage-5b stage-6
make help                   # список всех целей
```

`stage-1b` идемпотентен: если automation-ключ уже работает (probe через ssh-agent), bootstrap пропускается (повторный прогон безопасен).

**Расчёт времени на чистом сервере:** ~25 мин (4 vCPU / 4 GB RAM, Ubuntu 24.04). Подробная раскладка по стадиям и предложения по ускорению — `001-PERF-ANALYSIS.md`.

### Архивирование ключей в KeePass (сделать сразу после первого успешного прогона!)

Чтобы через год не искать ключи. Все приватные ключи лежат в `~/.ssh/<domain>/` (`local_ssh_keys_dir` = `{{ local_home_path }}/.ssh/{{ domain_name }}`, напр. `~/.ssh/bes-v.ru/`; нативная ext4 — Unix-права/chattr работают, ключи изолированы от личных в `~/.ssh`, рядом с плейбуком больше не хранятся):

| Файл                          | passphrase | Назначение                                         |
|-------------------------------|------------|----------------------------------------------------|
| `key_<domain>_<automation>`   | ДА         | ходит Ansible (через ssh-agent + `make agent-up`)  |
| `key_<domain>_<human>`        | ДА         | человек руками (Kitty/WinSCP/HeidiSQL)             |
| `key_<domain>_emergency_root` | ДА         | аварийный вход root, обычно не нужен               |

Процедура:

1. После успешного `make stage-6` (или `make full-deploy`) создать в KeePass запись на каждый приватный ключ (вложением — сам файл ключа; в поле пароля — passphrase ключа).
2. Туда же: `vault_root_password`, `vault_ssh_key_passphrase`, `vault_user_ansible_passphrase`, все `vault_user_*` пользовательские, пароль Ansible Vault (`secrets/!vault_pass.txt`).
3. Сделать **две** копии базы KeePass в разные места (правило из плана).
4. Проверить, что вход по ключам реально работает (`make stage-6` — проверяет реальный SSH-вход через verify_ssh), и только потом считать ключи «архивными».

Подключение клиентов: HeidiSQL/Kitty/WinSCP — по `key_<domain>_<human>` под именем человека (`type: human`) на порт `target_ssh_port`; MySQL — через SSH-туннель на `127.0.0.1:3306`. Ansible-ключом (`key_<domain>_<automation>`) руками не ходим.

---

## Связанные документы

- **`000-AUDIT.md`** — сквозной аудит проекта (логика пайплайна, безопасность, идемпотентность, проверки). Авторитетный источник по архитектурным решениям.
- **`000-NOTES.MD`** — решения по аудиту, заметки по конкретным находкам.
- **`001-PERF-ANALYSIS.md`** — анализ таймингов `full-deploy` (~25 мин), топ медленных задач, предложения по ускорению с оценкой риска/экономии.

---

## Общий план (🔥 LEGACY — реализован пайплайном stage-0…6; см. актуальный порядок выше)

Оставлен как историческая справка о том, что должен делать пайплайн. Актуальная реализация — в `playbooks/stage-*.yml`.

1) Отредактировать данные в соответствии с настраиваемым хостом
    - IP адрес удалённого хоста
    - Название домена
    - Пароль root (Ansible Vault)
    - Имя пользователя базы данных
    - Пароль для базы данных (Ansible Vault)
    - Парольная фраза для генерируемых ключей (Ansible Vault)
    - Часовой пояс сервера
    - Список пользователей `server_users` (бывш. «имя нового пользователя sudo») — см. актуальную секцию выше
    - Проверить версии устанавливаемых компонентов
    - Проверить пароль Ansible Vault хранилища
    - Удостовериться что все пароли продублированы и надёжно сохранены как минимум еще в 2-х местах
2) Зашифровать новые пароли для сервера в Ansible Vault
3) Сгенерировать ключи на localhost
4) Добавить ECDSA-записи удалённого хоста в known_hosts
5) Обновить Ubuntu
6) Базовая настройка ОС:
    - Временная зона
    - Региональные настройки (locale)
    - hostname
    - swap
    - systemd limits
7) Настройка доступа
    - Настройка доступа для root
    - Добавление пользователя sudo
    - Настройка доступа SSH о ключам
    - Настройка SSH (client alive)
    - Настройка SSH логирования в journald
    - Тестирование SSH доступа по ключам для root и для созданного пользователя
8) Настройка веб-сервера
    - nginx
    - php
    - mysql
    - redis
    - копирование файлов??????
    - Настройка очередей через redis и systemd
9) Настройки безопасности
    - ufw
    - file2ban
    - AppArmor
10) Очистка ОС
11) Тестирование

---

## Ansible Playbook

### Установка Ansible

```bash
make init-ansible
```

Ставит: `ansible-core`, `python3-pexpect`, `nano`, `sshpass`, коллекцию `community.mysql`.

```bash
make galaxy-install
```

Ставит коллекции `community.mysql` и `community.crypto` (нужны для роли генерации ключей и MySQL).

### Проверки

Проверка синтаксиса всех stage-плейбуков:

```bash
make syntax-check
```

Сухой прогон конкретного плейбука (показывает что бы изменилось, без записей):

```bash
ansible-playbook -i inventory/hosts.yml playbooks/stage-X.yml --check
```

Просмотр иерархии inventory:

```bash
make inventory-graph
```

---

## Анализ: не повторится ли «Apple не открывает сайт» (Let's Encrypt / TLS) после настройки ansible

Контекст: месяц назад устройства Apple (iPhone 15/16, iOS 17/18/19, macOS/Safari) перестали
открывать сайты на серверах, настроенных годами ранее. Разбор причин — в `/workspace/TODO/!!!Certbot.md`.
Проблему на старых серверах устранили. Вопрос: воспроизведёт ли её свежая настройка через `/workspace/ansible`.

### Как сейчас устроен TLS в ansible

- `roles/web-server/nginx/templates/site.tmp.j2` описывает **только `listen 80`**. 443-блок дописывает
  **`certbot --nginx`** (`roles/web-server/certbot`): вставляет `listen 443 ssl; # managed by Certbot`
  и `include /etc/letsencrypt/options-ssl-nginx.conf`.
- Глобально в `nginx.conf.j2` есть `ssl_protocols TLSv1.2 TLSv1.3;`, но per-vhost его перекрывает
  включаемый certbot файл (это признано и в комментарии на строке 58).

### Причина 1 (старые шифры / TLS 1.0–1.1) — НЕ повторится на свежей установке

Файл, сломавший старые серверы (`options-ssl-nginx.conf`, годами лежавший с TLS 1.0/1.1 и шифрами без
Forward Secrecy), на свежем сервере пишется **текущим** пакетом `python3-certbot-nginx` (Ubuntu 24.04,
certbot 2.x): там уже `ssl_protocols TLSv1.2 TLSv1.3;`, `ssl_prefer_server_ciphers off;`, а `ssl_ciphers`
не пиннится (дефолты OpenSSL: для TLS1.2 остаются ECDHE-GCM с FS, TLS1.3 всегда AEAD). Safari/iOS
согласуют ECDHE-…-GCM → хендшейк проходит. Ровно та ловушка не воспроизводится.

⚠️ Структурный нюанс тот же, что укусил: файл принадлежит **пакету certbot, а не ansible** — вне version
control и может тихо «постареть» через годы (сценарий fire-and-forget-серверов). Современные версии
устойчивее старых, но дыра во владении остаётся.

### Причина 2 (нет HTTP/2) — повторится

`certbot --nginx` добавляет `listen 443 ssl;` **без http2** → HTTPS по HTTP/1.1, как на старых серверах
до правки. Честно: отсутствие http2 почти наверняка НЕ было настоящей причиной блокировки Apple —
хард-блок хендшейка даёт Причина 1 (+ смена корневых цепочек Let's Encrypt). Safari работает по
HTTP/1.1; http2 — про скорость и edge-случаи, а не «сайт не открывается». Реальный блокер уже закрыт
свежестью certbot; http2 стоит добавить ради корректности и скорости.

### Причина 3 (смена цепочки Let's Encrypt Gen X→Y) — закрыта автоматически

certbot отдаёт `fullchain.pem` и на renewal тянет актуальную цепочку; современные Apple-устройства
доверяют ISRG Root X1/X2. Действий не требуется.

### Рекомендация

Свежий деплой Apple не сломает. Но чтобы (а) гарантировать http2 и (б) закрыть структурную дыру
«критичный TLS-файл не у меня», правильный ход — перестать отдавать 443-блок на откуп плагину и владеть
им самому:

1. 443-server-блоки — в ansible-шаблоне, с явными `listen 443 ssl http2;` (на nginx 1.24 из Ubuntu 24.04
   http2 идёт в строке `listen`; standalone `http2 on;` — только с nginx 1.25.1+), современным
   `ssl_protocols`/`ssl_ciphers` (Mozilla Intermediate, `ssl_prefer_server_ciphers off`), OCSP stapling
   и путями к `fullchain.pem`.
2. certbot перевести в `certonly --webroot` (только выпуск/продление, конфиг nginx не трогает) +
   `.well-known/acme-challenge` в 80-блоке + reload-hook на renew.

Тогда весь TLS под git, http2 гарантирован, шифры не «стареют» за спиной. Минимальная альтернатива
(оставить `--nginx` и дописывать http2 через `lineinfile` поверх certbot-строки) — хрупкая и не
закрывает проблему владения шифрами; не рекомендуется.
