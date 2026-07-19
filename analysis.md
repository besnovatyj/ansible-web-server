# Анализ Ansible-проекта `/workspace/ansible`

Дата: 2026-07-19.
Охват: все плейбуки, Makefile/environments.mk/.env, ansible.cfg, inventory + group_vars,
структура ролей и их подключение, документация (readme*, TODO/000-*).
**Вне охвата (по договорённости):** содержимое `optional-docker.yml` и `stage-5c-data-transfer.yml`
— для них проверено только то, что они полноценно подключены в проект (см. §7).

Формат рекомендаций: для каждой проблемы — один целевой вариант, без альтернатив.

---

## 1. Общая оценка

Ядро проекта в хорошем состоянии: стадии реальны и работоспособны, у каждой есть
pre-flight и post-check'и, bootstrap идемпотентен, секреты изолированы в vault,
осознанные решения (отключение SSH-мультиплексинга, ssh-agent, fire-and-forget-политика)
задокументированы прямо в коде. Неиспользуемых ролей нет, «висящих» плейбуков нет.

Проблемы проекта — почти целиком **навигационные**:

1. **Имена стадий врут о порядке запуска** — `stage-1b` идёт *до* `stage-1`;
   буквы `5a/5b/5c/5d` не соответствуют фактическому порядку (`5d → 5a → 5b`);
   `stage-6` в `full-deploy` выполняется *до* любых пятых стадий. Причина системная:
   сквозная нумерация 0–6 не оставляет места для вставки, поэтому новые этапы
   получали суффиксы (`1b`, `5d`) по времени появления, а не по позиции.
2. **Канонический порядок запуска нигде не записан целиком.** `readme.md` устарел
   (не знает про `make release`), актуальный порядок лежит в рабочих заметках
   `readme-TODO 2.md` — файле, который по имени выглядит черновиком.
3. **Конфигурация размазана по 8 файлам** с четырьмя точками ручной синхронизации
   (см. §5); сводной карты «что и где править» не было.

Целевая структура, снимающая п.1 целиком, — в §3.2. Ни одна из находок не блокирует
деплой.

---

## 2. Фактический пайплайн (как есть)

### Автоматическая часть — `make full-deploy`

```
stage-0    localhost  ключи (~/.ssh/<домен>/) + known_hosts     agent не нужен
stage-1b   site       bootstrap: юзеры + доставка ключей        ЕДИНСТВЕННЫЙ заход по паролю root
stage-1    site       ОС: apt, locales, swap, systemd           далее везде automation-ключ + sudo
stage-2    site       journald для SSH + verify входов          пароль ещё НЕ отключён
stage-3    site       UFW → sshd hardening → unattended → f2b   fail2ban строго ПОСЛЕ verify SSH
stage-4    site       Redis, Memcached, MySQL, Nginx, PHP,      + composer, app_secrets,
                      apt_clean                                  service_restart
stage-6    site       комплексная верификация (гибрид            HTTP/HTTPS probe не валит прогон —
                      enforcing/report)                          HTTPS до 5a законно отсутствует
```

### Ручная пост-деплойная часть (канонический порядок)

```
make release     stage-5d  git clone + composer install + php init (+ release-db: импорт дампа)
make stage-5a    stage-5a  certbot (требование: DNS уже указывает на сервер)
make stage-5b    stage-5b  queue-воркеры (строго ПОСЛЕ release — нужен yii на сервере)
make stage-6     stage-6   повторная верификация, теперь уже с HTTPS
```

