# Пошаговый план реструктуризации Ansible-проекта

> Документ-спутник к [`ANALYSIS.md`](./ANALYSIS.md). Здесь только последовательность маленьких коммитов.
> Аргументация и проектные решения — в анализе, тут — только «что и в каком порядке делать».

## Принципы

1. **Один коммит = одна тема.** Каждый шаг — атомарное изменение, которое можно откатить.
2. **Аддитивно перед миграцией.** Новые файлы кладём рядом со старыми, переключаемся, потом удаляем
   старые. Между шагами проект остаётся в рабочем (или частично рабочем) состоянии.
3. **Багфиксы раньше реструктуризации.** Сначала чиним явные ошибки на текущей архитектуре —
   потом перетряхиваем структуру.
4. **Переименования атомарны.** Если переименовываем переменную — в одном коммите правим все
   ссылки на неё (`global.yml` + все роли + все шаблоны + Inventory).
5. **Smoke-test после каждой фазы.** В конце каждой фазы — `make syntax-check` + (по возможности)
   прогон затронутого плейбука на тестовом сервере.

## Зависимости фаз

```
A. Pre-stage-0 (ручной шаг)
   └── B. Багфиксы на текущей архитектуре
        └── C. group_vars/all/ (аддитивно)
             └── D. Переименование переменных в snake_case
                  └── E. SSH-ключи → ansible/secrets/ssh/
                       └── F. Stage-плейбуки (создание рядом со старыми)
                            └── G. nginx_sites + создание web_root
                                 └── H. Security-правки (Redis, PHP, AppArmor, pre-flight assert)
                                      └── I. Stage 5a/5b/5c + optional-docker (резерв)
                                           └── J. Удаление старого + новый Makefile
                                                └── K. Stage 6 verification
                                                     └── L. (опц.) Stage 7 key-hardening
```

---

## Фаза A. Подготовка (без правки кода Ansible)

Один шаг — описание процедуры, **код не меняем**.

### A1. Зафиксировать процедуру первого подключения

**Проблема (из внешнего обзора, п. 5):** в новом inventory будет `site_ansible_key:
"{{ ordinary_key_path }}"` — Stage 1 уже идёт по ключу. Но ключ окажется на сервере только в
Stage 2. Курица-яйцо.

**Что делаем:**

- Создать `ansible/secrets/README.md` с разделом «Pre-stage-0».
- Описать ровно один способ (выбрать тот, который проще для конкретной хостинг-площадки):
    - **Вариант 1**: после провижининга VPS админ один раз руками копирует
      `ordinary_key_path.pub` в `/root/.ssh/authorized_keys` через панель управления хостера или
      через `ssh-copy-id root@host` (с паролем root, который хостер выдаёт при создании VPS).
    - **Вариант 2**: хостер позволяет указать публичный ключ при создании VPS — указываем
      `ordinary_key_path.pub`, никаких ручных шагов после.
- Этот README **не код**, изменений в плейбуках нет.

**Коммит:** `docs(ansible): describe pre-stage-0 manual key bootstrap procedure`

---

## Фаза B. Багфиксы на текущей архитектуре

Изменения работают с текущим `global.yml` и текущими `remote-*.yml`. Никакой реструктуризации.
Каждый коммит независим — порядок не критичен, но удобно идти сверху вниз.

### B1. Деплой аварийного ключа на root

**Файл:** `roles/system/ssh_remote_root_keys/tasks/main.yml:13`

```diff
-    key: "{{ lookup('file', ordinary_pubkey_path) }}"
+    key: "{{ lookup('file', emergency_pubkey_path) }}"
```

**Проверка:** после прогона `remote-security` на тестовом сервере — `ssh -i emergency root@…`
должен работать.

**Коммит:** `fix(ansible): deploy emergency pubkey to root instead of ordinary`

### B2. Тесты SSH — заменить `wait_for_connection` на реальный `command: ssh`

**Файл:** `roles/tests/tasks/new_user_ssh.yml` (и соседние, если есть).

Заменить блок `wait_for_connection + delegate_to: localhost` на:

```yaml
- name: Verify SSH key login for {{ verify_ssh_user }}
  delegate_to: localhost
  command: >
    ssh -i {{ ordinary_key_path }}
        -o BatchMode=yes
        -o StrictHostKeyChecking=yes
        -o ConnectTimeout=10
        -p {{ target_ssh_port }}
        {{ verify_ssh_user }}@{{ target_host }} "echo OK"
  register: ssh_test
  changed_when: false
  failed_when: "'OK' not in ssh_test.stdout"
```

Важно: `StrictHostKeyChecking=yes` (см. ⚠️⚠️ ЗАМЕЧАНИЕ 2 в 3.1.4 анализа). Это требует чтобы
Stage 0 уже добавил отпечаток сервера в `known_hosts`.

**Коммит:** `fix(ansible): test SSH via real ssh command instead of wait_for_connection`

### B3. MySQL — whitelist вместо `when item != 'localhost'`

**Файл:** `roles/web-server/mysql/tasks/mysql_secure_installation.yml`

Заменить `when: item != 'localhost'` на whitelist-подход:

```yaml
keep_mysql_root_hosts:
    - localhost
    - 127.0.0.1
# loop body:
when: item not in keep_mysql_root_hosts
```

Список `keep_mysql_root_hosts` положить в `group_vars/global.yml` (либо позже — в
`webserver.yml`).

**Коммит:** `fix(ansible): use whitelist for mysql root host preservation`

### B4. AppArmor → complain mode + убрать `deny /etc/passwd r`

**Файлы:** `roles/system/app_armor/templates/*.j2`, `roles/system/app_armor/tasks/main.yml`

- Удалить из шаблонов директивы `deny /etc/passwd r` (и аналогичные).
- В tasks заменить `aa-enforce` на `aa-complain`.

Роль всё равно закомментирована в плейбуках — изменение чисто косметическое до Stage 3.

**Коммит:** `fix(ansible): switch apparmor profiles to complain mode and drop unsafe deny rules`

---

## Фаза C. `group_vars/all/` (аддитивно)

Создаём новую структуру переменных **рядом** с `global.yml`. Старый файл пока продолжает
работать через `vars_files:` в плейбуках. После этой фазы переменные дублируются — это
временно нормально.

### C1. Включить `group_vars/all/` через `ansible.cfg`

Убедиться, что `ansible.cfg` указывает `inventory = inventory/hosts.yml` и
`vault_password_file = ./secrets/!vault_pass.txt`. Без этих настроек авто-загрузка
`group_vars/all/` + расшифровка vault не сработают.

**Коммит:** `chore(ansible): ensure ansible.cfg has inventory and vault_password_file`

### C2. Создать `group_vars/all/main.yml`

Содержимое — из ANALYSIS 5.3, секция `main.yml`. Имена переменных пока **оставляем как в
`global.yml`** (`DOMAIN_NAME`, `HOST_IP`, `LOCAL_HOME_PATH`) — переименование в фазе D.

Файл по факту дублирует часть `global.yml`. Это ок: Ansible применит последнее значение,
а значения совпадают.

**Коммит:** `chore(ansible): introduce group_vars/all/main.yml (duplicates global.yml subset)`

### C3. Создать `group_vars/all/ssh.yml`

Аналогично — копируем SSH-секцию из `global.yml`. Имена сохраняем. Удалить:
- `target_user` (нигде не используется, см. ответ AI на 5.3).
- `site_ansible_password` (нигде не используется).

**Коммит:** `chore(ansible): introduce group_vars/all/ssh.yml`

### C4. Создать `group_vars/all/security.yml`

Перенести `fail2ban` секцию + `keep_mysql_root_hosts` из B3 + добавить **`yii2_auth: false`**
в `jails_enable_status` (внешний обзор, п. 8).

**Коммит:** `chore(ansible): introduce group_vars/all/security.yml`

### C5. Создать `group_vars/all/webserver.yml`

Перенести PHP-секцию + MySQL + Certbot (`certbot_email`). Структуру `nginx_sites` пока **не
добавляем** — она будет в фазе G, иначе разъедется со старым `site.tmp.j2`.

