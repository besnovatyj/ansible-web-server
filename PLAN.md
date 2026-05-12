# Пошаговый план реструктуризации Ansible-проекта

> Документ-спутник к [`ANALYSIS.md`](./ANALYSIS.md). Здесь — последовательность маленьких
> коммитов с примерами кода. Аргументация и проектные решения — в анализе.

## Как пользоваться этим планом

- Каждый шаг — отдельный коммит. После каждого шага проект должен оставаться рабочим (или
  частично рабочим, если это явно отмечено).
- Если перед примером стоит **«ДО»** — это текущее содержимое файла. **«ПОСЛЕ»** — целевое.
- Если шаг создаёт новый файл — пример — это полное содержимое.
- Если шаг правит одну строку — показан минимальный diff.
- Перед каждым коммитом — `ansible-playbook playbooks/<нужный>.yml --syntax-check`.
- После фазы — прогон полного цикла на тестовом сервере (если есть).

## Зависимости фаз

```
A. Pre-stage-0 (ручной шаг)
   └── B. Багфиксы на текущей архитектуре
        └── C. group_vars/all/ (аддитивно)
             └── D. Переименование переменных в snake_case
                  └── E. SSH-ключи → ansible/secrets/ssh/
                       └── F. Stage-плейбуки (создание рядом со старыми)
                            └── G. nginx_sites + создание web_root
                                 └── H. Security-правки
                                      └── I. Stage 5a/5b/5c + optional-docker
                                           └── J. Удаление старого + новый Makefile
                                                └── K. Stage 6 verification
                                                     └── L. (опц.) Stage 7 key-hardening
```

---

# Фаза A. Подготовка (без правки кода)

## A1. Зафиксировать процедуру первого подключения

**Проблема.** В новом inventory будет `site_ansible_key: "{{ ordinary_key_path }}"` —
Stage 1 идёт по ключу. Но ключ окажется на сервере только в Stage 2. Курица-яйцо.

**Что делаем.** Создаём `ansible/secrets/README.md` (это документация, не код).

Создать файл `ansible/secrets/README.md`:

```markdown
# secrets/

## Pre-stage-0: первое подключение к серверу

Stages 1+ работают по SSH-ключу. Ключ генерируется в Stage 0 и кладётся в
`ansible/secrets/ssh/`. Но на сервер он попадает только в Stage 2. Поэтому до запуска
Stage 1 нужно один раз вручную положить `ordinary_pubkey_path` на root.

### Вариант 1: панель управления хостера

Большинство VPS-хостеров позволяют добавить публичный ключ при создании сервера.
Указать там содержимое `ansible/secrets/ssh/key_<domain>.pub` (создаётся в Stage 0).

### Вариант 2: ssh-copy-id с паролем root

После провижининга VPS, до Stage 1:

    ssh-copy-id -i ansible/secrets/ssh/key_<domain>.pub root@<server_ip>

(хостер при создании VPS присылает пароль root на email.)

### Архивирование ключей после Stage 6

После того как сервер настроен и проверен:

1. Архивировать `ansible/secrets/ssh/` (вместе с приватными ключами).
2. Положить архив в KeePass + два внешних бэкапа.
3. Удалить локальные приватные ключи из `ansible/secrets/ssh/` (опц.).

Ключи больше не понадобятся пока что-то не сломается.
```

**Коммит:** `docs(ansible): describe pre-stage-0 manual key bootstrap procedure`

---

# Фаза B. Багфиксы на текущей архитектуре

Работаем с текущим `global.yml` и текущими `remote-*.yml`. Никакой реструктуризации.
Каждый коммит независим — порядок можно менять.

## B1. Деплой аварийного ключа на root

**Файл:** `ansible/roles/system/ssh_remote_root_keys/tasks/main.yml`

> Похоже, этот файл уже исправлен (там `emergency_pubkey_path`). Если так — шаг
> пропускаем. Проверить:
>
>     grep -n "ordinary_pubkey_path\|emergency_pubkey_path" \
>         ansible/roles/system/ssh_remote_root_keys/tasks/main.yml

Если строка `key: "{{ lookup('file', ordinary_pubkey_path) }}"` — заменить на
`emergency_pubkey_path`. Полное содержимое файла:

```yaml
---
- name: Ensure .ssh directory exists for target user
  file:
    path: "/root/.ssh"
    state: directory
    mode: '0700'
    owner: "root"
    group: "root"

- name: Copy public key to root (for emergency access)
  authorized_key:
    user: root
    key: "{{ lookup('file', emergency_pubkey_path) }}"
    state: present
    manage_dir: yes
```

**Коммит:** `fix(ansible): deploy emergency pubkey to root instead of ordinary`

## B2. Тесты SSH — заменить `wait_for_connection` на реальный `command: ssh`

**Проблема.** `wait_for_connection + delegate_to: localhost` фактически проверяет
locally connection plugin, а не SSH до сервера (см. ANALYSIS 3.1.4).

### B2.1. Переписать `roles/tests/tasks/new_user_ssh.yml`

ДО (часть с `wait_for_connection`):

```yaml
- name: Test SSH connection as new user
  wait_for_connection:
    delay: 5
    timeout: 30
  vars:
    ansible_user: "{{ new_user }}"
  delegate_to: localhost
  run_once: true
  changed_when: false
```

ПОСЛЕ:

```yaml
- name: Verify SSH key login for new user
  delegate_to: localhost
  command: >
    ssh -i {{ ordinary_key_path }}
        -o BatchMode=yes
        -o StrictHostKeyChecking=yes
        -o ConnectTimeout=10
        -p {{ target_ssh_port }}
        {{ new_user }}@{{ target_host }} "echo OK"
  register: ssh_test_new_user
  changed_when: false
  failed_when: "'OK' not in ssh_test_new_user.stdout"
```

> Уже есть похожий блок `Verify SSH key login for {{ verify_ssh_user }}` — он использует
> переменную `verify_ssh_user`, которая нигде не определена. Заменяем его на блок выше
> с явным `{{ new_user }}`. После фазы F эту задачу заменит роль `verify_ssh`.

### B2.2. Переписать `roles/tests/tasks/root_ssh.yml`

ДО:

```yaml
- name: Test SSH connection as root
  wait_for_connection:
    delay: 5
    timeout: 30
  vars:
    ansible_user: "root"
  delegate_to: localhost
  run_once: true
  changed_when: false
```

ПОСЛЕ:

```yaml
- name: Verify SSH key login for root (emergency key)
  delegate_to: localhost
  command: >
    ssh -i {{ emergency_key_path }}
        -o BatchMode=yes
        -o StrictHostKeyChecking=yes
        -o ConnectTimeout=10
        -p {{ target_ssh_port }}
        root@{{ target_host }} "echo OK"
  register: ssh_test_root
  changed_when: false
  failed_when: "'OK' not in ssh_test_root.stdout"
```

**Замечание про `StrictHostKeyChecking=yes`:** требует, чтобы Stage 0 уже добавил отпечаток
сервера в `~/.ssh/known_hosts`. Если запускать тесты до Stage 0 — будет ошибка про unknown
host. Это правильное поведение.

**Коммит:** `fix(ansible): test SSH via real ssh command, use correct keys per user`

## B3. MySQL — whitelist вместо `when item != 'localhost'`

**Файл:** `ansible/roles/web-server/mysql/tasks/mysql_secure_installation.yml`

**Куда класть `keep_mysql_root_hosts`:** в `group_vars/global.yml` рядом с другими
mysql-переменными. Это переменная конфигурации, она не должна жить внутри tasks-файла.

### B3.1. Добавить переменную в `group_vars/global.yml`

В секцию `MYSQL`:

```yaml
# --------------------------------------------------------
# MYSQL
# --------------------------------------------------------

mysql_db_name: mysql_db_name
mysql_db_user: mysql_db_user
mysql_db_user_password: "{{ vault_mysql_db_user_password }}"
mysql_root_password : "{{ vault_mysql_root_password }}"

# Список host-значений в mysql.user, которые root@<host> НЕ удаляются при secure_installation.
# Всё остальное (включая '%' и FQDN сервера) удаляется.
keep_mysql_root_hosts:
  - localhost
  - 127.0.0.1
```

### B3.2. Переписать цикл удаления root-аккаунтов

ДО (последняя задача в `mysql_secure_installation.yml`):

```yaml
- name: Удаление дополнительных root-аккаунтов для запрета удалённого доступа
  mysql_user:
    name: root
    host: "{{ item }}"
    state: absent
    login_user: root
    login_password: "{{ mysql_root_password }}"
    login_unix_socket: /var/run/mysqld/mysqld.sock
  loop:
    - "::1"
    - "127.0.0.1"
    - "{{ ansible_fqdn | default('') }}"
    - "{{ inventory_hostname }}"
    - "{{ ansible_hostname }}"
    - "%"
  no_log: true
  when: item != 'localhost'
```

ПОСЛЕ:

```yaml
- name: Получить список всех root@host из mysql.user
  community.mysql.mysql_query:
    login_user: root
    login_password: "{{ mysql_root_password }}"
    login_unix_socket: /var/run/mysqld/mysqld.sock
    query: "SELECT Host FROM mysql.user WHERE User = 'root'"
  register: mysql_root_hosts
  no_log: true

- name: Удалить все root-аккаунты, не входящие в keep_mysql_root_hosts
  mysql_user:
    name: root
    host: "{{ item.Host }}"
    state: absent
    login_user: root
    login_password: "{{ mysql_root_password }}"
    login_unix_socket: /var/run/mysqld/mysqld.sock
  loop: "{{ mysql_root_hosts.query_result[0] }}"
  loop_control:
    label: "root@{{ item.Host }}"
  when: item.Host not in keep_mysql_root_hosts
  no_log: true
```