Зависимости, зафиксированные в самих плейбуках: `5d` требует stage-4
(php-fpm + composer, проверяется pre-flight'ом); `5a` требует stage-4 + DNS;
`5b` требует задеплоенных исходников. `5a` и `5d` между собой не упорядочены
жёстко (nginx-роль stage-4 создаёт скелет web-корней, так что certbot пройдёт и до
релиза), канон — `release → 5a → 5b`.

### Резерв (подключено, не запускается)

```
make stage-5c        stage-5c-data-transfer  (резервный rsync вместо release)
make docker-install  optional-docker         (установка Docker)
```

---

## 3. Именование: проблемы и целевая структура

### 3.1. Зафиксированные проблемы текущей схемы

1. **`stage-1b` выполняется до `stage-1`.** Суффикс «b» читается как «после 1»,
   фактический порядок — `0 → 1b → 1 → 2`. Имя приходится опровергать комментарием
   в шапке `stage-1-server-base.yml` («Порядок: stage-0 → stage-1b → ЭТОТ stage-1»).
2. **Буквы `5a…5d` не соответствуют порядку запуска**: фактически `5d → 5a → 5b`,
   `5c` — резерв. Буквы отражают историю появления файлов, не последовательность.
3. **`stage-6` — не этап, а повторяемая проверка**: в `full-deploy` идёт до пятых
   стадий и запускается повторно после них. Плейбук к этому готов (HTTP/HTTPS probe
   намеренно не валит прогон до certbot) — семантика уже «verify, запускаемый когда
   угодно», номер говорит иное.
4. **Нет единого правила «make-цель ↔ файл»**: у всех стадий цель = имя стадии
   (`stage-4`), но у 5d цель `release`/`release-db`, у optional-docker —
   `docker-install`. Правило приходится помнить.
5. **Пост-деплойная фаза не закодирована**: `full-deploy` есть, а комбинированной
   цели для `release → certbot → queue → verify` нет — порядок живёт в заметках.
6. Глоб `stage-*.yml` в `syntax-check` захватывает резервный `stage-5c` (имеющий
   право быть нерабочим), но не `optional-docker.yml` — граница «проверяемое/резерв»
   проведена не по признаку резервности, а по префиксу имени.

### 3.2. Целевая структура

Нумерация десятками: номер = позиция в пайплайне, шаг 10 оставляет место для вставки
без перенумерации. Слово `stage` из имён уходит — номер уже несёт эту семантику.
`verify` выводится из нумерации — это не позиция, а повторяемая операция.
Резервные плейбуки получают единый префикс `optional-` — он же исключает их из
syntax-check по глобу.

```
playbooks/
  10-local-init.yml            localhost: ключи + known_hosts
  20-bootstrap-access.yml      по паролю root: юзеры + доставка ключей (бывш. stage-1b)
  30-server-base.yml           ОС: apt, locales, swap, systemd
  40-server-access.yml         journald + verify SSH-входов
  50-server-security.yml       UFW, sshd hardening, unattended, fail2ban
  60-webserver.yml             LEMP + composer + app_secrets + service_restart
  70-release.yml               git clone + composer install + php init
  80-certbot.yml               TLS (после DNS)
  90-queue.yml                 queue-воркеры (после release)
  verify.yml                   комплексная проверка, запускается когда угодно (бывш. stage-6)
  optional-data-transfer.yml   резерв (бывш. stage-5c)
  optional-docker.yml          резерв
```

Дерево директорий читается сверху вниз как порядок запуска — структура
самодокументируется, комментарии-опровержения в шапках больше не нужны.

Make-цели — по единому правилу: **цель = имя задачи (без номера), файл = номер +
то же имя задачи**. Цель — это команда человека («что сделать»), файл — позиция в
пайплайне («когда»). Никаких алиасов и исключений:

```make
local-init:       10-local-init.yml
bootstrap:        20-bootstrap-access.yml
server-base:      30-server-base.yml
server-access:    40-server-access.yml
server-security:  50-server-security.yml
webserver:        60-webserver.yml
release:          70-release.yml        (+ release-db: -e release_import_db=true)
certbot:          80-certbot.yml        (+ certbot-staging, certbot-force)
queue:            90-queue.yml
verify:           verify.yml
data-transfer:    optional-data-transfer.yml   # резерв
docker-install:   optional-docker.yml          # резерв
```

Комбинированные цели — две, по фазам жизненного цикла:

```make
# Настройка чистого сервера (бывш. full-deploy)
provision: local-init bootstrap server-base server-access server-security webserver verify

# Первый вывод приложения (порядок каноничен: код → TLS → очереди → проверка)
deploy: release certbot queue verify
```

Последующие выкладки — просто `make release`.

Сопутствующие правки Makefile/environments.mk:

- `syntax-check`: глоб `playbooks/[0-9]*.yml playbooks/verify.yml` — нумерация даёт
  естественный глоб взамен `stage-*.yml`; `optional-*` исключены по праву быть
  нерабочими (сейчас 5c в проверку попадает — см. §3.1 п.6).
- `.PHONY` переписывается под новый список целей (сейчас в нём и так нет
  `release`, `release-db`, `stage-5a-staging`, `stage-5a-force` — список разошёлся).
- `make help`: убрать `| sort` — порядок целей в Makefile = порядок пайплайна,
  help обязан показывать его, а не алфавит.

### 3.3. Таблица переименования

| Сейчас (файл)           | Сейчас (цель)      | Станет (файл)          | Станет (цель)      |
|-------------------------|--------------------|------------------------|--------------------|
| stage-0-local-init      | stage-0            | 10-local-init          | local-init         |
| stage-1b-bootstrap-keys | stage-1b           | 20-bootstrap-access    | bootstrap          |
| stage-1-server-base     | stage-1            | 30-server-base         | server-base        |
| stage-2-server-access   | stage-2            | 40-server-access       | server-access      |
| stage-3-server-security | stage-3            | 50-server-security     | server-security    |
| stage-4-webserver       | stage-4            | 60-webserver           | webserver          |
| stage-5d-release        | release/release-db | 70-release             | release/release-db |
| stage-5a-certbot        | stage-5a (+2)      | 80-certbot             | certbot (+2)       |
| stage-5b-queue          | stage-5b           | 90-queue               | queue              |
| stage-6-verification    | stage-6            | verify                 | verify             |
| stage-5c-data-transfer  | stage-5c           | optional-data-transfer | data-transfer      |
| optional-docker         | docker-install     | optional-docker        | docker-install     |
| full-deploy             | full-deploy        | —                      | provision          |
| —                       | —                  | —                      | deploy             |

При переименовании: обновить шапки плейбуков (упоминания «stage-N» в описаниях
порядка), readme, и вычистить исторические комментарии-опровержения — при говорящих
именах они не нужны.

---

## 4. Документация: где живёт правда о порядке запуска

Сейчас три readme с разной степенью актуальности:

| Файл               | Статус                                                                                        | Проблема                                                                                                                                                                                                                            |
|--------------------|-----------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `readme.md`        | Основной, краткий                                                                             | **Устарел в §3**: «Залить исходники … git-pull на сервере или `make stage-5c` — резервный rsync» — не упоминает `make release` (stage-5d), основной путь деплоя. Порядок «исходники → 5a → 5b» без release и без повторного verify. |
| `readme-TODO.md`   | Большой: секция «Актуальный порядок (авторитетная)» + LEGACY-план + перф-заметки + анализ TLS | Четыре жанра в одном файле; «авторитетная» секция написана до появления release и тоже устарела.                                                                                                                                    |
| `readme-TODO 2.md` | Рабочие заметки                                                                               | Содержит **самый актуальный** канонический порядок («full-deploy, затем release, потом 5a, 5b и 6») — но по имени (с пробелом!) выглядит черновиком.                                                                                |

Целевое состояние — один источник правды:

1. `readme.md` — единственная инструкция. В него переносится актуальный порядок:
   `make provision` → `make deploy` (внутри: release → certbot → queue → verify),
   плюс существующие разделы подготовки (.env, inventory, vault).
2. Анализ TLS/Apple из `readme-TODO.md` → отдельный файл в `TODO/` (это исследование,
   не инструкция).
3. Секция «Актуальный порядок» из `readme-TODO.md` удаляется (правда — в readme.md),
   LEGACY-план удаляется (история есть в git). Живые справочные части (версии ПО,
   KeePass-процедура, структура make-проекта) — в `readme.md` или `TODO/`.
4. `readme-TODO 2.md` удаляется после переноса: порядок деплоя → readme.md; заметки
   про `sudo -u www-data`/OPcache → `TODO/` (частично уже зафиксированы там и в memory).

---

## 5. Карта конфигурации: что где настраивается

### 5.1. Файлы настройки (по слоям)

| Слой           | Файл                                                                    | Что настраивается                                                                                          |
|----------------|-------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------|
| Make           | `.env`                                                                  | `DOMAIN` (нужен make для путей AGENT_KEYS)                                                                 |
| Make           | `environments.mk`                                                       | `AGENT_KEYS` (ключи для ssh-agent), `SSH_KEYS_DIR`, обёртка `$(PLAY)`, `.PHONY`                            |
| Ansible-глобал | `ansible.cfg`                                                           | roles_path, inventory, лог, vault-пароль, SSH-поведение (no multiplexing, pipelining, IdentitiesOnly)      |
| Inventory      | `inventory/hosts.yml`                                                   | **IP сервера** (единственная ручная правка тут)                                                            |
| Vars           | `group_vars/all/main.yml`                                               | `domain_name`, `app_hosts` (3 домена приложения), `host_ip` (вычисляемый), `web_root`, локали, `time_zone` |
| Vars           | `group_vars/all/ssh.yml`                                                | `server_users`, `ssh_automation_user`, порт, пути и тип ключей                                             |
| Vars           | `group_vars/all/webserver.yml`                                          | PHP-версия и модули, MySQL db/user, `certbot_email`, `nginx_sites`, queue-воркеры                          |
| Vars           | `group_vars/all/security.yml`                                           | fail2ban: тайминги + `jails_enable_status`                                                                 |
| Vars           | `group_vars/all/vault.yml`                                              | публичный маппинг vault-переменных                                                                         |
| Секреты        | `secrets/secrets.yml` → `make vault-encrypt` → `group_vars/all/secrets` | все `vault_*`                                                                                              |
| Секреты        | `secrets/!vault_pass.txt`                                               | пароль vault (путь прописан в ansible.cfg)                                                                 |

Схема «per-project правки» из readme корректна: `.env`, `hosts.yml`, `main.yml`,
`webserver.yml` (db/email), секреты. Пять мест, каждое обосновано (make не читает
yaml; inventory отделён от vars; секреты отделены от несекретного).

### 5.2. Точки ручной синхронизации

| # | Что                                                                                                                                                            | С чем                      | Вердикт                                                                                                                                                                                                                                                                                                                                                                                                        |
|---|----------------------------------------------------------------------------------------------------------------------------------------------------------------|----------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1 | `DOMAIN` в `.env`                                                                                                                                              | `domain_name` в `main.yml` | Оставить: make не умеет yaml, дубль задокументирован в обоих файлах. Это развязка форматов, не путаница.                                                                                                                                                                                                                                                                                                       |
| 2 | `AGENT_KEYS` в `environments.mk`                                                                                                                               | `server_users` в `ssh.yml` | Оставить: чтение inventory из make (yaml + vault) хрупко и медленно; дубль задокументирован с обеих сторон.                                                                                                                                                                                                                                                                                                    |
| 3 | Захардкоженные списки в post-check'ах (сервисы, секреты, артефакты)                                                                                            | роли-источники             | Оставить: проверка не должна вычисляться из проверяемого; принцип зафиксирован комментариями в плейбуках.                                                                                                                                                                                                                                                                                                      |
| 4 | **Двойной маппинг vault**: `vault.yml` определяет `mysql_root_password_from_vault` и т.п., а `webserver.yml` параллельно маппит те же `vault_mysql_*` напрямую | —                          | **Устранить.** Единственный маппинг vault → публичные имена — в `vault.yml` (это его заявленная роль): `mysql_root_password: "{{ vault_mysql_root_password }}"`, `mysql_db_user_password: …`. Суффиксы `*_from_vault` удаляются, `webserver.yml` перестаёт трогать `vault_*` и содержит только несекретные параметры. Открытый вопрос «решить при реализации» из комментария vault.yml закрывается именно так. |

### 5.3. `.PHONY` отстал от целей

В `environments.mk` `.PHONY` не содержит `stage-5a-staging`, `stage-5a-force`,
`release`, `release-db`. Закрывается переписыванием `.PHONY` при переходе на целевую
схему целей из §3.2.

---

## 6. Карта «стадия → роли» и качество подключения

| Плейбук  | Роли (в порядке применения)                                                                                                                                           |
|----------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| stage-0  | system: ssh_generate_local_keys, ssh_add_remote_host_to_known_hosts                                                                                                   |
| stage-1b | system: ssh_agent_check, users_provision, ssh_push_keys, verify_ssh                                                                                                   |
| stage-1  | system: apt_update, locales_hostname_timezone, swap, systemd                                                                                                          |
| stage-2  | system: ssh_agent_check, ssh_logs_journald, verify_ssh, verify_sshd_policy                                                                                            |
| stage-3  | system: ssh_agent_check, verify_ssh/verify_sshd_policy (pre), ufw, ssh_remote_security, unattended_upgrades, verify_* (post), fail2ban; `app_armor` — закомментирован |
| stage-4  | web-server: redis, memcached, mysql, nginx, php, composer, app_secrets; system: service_restart, apt_clean                                                            |
| stage-5a | web-server: certbot                                                                                                                                                   |
| stage-5b | web-server: queue/systemd                                                                                                                                             |
| stage-5c | web-server: data_transfer *(резерв, содержимое вне охвата)*                                                                                                           |
| stage-5d | web-server: release                                                                                                                                                   |
| stage-6  | system: ssh_agent_check, verify_ssh, verify_sshd_policy (роли-проверки; остальное — задачи)                                                                           |

Наблюдения и решения:

- **Сиротских ролей нет**: каждая роль подключена ровно одним плейбуком
  (verify-семейство и ssh_agent_check переиспользуются четырьмя — это их назначение).
- **`app_armor` — единственная роль без активного подключения** (закомментированная
  строка в stage-3 + 5 готовых шаблонов профилей). Пауза осознанная (фаза B4,
  complain-mode сначала — TODO/000-AUDIT.md), но статус виден только из комментария
  в stage-3. **Решение:** строка статуса в шапку
  `roles/system/app_armor/tasks/main.yml`: «не подключена; включение — в
  50-server-security после фазы B4 (complain → enforce)».
- **fail2ban-фильтры `redis-auth`/`yii2-auth` разложены заранее, jail'ы выключены**
  в `security.yml` — намеренно (включаются после первой выкладки / после
  Monolog→Syslog). Задокументировано — ок, не трогать.
- **Пути подключения ролей противоречат ansible.cfg.** Cfg задаёт
  `roles_path = ./roles/`, но плейбуки пишут `../roles/system/...` — roles_path
  фактически мёртв, а длинные относительные пути шумят. **Решение:** во всех
  плейбуках короткие имена через roles_path (`- system/ufw`,
  `- web-server/nginx`); запуск из корня проекта гарантирован обёрткой `$(PLAY)`
  и `ANSIBLE_CONFIG` из environments.mk.

---

## 7. Резервные плейбуки: проверка подключения (без анализа содержимого)

|                     | `stage-5c-data-transfer.yml`            | `optional-docker.yml`                            |
|---------------------|-----------------------------------------|--------------------------------------------------|
| Make-цель           | `stage-5c` («(РЕЗЕРВ) data_transfer») ✓ | `docker-install` («(РЕЗЕРВ) Установка Docker») ✓ |
| `.PHONY`            | есть ✓                                  | есть ✓                                           |
| В `full-deploy`     | нет — осознанно ✓                       | нет — осознанно ✓                                |
| Упоминание в readme | да (§3, как резерв) ✓                   | нет (допустимо для optional)                     |
| Виден в `make help` | ✓ (есть `##`-комментарий)               | ✓                                                |

Оба подключены полноценно и пропускаются при обычном запуске — как и требуется.

**Решение** (часть схемы §3.2): `stage-5c-data-transfer.yml` →
`optional-data-transfer.yml`, цель `data-transfer`. Префикс `optional-` становится
единственным маркером резервности, и оба резервных плейбука автоматически выходят
из-под `syntax-check` (глоб `[0-9]*.yml` + `verify.yml`) — сейчас 5c в проверку
попадает, хотя имеет право быть нерабочим.

---

## 8. Прочие находки по плейбукам и обвязке

Роли глубоко не аудировались — это сделано в `TODO/000-AUDIT.md`, его статусы
актуальны. Ниже — найденное попутно, с решением по каждому пункту:

1. **Устаревший комментарий в `stage-0-local-init.yml:7`** — «Генерация SSH-ключей …
   в `secrets/ssh/`». Ключи давно в `~/.ssh/<домен>/` (`local_ssh_keys_dir`, миграция
   из-за drvfs/прав). **Решение:** поправить шапку при переименовании в
   `10-local-init.yml`.
2. **`stage-5b` (queue) не проверяет своё главное предусловие.** Шапка роли заявляет:
   «должны существовать `{{ web_root }}/{{ domain_name }}/yii` и рабочий .env», но
   pre-flight'а на это нет (assert на `queue_workers_count` есть — M5 закрыт; H1 из
   аудита в части 5b остался). Воркеры поднимутся и будут циклично падать.
   **Решение:** pre-flight в `90-queue.yml` — `stat` на `yii` + assert. Заодно
   поправить шапку роли: приложение читает `/run/secrets` (app_secrets), а не `.env`.