**Коммит:** `chore(ansible): introduce group_vars/all/webserver.yml`

### C6. Создать `group_vars/all/vault.yml`

Публичный маппинг vault-переменных. **Важно (внешний обзор, п. 2):** строку
`vault_ssh_key_passphrase: "{{ vault_ssh_key_passphrase }}"` **НЕ кладём** — она рекурсивна.
`ssh_key_passphrase` уже маппится в `ssh.yml`.

```yaml
mysql_root_password: "{{ vault_mysql_root_password }}"
mysql_db_user_password: "{{ vault_mysql_db_user_password }}"
redis_password: "{{ vault_redis_password | default('') }}"  # появится в фазе H
```

**Коммит:** `chore(ansible): introduce group_vars/all/vault.yml mapping`

### C7. Переместить `secrets.vault` → `group_vars/all/secrets.vault`

```bash
git mv ansible/secrets/secrets.vault ansible/group_vars/all/secrets.vault
```

После этого Ansible сам расшифрует файл при загрузке `group_vars/all/`. **`vars_files:
secrets.vault` из плейбуков пока не удаляем** — удаляется в шаге C9.

**Коммит:** `chore(ansible): move secrets.vault into group_vars/all/ for auto-loading`

### C8. Прогон `make syntax-check` + `make remote-test`

Никаких правок — только проверка. Если на этом этапе что-то ломается — Ansible видит
конфликт переменных или `secrets.vault` не нашёл `vault_password_file`. Если всё чисто —
переходим к C9.

**Коммит:** нет, это проверочный шаг.

### C9. Удалить `vars_files: global.yml` и `vars_files: ../secrets/secrets.vault` из плейбуков

Все 6 `remote-*.yml` (+ `local-init.yml`) — убрать `vars_files:` блоки. Если плейбук
сломается на этом шаге — значит, какая-то переменная не попала в `group_vars/all/`,
возвращаемся к C2–C6.

**Коммит:** `chore(ansible): drop vars_files from playbooks (group_vars/all auto-loads)`

### C10. Удалить `group_vars/global.yml`

Все переменные уже в `group_vars/all/*.yml`. Файл больше не нужен.

```bash
git rm ansible/group_vars/global.yml
```

**Коммит:** `chore(ansible): remove obsolete group_vars/global.yml`

---

## Фаза D. Переименование переменных в snake_case

**Каждое переименование = один коммит**, в котором правим все ссылки сразу (включая шаблоны
Jinja2 в ролях). Если что-то пропустить — Ansible упадёт с `undefined variable`.

Порядок выбран от менее опасных к более опасным.

### D1. `php-version` → `php_version`

Найти все вхождения:
```bash
grep -RIn "php-version" ansible/
```

**Особое внимание (внешний обзор, п. 12):** `roles/web-server/nginx/templates/site.tmp.j2`
содержит `php{{ php-version }}-fpm.sock` — там тоже править.

**Коммит:** `refactor(ansible): rename php-version → php_version (snake_case)`

### D2. `DOMAIN_NAME` → `domain_name`

Большая правка — переменная используется во многих ролях, в Inventory и в путях ssh-ключей.

```bash
grep -RIn "DOMAIN_NAME" ansible/
```

**Коммит:** `refactor(ansible): rename DOMAIN_NAME → domain_name`

### D3. `HOST_IP` → `host_ip`

**Коммит:** `refactor(ansible): rename HOST_IP → host_ip`

### D4. `LOCAL_HOME_PATH` → `local_home_path`

**Коммит:** `refactor(ansible): rename LOCAL_HOME_PATH → local_home_path`

### D5. `banTime`, `findTime`, `maxRetry` → `ban_time`, `find_time`, `max_retry`

Используются в `fail2ban/templates/jail.local.j2`.

**Коммит:** `refactor(ansible): rename fail2ban camelCase vars to snake_case`

### D6. `jailsEnableStatus` → `jails_enable_status`

В шаблоне `jail.local.j2` ключи внутри объекта тоже меняем с дефисов на подчёркивания
(`nginx-http-auth` → `nginx_http_auth` и т.д.). Имена jails в выходном `.local` оставляем
с дефисами — это уже не Jinja-переменные.