**Что изменилось:**
- Раньше: пробегаем фиксированный список из 6 значений и удаляем те, что не `'localhost'`.
- Теперь: смотрим что **реально** есть в `mysql.user`, и удаляем всё кроме whitelist.
- Преимущество: если MySQL сам создал какой-нибудь `root@<нестандартный_hostname>` — мы его
  тоже удалим.

**Требование:** должна быть установлена коллекция `community.mysql` — она уже в Makefile
(`galaxy-mysql-crypto`).

**Коммит:** `fix(ansible): use whitelist for mysql root host preservation`

## B4. AppArmor → complain mode + убрать `deny /etc/passwd r`

**Файлы:**
- `ansible/roles/system/app_armor/tasks/main.yml`
- `ansible/roles/system/app_armor/templates/usr.sbin.nginx.j2`
- `ansible/roles/system/app_armor/templates/usr.sbin.php-fpm.j2`
- `ansible/roles/system/app_armor/templates/usr.sbin.mysqld.j2`
- `ansible/roles/system/app_armor/templates/usr.bin.redis-server.j2`
- `ansible/roles/system/app_armor/templates/usr.sbin.fail2ban-server.j2`

### B4.1. Заменить `aa-enforce` на `aa-complain` в tasks

Во всех `command: aa-enforce ...` блоках:

ДО:

```yaml
- name: Enforce Nginx profile
  command: aa-enforce /etc/apparmor.d/usr.sbin.nginx
  ignore_errors: true
  notify: Reload AppArmor
```

ПОСЛЕ:

```yaml
- name: Set Nginx profile to complain mode
  command: aa-complain /etc/apparmor.d/usr.sbin.nginx
  changed_when: false
  notify: Reload AppArmor
```

Аналогично для php-fpm, mysqld, redis-server, fail2ban-server. Заменить заголовки задач:
`Enforce X profile` → `Set X profile to complain mode`. `ignore_errors: true` можно
убрать — `aa-complain` идемпотентен.

### B4.2. Убрать `deny /etc/passwd r` из шаблонов

В каждом `.j2`-шаблоне в `templates/` найти и удалить строки вида:

```
deny /etc/passwd r,
```

Также удалить аналогичные опасные `deny` для системных файлов, нужных getpwuid (например,
`deny /etc/group r,`, `deny /etc/nsswitch.conf r,`). Конкретный список — зависит от
содержимого шаблонов, нужно открыть каждый и посмотреть.

**Коммит:** `fix(ansible): switch apparmor to complain mode and drop unsafe deny rules`

---

# Фаза C. `group_vars/all/` (аддитивно)

Создаём новую структуру переменных рядом с `global.yml`. Старый файл пока продолжает
работать через `vars_files:` в плейбуках. На этой фазе переменные дублируются — это
временно нормально.

## C1. Включить `group_vars/all/` через `ansible.cfg`

**Файл:** `ansible/ansible.cfg`

Уже всё на месте (`inventory = ./inventory/`, `vault_password_file = ./secrets/!vault_pass.txt`).
Проверить и убедиться. Если нет — добавить.

**Коммит:** `chore(ansible): ensure ansible.cfg has inventory and vault_password_file`
(если правок нет — пропустить шаг).

## C2. Создать `group_vars/all/main.yml`

**Новый файл:** `ansible/group_vars/all/main.yml`

```yaml
---
##########################################################
# GLOBAL
##########################################################

DOMAIN_NAME: domain.zone
HOST_IP: "{{ hostvars[groups['site'][0]]['ansible_host'] }}"
web_root: "/var/www"
locale1: ru_RU.UTF-8
locale2: en_US.UTF-8
time_zone: UTC # Asia/Yekaterinburg # Europe/Moscow
```

> Имена переменных пока сохраняем как в `global.yml` (CAPS). Переименование — в фазе D,
> атомарно. На этой фазе главное — переехать на новую структуру, не сломав ничего.

**Коммит:** `chore(ansible): introduce group_vars/all/main.yml (duplicates global.yml)`

## C3. Создать `group_vars/all/ssh.yml`

**Новый файл:** `ansible/group_vars/all/ssh.yml`

```yaml
---
##########################################################
# SSH-USERS
##########################################################

############### Общее
LOCAL_HOME_PATH: "{{ lookup('env', 'HOME') }}"
force_key_regen: false # true — принудительно регенерировать ключи (бэкапит существующие в той же директории)
ssh_known_hosts_path: "{{ LOCAL_HOME_PATH }}/.ssh/known_hosts"
ssh_key_type: "ed25519" # или "rsa" (только если не поддерживается ed25519, например, если версия OpenSSH ниже 6.5)
ssh_key_size: 0 # Для RSA указать `4096`. Для ed25519 длина фиксированная.
ssh_key_passphrase: "{{ vault_ssh_key_passphrase }}"
target_ssh_port: 22 # TODO - лучше потом поменять порт по умолчанию для SSH

############### Пути к ключам
local_ssh_keys_dir: "{{ LOCAL_HOME_PATH }}/.ssh"
ordinary_key_path: "{{ local_ssh_keys_dir }}/key_{{ DOMAIN_NAME }}"
ordinary_pubkey_path: "{{ ordinary_key_path }}.pub"
emergency_key_path: "{{ local_ssh_keys_dir }}/key_{{ DOMAIN_NAME }}_emergency_root"
emergency_pubkey_path: "{{ emergency_key_path }}.pub"

############### Куда копируем
target_host: "{{ hostvars[groups['site'][0]]['ansible_host'] }}"

############### Подключение Ansible
site_ansible_user: root
site_ansible_key: ~

############### Новый пользователь вместо root (для людей, не для Ansible)
new_user: "bes" # Укажите имя нового пользователя
```

**Что выкинули относительно `global.yml`:**
- `target_user` — нигде не использовалась.
- `site_ansible_password` — Ansible работает только по ключу, пароль больше не нужен. 
   !!!НЕПРАВДА!!! Сначала пароль, потом копирование ключей, потом уже без пароля. Чтобы автоматизировать копирование ключей, нужен пароль. 

> `local_ssh_keys_dir` пока остаётся в `~/.ssh/` — переедем на `secrets/ssh/` в фазе E.

**Коммит:** `chore(ansible): introduce group_vars/all/ssh.yml`

## C4. Создать `group_vars/all/security.yml`

**Новый файл:** `ansible/group_vars/all/security.yml`

```yaml
---
##########################################################
# FAIL2BAN
##########################################################

# fail2ban_version: 1.1.0 # v=1.0.2-3 Предустановлена в Ubuntu 24.04.3 (Noble Numbat).
banTime: 3600 # default - 10m
findTime: 600 # default - 10m
maxRetry: 5
# NB: Защищаем точки входа, а не всё подряд.
# Если сервис имеет доступ снаружи сервера, тогда защищаем,
# иначе просто закрываем доступ извне на уровне фаервола.
jailsEnableStatus:
  # Предустановленные
  sshd: true
  nginx-http-auth: true
  nginx-limit-req: false # Чтобы включить, сначала прочитай описание в файле конфига
  nginx-botsearch: true
  nginx-bad-request: true
  nginx-forbidden: true
  php-url-fopen: true
  vsftpd: false # Не устанавливаем. Зачем, если есть WinSCP
  mysqld-auth: false # Слушает только localhost
  traefik-auth: false # Сначала настрой его. :)
  recidive: true
  sendmail-auth: false
  sendmail-reject: false
  # Добавленные
  php-fpm: false # Для защиты от брутфорса PHP-приложений. Логирование см. ANALYSIS 3.2.6
  redis-auth: false # Слушает только localhost
  yii2-auth: false # Включится после внедрения Monolog→SyslogHandler в Yii2. См. ANALYSIS 3.2.6
```

**Что нового:**
- `yii2-auth: false` — добавлено заранее, чтобы шаблон `jail.local.j2` не падал с
  undefined переменной (см. внешний обзор п. 8 в ANALYSIS).

**Коммит:** `chore(ansible): introduce group_vars/all/security.yml`

## C5. Создать `group_vars/all/webserver.yml`

**Новый файл:** `ansible/group_vars/all/webserver.yml`

