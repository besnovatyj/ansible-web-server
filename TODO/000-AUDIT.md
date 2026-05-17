# Аудит Ansible-проекта

Сквозной анализ: логика пайплайна, безопасность, идемпотентность, проверки.
Объём: 11 плейбуков-стадий, ~30 ролей, inventory с vault.

**Метод:** 2 параллельных аудита (логика+пайплайн / безопасность) + прямая
верификация топ-находок чтением файлов.
`[ПРОВЕРЕНО]` — прочитано лично; `[СООБЩЕНО]` — найдено аудитом, проверить при исправлении.

**Общая оценка:** ядро (ssh-bootstrap, hardening, LEMP, fail2ban, vault)
спроектировано продуманно и качественно. Критические проблемы сосредоточены в
одной незавершённой роли (`data_transfer`) и нескольких точках
идемпотентности/устойчивости. Места, доведённые в недавних сессиях (certbot,
swap, journald, unattended_upgrades, service_restart, ansible.cfg) —
подтверждены корректными, в backlog не входят.

---

## БЛОКЕРЫ (исправить до любого прод-прогона)

✅ ИСПРАВЛЕНО
---

## ВЫСОКИЕ (корректность / безопасность)

- **H1** `[СООБЩЕНО]` — `stage-5b`/`stage-5c` без pre-flight, что код и `yii`
  развёрнуты. Запуск вне очереди → тихий сбой. Добавить `assert`/`stat`.
- **H2** `[ПРОВЕРЕНО частично]` — `ssh_generate_local_keys/tasks/main.yml:32-35`
  использует `ansible_date_time` под `when: force_key_regen|bool`. Если play
  stage-0 с `gather_facts: false` — при `force_key_regen=true` падение
  «undefined». Дефолт `false` → латентно. Проверить `gather_facts` в
  `stage-0-local-init.yml`; вариант через `lookup('pipe','date')` уже рядом
  (закомментирован, L27-31).
- **H3** `[СООБЩЕНО]` — sshd hardening через `lineinfile`
  (`ssh_remote_security/tasks/main.yml:13-40`): при появлении `Match`-блоков
  директивы могут попасть внутрь Match. Сейчас безопасно, но хрупко.
  Митигировать через drop-in `/etc/ssh/sshd_config.d/`. `validate: sshd -t`
  уже есть (L52-56) — плюс.
- **H4** `[СООБЩЕНО]` — `ssh_push_keys/tasks/main.yml:29-55`: `authorized_key`
  без `exclusive` — посторонние ключи не вычищаются. Для fire-and-forget
  рассмотреть `exclusive: true` для automation-ключа.

---

## СРЕДНИЕ (идемпотентность / надёжность)

| #  | Файл:строка                                                       | Проблема                                                                                                                                  | Статус    |
|----|-------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------|-----------|
| M1 | `locales_hostname_timezone/tasks/main.yml:20-26`                  | `shell: locale-gen`/`hostnamectl` без `changed_when` → всегда changed; дублирует `locale_gen` (L12-18); вместо `ansible.builtin.hostname` | ПРОВЕРЕНО |
| M2 | `roles/web-server/php/tasks/main.yml:~41`                         | `phpenmod` с `creates:` на путь, который команда не создаёт → реран каждый прогон                                                         | СООБЩЕНО  |
| M3 | `inventory/group_vars/all/main.yml:~12`                           | `host_ip` через `hostvars[groups['site'][0]]` на загрузке vars → поздние непонятные ошибки при пустой группе                              | СООБЩЕНО  |
| M4 | `roles/web-server/mysql` install.yml notify `Start MySQL on boot` | возможно нет handler → тихий no-op                                                                                                        | СООБЩЕНО  |
| M5 | `roles/web-server/queue/systemd/tasks/main.yml:~21`               | `queue_workers_count`=0/undef → тихо ноль воркеров, нет assert ≥1                                                                         | ✅ ИСПРАВЛЕНО |
| M6 | `mysql/tasks/mysql_secure_installation.yml:51-124`                | мёртвый legacy-блок (MySQL<5.7) — техдолг                                                                                                 | СООБЩЕНО  |
| M7 | `verify_ssh/tasks/main.yml:~13`                                   | проверка по `'OK' in stdout` хрупка; `rc==0` (L18) надёжнее, L13 избыточен                                                                | СООБЩЕНО  |
| M8 | `roles/web-server/nginx/tasks/main.yml`                           | `nginx -t` с `notify: Restart nginx` — рестарт даже без изменений                                                                         | СООБЩЕНО  |

---

## НИЗКИЕ / hardening / осознанные решения

- AppArmor в `complain` — осознанно (NOTES п.5), не баг.
- `open_basedir` отключён под Composer — осознанный компромисс.
- nginx `site.tmp.j2` только `listen 80` (HTTPS дописывает certbot) — NOTES п.12;
  HSTS/CSP — NOTES п.6.
- stage-2/6: проверки поверхностные (коды ответов, не контент) — для smoke ок.
- `secrets/` права `777/666` в песочнице — **артефакт WSL/контейнерного
  монтирования** (вся ФС `/workspace` = 777), НЕ дефект проекта. `.gitignore`
  корректно исключает секреты (`git ls-files` чист). На реальном хосте права
  задаются отдельно — задокументировать в Readme как чек деплоя. В репозитории
  исправлять нечего.

---

## Что сделано ХОРОШО (не трогать)

SSH: ed25519, современные ciphers/MACs/Kex, key-only root, `restrict` на
automation, `validate: sshd -t`. fail2ban: systemd-backend, экспоненциальный
бан, recidive. UFW: reject + минимальный allowlist 22/80/443. MySQL:
caching_sha2, localhost-bind, `local-infile=0`, чистка анонимов. Redis:
protected-mode + requirepass + localhost. PHP: `disable_functions`,
`expose_php=Off`, `allow_url_*=Off`. Vault: `no_log`, git-исключён. Стадийные
post-condition asserts (enforcing-паттерн) выстроены последовательно.

---

## Рекомендуемый порядок исправления

1. ~~**B1** (data_transfer) и **B2** (apt lock) — блокеры прод-прогона.~~ ✅ ИСПРАВЛЕНО
2. **H1–H4** — корректность пайплайна и устойчивость доступа.
3. **M1–M8** — идемпотентность/надёжность (пачкой, низкий риск).
4. Низкие — задокументировать решения в `TODO/000-NOTES.MD`, кода не трогать.

## Verification (после исправлений)

- Синтаксис (запускает пользователь — в песочнице нет ansible):
  `ansible-playbook --syntax-check playbooks/stage-*.yml -i inventory/hosts.yml`
- Линт при наличии: `ansible-lint playbooks/ roles/`
- Идемпотентность: двойной прогон стадии, второй → `changed=0` на M1/M2.
- B1: на тестовом хосте `find {{web_root}} -perm -0002` (нет world-writable),
  `stat -c '%a'` каталогов = 755/775.
- B2: занять dpkg-lock фоновым `apt` → stage-1 не виснет, отваливается по
  таймауту с понятным сообщением.
- Полный прогон `make full-deploy` на чистой тестовой Ubuntu 24.04.