**Коммит:** `refactor(ansible): rename jailsEnableStatus → jails_enable_status`

---

## Фаза E. SSH-ключи → `ansible/secrets/ssh/`

### E1. Создать директорию + `.gitignore`

```bash
mkdir -p ansible/secrets/ssh
echo "/ssh/" >> ansible/secrets/.gitignore  # либо уже /secrets/ssh/ в корневом .gitignore
```

**Коммит:** `chore(ansible): add secrets/ssh/ directory with gitignore`

### E2. Переключить `local_ssh_keys_dir` на новую директорию

В `group_vars/all/ssh.yml`:
```yaml
local_ssh_keys_dir: "{{ playbook_dir }}/../secrets/ssh"
```

`local_home_path` остаётся для `ssh_known_hosts_path` (`~/.ssh/known_hosts` — единственное
место, которое продолжает жить в HOME).

**Коммит:** `refactor(ansible): store SSH keys in project (secrets/ssh/) instead of HOME`

### E3. Обновить `inventory/hosts.yml.example`

```yaml
ansible_ssh_private_key_file: "{{ ordinary_key_path }}"
```

(Раньше было либо хардкод пути, либо `~`.)

В `inventory/hosts.yml` (gitignored реальный файл) пользователь поправит вручную и/или
перегенерирует ключи через Stage 0 — они сразу окажутся в новой директории.

**Коммит:** `refactor(ansible): use ordinary_key_path in inventory ansible_ssh_private_key_file`

### E4. Фиксировать `ssh_key_passphrase` пустым

**Внешний обзор, п. 7:** в текущей формулировке `ssh_key_passphrase: "{{
vault_ssh_key_passphrase | default('') }}"` поведение зависит от содержимого vault. Если
там что-то лежит — Stage 0 сгенерит ключ с passphrase и всё сломается.

В `group_vars/all/ssh.yml` заменить на:
```yaml
# Stages 0–6 работают БЕЗ passphrase. Vault-переменная зарезервирована за Stage 7.
ssh_key_passphrase: ""
stage7_ssh_key_passphrase: "{{ vault_ssh_key_passphrase | default('') }}"
```

В Stage 7 (если до него дойдём) используется `stage7_ssh_key_passphrase`.

**Коммит:** `fix(ansible): hardcode empty ssh_key_passphrase for stages 0-6`

---

## Фаза F. Stage-плейбуки (создание рядом со старыми)

Создаём новые `stage-*.yml` плейбуки **рядом** со старыми `remote-*.yml`. Старые пока
работают. На этом этапе никаких ролевых изменений — только новые «обёртки» вокруг
существующих ролей + assert-блоки.

### F1. Новая роль `verify_ssh`

Создать `roles/system/verify_ssh/` с параметризацией **через `vars:` блок при `include_role`**
— не через group_vars (иначе в одном плейбуке проверим только одного пользователя).

`roles/system/verify_ssh/defaults/main.yml`:
```yaml
# Переопределяется в вызывающем плейбуке.
verify_ssh_user: root
verify_ssh_key: "{{ emergency_key_path }}"
```

`roles/system/verify_ssh/tasks/main.yml` — задача из B2, использует
`{{ verify_ssh_user }}` и `{{ verify_ssh_key }}` (важно: ключ тоже параметризуется, т.к.
root проверяется emergency-ключом, а new_user — обычным).

Вызов роли в Stage 2 / Stage 3 — двумя последовательными `include_role` с `vars:`:

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

Альтернатива (если будем вызывать в 3+ местах) — список `verify_ssh_checks` и `loop:` по
нему внутри роли. Пока двух вызовов хватает, оставляем простую параметризацию.

**Коммит:** `feat(ansible): add verify_ssh role for real SSH key login check`

### F2. Новая роль `ssh_remote_user_keys`

По образцу `ssh_remote_root_keys`, но деплоит `ordinary_pubkey_path` на `new_user`. Чтобы
впредь нельзя было перепутать ключи — будут две роли с очевидными названиями.