3. **DNS-pre-flight `stage-5a` проверяет только `domain_name`**, а certbot выпускает
   сертификаты для всех `server_name` из `nginx_sites` (включая `www.`, `adm.`,
   `files.`). Незаведённый поддомен пройдёт pre-flight и уронит certbot позже с
   невнятной ошибкой. Плюс `dig +short` при CNAME возвращает несколько строк —
   сравнение `== host_ip` даёт ложный отказ. **Решение:** в `80-certbot.yml`
   проверять циклом все хосты из `app_hosts` (+ `www.`), условием
   `host_ip in dns_check.stdout_lines`.
4. **Пост-деплойная фаза не закодирована в Makefile.** Закрывается целью `deploy`
   из §3.2.
5. **Бэкап-файлы рядом с боевыми**: `roles/web-server/certbot/tasks/main.yml_b`,
   `roles/web-server/nginx/templates/site.tmp_b.j2`. Ansible их не подхватывает, но
   при чтении роли непонятно, какой файл живой (`site.tmp_b.j2` в 5 раз больше
   боевого). **Решение:** удалить оба — история в git.
6. **`logs/ansible.log` растёт бесконечно** (`log_path` в ansible.cfg; в git не
   попадает — `/logs/*` в .gitignore). Не проблема корректности; чистится вручную
   по мере разрастания.