```yaml
---
##########################################################
# PHP
##########################################################

php-version: 8.4 # Стабильная версия из ubuntu.com для Ubuntu 24.04.3 (Noble Numbat)

php_modules: [
  "php{{ php-version }}-fpm",
  "php{{ php-version }}-cli",
  "php{{ php-version }}-common", # Содержит calendar
  "php{{ php-version }}-mysqlnd",
  "php{{ php-version }}-mysql", # Содержит pdo_mysql
  "php{{ php-version }}-redis",
  "php{{ php-version }}-zip",
  "php{{ php-version }}-gd",
  "php{{ php-version }}-mbstring",
  "php{{ php-version }}-curl",
  "php{{ php-version }}-xml", # Содержит simplexml, dom
  "php{{ php-version }}-apcu", # 5.1.24; для кэширования; включить apcu.enable=1 в conf.d/apcu.ini
  "php{{ php-version }}-intl", # TODO проверить что работает (должны работать форматтеры Yii2)
  "php{{ php-version }}-bcmath",
  "php{{ php-version }}-fileinfo",
  "php{{ php-version }}-pdo",
  "php{{ php-version }}-opcache", # Включить opcache.enable=1 в conf.d/opcache.ini
  "php{{ php-version }}-exif",
  "php{{ php-version }}-imagick",
  "php{{ php-version }}-memcached",
#  "php{{ php-version }}-pcntl" # Только CLI, в FPM не работает
]

##########################################################
# MYSQL
##########################################################

mysql_db_name: mysql_db_name
mysql_db_user: mysql_db_user
mysql_db_user_password: "{{ vault_mysql_db_user_password }}"
mysql_root_password: "{{ vault_mysql_root_password }}"

# Список host-значений в mysql.user, которые root@<host> НЕ удаляются при secure_installation.
keep_mysql_root_hosts:
  - localhost
  - 127.0.0.1

##########################################################
# CERTBOT
##########################################################

certbot_email: 'name@domain.zone'
```

> Структура `nginx_sites` появится в фазе G, в этом же файле.

**Коммит:** `chore(ansible): introduce group_vars/all/webserver.yml`

## C6. Создать `group_vars/all/vault.yml`

**Новый файл:** `ansible/group_vars/all/vault.yml`

```yaml
---
##########################################################
# Публичный маппинг vault-переменных
# Сами зашифрованные значения хранятся в group_vars/all/secrets.vault
# (перенесём туда в шаге C7).
##########################################################

# vault_ssh_key_passphrase уже маппится в ssh.yml на ssh_key_passphrase — не дублируем здесь
# vault_root_password больше не используется — Ansible работает только по ключу

mysql_root_password_from_vault: "{{ vault_mysql_root_password }}"
mysql_db_user_password_from_vault: "{{ vault_mysql_db_user_password }}"
redis_password_from_vault: "{{ vault_redis_password | default('') }}"
```

> Важно (внешний обзор п. 2): **не пишем** строку
> `vault_ssh_key_passphrase: "{{ vault_ssh_key_passphrase }}"` — это рекурсивная ссылка
> и Ansible выдаст `RecursiveLoopError` либо тихий noop.

> Имена с суффиксом `_from_vault` — чтобы не конфликтовать с такими же ключами в
> `webserver.yml` (`mysql_root_password: "{{ vault_mysql_root_password }}"`). Альтернатива
> — переписать `webserver.yml` так, чтобы он не маппил vault, а только использовал
> маппинг из этого файла. Решить при реализации.

**Коммит:** `chore(ansible): introduce group_vars/all/vault.yml mapping`

## C7. Переместить `secrets.vault` → `group_vars/all/secrets.vault`

```bash
git mv ansible/secrets/secrets.vault ansible/group_vars/all/secrets.vault
```

После этого Ansible автоматически расшифрует файл при загрузке `group_vars/all/` —
благодаря `vault_password_file = ./secrets/!vault_pass.txt` в `ansible.cfg`.

**`vars_files:` в плейбуках пока не трогаем** — удалим в C9.

**Коммит:** `chore(ansible): move secrets.vault into group_vars/all/ for auto-loading`

## C8. Smoke-тест

Прогон без правок, проверяем что ничего не сломалось:

```bash
make remote-test
ansible-playbook -i inventory/hosts.yml playbooks/remote-base.yml --check
```

Если падает `undefined variable` — какая-то переменная не попала в `group_vars/all/`,
возвращаемся к C2–C6.

(Это проверочный шаг, коммита нет.)

## C9. Удалить `vars_files:` из плейбуков

Во всех плейбуках убрать блоки:

```yaml
vars_files:
  - ../secrets/secrets.vault
  - ../group_vars/global.yml
```

Файлы:
- `ansible/playbooks/local-init.yml`
- `ansible/playbooks/remote-base.yml`
- `ansible/playbooks/remote-security.yml`
- `ansible/playbooks/remote-webserver.yml` (обе play в нём — `Global installation...` и
  `Clean server`)

Пример для `remote-base.yml` — ДО:

```yaml
- name: Basic server configuration
  hosts: site
  remote_user: root
  become: true
  vars_files:
    - ../secrets/secrets.vault
    - ../group_vars/global.yml
  roles:
    - ../roles/system/apt_update
    ...
```

ПОСЛЕ:

```yaml
- name: Basic server configuration
  hosts: site
  remote_user: root
  become: true
  roles:
    - ../roles/system/apt_update
    ...
```

**Коммит:** `chore(ansible): drop vars_files from playbooks (group_vars/all auto-loads)`

## C10. Удалить `group_vars/global.yml`

```bash
git rm ansible/group_vars/global.yml
```

После этого вся конфигурация — в `group_vars/all/*.yml`.

**Коммит:** `chore(ansible): remove obsolete group_vars/global.yml`

---

# Фаза D. Переименование переменных в snake_case

**Принцип:** одно имя за один коммит, в коммите правим **все** места одновременно
(переменные + шаблоны + tasks + inventory). Если пропустить хоть одно — Ansible упадёт с
`undefined variable`.

**Утилита поиска:** перед каждой правкой
```bash
grep -RIn "PATTERN" ansible/ \
    --include="*.yml" --include="*.yaml" --include="*.j2" --include="*.cfg"
```

## D1. `php-version` → `php_version`

**Почему важно:** дефис в Jinja2 — оператор вычитания. `{{ php-version }}` Jinja2
трактует как `php` минус `version`. Работает только случайно.

### D1.1. Поиск

```bash
grep -RIn "php-version" ansible/
```

Типичные места:
- `ansible/group_vars/all/webserver.yml` (определение)
- `ansible/roles/web-server/php/tasks/main.yml` (использование в путях
  `/etc/php/{{ php-version }}/...`)
- `ansible/roles/web-server/nginx/templates/site.tmp.j2`
  (`php{{ php-version }}-fpm.sock`)
- `ansible/roles/system/app_armor/tasks/main.yml`
  (`usr.sbin.php-fpm{{ php-version }}`)
- `ansible/roles/system/fail2ban/templates/jail.local.j2`
  (`/var/log/php{{ php-version }}-fpm.log`)

### D1.2. Замена

В `group_vars/all/webserver.yml`:

ДО:
```yaml
php-version: 8.4
```

ПОСЛЕ:
```yaml
php_version: "8.4"  # обязательно строкой, иначе YAML парсит как float и теряет ".0"
```

И во всех `php_modules: [...]`, и во всех шаблонах — `php-version` → `php_version`.

Пример для одной строки в `php/tasks/main.yml`:

ДО:
```yaml
- name: Ensure required PHP modules are enabled (if needed)
  command: phpenmod {{ item }}
  ...
  args:
    creates: "/etc/php/{{ php-version }}/mods-available/{{ item }}.ini"
```

ПОСЛЕ:
```yaml
- name: Ensure required PHP modules are enabled (if needed)
  command: phpenmod {{ item }}
  ...
  args:
    creates: "/etc/php/{{ php_version }}/mods-available/{{ item }}.ini"
```

### D1.3. Проверка после замены

```bash
grep -RIn "php-version" ansible/
# Должно вывести 0 строк
ansible-playbook playbooks/remote-webserver.yml --syntax-check
```

**Коммит:** `refactor(ansible): rename php-version → php_version`

## D2. `DOMAIN_NAME` → `domain_name`

### D2.1. Поиск
```bash
grep -RIn "DOMAIN_NAME" ansible/
```

Места (примерно):
- `ansible/group_vars/all/main.yml` (определение)
- `ansible/group_vars/all/ssh.yml` (использование в `ordinary_key_path`,
  `emergency_key_path`)
- `ansible/roles/web-server/nginx/tasks/main.yml`
- `ansible/roles/web-server/nginx/templates/site.tmp.j2` (множество мест)
- Возможно ещё в других ролях.

### D2.2. Замена

В `group_vars/all/main.yml`:

ДО:
```yaml
DOMAIN_NAME: domain.zone
```

ПОСЛЕ:
```yaml
domain_name: domain.zone
```

Во всех использованиях `{{ DOMAIN_NAME }}` → `{{ domain_name }}`.

Пример для nginx-template (одна из многих строк):

ДО:
```nginx
server_name {{ DOMAIN_NAME }} www.{{ DOMAIN_NAME }};
root        {{ web_root }}/{{ DOMAIN_NAME }}/app/frontend/pub/;
```

ПОСЛЕ:
```nginx
server_name {{ domain_name }} www.{{ domain_name }};
root        {{ web_root }}/{{ domain_name }}/app/frontend/pub/;
```

**Коммит:** `refactor(ansible): rename DOMAIN_NAME → domain_name`

## D3. `HOST_IP` → `host_ip`

```bash
grep -RIn "HOST_IP" ansible/
```

В `group_vars/all/main.yml`:

ДО:
```yaml
HOST_IP: "{{ hostvars[groups['site'][0]]['ansible_host'] }}"
```

ПОСЛЕ:
```yaml
host_ip: "{{ hostvars[groups['site'][0]]['ansible_host'] }}"
```

Заменить все `{{ HOST_IP }}` → `{{ host_ip }}` в ролях.

**Коммит:** `refactor(ansible): rename HOST_IP → host_ip`