**Коммит:** `feat(ansible): add ssh_remote_user_keys role for sudo user pubkey deploy`

### F3. `playbooks/stage-0-local-init.yml`

Скопировать `local-init.yml`, добавить pre-flight assert (только то, что нужно на
localhost — например, проверка существования inventory).

**Важно (внешний обзор, п. 3):** при запуске через Makefile передавать
`-i inventory/hosts.yml` — `target_host` тянется из `groups['site']`.

**Коммит:** `feat(ansible): add stage-0-local-init.yml playbook`

### F4. `playbooks/stage-1-server-base.yml`

Из `remote-base.yml` забрать только: `apt_update`, `locales_hostname_timezone`, `swap`,
`systemd`. UFW и fail2ban — НЕ включать, они переезжают в Stage 3.

Pre-flight assert: проверить базовые переменные (`domain_name`, `host_ip`).
`remote_user: root`.

**Коммит:** `feat(ansible): add stage-1-server-base.yml playbook`

### F5. `playbooks/stage-2-server-access.yml`

Роли: `user_sudo_add_new`, `ssh_remote_root_keys` (после фикса B1 — деплоит emergency),
`ssh_remote_user_keys` (новая, F2), `ssh_logs_journald`, далее **два вызова** `verify_ssh`
через `include_role` + `vars:` (root с emergency_key_path, new_user с ordinary_key_path —
см. F1).

Pre-flight assert: vault-переменные для пароля sudo-пользователя.
`remote_user: root`.

**Коммит:** `feat(ansible): add stage-2-server-access.yml playbook`

### F6. `playbooks/stage-3-server-security.yml`

**Порядок (внешний обзор, п. 6 — поправлен относительно ANALYSIS 5.2):**
1. pre-check `verify_ssh` — два вызова (root по emergency, new_user по ordinary), как в F5
2. `ufw`
3. `ssh_remote_security` — отключение пароля, hardening sshd
4. post-check `verify_ssh` — те же два вызова после hardening
5. `fail2ban` — поднимаем jails **после** post-check, чтобы серия проверочных подключений
   не успела забанить контроллер
6. `app_armor` (complain mode после B4) — опционально, можно сразу запустить или
   отдельной целью

Pre-flight assert: ничего критичного из vault.
`remote_user: root`.

**Коммит:** `feat(ansible): add stage-3-server-security.yml playbook`

### F7. `playbooks/stage-4-webserver.yml`

Аналог `remote-webserver.yml`. **Единое решение по `remote_user` (внешний обзор, п. 4):**
**root**, никакого `become_user: new_user`. В заголовках стейджей в ANALYSIS 5.2
упоминается «sudo user + become» — игнорируем, идём по ответу AI на 3.3.1.

Pre-flight assert: `mysql_root_password`, `mysql_db_user_password`, `redis_password`.

**Коммит:** `feat(ansible): add stage-4-webserver.yml playbook`

### F8. Smoke-тест: прогнать каждый stage на тестовом сервере

Никакого коммита. Просто прогон. Если что-то падает — фиксим до фазы G.

---

## Фаза G. `nginx_sites` + создание `web_root`

### G1. Добавить `nginx_sites` в `group_vars/all/webserver.yml`

Структура — из ANALYSIS 3.2.3 / 5.3:
```yaml
nginx_sites:
    -   name: frontend
        server_name: "{{ domain_name }} www.{{ domain_name }}"
        web_root: "{{ web_root }}/{{ domain_name }}/app/frontend/pub"
        client_max_body_size: 10M
        php_fpm: true
    # ... backend, static
```

Само значение пока никем не используется — только определено. Это безопасный коммит.

**Коммит:** `feat(ansible): introduce nginx_sites structure`

### G2. Добавить создание `web_root` в роль `nginx`

В `roles/web-server/nginx/tasks/main.yml` перед задачами рендера конфига:
```yaml
- name: Create web roots for all configured nginx sites
  file:
    path: "{{ item.web_root }}"
    state: directory
    owner: www-data
    group: www-data
    mode: '0755'
  loop: "{{ nginx_sites }}"
```