---

## 9. Целевое состояние — сводный чеклист

Порядок выполнения логический (структура → документация → точечные фиксы):

1. **Переименовать плейбуки** по схеме §3.2/§3.3: нумерация десятками `10…90`,
   `verify.yml` вне нумерации, резерв — `optional-*`. Обновить шапки (упоминания
   stage-N), вычистить комментарии-опровержения порядка.
2. **Переписать цели Makefile**: цель = имя задачи; `provision` и `deploy` как
   комбинированные; `syntax-check` по глобу `[0-9]*.yml` + `verify.yml`; `.PHONY`
   под новый список; `make help` без `sort` (порядок целей = порядок пайплайна).
3. **Свести документацию к одному источнику** (§4): актуальный порядок — в
   `readme.md`; TLS-анализ → `TODO/`; LEGACY-план и «авторитетную» секцию из
   `readme-TODO.md` удалить; `readme-TODO 2.md` удалить после переноса.
4. **Единый vault-маппинг в `vault.yml`** (§5.2 п.4): убрать `*_from_vault`,
   `webserver.yml` не трогает `vault_*`.
5. **Короткие имена ролей через roles_path** во всех плейбуках (§6).
6. **Pre-flight в queue** (`stat` на `yii`) и фикс упоминания `.env` в шапке роли
   (§8 п.2).
7. **DNS-проверка certbot по всем `app_hosts` (+www)** через `in stdout_lines`
   (§8 п.3).
8. **Чистка**: удалить `main.yml_b` и `site.tmp_b.j2`; статус-строка в шапку роли
   `app_armor`; поправить `secrets/ssh/` в шапке local-init (§6, §8).