## D4. `LOCAL_HOME_PATH` → `local_home_path`

```bash
grep -RIn "LOCAL_HOME_PATH" ansible/
```

В `group_vars/all/ssh.yml`:

ДО:
```yaml
LOCAL_HOME_PATH: "{{ lookup('env', 'HOME') }}"
...
ssh_known_hosts_path: "{{ LOCAL_HOME_PATH }}/.ssh/known_hosts"
...
local_ssh_keys_dir: "{{ LOCAL_HOME_PATH }}/.ssh"
```

ПОСЛЕ:
```yaml
local_home_path: "{{ lookup('env', 'HOME') }}"
...
ssh_known_hosts_path: "{{ local_home_path }}/.ssh/known_hosts"
...
local_ssh_keys_dir: "{{ local_home_path }}/.ssh"
```

**Коммит:** `refactor(ansible): rename LOCAL_HOME_PATH → local_home_path`

## D5. `banTime`, `findTime`, `maxRetry` → snake_case

В `group_vars/all/security.yml`:

ДО:
```yaml
banTime: 3600
findTime: 600
maxRetry: 5
```

ПОСЛЕ:
```yaml
ban_time: 3600
find_time: 600
max_retry: 5
```

В `roles/system/fail2ban/templates/jail.local.j2`:

ДО:
```jinja
bantime = {{ banTime }}
findtime = {{ findTime }}
maxretry = {{ maxRetry }}
```

ПОСЛЕ:
```jinja
bantime = {{ ban_time }}
findtime = {{ find_time }}
maxretry = {{ max_retry }}
```

**Коммит:** `refactor(ansible): rename fail2ban camelCase vars to snake_case`

## D6. `jailsEnableStatus` → `jails_enable_status`, ключи внутри тоже в snake_case

Самая объёмная правка — потому что ключи внутри объекта тоже надо переименовать
(`nginx-http-auth` → `nginx_http_auth` и т.д., иначе тот же Jinja-капкан).

### D6.1. Заменить определение в `group_vars/all/security.yml`

ДО:
```yaml
jailsEnableStatus:
  sshd: true
  nginx-http-auth: true
  nginx-limit-req: false
  nginx-botsearch: true
  nginx-bad-request: true
  nginx-forbidden: true
  php-url-fopen: true
  ...
  php-fpm: false
  redis-auth: false
  yii2-auth: false
```

ПОСЛЕ:
```yaml
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
  yii2_auth: false
```

### D6.2. Поправить `jail.local.j2`

ДО:
```jinja
[sshd]
enabled = {{ jailsEnableStatus.sshd | bool | lower }}

[nginx-http-auth]
enabled = {{ jailsEnableStatus['nginx-http-auth'] | bool | lower }}

[nginx-limit-req]
enabled = {{ jailsEnableStatus['nginx-limit-req'] | bool | lower }}

[php-fpm]
enabled = {{ jailsEnableStatus['php-fpm'] | bool | lower }}
port = http,https
filter = php-fpm
logpath = /var/log/php{{ php_version }}-fpm.log
backend = polling
```

ПОСЛЕ:
```jinja
[sshd]
enabled = {{ jails_enable_status.sshd | bool | lower }}

[nginx-http-auth]
enabled = {{ jails_enable_status.nginx_http_auth | bool | lower }}

[nginx-limit-req]
enabled = {{ jails_enable_status.nginx_limit_req | bool | lower }}

[php-fpm]
enabled = {{ jails_enable_status.php_fpm | bool | lower }}
port = http,https
filter = php-fpm
logpath = /var/log/php{{ php_version }}-fpm.log
backend = polling
```

**Важно:** имена jail в заголовках секций (`[nginx-http-auth]`, `[php-fpm]`) **остаются с
дефисами** — это формат fail2ban, не Jinja. Меняем только обращения вида
`jails_enable_status['nginx-http-auth']` → `jails_enable_status.nginx_http_auth`.

**Коммит:** `refactor(ansible): rename jailsEnableStatus → jails_enable_status (snake_case keys too)`

---

# Фаза E. SSH-ключи → `ansible/secrets/ssh/`

## E1. Создать директорию и обновить `.gitignore`

```bash
mkdir -p ansible/secrets/ssh
```

В `ansible/.gitignore` добавить строку:

ДО:
```
/inventory/hosts.yml
/logs/*
/mysql_dump
/secrets/!vault_pass.txt
/secrets/secrets.yml
```

ПОСЛЕ:
```
/inventory/hosts.yml
/logs/*
/mysql_dump
/secrets/!vault_pass.txt
/secrets/secrets.yml
/secrets/ssh/
```

Опционально: положить пустой `.gitkeep` в `ansible/secrets/ssh/`, чтобы директория
гарантированно существовала в свежей копии репо:

```bash
touch ansible/secrets/ssh/.gitkeep
```

(`.gitkeep` не игнорируется, потому что в `.gitignore` указана сама директория `/ssh/`,
но git ignore-правило с trailing slash игнорирует только содержимое; `.gitkeep` всё равно
попадёт под игнор. Проще явное исключение):

```
/secrets/ssh/*
!/secrets/ssh/.gitkeep
```

**Коммит:** `chore(ansible): add secrets/ssh/ directory with gitignore`

## E2. Переключить `local_ssh_keys_dir` на новую директорию

**Файл:** `ansible/group_vars/all/ssh.yml`

ДО:
```yaml
local_ssh_keys_dir: "{{ local_home_path }}/.ssh"
```

ПОСЛЕ:
```yaml
local_ssh_keys_dir: "{{ playbook_dir }}/../secrets/ssh"
```

`local_home_path` остаётся для `ssh_known_hosts_path` — `~/.ssh/known_hosts` живёт в HOME
по-прежнему.

**После этого коммита** существующие ключи (если есть) в `~/.ssh/` перестанут
использоваться. Нужно либо перенести их вручную:

```bash
mv ~/.ssh/key_<domain>* ansible/secrets/ssh/
```

либо перегенерировать через `make local-init` (этот плейбук вообще не подключается к
серверу, можно запускать без риска).

**Коммит:** `refactor(ansible): store SSH keys in project (secrets/ssh/) instead of HOME`

## E3. Обновить `inventory/hosts.yml.example`

**Файл:** `ansible/inventory/hosts.yml.example`

ДО:
```yaml
---
all:
  children:
    site:
      hosts:
        server:
          ansible_connection: ssh
          ansible_host: 000.000.000.000
          ansible_port: 22
          ansible_ssh_private_key_file: "{{ site_ansible_key | default(omit) }}"
          ansible_user: "{{ site_ansible_user }}"
          ansible_password: "{{ vault_ansible_password | default(omit) }}"
```

ПОСЛЕ:
```yaml
---
all:
  children:
    site:
      hosts:
        server:
          ansible_connection: ssh
          ansible_host: 000.000.000.000
          ansible_port: 22
          ansible_ssh_private_key_file: "{{ ordinary_key_path }}"
          ansible_user: "{{ site_ansible_user }}"
          # ansible_password больше не нужен — Ansible работает только по ключу.
          # Если нужен пароль для первого ssh-copy-id, использовать ssh CLI напрямую.
```

В `group_vars/all/ssh.yml` синхронно убрать `site_ansible_key` (он стал лишним):

ДО:
```yaml
site_ansible_user: root
site_ansible_key: ~
```

ПОСЛЕ:
```yaml
site_ansible_user: root
```

**Коммит:** `refactor(ansible): use ordinary_key_path directly in inventory`

## E4. Захардкодить `ssh_key_passphrase: ""` для stages 0–6

**Проблема (внешний обзор п. 7):** сейчас `ssh_key_passphrase: "{{ vault_ssh_key_passphrase }}"`
читает из vault. Если в vault уже что-то лежит — Stage 0 сгенерит ключ с passphrase, и
весь основной цикл сломается.

**Файл:** `ansible/group_vars/all/ssh.yml`

ДО:
```yaml
ssh_key_passphrase: "{{ vault_ssh_key_passphrase }}"
```

ПОСЛЕ:
```yaml
# Stages 0–6 работают БЕЗ passphrase. Vault-переменная зарезервирована за Stage 7.
ssh_key_passphrase: ""
stage7_ssh_key_passphrase: "{{ vault_ssh_key_passphrase | default('') }}"
```

В Stage 7 (если будем делать) — использовать `stage7_ssh_key_passphrase`.

**Коммит:** `fix(ansible): hardcode empty ssh_key_passphrase for stages 0-6`

---

# Фаза F. Stage-плейбуки (создание рядом со старыми)

Создаём новые `stage-*.yml` **рядом** со старыми `remote-*.yml`. Старые продолжают
работать. Только в фазе J удалим старые.

## F1. Новая роль `verify_ssh`

Параметризация — **через `vars:` блок при `include_role`**, не через group_vars (иначе
проверим только одного пользователя в плейбуке). И пользователь, и ключ — параметры роли.

### F1.1. Создать `roles/system/verify_ssh/defaults/main.yml`

```yaml
---
# Переменные роли. Переопределяются при include_role + vars:
# - verify_ssh_user — какого пользователя проверять (root, "{{ new_user }}", etc.)
# - verify_ssh_key  — каким приватным ключом подключаться
verify_ssh_user: root
verify_ssh_key: "{{ emergency_key_path }}"
```