Это аддитивная задача — она создаёт директории, но конфиги пока их не используют
(хардкод ещё в `site.tmp.j2`).

**Коммит:** `feat(ansible): create web_root directories in nginx role`

### G3. Переписать `site.tmp.j2` как цикл по `nginx_sites`

Старый трёхблочный шаблон с хардкодом `frontend/pub`, `backend/pub`, `static` заменить на
цикл. Пути берём из `nginx_sites[*].web_root`. На этом шаге HTTPS-редирект пока **не
добавляем** — он появится в Stage 5a через Certbot.

**Коммит:** `refactor(ansible): generate nginx site config from nginx_sites loop`

### G4. (опц.) Перевести Nginx на полное управление SSL из Ansible

**Из ⚠️⚠️ ЗАМЕЧАНИЯ 2 в 3.2.3:** «Certbot только получает сертификаты (`certbot certonly`),
а Nginx-шаблоны сами подключают сертификаты и делают redirect.»

Этот шаг можно отложить до момента, когда Stage 5a (G/I) будет писаться. Если делать —
шаблон `site.tmp.j2` дополняется блоком `if certbot_ssl_enabled and item.ssl_enabled` со
`listen 443 ssl; ssl_certificate /etc/letsencrypt/live/.../fullchain.pem; ...` и
`return 301 https://...` в HTTP-блоке.

**Коммит:** `feat(ansible): manage SSL certificates inclusion in nginx templates`

---

## Фаза H. Security-правки

### H1. Redis с паролем

1. В `group_vars/all/secrets.vault`: добавить `vault_redis_password`.
2. В `group_vars/all/vault.yml`: `redis_password: "{{ vault_redis_password }}"` (уже
   подготовлено в C6 с `default('')`).
3. В `roles/web-server/redis/templates/redis.conf.j2`: `requirepass {{ redis_password }}`.

**Доставка пароля в Yii2 — вне зоны Ansible** (см. ответ AI на 3.2.1, паттерн
`/etc/yii2/env` 0640 root:www-data).

**Коммит:** `feat(ansible): protect redis with requirepass from vault`

### H2. PHP security-конфиги

В `roles/web-server/php/files/conf.d/` создать:
- `security.ini` — `disable_functions`, `expose_php = Off`, `allow_url_fopen = Off`,
  `allow_url_include = Off`.
- `opcache.ini` — `opcache.enable=1`, `opcache.enable_cli=1`, `memory_consumption=128`,
  `max_accelerated_files=10000`, `validate_timestamps=0`.
- `apcu.ini` — `apcu.enable=1`, `apcu.shm_size=64M`.
- `open_basedir.ini` — **закомментирован**, оставить как пример с комментарием про
  composer.

Скопировать файлы во все нужные SAPI (`fpm`, `cli`) через `with_items` в роли.

**Коммит:** `feat(ansible): add php security/opcache/apcu ini files`

### H3. Pre-flight assert по vault-переменным

В каждый stage-плейбук в начало — отдельная play на `hosts: localhost` (или `hosts: site`
с `gather_facts: no`) с блоком `assert`.

**Важно (внешний обзор, п. 1):** `vault_root_password` **не проверять** — переменная
выпилена. Списки переменных — per-stage:

| Stage | Что проверяем |
|-------|---------------|
| 0     | (ничего из vault) |
| 1     | (ничего из vault) |
| 2     | `vault_sudo_user_password` (если используется при создании пользователя) |
| 3     | (ничего из vault) |
| 4     | `vault_mysql_root_password`, `vault_mysql_db_user_password`, `vault_redis_password` |
| 5a    | (ничего, но проверить что DNS на месте — отдельный pre-check через `dig`) |
| 5b    | (ничего из vault) |

**Коммит:** `feat(ansible): add per-stage pre-flight assert on vault variables`

### H4. (опц.) `[yii2-auth]` jail в fail2ban

Только когда Yii2-приложение начнёт писать через Monolog→SyslogHandler с ident
`yii2-auth`. До этого — оставить `jails_enable_status.yii2_auth: false` (уже добавлено в
C4) и сам блок `{% if jails_enable_status.yii2_auth %}` в `jail.local.j2`.

