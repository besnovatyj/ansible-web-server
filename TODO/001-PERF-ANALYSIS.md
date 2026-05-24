# Анализ таймингов full-deploy и предложения по ускорению

**Дата лога:** 2026-05-24 (`logs/ansible.log`, последний полный прогон).
**Сервер:** 4 vCPU / 4 GB RAM / 50 GB, Ubuntu 24.04, чистая инсталляция.
**Контроллер:** WSL2 / Ubuntu, домашний интернет (185.223.169.81).
**Релевантное состояние `ansible.cfg`:**

- `ControlMaster=no` (отключён умышленно из-за reboot-бага Ansible #79992)
- `pipelining = True`
- `IdentitiesOnly=yes` (для совместимости с ssh-agent)

---

## 1. Сводка по стадиям

| Стадия      |       Время | Доля от total | Что внутри                                        |
|-------------|------------:|--------------:|---------------------------------------------------|
| stage-0     |          6с |          0.4% | Локальная генерация ключей + known_hosts          |
| stage-1b    |         45с |          3.0% | Bootstrap по паролю root                          |
| **stage-1** |    **7:01** |     **28.1%** | OS base — apt update + security upgrades + reboot |
| stage-2     |         41с |          2.7% | User access setup, journald, verify               |
| stage-3     |        3:36 |         14.4% | Hardening — UFW, sshd, unattended, fail2ban       |
| **stage-4** |   **11:46** |     **47.1%** | LEMP — Redis, Memcached, MySQL, Nginx, PHP        |
| stage-6     |        1:05 |          4.3% | Verification — SSH-вход, services, smoke          |
| **TOTAL**   | **~25 мин** |          100% |                                                   |

> **Два главных «жирных» этапа** — stage-1 и stage-4, дающие **75% времени** деплоя.

---

## 2. Топ-15 самых медленных задач

| #  |    Время | Стадия  | Задача                                                              |
|----|---------:|---------|---------------------------------------------------------------------|
| 1  | **307с** | stage-1 | `apt_update : Install security updates only`                        |
| 2  |  **71с** | stage-4 | `web-server/php : Copy PHP configuration files from files/conf.d`   |
| 3  |  **71с** | stage-4 | `web-server/php : Copy PHP configuration files to cli/conf.d`       |
| 4  |  **63с** | stage-4 | `system/service_restart : Deploy auto-restart drop-in per unit`     |
| 5  |  **47с** | stage-4 | `web-server/php : Install PHP` (apt)                                |
| 6  |  **36с** | stage-4 | `web-server/mysql : Install MySQL 8.4 LTS` (apt)                    |
| 7  |  **29с** | stage-4 | `web-server/nginx : Copy host settings` (template)                  |
| 8  |  **27с** | stage-1 | `apt_update : Reboot server if needed`                              |
| 9  |  **25с** | stage-4 | `web-server/php : Install ImageMagick` (apt)                        |
| 10 |  **19с** | stage-1 | `apt_update : Update APT package cache`                             |
| 11 |  **17с** | stage-3 | `Dry-run unattended-upgrade (config sanity)`                        |
| 12 |  **16с** | stage-4 | `apt_clean : Remove useless dependencies`                           |
| 13 |  **15с** | stage-4 | `Check critical services are active` (loop)                         |
| 14 |  **15с** | stage-4 | `web-server/php : Ensure required PHP modules are enabled` (loop 6) |
| 15 |  **15с** | stage-4 | `web-server/nginx : Install Nginx` (apt)                            |

**Суммарно топ-15: 783с ≈ 13 мин** — больше половины всего деплоя.

Из них:

- **`apt install` различных пакетов** — ~158с (#5, #6, #9, #10, #12, #15). Аппаратно/сетевая загрузка, **неустранимо без
  локального зеркала**.
- **`apt security upgrades` + reboot** — 334с (#1, #8). Можно сократить (см. §6.4).
- **File-loop copy/template без multiplexing** — 234с (#2, #3, #4, #7). **Главный кандидат на оптимизацию.**
- **Внутренние loop-проверки** (assert, check services, modules) — ~60с. Малый выигрыш.

---

## 3. Root cause: SSH overhead × loop-задачи

### 3.1. Стоимость одной задачи

При `ControlMaster=no` каждая Ansible-задача (или каждая итерация loop) выполняет полный цикл:

1. TCP-handshake до server:22 (~50-100ms)
2. SSH key-exchange + аутентификация через ssh-agent (~300-600ms)
3. sudo NOPASSWD + старт `/usr/bin/python3` для модуля (~200-400ms)
4. Передача модуля + аргументов (pipelining=True — в одном сообщении)
5. Выполнение модуля (миллисекунды для file/copy/stat)
6. Возврат результата + закрытие соединения (~100-200ms)

**Итого: ~1.5-2с на одну задачу** даже если сам модуль выполняется мгновенно.

С `ControlMaster=auto` (которого мы избегаем) первая задача платит этот цикл, остальные через тот же multiplexed-сокет
идут за ~0.1-0.2с. Разница: **5-10× для последующих задач**.

### 3.2. Loop-tasks умножают эффект

`ansible.builtin.copy` с `src=directory/` под капотом разворачивается в **N отдельных задач** по числу файлов:

- 8 файлов в `roles/web-server/php/files/conf.d/` → 8 копий → 8 × 9с = 72с.
- Loop по `service_restart_units` (5 unit-ов) → 5 × ~12с = 60с.

`pipelining=True` отчасти лечит — он экономит на «загрузке модуля во временный файл», но не экономит на **самой
SSH-сессии**, которая каждый раз новая.

### 3.3. Почему `Copy host settings` (single template) = 29с

`ansible.builtin.template` для ОДНОГО файла под капотом делает:

1. stat удалённого файла (есть ли, какие права/owner)
2. локальный рендеринг Jinja
3. diff: считает хеш удалённого, сравнивает
4. push нового файла, если diff
5. chmod, chown отдельными вызовами

Каждый шаг — потенциально отдельная SSH-сессия. Без multiplexing складывается в ~25-30с даже для одного файла.

### 3.4. Что НЕ источник медленности

Проверено по логу:

- **Не сервер** — load avg 0.08, RAM/swap не нагружены (диагностика `123.sh` показала здоровый сервер).
- **Не сеть** — `apt install` качает мегабайты за разумное время; `Copy host settings` гонит килобайты — тут не сеть.
- **Не fail2ban / rate-limit** — нас не банят, fail2ban за весь прогон видел 17 чужих преаутх-фейлов.
- **Не WSL2-икота** — текущий прогон прошёл целиком без таймаутов (предыдущий с become-таймаутом был транзиентный).

---

## 4. Детальный разбор stage-4 (11 мин 46с)

### Внутренняя раскладка stage-4

| Время                                |           Δ | Задача                                             |
|--------------------------------------|------------:|----------------------------------------------------|
| 17:11:26 start                       |           — | (Stage 4 - LEMP installation начало)               |
| 17:11:33                             |          7с | apt-cache check                                    |
| 17:11:33                             |         13с | Ensure Redis is present (apt)                      |
| 17:11:50                             |         13с | Ensure Redis custom configuration (drop-in)        |
| 17:12:08                             |         12с | Configure redis to log to journald                 |
| 17:12:20                             |         13с | Ensure Memcached is present (apt)                  |
| 17:12:33                             |         14с | Configure Memcached                                |
| 17:12:51                             |         12с | APT-репозиторий MySQL 8.4 LTS                      |
| 17:13:06                             |          9с | Утилита для debconf preseed                        |
| 17:13:23                             |     **36с** | **Install MySQL 8.4 LTS** (apt — основная масса)   |
| 17:14:02                             |         10с | Установка python3-pymysql                          |
| 17:14:26                             |         13с | Настройка MySQL для низкой памяти                  |
| 17:14:39                             |     **15с** | **Install Nginx** (apt)                            |
| 17:14:54                             |         13с | Настройка Nginx для низкой памяти                  |
| 17:15:07                             |          7с | Create web roots (loop 3)                          |
| 17:15:14                             |     **29с** | **Copy host settings** (1 template — overhead!)    |
| 17:15:47                             |         13с | Configure nginx to log to journald                 |
| 17:16:02                             |          6с | Install software-properties-common                 |
| 17:16:08                             |         13с | Add ondrej repository                              |
| 17:16:21                             |     **25с** | **Install ImageMagick** (apt)                      |
| 17:16:46                             |     **47с** | **Install PHP** (apt — большой пакет-мета)         |
| 17:17:33                             |         15с | Ensure required PHP modules (loop 6)               |
| 17:17:50                             |     **71с** | **Copy PHP conf.d → fpm** (loop 8 файлов)          |
| 17:19:01                             |     **71с** | **Copy PHP conf.d → cli** (loop 8 файлов)          |
| 17:20:12                             |         12с | Copy PHP templates (loop)                          |
| 17:20:27                             |         13с | Настройка PHP-FPM для низкой памяти                |
| 17:20:40                             |         11с | Ensure systemd drop-in directory per unit (loop 5) |
| 17:20:51                             |     **63с** | **Deploy auto-restart drop-in per unit** (loop 5)  |
| ... handlers + cleanup + post-checks | до 17:23:11 |                                                    |

**Вердикт по stage-4:** из 11:46 на **«полезный apt-install»** уходит ~123с (MySQL + Nginx + ImageMagick + PHP), на *
*file-loop overhead** — ~234с (PHP conf.d × 2 + service_restart drop-ins + nginx Copy host settings). Полезная работа =
17% времени. Остальное — SSH-накладные.

---

## 5. Детальный разбор stage-1 (7 мин 01с)

| Время    |        Δ | Задача                                          |
|----------|---------:|-------------------------------------------------|
| 17:00:04 |        — | start                                           |
| 17:00:13 |       9с | Gathering Facts                                 |
| 17:00:13 |      19с | Update APT package cache                        |
| 17:00:32 | **307с** | **Install security updates only**               |
| 17:05:44 |      27с | Reboot server if needed (фактически ребутается) |
| 17:06:13 |     ~50с | locales, hostname, timezone (loop)              |
| 17:06:40 |      13с | Configure systemd journald log limits           |
| ...      |          | swap, прочее быстро                             |
| 17:07:06 |          | end                                             |

**Вердикт по stage-1:** **80% времени** — `Install security updates only` + reboot после. На свежей ноде это ~5 минут
«лечения» отставшего за месяцы security-патчинга. Само по себе оправдано (свежий сервер с дырявым ядром нельзя оставлять
онлайн до ночного `unattended-upgrade`), но возможны компромиссы (§6.4).

---

## 6. Предложения по ускорению

### 6.1. **PHP conf.d через `archive`+`unarchive`** ⭐⭐⭐

**Текущее (`roles/web-server/php/tasks/main.yml:76-92`):**

```yaml
-   name: Copy PHP configuration files from files/conf.d
    ansible.builtin.copy:
        src: files/conf.d/
        dest: /etc/php/{{ php_version }}/fpm/conf.d/
        ...
-   name: Copy PHP configuration files to cli/conf.d
    ansible.builtin.copy:
        src: files/conf.d/
        dest: /etc/php/{{ php_version }}/cli/conf.d/
        ...
```

`copy:` с `src=dir/` разворачивается Ansible-ом в N отдельных задач (по числу файлов внутри). С отключённым
ControlMaster — 8 файлов × ~9с = ~70с на каждый dest.

**Предлагаемое:**

```yaml
-   name: Pack PHP conf.d locally (один tar — одна передача)
    delegate_to: localhost
    become: false
    community.general.archive:
        path: "{{ role_path }}/files/conf.d/."
        dest: /tmp/php-confd-{{ ansible_date_time.epoch }}.tar.gz
        format: gz
    run_once: true
    register: php_confd_archive

-   name: Unpack PHP conf.d to fpm + cli (одна SSH-сессия)
    ansible.builtin.unarchive:
        src: "{{ php_confd_archive.dest }}"
        dest: "{{ item }}"
        owner: "{{ item == '/etc/php/' + php_version + '/fpm/conf.d/' | ternary('www-data', 'root') }}"
        group: "{{ item == '/etc/php/' + php_version + '/fpm/conf.d/' | ternary('www-data', 'root') }}"
        mode: '0644'
    loop:
        - /etc/php/{{ php_version }}/fpm/conf.d/
        - /etc/php/{{ php_version }}/cli/conf.d/
    notify: Restart PHP-FPM
```

**Экономия:** ~140с → ~10с. Минус **130 секунд** (~9% от full-deploy).
**Риск:** низкий. `unarchive` — стандартный модуль. Нужен `community.general` коллекшн (уже стоит, см. Makefile
`galaxy-install`).
**Усложнение:** небольшое — добавляется промежуточный tar, но логически прозрачно.

### 6.2. **service_restart: единый drop-in вместо loop** ⭐⭐

**Текущее (`roles/system/service_restart/tasks/main.yml`):**

```yaml
-   name: Ensure systemd drop-in directory per unit
    ansible.builtin.file:
        path: "/etc/systemd/system/{{ item }}.service.d"
        state: directory
    loop: "{{ service_restart_units }}"

-   name: Deploy auto-restart drop-in per unit
    ansible.builtin.template:
        src: restart.conf.j2
        dest: "/etc/systemd/system/{{ item }}.service.d/10-restart.conf"
        ...
    loop: "{{ service_restart_units }}"
```

Шаблон **одинаков** для всех 5 unit-ов (нет per-unit вариаций), но Ansible честно деплоит по одному через push.

**Предлагаемое (тот же `archive`+`unarchive`-подход):**

```yaml
-   name: Render restart.conf once on controller
    delegate_to: localhost
    become: false
    ansible.builtin.template:
        src: restart.conf.j2
        dest: /tmp/restart.conf.rendered
    run_once: true

-   name: Build tarball with drop-ins for all units
    delegate_to: localhost
    become: false
    ansible.builtin.shell: |
        work=$(mktemp -d)
        for u in {{ service_restart_units | join(' ') }}; do
          mkdir -p "$work/$u.service.d"
          cp /tmp/restart.conf.rendered "$work/$u.service.d/10-restart.conf"
        done
        tar -C "$work" -czf /tmp/service-restart-dropins.tar.gz .
    run_once: true

-   name: Push and unpack drop-ins (одна SSH-сессия)
    ansible.builtin.unarchive:
        src: /tmp/service-restart-dropins.tar.gz
        dest: /etc/systemd/system/
        owner: root
        group: root
    notify: Reload systemd daemon
```

**Экономия:** ~60с → ~10с. Минус **50 секунд** (~3% от full-deploy).
**Риск:** средний. Локальный `shell` с mktemp — небольшая некрасота, но логика проста.
**Альтернатива:** оставить как есть, выигрыш не критичен.

### 6.3. **Mitogen Ansible-плагин** ⭐⭐⭐⭐ (самый большой блан-эффект)

**Что это:** Сторонний strategy-плагин для Ansible, заменяет per-task SSH-цикл на **persistent Python-интерпретатор** на
сервере. Это НЕ SSH multiplexing → reboot-баг #79992 не возвращается.

**Установка:**

```bash
pip install --user mitogen
```

(или через `apt install python3-mitogen` если есть в репах)

**Конфиг (`ansible.cfg`):**

```ini
[defaults]
strategy = mitogen_linear
strategy_plugins = ~/.local/lib/python3/site-packages/ansible_mitogen/plugins/strategy
```

**Экономия:** обычно **2-5× по всему деплою**. Для нашего профиля (множество мелких задач) — ближе к 5×. Full-deploy с
25 мин → ~8-12 мин.
**Покрывает все проблемы из §3** без точечных правок.

**Риски:**

- Дополнительная зависимость на контроллере.
- Иногда конфликтует с экзотическими модулями/become-методами — у нас стандартный sudo NOPASSWD + копи/темплейты/apt,
  всё в supported-наборе.
- Может потребовать настройки если ssh-agent ведёт себя нестандартно.

**Рекомендация:** **попробовать на одной стадии** (`make stage-4`), сравнить, и если ок — оставить на постоянку.

### 6.4. **Скипнуть `Install security updates only` в stage-1** ⭐ (компромисс)

**Текущее (`roles/system/apt_update/tasks/main.yml`):** при первом запуске apt-upgrade всех security-only пакетов = ~5
минут.

**Что предлагается:** удалить таск (или сделать опциональным через флаг `apply_security_updates: false`). Полагаться на:

- `unattended_upgrades` (stage-3) — настраивает ночной автопатчинг.
- `apt-daily-upgrade.timer` — стартует через 1-2 часа после инсталляции системы.

**Экономия:** **5 минут** (20% от full-deploy).
**Риск:** окно ~12-24 ч с непропатченным ядром/openssl. Для **fire-and-forget** проекта (см. memory
`project_unmanaged_servers.md`) — приемлемый компромисс: сервер изолирован за UFW, fail2ban, SSH-key-only + hardening;
критические уязвимости в этом окне маловероятны.
**Trade-off:** если деплой делается часто (CI/CD каждый день) — экономия драгоценна. Если деплой делается раз в год — 5
мин не критично, лучше иметь свежий патчинг сразу.

### 6.5. **NO-GO: re-enable ControlMaster per-play** ❌

Возможно технически (через `vars: ansible_ssh_extra_args: -o ControlMaster=auto -o ControlPersist=60s` в плеях БЕЗ
reboot-модуля), даст ~3-5 минут экономии.

**НЕ рекомендую:**

- Memory `project_ansible_reboot_controlpersist.md` явно: «не возвращать auto/ControlPersist».
- Легко забыть для будущих плеев → внезапная регрессия #79992 (зависание reboot-таска на 12+ минут).
- Митоген (§6.3) даёт больший выигрыш без этого риска.

### 6.6. **NO-GO: оптимизировать apt-install** ❌

`Install PHP` (47с), `Install MySQL` (36с), `Install ImageMagick` (25с) — это **полезная сетевая загрузка** пакетов из
репозиториев. Альтернативы:

- Локальное apt-зеркало (`apt-cacher-ng`) — нужен ещё один сервис; для одного сервера в год — overkill.
- `apt-get install --download-only` заранее — добавляет шаг и комплексность; экономия только если запускаете повторно за
  короткое время.

Оставить как есть.

### 6.7. **NO-GO: внутренние loop-проверки** ❌

`Check critical services are active` (15с, loop 7), `Ensure PHP modules` (15с, loop 6) — эти проверки **enforcing** (
валят прогон если что-то не так), убирать нельзя. Можно ужать через `community.general` модули с batch-операциями, но
выигрыш ~10-20с — не стоит сложности.

---

## 7. Рекомендуемый порядок действий

### Фаза A: безопасные точечные правки

1. **§6.1** — PHP conf.d через archive/unarchive. Самый осязаемый эффект на конкретную боль (которую вы заметили в
   терминале). **-2 мин** из деплоя. Низкий риск.
2. *(опционально)* **§6.2** — service_restart drop-ins. **-50с**. Средний риск, не критично.

После фазы A: ~22 мин full-deploy вместо 25.

### Фаза B: глобальное ускорение (одно решение)

3. **§6.3** — Mitogen. Прогнать сначала на одной стадии для замера. Если работает чисто — оставить. **-10-15 мин** от
   того, что останется после фазы A.

После фазы B: ~8-12 мин full-deploy.

### Фаза C: компромисс (по желанию)

4. **§6.4** — скип `Install security updates only`. **-5 мин**, ценой ~12-24ч окна непропатченности.

После фазы C: ~5-8 мин full-deploy. Это лимит без apt-зеркала.

---

## 8. Ориентир для замеров после изменений

Прогнать `make full-deploy` на чистом сервере (как сейчас) до и после, сравнить `PLAY RECAP` в `logs/ansible.log`. Для
отдельных задач — глазами по timestamp-ам соседних `TASK [...]`-строк.

Грубая команда для топ-10 медленных задач:

```bash
awk -F' ' '
/TASK \[|RUNNING HANDLER/{
    line=$0
    split($2, t, ","); split(t[1], hms, ":")
    secs = hms[1]*3600 + hms[2]*60 + hms[3]
    if (prev_secs > 0) {
        delta = secs - prev_secs
        if (delta > 3) printf "%5.1fs  %s\n", delta, prev_task
    }
    match(line, /TASK \[[^]]*\]|RUNNING HANDLER \[[^]]*\]/)
    prev_task = substr(line, RSTART, RLENGTH)
    prev_secs = secs
}
' logs/ansible.log | sort -rn | head -15
```

---

## 9. История

- **2026-05-24** — первоначальный анализ на основе прогона `make full-deploy` после Phase 2 (passphrase для
  automation-ключа через ssh-agent).