### F1.2. Создать `roles/system/verify_ssh/tasks/main.yml`

```yaml
---
- name: "verify_ssh: SSH login {{ verify_ssh_user }}@{{ target_host }}"
  delegate_to: localhost
  command: >
    ssh -i {{ verify_ssh_key }}
        -o BatchMode=yes
        -o StrictHostKeyChecking=yes
        -o ConnectTimeout=10
        -p {{ target_ssh_port }}
        {{ verify_ssh_user }}@{{ target_host }} "echo OK"
  register: verify_ssh_result
  changed_when: false
  failed_when: "'OK' not in verify_ssh_result.stdout"

- name: "verify_ssh: assert login succeeded for {{ verify_ssh_user }}"
  assert:
    that:
      - verify_ssh_result.rc == 0
    fail_msg: "SSH login as {{ verify_ssh_user }} via {{ verify_ssh_key }} FAILED!"
    success_msg: "SSH login as {{ verify_ssh_user }} OK"
```

### F1.3. Пример использования (для F5, F6)

```yaml
- name: Verify root SSH login via emergency key
  include_role:
    name: verify_ssh
  vars:
    verify_ssh_user: root
    verify_ssh_key: "{{ emergency_key_path }}"

- name: Verify sudo user SSH login via ordinary key
  include_role:
    name: verify_ssh
  vars:
    verify_ssh_user: "{{ new_user }}"
    verify_ssh_key: "{{ ordinary_key_path }}"
```

**Коммит:** `feat(ansible): add verify_ssh role for real SSH key login check`

## F2. Новая роль `ssh_remote_user_keys`

По образцу `ssh_remote_root_keys`, но деплоит **обычный** публичный ключ на
`new_user` (а не emergency на root).

### F2.1. Создать `roles/system/ssh_remote_user_keys/tasks/main.yml`

```yaml
---
- name: Ensure .ssh directory exists for new user
  file:
    path: "/home/{{ new_user }}/.ssh"
    state: directory
    mode: '0700'
    owner: "{{ new_user }}"
    group: "{{ new_user }}"

- name: Copy ordinary public key to {{ new_user }}
  authorized_key:
    user: "{{ new_user }}"
    key: "{{ lookup('file', ordinary_pubkey_path) }}"
    state: present
    manage_dir: yes
```

> Зачем отдельная роль, если можно положить в `user_sudo_add_new`? Чтобы:
> - роли соответствовали ровно одной задаче (создание юзера vs. деплой ключа);
> - имена ролей `ssh_remote_root_keys` и `ssh_remote_user_keys` симметричны и в плейбуке
>   видно, какой ключ куда едет.

**Коммит:** `feat(ansible): add ssh_remote_user_keys role for sudo user pubkey deploy`

## F3. `playbooks/stage-0-local-init.yml`

**Новый файл:** `ansible/playbooks/stage-0-local-init.yml`

```yaml
##########################################################
# Stage 0: локальная инициализация
# 1) Pre-flight: проверка что inventory загружен
# 2) Генерация SSH-ключей (ordinary + emergency) в secrets/ssh/
# 3) Добавление отпечатка сервера в ~/.ssh/known_hosts
##########################################################
---
- name: Pre-flight checks for stage 0
  hosts: localhost
  gather_facts: false
  tasks:
    - name: Assert site group is non-empty in inventory
      assert:
        that:
          - groups['site'] is defined
          - groups['site'] | length > 0
        fail_msg: "Inventory file does not define group 'site'. Запустите с -i inventory/hosts.yml"

- name: Generate SSH keys and trust remote host
  hosts: localhost
  gather_facts: false
  roles:
    - ../roles/system/ssh_generate_local_keys
    - ../roles/system/ssh_add_remote_host_to_known_hosts
```

> `gather_facts: false` для localhost — не нужны.
> `-i inventory/hosts.yml` обязателен при запуске — иначе `groups['site']` пустой.

**Коммит:** `feat(ansible): add stage-0-local-init.yml playbook`

## F4. `playbooks/stage-1-server-base.yml`

**Новый файл:** `ansible/playbooks/stage-1-server-base.yml`

Из `remote-base.yml` забираем только базовую конфигурацию ОС. UFW и fail2ban — НЕ
включаем, они переезжают в Stage 3.

```yaml
##########################################################
# Stage 1: базовая настройка ОС
# 1) Обновление security-патчей
# 2) Локали, hostname, timezone
# 3) Swap
# 4) Лимиты journald
#
# UFW и fail2ban — в Stage 3, чтобы не мешать первой проверке ключей.
##########################################################
---
- name: Pre-flight checks for stage 1
  hosts: site
  gather_facts: false
  tasks:
    - name: Assert essential variables are defined
      assert:
        that:
          - domain_name is defined and domain_name | length > 0
          - host_ip is defined and host_ip | length > 0
        fail_msg: "domain_name or host_ip is missing. Check group_vars/all/main.yml."

- name: Stage 1 - OS base configuration
  hosts: site
  remote_user: root
  gather_facts: true
  roles:
    - ../roles/system/apt_update
    - ../roles/system/locales_hostname_timezone
    - ../roles/system/swap
    - ../roles/system/systemd
```

> `become: true` намеренно убран — `remote_user: root` уже даёт нужные права. `become`
> относится к sudo-эскалации, под root она не нужна.

**Коммит:** `feat(ansible): add stage-1-server-base.yml playbook`

## F5. `playbooks/stage-2-server-access.yml`

**Новый файл:** `ansible/playbooks/stage-2-server-access.yml`

```yaml
##########################################################
# Stage 2: настройка пользовательского доступа
# 1) Создание sudo-пользователя
# 2) Деплой emergency-ключа на root
# 3) Деплой обычного ключа на sudo-пользователя
# 4) Перенаправление SSH-логов в journald
# 5) Verify SSH-входа для root и для new_user
#
# ВНИМАНИЕ: пароль НЕ отключается, hardening — в Stage 3.
##########################################################
---
- name: Pre-flight checks for stage 2
  hosts: site
  gather_facts: false
  tasks:
    - name: Assert new_user is set
      assert:
        that:
          - new_user is defined and new_user | length > 0
        fail_msg: "new_user is not set. Check group_vars/all/ssh.yml."

- name: Stage 2 - User access setup
  hosts: site
  remote_user: root
  gather_facts: true
  roles:
    - ../roles/system/user_sudo_add_new
    - ../roles/system/ssh_remote_root_keys      # emergency на root
    - ../roles/system/ssh_remote_user_keys      # ordinary на new_user (F2)
    - ../roles/system/ssh_logs_journald

  post_tasks:
    - name: Verify root SSH login via emergency key
      include_role:
        name: ../roles/system/verify_ssh
      vars:
        verify_ssh_user: root
        verify_ssh_key: "{{ emergency_key_path }}"

    - name: Verify new_user SSH login via ordinary key
      include_role:
        name: ../roles/system/verify_ssh
      vars:
        verify_ssh_user: "{{ new_user }}"
        verify_ssh_key: "{{ ordinary_key_path }}"
```

> `post_tasks:` — выполняются после ролей. Это правильное место для проверок «после
> деплоя всё работает».

**Коммит:** `feat(ansible): add stage-2-server-access.yml playbook`

## F6. `playbooks/stage-3-server-security.yml`

**Новый файл:** `ansible/playbooks/stage-3-server-security.yml`

Порядок шагов (внешний обзор п. 6):
1. pre-check verify_ssh — убедиться что ключи работают **до** того как отключим пароль.
2. UFW — фаервол.
3. ssh_remote_security — отключение пароля + hardening sshd.
4. post-check verify_ssh — убедиться что после hardening ключи всё ещё работают.
5. fail2ban — поднимаем jails **после** post-check (иначе серия SSH-проверок может
   забанить контроллер).
6. AppArmor (опц.) — complain mode.

```yaml
##########################################################
# Stage 3: hardening
# Запускать ТОЛЬКО после успешного Stage 2.
##########################################################
---
- name: Pre-flight checks for stage 3
  hosts: site
  gather_facts: false
  tasks:
    - name: Assert essential variables
      assert:
        that:
          - new_user is defined and new_user | length > 0
        fail_msg: "new_user is not set"

- name: Stage 3 - Security hardening
  hosts: site
  remote_user: root
  gather_facts: true

  pre_tasks:
    - name: Pre-check root SSH login
      include_role:
        name: ../roles/system/verify_ssh
      vars:
        verify_ssh_user: root
        verify_ssh_key: "{{ emergency_key_path }}"

    - name: Pre-check new_user SSH login
      include_role:
        name: ../roles/system/verify_ssh
      vars:
        verify_ssh_user: "{{ new_user }}"
        verify_ssh_key: "{{ ordinary_key_path }}"

  roles:
    - ../roles/system/ufw
    - ../roles/system/ssh_remote_security

  post_tasks:
    - name: Post-check root SSH login after sshd hardening
      include_role:
        name: ../roles/system/verify_ssh
      vars:
        verify_ssh_user: root
        verify_ssh_key: "{{ emergency_key_path }}"

    - name: Post-check new_user SSH login after sshd hardening
      include_role:
        name: ../roles/system/verify_ssh
      vars:
        verify_ssh_user: "{{ new_user }}"
        verify_ssh_key: "{{ ordinary_key_path }}"

- name: Stage 3 - Enable fail2ban (after SSH verification)
  hosts: site
  remote_user: root
  roles:
    - ../roles/system/fail2ban
    # AppArmor (после фазы B4 — в complain mode) можно включать тут же или отдельно:
    # - ../roles/system/app_armor
```