**Коммит:** `feat(ansible): add yii2-auth fail2ban jail (disabled by default)`

---

## Фаза I. Дополнительные stage-плейбуки

Не входят в `full-deploy`, запускаются по мере готовности внешних условий (DNS, исходники).

### I1. `stage-5a-certbot.yml`

Зависит от G3 (Nginx уже умеет создавать web_root до рендера). Запускает
`certbot certonly --nginx` (вариант с `--webroot` тоже допустим) для всех доменов из
`nginx_sites[*].server_name`. Регистрирует cron/timer на `certbot renew`.

Если выбран вариант G4 — после получения сертификатов запустить рендер шаблонов Nginx с
SSL-блоками. Если G4 пропущен — Certbot сам правит конфиги.

**Коммит:** `feat(ansible): add stage-5a-certbot.yml playbook`

### I2. `stage-5b-queue.yml`

Роль `queue/systemd` + ресурсные лимиты в systemd-юните (`MemoryMax`, `CPUQuota`,
`RestartSec=5`).

**Важно (внешний обзор, п. 10):** юниты только **раскладываем** на сервер с
`state: stopped, enabled: no`. После первого деплоя кода админ вручную делает
`systemctl enable --now yii-queue@1`.

**Коммит:** `feat(ansible): add stage-5b-queue.yml playbook`

### I3. `stage-5c-data-transfer.yml` (резерв)

Просто заворачиваем существующую роль `data_transfer` в отдельный плейбук. В Makefile —
своя цель, но **не входит** в `full-deploy`. Хардкод `mode: '7777'` и Windows-пути не
трогаем (роль не используется), но добавляем `# TODO: harden when actually used`.

**Коммит:** `feat(ansible): add stage-5c-data-transfer.yml playbook (reserve)`

### I4. Переименовать `docker.yml` → `optional-docker.yml`

```bash
git mv ansible/playbooks/docker.yml ansible/playbooks/optional-docker.yml
```

(Опционально) обновить до Ubuntu Noble + Docker Compose v2.

**Коммит:** `chore(ansible): rename docker.yml → optional-docker.yml`

---

## Фаза J. Удаление старого + новый Makefile

### J1. Удалить старые `remote-*.yml`

После того как Stage 0–4 успешно прогнаны на тестовом сервере хотя бы один раз:

```bash
git rm ansible/playbooks/local-init.yml
git rm ansible/playbooks/remote-base.yml
git rm ansible/playbooks/remote-security.yml
git rm ansible/playbooks/remote-webserver.yml
```

Тестовые плейбуки `remote-test.yml`, `remote-test-security.yml` — оставить или заменить на
Stage 6 (фаза K).

**Коммит:** `chore(ansible): remove legacy remote-*.yml playbooks`

### J2. Новый Makefile

По схеме из ANALYSIS 5.4. **Внешний обзор, п. 3:** в целях `stage-0` и `stage-7` тоже
добавить `-i inventory/hosts.yml`:

```makefile
stage-0:  ansible-playbook -i inventory/hosts.yml playbooks/stage-0-local-init.yml
stage-7:  ansible-playbook -i inventory/hosts.yml playbooks/stage-7-key-hardening.yml
```

`full-deploy: stage-0 stage-1 stage-2 stage-3 stage-4 stage-6` (stage-5/7 не входят).

**Коммит:** `chore(ansible): rewrite Makefile around stage-* targets`

---

## Фаза K. Stage 6 — verification

### K1. `playbooks/stage-6-verification.yml`

- SSH-входы (root по emergency, new_user по ordinary) через роль `verify_ssh`.
- `systemctl is-active` для nginx, php-fpm, mysql, redis, memcached.
- `ss -tlnp` — слушающие порты.
- `uri` на http://… и https://… с `status_code: [200, 301, 302, 308, 404]`,
  `failed_when: false` (ANALYSIS 5.2 Stage 6) — для случая «Certbot ещё не настраивали».
- `php -m` через `command:` — проверить наличие модулей.
- UFW status, fail2ban-client status.

**Коммит:** `feat(ansible): add stage-6-verification.yml playbook`

### K2. Удалить `remote-test.yml`, `remote-test-security.yml`

Если их логика перенесена в Stage 6:

```bash
git rm ansible/playbooks/remote-test.yml ansible/playbooks/remote-test-security.yml
```

**Коммит:** `chore(ansible): drop legacy remote-test*.yml in favor of stage-6`

---

## Фаза L (опциональная). Stage 7 — миграция на passphrase

Запускается **один раз** в самом конце. После него Ansible с сервером больше не работает.

### L1. Решить судьбу старых ключей без passphrase

**Открытый вопрос (внешний обзор, п. 9 + ⚠️⚠️ ЗАМЕЧАНИЕ 2 в 5.2 Stage 7):** что делать со
старыми ключами после регенерации?

Предложенная логика (если решим делать Stage 7):

1. Сгенерировать **новые** ключи с passphrase под именами
   `key_{{ domain_name }}_with_passphrase` (рядом со старыми, не перезаписывая).
2. Передеплоить новые публичные ключи на сервер (поверх старых в `authorized_keys`).
3. Ручная проверка SSH под passphrase из обычного терминала.
4. Удалить **старые публичные** ключи из `authorized_keys` на сервере (новой задачей).
5. Старые приватные ключи `key_{{ domain_name }}` и `key_{{ domain_name
   }}_emergency_root` — оставить в `ansible/secrets/ssh/` или удалить. Поскольку они
   больше не работают (соответствующие публичные удалены с сервера) — не критично.

Бэкап старых ключей в архив `secrets/ssh/_backup_no_passphrase.tar` — на случай если
понадобится восстановить.

### L2. `playbooks/stage-7-key-hardening.yml`

Реализовать после согласования L1.

---

## Контрольные точки (что должно работать после каждой фазы)

| После фазы | Что работает |
|-----------|--------------|
| B | Старый flow (`remote-*`) + аварийный ключ корректно деплоится, SSH-тесты реально проверяют SSH |
| C | Тот же flow, но переменные читаются из `group_vars/all/*.yml` и `secrets.vault` |
| D | То же, переменные в едином snake_case |
| E | SSH-ключи лежат в проекте, не в HOME |
| F | Новый flow `make stage-0 .. stage-4` параллельно со старым `make remote-*` |
| G | Nginx без хардкода путей, директории создаются перед стартом |
| H | Redis с паролем, PHP с security/opcache/apcu, pre-flight assert ловит пустой vault |
| I | Доступны `make stage-5a`, `stage-5b` (запуск вручную) |
| J | Только новые `stage-*.yml` в репо, `full-deploy` собирает 0+1+2+3+4+6 |
| K | `make stage-6` проверяет весь сервер целиком |
| L | (опц.) Сервер на ключах с passphrase, ключи в KeePass |

---

## Параллельная работа на проекте

Если хочется работать **сразу в нескольких фазах**:
- Фаза B (багфиксы) — независима от всего, можно делать первой.
- Фазы C → D → E — строго последовательно, между ними нельзя.
- Фаза F (новые плейбуки) — можно делать параллельно с G/H, новые плейбуки никого не
  ломают, пока не подключены в Makefile.
- Фаза I — независима после G3 (`nginx_sites`).
- Фаза J (удаление старого) — только после того, как новый flow живёт стабильно >= 1 цикла.

---

## Что НЕ делаем в этом плане

Намеренно не включено (зафиксировано в ANALYSIS как «низкий приоритет» или «вне зоны
Ansible»):

- Бэкап-стратегия (mysqldump + cron) — отдельный будущий проект.
- Мониторинг (OOM, диск) — отдельный будущий проект.
- Очистка хардкода Windows-путей в `data_transfer` — не используется.
- gzip и rate-limiting в Nginx — отдельное улучшение после Stage 5a.
- Перевод приложения Yii2 на `Monolog\SyslogHandler` — вне Ansible.
- Разделение на `inventory/prod/`, `inventory/dev/` (⚠️ ЗАМЕЧАНИЕ к 5.3) — пока один
  сервер, делаем когда появится второй.