> fail2ban вынесен в отдельную play **специально** — чтобы post-tasks из предыдущей play
> отработали до того как jail [sshd] активируется.

**Коммит:** `feat(ansible): add stage-3-server-security.yml playbook`

## F7. `playbooks/stage-4-webserver.yml`

**Новый файл:** `ansible/playbooks/stage-4-webserver.yml`

Аналог `remote-webserver.yml`. **Единое решение по `remote_user` (внешний обзор п. 4):**
**root**, никакого `become_user: new_user`.

```yaml
##########################################################
# Stage 4: LEMP-стек
# Redis, Memcached, MySQL, Nginx, PHP + очистка apt.
##########################################################
---
- name: Pre-flight checks for stage 4
  hosts: site
  gather_facts: false
  tasks:
    - name: Assert vault-derived variables
      assert:
        that:
          - vault_mysql_root_password is defined and vault_mysql_root_password | length > 0
          - vault_mysql_db_user_password is defined and vault_mysql_db_user_password | length > 0
          # vault_redis_password добавится в фазе H1
        fail_msg: |
          Required vault variables are missing.
          Проверьте что group_vars/all/secrets.vault расшифровывается и содержит ключи.

- name: Stage 4 - LEMP stack installation
  hosts: site
  remote_user: root
  gather_facts: true
  roles:
    - ../roles/web-server/redis
    - ../roles/web-server/memcached
    - ../roles/web-server/mysql
    - ../roles/web-server/nginx
    - ../roles/web-server/php

- name: Stage 4 - Cleanup
  hosts: site
  remote_user: root
  roles:
    - ../roles/system/apt_clean
```

**Коммит:** `feat(ansible): add stage-4-webserver.yml playbook`

## F8. Smoke-тест на тестовом сервере

Без коммита. Прогон каждого стейджа подряд:

```bash
ansible-playbook -i inventory/hosts.yml playbooks/stage-0-local-init.yml
ansible-playbook -i inventory/hosts.yml playbooks/stage-1-server-base.yml
ansible-playbook -i inventory/hosts.yml playbooks/stage-2-server-access.yml
ansible-playbook -i inventory/hosts.yml playbooks/stage-3-server-security.yml
ansible-playbook -i inventory/hosts.yml playbooks/stage-4-webserver.yml
```

Если что-то падает — фиксим до фазы G.

---

# Фаза G. `nginx_sites` + создание `web_root`

## G1. Добавить `nginx_sites` в `group_vars/all/webserver.yml`

В конец файла:

```yaml
##########################################################
# NGINX SITES
##########################################################

nginx_sites:
  - name: frontend
    server_name: "{{ domain_name }} www.{{ domain_name }}"
    web_root: "{{ web_root }}/{{ domain_name }}/app/frontend/pub"
    client_max_body_size: 10M
    php_fpm: true
  - name: backend
    server_name: "adm.{{ domain_name }} www.adm.{{ domain_name }}"
    web_root: "{{ web_root }}/{{ domain_name }}/app/backend/pub"
    client_max_body_size: 750M
    php_fpm: true
  - name: static
    server_name: "files.{{ domain_name }} www.files.{{ domain_name }}"
    web_root: "{{ web_root }}/{{ domain_name }}/app/static"
    client_max_body_size: 1024M
    php_fpm: false
```

На этом шаге переменная определена, но **не используется** — это безопасный коммит.

**Коммит:** `feat(ansible): introduce nginx_sites structure`

## G2. Добавить создание `web_root` в роль `nginx`

**Файл:** `ansible/roles/web-server/nginx/tasks/main.yml`

Вставить **перед** задачей `Copy host settings` (чтобы директории существовали до того,
как nginx попытается их обслуживать):

```yaml
- name: Create web roots for all configured nginx sites
  ansible.builtin.file:
    path: "{{ item.web_root }}"
    state: directory
    owner: www-data
    group: www-data
    mode: '0755'
  loop: "{{ nginx_sites }}"
  loop_control:
    label: "{{ item.name }}"
```

> Заменяет закомментированный блок `Create web root directories` в конце файла.

**Коммит:** `feat(ansible): create web_root directories in nginx role`

## G3. Переписать `site.tmp.j2` как цикл по `nginx_sites`

**Файл:** `ansible/roles/web-server/nginx/templates/site.tmp.j2`

Сейчас в нём три почти одинаковых `server { ... }` блока с хардкодом. Заменяем на цикл.

ПОСЛЕ (полное содержимое):

```jinja
{% for site in nginx_sites %}
server {
    listen 80;
    charset utf-8;
    client_max_body_size {{ site.client_max_body_size }};
    sendfile off;
    server_tokens off;

    server_name {{ site.server_name }};
    root        {{ site.web_root }};
{% if site.php_fpm %}
    index       index.php;
{% else %}
    index       index.html;
{% endif %}

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    location ~ /\.(ht|svn|git|env|json|lock|yml) {
        deny all;
    }

    location ~* \.(jpg|jpeg|png|gif|ico|css|js|woff|woff2|ttf|svg|eot|otf|ttc)$ {
        expires 1y;
        access_log off;
        add_header Cache-Control "public";
    }

{% if site.php_fpm %}
    location / {
        try_files $uri $uri/ /index.php$is_args$args;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php{{ php_version }}-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO $fastcgi_path_info;
        try_files $uri =404;
        fastcgi_read_timeout 60s;
        fastcgi_connect_timeout 60s;
        fastcgi_send_timeout 60s;
    }
{% else %}
    location / {
        try_files $uri $uri/ =404;
    }
{% endif %}
}

{% endfor %}
```

**HTTPS-редирект** не добавляем — он появится в Stage 5a (Certbot). До получения
сертификатов сайт живёт на 80 порту, и это нормально.

**Коммит:** `refactor(ansible): generate nginx site config from nginx_sites loop`

## G4. (опц.) Полное управление SSL из Ansible-шаблонов

Только если решили идти по варианту «certbot certonly + Ansible сам пишет SSL-блоки»
(⚠️⚠️ ЗАМЕЧАНИЕ 2 в ANALYSIS 3.2.3).

Логика:
- В `nginx_sites` добавить булевый ключ `ssl_enabled: false` (по умолчанию).
- Stage 5a после получения сертификатов переключает `ssl_enabled: true` (либо через
  отдельный inventory var, либо проще — через factual check
  `stat: path=/etc/letsencrypt/live/.../fullchain.pem`).
- В шаблоне `site.tmp.j2` добавить `{% if site.ssl_enabled %}{% set has_ssl = true %}{% endif %}`
  блок 443 с подключением сертификатов и `return 301 https://...` в 80-блоке.

Этот шаг можно отложить — если в Stage 5a будем использовать `certbot --nginx`, он сам
правит конфиги. Рекомендуется к G4 не приступать без явного решения.

**Коммит (если делаем):** `feat(ansible): manage SSL inclusion in nginx templates`

---

# Фаза H. Security-правки

## H1. Redis с паролем

### H1.1. Добавить `vault_redis_password` в `secrets.vault`

```bash
ansible-vault edit ansible/group_vars/all/secrets.vault
```

В открывшемся редакторе добавить:

```yaml
vault_redis_password: "сгенерированный_длинный_пароль"
```

### H1.2. Раскомментировать маппинг в `group_vars/all/vault.yml`

ДО:
```yaml
redis_password_from_vault: "{{ vault_redis_password | default('') }}"
```

ПОСЛЕ:
```yaml
redis_password: "{{ vault_redis_password }}"
```

(Убираем `default('')` — теперь переменная обязательна.)

### H1.3. Добавить `requirepass` в `redis.conf.j2`

**Файл:** `ansible/roles/web-server/redis/templates/redis.conf.j2`

ДО:
```
bind 127.0.0.1
protected-mode yes
port 6379
maxmemory 128mb
maxmemory-policy allkeys-lru
logfile ""
loglevel warning
supervised systemd
dir /var/lib/redis
dbfilename dump.rdb
```

ПОСЛЕ:
```
bind 127.0.0.1
protected-mode yes
port 6379
requirepass {{ redis_password }}
maxmemory 128mb
maxmemory-policy allkeys-lru
logfile ""
loglevel warning
supervised systemd
dir /var/lib/redis
dbfilename dump.rdb
```

### H1.4. Добавить pre-flight assert в Stage 4

В `playbooks/stage-4-webserver.yml` в блок assert (см. F7) добавить:

```yaml
- vault_redis_password is defined and vault_redis_password | length > 0
```

**Доставка пароля в Yii2** — вне зоны Ansible-проекта (см. ANALYSIS 3.2.1).

**Коммит:** `feat(ansible): protect redis with requirepass from vault`

## H2. PHP security/opcache/apcu конфиги

### H2.1. Создать `roles/web-server/php/files/conf.d/security.ini`

```ini
; Отключаем опасные функции
disable_functions = system,exec,shell_exec,passthru,proc_open,popen,proc_close,curl_multi_exec,parse_ini_file,show_source,phpinfo

; Не раскрывать версию PHP в HTTP-заголовках
expose_php = Off

; Отключаем удалённые URL в file-функциях (RFI-вектор)
allow_url_fopen = Off
allow_url_include = Off

; Лимит размера POST/upload — синхронизирован с nginx client_max_body_size
; (берём максимум из nginx_sites; если нужно меньше — переопределяем)
; post_max_size = 1024M
; upload_max_filesize = 1024M
```

### H2.2. Создать `roles/web-server/php/files/conf.d/opcache.ini`

```ini
opcache.enable=1
opcache.enable_cli=1
opcache.memory_consumption=128
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000
opcache.validate_timestamps=0
opcache.revalidate_freq=0
opcache.save_comments=1
```

> `validate_timestamps=0` — для production. После деплоя кода нужно вручную делать
> `systemctl reload php-fpm` или OPcache reset. На dev оставить `1`.

### H2.3. Создать `roles/web-server/php/files/conf.d/apcu.ini`

```ini
apcu.enable=1
apcu.enable_cli=1
apcu.shm_size=64M
```

### H2.4. (опц.) Создать `roles/web-server/php/files/conf.d/open_basedir.ini`

```ini
; ОСТОРОЖНО: может сломать composer-операции из под www-data и системные пути библиотек.
; Включайте только после полной проверки приложения.
; open_basedir = /var/www/:/tmp/:/usr/share/php/
```

Файл создаём с закомментированной директивой — чтобы потом раскомментировать вручную
после ручного тестирования.

### H2.5. Проверить что роль php копирует все файлы из conf.d/

В `ansible/roles/web-server/php/tasks/main.yml` уже есть:

```yaml
- name: Copy PHP configuration files from files/conf.d
  ansible.builtin.copy:
    src: files/conf.d/
    dest: /etc/php/{{ php_version }}/fpm/conf.d/
    owner: www-data
```

Если этой задачи нет (или копируются не все файлы) — добавить/исправить. Также скопировать
в `cli` SAPI (если используется CLI Yii2):

```yaml
- name: Copy PHP configuration files to cli/conf.d
  ansible.builtin.copy:
    src: files/conf.d/
    dest: /etc/php/{{ php_version }}/cli/conf.d/
    owner: root
    group: root
    mode: '0644'
```

**Коммит:** `feat(ansible): add php security/opcache/apcu ini files`

## H3. Pre-flight assert по vault-переменным во все stage-плейбуки

Уже частично сделано в F4–F7. На этом шаге — формализуем. Per-stage списки переменных:

| Stage | vault-переменные для assert |
|-------|------------------------------|
| 0     | (ничего) |
| 1     | (ничего) |
| 2     | (ничего из vault; проверяем `new_user`) |
| 3     | (ничего из vault) |
| 4     | `vault_mysql_root_password`, `vault_mysql_db_user_password`, `vault_redis_password` |
| 5a    | (ничего из vault; проверяем DNS) |
| 5b    | (ничего) |
| 6     | (ничего) |

Шаблон pre-flight (повторно — см. F4):

```yaml
- name: Pre-flight checks for stage N
  hosts: site            # или localhost для stage 0
  gather_facts: false
  tasks:
    - name: Assert required vault variables are defined
      assert:
        that:
          - vault_mysql_root_password is defined and vault_mysql_root_password | length > 0
          # ...
        fail_msg: |
          Required vault variables are missing or empty.
          Make sure group_vars/all/secrets.vault is decrypted and contains all required keys.
      run_once: true
```

> **Важно (внешний обзор п. 1):** `vault_root_password` НЕ проверяем — переменная выпилена.

**Коммит:** `feat(ansible): formalize per-stage pre-flight assert on vault variables`

## H4. (опц.) `[yii2-auth]` jail в fail2ban

Только когда Yii2-приложение начнёт писать через Monolog→SyslogHandler с ident
`yii2-auth`. До этого:
- `jails_enable_status.yii2_auth: false` (уже в C4).
- В `jail.local.j2` добавить блок (необходим filter в `/etc/fail2ban/filter.d/yii2-auth.conf`,
  но его создание — задача отдельного коммита):

```jinja
[yii2-auth]
enabled = {{ jails_enable_status.yii2_auth | bool | lower }}
backend = systemd
journalmatch = _SYSTEMD_UNIT=php{{ php_version }}-fpm.service + SYSLOG_IDENTIFIER=yii2-auth
filter = yii2-auth
port = http,https
```

Файл фильтра `roles/system/fail2ban/files/filter.d/yii2-auth.conf` создаётся отдельно,
когда формат логов Monolog будет известен.

**Коммит:** `feat(ansible): add yii2-auth fail2ban jail (disabled by default)`

---

# Фаза I. Дополнительные stage-плейбуки

Не входят в `full-deploy`. Запускаются вручную по мере готовности внешних условий.

## I1. `stage-5a-certbot.yml`

**Новый файл:** `ansible/playbooks/stage-5a-certbot.yml`

Зависит от G2 (web_root уже создаётся в роли nginx). DNS должен указывать на сервер.

```yaml
##########################################################
# Stage 5a: Let's Encrypt сертификаты
# Запускать после Stage 4 и настройки DNS.
##########################################################
---
- name: Pre-flight checks for stage 5a
  hosts: site
  gather_facts: false
  tasks:
    - name: Resolve {{ domain_name }} (DNS check)
      delegate_to: localhost
      command: dig +short {{ domain_name }}
      register: dns_check
      changed_when: false

    - name: Assert DNS resolves to server IP
      assert:
        that:
          - dns_check.stdout | trim == host_ip
        fail_msg: |
          DNS для {{ domain_name }} указывает на {{ dns_check.stdout | trim }},
          а сервер — {{ host_ip }}. Поправь DNS и повтори.

- name: Stage 5a - Certbot
  hosts: site
  remote_user: root
  roles:
    - ../roles/web-server/certbot
```

В `roles/web-server/certbot/tasks/main.yml` (создаётся/обновляется отдельно — это код
самой роли, не плейбука):

```yaml
---
- name: Install certbot + nginx plugin
  apt:
    name:
      - certbot
      - python3-certbot-nginx
    state: present
    update_cache: yes

- name: Build list of -d arguments from nginx_sites
  set_fact:
    certbot_domains_args: >-
      {{ nginx_sites | map(attribute='server_name')
                     | map('split', ' ')
                     | flatten
                     | map('regex_replace', '^(.+)$', '-d \1')
                     | join(' ') }}

- name: Request Let's Encrypt certificates
  command: >
    certbot --nginx --non-interactive --agree-tos
            -m {{ certbot_email }}
            {{ certbot_domains_args }}
  args:
    creates: "/etc/letsencrypt/live/{{ domain_name }}/fullchain.pem"

- name: Ensure certbot renew timer is enabled
  systemd:
    name: certbot.timer
    enabled: yes
    state: started
```

**Коммит:** `feat(ansible): add stage-5a-certbot.yml playbook`

## I2. `stage-5b-queue.yml`

**Новый файл:** `ansible/playbooks/stage-5b-queue.yml`

```yaml
##########################################################
# Stage 5b: Yii2 queue workers (systemd units)
# Юниты раскладываются на сервер в state=stopped, enabled=no.
# Запуск — вручную после деплоя исходников приложения:
#     systemctl enable --now yii-queue@1
##########################################################
---
- name: Stage 5b - Queue workers
  hosts: site
  remote_user: root
  roles:
    - ../roles/web-server/queue/systemd
```

В роли `roles/web-server/queue/systemd/` нужно убедиться, что юнит-файл:
- использует `{{ queue_workers_count }}` для параметризации;
- содержит `MemoryMax`, `CPUQuota`, `RestartSec=5`;
- юнит-задача в Ansible — `state: stopped, enabled: no` (не `started/enabled`).

Пример конца роли:

```yaml
- name: Install yii-queue@.service unit
  template:
    src: yii-queue@.service.j2
    dest: /etc/systemd/system/yii-queue@.service
    mode: '0644'

- name: Reload systemd
  systemd:
    daemon_reload: yes

- name: Ensure units are stopped and disabled (will be enabled manually after first deploy)
  systemd:
    name: "yii-queue@{{ item }}"
    state: stopped
    enabled: no
  loop: "{{ range(1, queue_workers_count + 1) | list }}"
  ignore_errors: true  # юнит может ещё не существовать на первой итерации
```

**Коммит:** `feat(ansible): add stage-5b-queue.yml playbook`

## I3. `stage-5c-data-transfer.yml` (резерв)

**Новый файл:** `ansible/playbooks/stage-5c-data-transfer.yml`

```yaml
##########################################################
# Stage 5c: data_transfer (РЕЗЕРВ, не используется по умолчанию)
# Деплой исходников через rsync + импорт MySQL-дампа.
# В Makefile не входит в full-deploy.
##########################################################
---
- name: Stage 5c - Data transfer (RESERVE)
  hosts: site
  remote_user: root
  roles:
    - ../roles/web-server/data_transfer
```

Хардкод путей `/mnt/a/openserver/...` и `mode: '7777'` в роли **не трогаем** — пока роль
не используется. При активации — почистить.

**Коммит:** `feat(ansible): add stage-5c-data-transfer.yml playbook (reserve)`

## I4. Переименовать `docker.yml` → `optional-docker.yml`

```bash
git mv ansible/playbooks/docker.yml ansible/playbooks/optional-docker.yml
```

(Обновление до Ubuntu Noble + Docker Compose v2 — отдельный шаг при необходимости.)

**Коммит:** `chore(ansible): rename docker.yml → optional-docker.yml`

---

# Фаза J. Удаление старого + новый Makefile

## J1. Удалить старые `remote-*.yml`

После того как фаза F прошла smoke-тест и stage-плейбуки работают:

```bash
git rm ansible/playbooks/local-init.yml
git rm ansible/playbooks/remote-base.yml
git rm ansible/playbooks/remote-security.yml
git rm ansible/playbooks/remote-webserver.yml
```

`remote-test.yml`, `remote-test-security.yml` — оставить, удалим в фазе K2 после Stage 6.

**Коммит:** `chore(ansible): remove legacy remote-*.yml playbooks`

## J2. Новый Makefile

**Файл:** `ansible/Makefile` — полная замена.

```makefile
include environments.sh
SHELL := /bin/bash
.ONESHELL:

# =============================================================================
# Stage-цели
# =============================================================================
stage-0:  ## Локально: SSH-ключи + known_hosts
	ansible-playbook -i inventory/hosts.yml playbooks/stage-0-local-init.yml

stage-1:  ## ОС: apt, locales, swap, systemd
	ansible-playbook -i inventory/hosts.yml playbooks/stage-1-server-base.yml

stage-2:  ## Доступ: sudo user, ключи, journald, verify
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

stage-7:  ## (опц.) Миграция ключей на passphrase
	ansible-playbook -i inventory/hosts.yml playbooks/stage-7-key-hardening.yml

docker-install: ## (РЕЗЕРВ) Установка Docker
	ansible-playbook -i inventory/hosts.yml playbooks/optional-docker.yml

# =============================================================================
# Комбинированные цели
# =============================================================================
full-deploy: stage-0 stage-1 stage-2 stage-3 stage-4 stage-6

# =============================================================================
# Vault
# =============================================================================
vault-encrypt:
	ansible-vault encrypt ./secrets/secrets.yml --output ./group_vars/all/secrets.vault
vault-create:
	ansible-vault create ./group_vars/all/secrets.vault
vault-edit:
	ansible-vault edit ./group_vars/all/secrets.vault
vault-view:
	ansible-vault view ./group_vars/all/secrets.vault

# =============================================================================
# Инициализация контроллера
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
		ansible-playbook -i inventory/hosts.yml $$f --syntax-check; \
	done

inventory-graph:
	ansible-inventory -i inventory/hosts.yml --graph

help:  ## Показать список команд
	@grep -E '^[a-zA-Z0-9_-]+:.*?##' $(MAKEFILE_LIST) | sort \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-18s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
```

**Важно:** в `stage-0` и `stage-7` — `-i inventory/hosts.yml` есть (внешний обзор п. 3).

**Коммит:** `chore(ansible): rewrite Makefile around stage-* targets`

---

# Фаза K. Stage 6 — verification

## K1. `playbooks/stage-6-verification.yml`

**Новый файл:** `ansible/playbooks/stage-6-verification.yml`

```yaml
##########################################################
# Stage 6: комплексная проверка сервера
##########################################################
---
- name: Stage 6 - Verify SSH access
  hosts: site
  gather_facts: false
  remote_user: "{{ new_user }}"
  tasks:
    - name: Verify root SSH login via emergency key
      include_role:
        name: ../roles/system/verify_ssh
      vars:
        verify_ssh_user: root
        verify_ssh_key: "{{ emergency_key_path }}"

    - name: Verify new_user SSH login via ordinary key
      include_role:
        name: ../roles/system/verify_ssh
      vars:
        verify_ssh_user: "{{ new_user }}"
        verify_ssh_key: "{{ ordinary_key_path }}"

- name: Stage 6 - Verify services
  hosts: site
  remote_user: root
  gather_facts: true
  tasks:
    - name: Check critical services are active
      command: systemctl is-active {{ item }}
      register: svc_status
      changed_when: false
      failed_when: svc_status.stdout != 'active'
      loop:
        - nginx
        - "php{{ php_version }}-fpm"
        - mysql
        - redis-server
        - memcached
        - ufw
        - fail2ban

    - name: List listening TCP ports
      command: ss -tlnp
      register: listening
      changed_when: false

    - name: Show listening ports
      debug:
        var: listening.stdout_lines

    - name: Check PHP modules
      command: "php -m"
      register: php_mods
      changed_when: false

    - name: Show PHP modules
      debug:
        var: php_mods.stdout_lines

    - name: Check UFW status
      command: ufw status verbose
      register: ufw_status
      changed_when: false

    - name: Show UFW status
      debug:
        var: ufw_status.stdout_lines

    - name: Check fail2ban-client status
      command: fail2ban-client status
      register: f2b_status
      changed_when: false

    - name: Show fail2ban status
      debug:
        var: f2b_status.stdout_lines

- name: Stage 6 - HTTP/HTTPS smoke
  hosts: site
  gather_facts: false
  remote_user: root
  tasks:
    - name: HTTP probe (80)
      uri:
        url: "http://{{ domain_name }}/"
        status_code: [200, 301, 302, 308, 404]
        validate_certs: false
        timeout: 10
      register: http_probe
      failed_when: false

    - name: HTTPS probe (443)
      uri:
        url: "https://{{ domain_name }}/"
        status_code: [200, 301, 302, 308, 404]
        validate_certs: false
        timeout: 10
      register: https_probe
      failed_when: false

    - name: Show HTTP/HTTPS probe results
      debug:
        msg:
          - "HTTP {{ http_probe.status | default('FAIL') }}"
          - "HTTPS {{ https_probe.status | default('not configured / FAIL') }}"
```

> Намеренно `failed_when: false` для HTTP/HTTPS — Stage 6 не должен падать на отсутствии
> Certbot. Админ сам читает вывод.

**Коммит:** `feat(ansible): add stage-6-verification.yml playbook`

## K2. Удалить `remote-test.yml`, `remote-test-security.yml`

После того как Stage 6 проверен на тестовом сервере:

```bash
git rm ansible/playbooks/remote-test.yml ansible/playbooks/remote-test-security.yml
```

В Makefile старые цели уже удалены (фаза J2).

**Коммит:** `chore(ansible): drop legacy remote-test*.yml in favor of stage-6`

---

# Фаза L (опц.). Stage 7 — миграция на passphrase

Запускается один раз в самом конце. После него Ansible с сервером больше не работает.

## L1. Решить судьбу старых ключей без passphrase

**Открытый вопрос (внешний обзор п. 9):** что делать со старыми ключами после
регенерации? Перед началом L1 — обсудить и зафиксировать политику в
`ansible/secrets/README.md`.

Предлагаемая логика:

1. Сгенерировать **новые** ключи с passphrase под именами
   `key_<domain>_with_passphrase` (рядом со старыми, без перезаписи).
2. Передеплоить новые публичные ключи на сервер.
3. Ручная проверка SSH под passphrase из обычного терминала.
4. Удалить старые публичные ключи из `/root/.ssh/authorized_keys` и
   `/home/<new_user>/.ssh/authorized_keys` на сервере.
5. Старые приватные ключи `key_<domain>`, `key_<domain>_emergency_root` — заархивировать
   в `ansible/secrets/ssh/_backup_no_passphrase.tar.gz` или удалить.

## L2. `playbooks/stage-7-key-hardening.yml`

Реализовать после согласования L1. Точный шаблон не привожу — зависит от того, какую
политику выберем в L1.

---

# Контрольные точки

После каждой фазы должно работать как минимум:

| После | Что работает |
|-------|--------------|
| A | (только документация) |
| B | Старый flow + правильный аварийный ключ + рабочие SSH-тесты + MySQL whitelist + AppArmor complain |
| C | Тот же flow, переменные читаются из `group_vars/all/*.yml` и `secrets.vault` |
| D | То же, переменные в snake_case |
| E | SSH-ключи в `ansible/secrets/ssh/`, не в HOME |
| F | Новый `make stage-0..stage-4` параллельно со старым `make remote-*` |
| G | Nginx без хардкода путей, web_root создаются перед стартом nginx |
| H | Redis с паролем, PHP security/opcache/apcu, formal pre-flight assert |
| I | Доступны `make stage-5a`, `stage-5b` (вручную) |
| J | Только новые `stage-*.yml`, `full-deploy = 0+1+2+3+4+6` |
| K | `make stage-6` проверяет весь сервер |
| L | (опц.) Ключи с passphrase, всё в KeePass |

---

# Параллельная работа

- **B** (багфиксы) — независима, можно начать первой.
- **C → D → E** — строго последовательно.
- **F** (новые плейбуки) — можно параллельно с **G/H**, пока не подключены в Makefile.
- **I** — после **G3** (nginx_sites).
- **J** — только после стабильного прогона новых stage-плейбуков ≥ 1 раз.

---

# Что НЕ делаем в этом плане

Зафиксировано в ANALYSIS как «низкий приоритет» или «вне зоны Ansible»:

- Бэкап-стратегия (mysqldump + cron) — отдельный будущий проект.
- Мониторинг (OOM, диск) — отдельный будущий проект.
- Очистка хардкода Windows-путей в `data_transfer` — не используется.
- gzip и rate-limiting в Nginx — отдельное улучшение после Stage 5a.
- Перевод Yii2 на `Monolog\SyslogHandler` — вне Ansible.
- Разделение на `inventory/prod/`, `inventory/dev/` — пока один сервер.
