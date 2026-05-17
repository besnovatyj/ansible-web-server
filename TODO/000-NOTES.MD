### Общие замечания (📝 ❌ ✅ ⚠️ 🔥)

1) Документировать в `Readme.md` процедуру архивирования ключей в KeePass после завершения настройки сервера. Так как
   присутствуют ключи без парольной фразы. Сразу настроить доступ через HeidiSql, Kitty и WinCSP.
   HeidiSQL/Kitty/WinSCP подключаются по ключу с парольной фразой от имени sudo пользователя `{{ здесь замена }}` через
   порт `{{ target_ssh_port }}`. WinSCP-протокол SCP/SFTP, MySQL через "SSH tunnel" в HeidiSQL на `127.0.0.1:3306`.
2) Безопасность обеспечивается тем, что приватный ключ `ansible` хранится только в зашифрованном KeePass, а на сервере
   он `password-locked` (В файле /etc/shadow в поле пароля появляется символ `!` или `*`. Это делает невозможным
   хеширование любой введенной строки так, чтобы она совпала с записью.) + ограничен `restrict`.
   Что реально делает restrict

   Это «зонтик»: включает все ограничения OpenSSH и автоматически любые новые в будущих версиях:
   no-pty, no-agent-forwarding, no-port-forwarding, no-X11-forwarding, no-user-rc.

   Чего restrict НЕ делает:
    - не блокирует выполнение команд (exec-канал);
    - не блокирует SFTP/SCP-subsystem;
    - не навязывает command=.

   А Ansible по SSH нужны ровно две вещи — выполнять модули (exec) и передавать файлы (sftp). Обе restrict не трогает.
   Поэтому полный restrict сам по себе проект не ломает.

   Единственная точка трения — `no-pty`: при `become` ssh-плагин форсит `-tt`,
   сервер pty не даёт → косметический шум в stderr, команда всё равно
   выполняется. Закрыто на уровне `ansible.cfg`: `pipelining=True` + `use_tty=False`.
   Если для конкретного automation-ключа когда-нибудь понадобится pty —
   аддитивно `restrict,pty` (re-enable поверх зонтика).

   NOPASSWD-sudo: реализован штатно — `users_provision/tasks/main.yml`
   разворачивает валидируемый (`visudo -cf`) drop-in `/etc/sudoers.d/<name>`
   `NOPASSWD:ALL` только для `sudo: nopasswd`. `requiretty` не задаётся.
   Доп. проверка не требуется.

   ⚠️ Проверить (не связано с `restrict` напрямую): `restrict` включает
   `no-agent-forwarding`. Если деплой клонирует приватные gitflic/TS-пакеты
   на сервере — это должно идти через серверный deploy-ключ, НЕ через проброс
   агента (`ssh -A`). При пробросе агента этот шаг сломается. Убедиться, что
   используется deploy-ключ.

3) Целевой пайплайн (что задаёт пользователь и что делают плейбуки)

   Пользователь задаёт ровно две вещи:

   1. `inventory/hosts.yml` → `ansible_host: <IP>`
   2. `secrets.yml` (vault) → `vault_root_password: <пароль root от провайдера>`
      (+ по паролю/passphrase на каждого human-пользователя)

   Дальше — `make` цель, прогоняющая стадии по порядку:

    ```
    stage-0   localhost   Генерация всех ключей (automation без passphrase,
                           human с passphrase, emergency root с passphrase) +
                           known_hosts. Pre-flight: vault_root_password задан.

    stage-1b  site         НОВЫЙ «bootstrap» плейбук — единственный, кто ходит
    (bootstrap)            ПО ПАРОЛЮ root. Создаёт всех server_users, кладёт
                           публичные ключи, ставит sudo (NOPASSWD/with-pass),
                           ставит UNIX-пароли human-юзерам. После него
                           парольный доступ больше не нужен Ansible никогда.
                           Идемпотентен (авто-детект «уже по ключу»).

    stage-2   site         Подключение УЖЕ как ansible-юзер по ключу
                           (become: true, NOPASSWD). Логи в journald.
                           verify_ssh циклом по всем пользователям.

    stage-3   site         Hardening: PasswordAuthentication no,
                           PermitRootLogin prohibit-password (или no),
                           ciphers/MACs/Kex, ufw, fail2ban[sshd] (после verify).

    stage-4..6 site        LEMP / certbot / queue / verification (без изменений).
    ```

   После `stage-3` сервер недостижим по паролю — и это ОК, потому что Ansible уже
   живёт на ключе automation-пользователя.

4) ⚠️ Fail2Ban настроен, но не проверялся, потому что локально у меня docker + Alpine, проверять на продакшн Ubuntu.
5) ⚠️ AppArmor работает в режиме `complain`. Подробнее в отдельном файле [AppArmor.md](AppArmor.md) Убрал критичные запреты.
   Все профили переведены временно из режима `enforce` в режим `complain`.
   После недели работы под `complain` смотрим `journalctl -u apparmor` / `dmesg | grep DENIED` и на основе
   реальных нарушений уже принимаем решение о переключении в `enforce`. Эти шаги — задача за рамками автоматизации
   Ansible, скорее ручная итерация.
6) 🔥 ContentSecurityPolicy(CSP) [ContentSecurityPolicy.md](ContentSecurityPolicy(CSP).md)
7) 🔥 Поменять порт SSH. Наверное, в том же плейбуке что отвечает за создание SSH keys с passphrase. То есть,
   максимальная защита сервера после того как больше не предвидится работа с Ansible.
8) ✅ Certbot: не было проверки содержимого сертификата (rate-limit risk) — ИСПРАВЛЕНО.

   Было: идемпотентность держалась на `args.creates:
   /etc/letsencrypt/live/{{ domain_name }}/fullchain.pem`. Хрупко — имя lineage
   certbot берёт из ПЕРВОГО `-d`, а не из `domain_name`; при ином порядке/составе
   `nginx_sites` путь не совпадал → перевыпуск на каждом прогоне → лимит LE
   «Duplicate Certificate» 5/нед. Плюс молчаливое недопокрытие: после первого
   выпуска `creates:` пропускал таск навсегда, новый vhost в сертификат не
   попадал.

   Стало (`roles/web-server/certbot`): `creates:` убран, идемпотентность и
   анти-rate-limit — на стороне certbot:
   - `--cert-name {{ domain_name }}` — детерминированное имя lineage.
   - `--keep-until-expiring` — валидный неизменный сертификат не
     перевыпускается; изменился набор доменов → авто-расширение.
   - `changed_when` по `Congratulations` в stdout (честный changed-репорт).
   - staging-тумблер `certbot_staging` (defaults/main.yml, по умолчанию
    `false`): при `true` → `--staging` (отдельные щедрые лимиты LE STAGING,
     прод-квоты не расходуются). Для отладки пайплайна: `-e certbot_staging=true`.
     ВАЖНО: staging-сертификат недоверенный — только для тестов.
9) ✅ **Nginx rate limiting** Нет `limit_req_zone`, fail2ban обнаруживает, но не предотвращает.
   Пока не актуально, можно себя самого забанить из-за количества ресурсов на доменах фронта и админки.
   `limit_req_zone $binary_remote_addr zone=one:10m rate=1r/s;`
10) **Backup стратегия** Нет mysqldump, нет бэкапа конфигов, нет off-site хранения
11) **Мониторинг** Нет алертинга, нет OOM-защиты (out of memory, особенно непонятно с opcache (смотри статью на Хабре)),
    нет проверки диска. (https://habr.com/ru/companies/vk/articles/310054/)
12) **Certbot**
    Добавлена роль Certbot, отвечающая за настройку HTTPS, но что она делает конкретно, пока не разбирался.
    Перейти на полное управление SSL-конфигами из Ansible. Certbot только получает сертификаты: `certbot certonly --nginx`
    или даже: `certbot certonly --webroot`. А nginx templates уже сами подключают сертификаты и делают redirect.
    Только если решили идти по варианту «certbot certonly + Ansible сам пишет SSL-блоки»

    Логика:

    - В `nginx_sites` добавить булевый ключ `ssl_enabled: false` (по умолчанию).
    - Stage 5a после получения сертификатов переключает `ssl_enabled: true` (либо через
      отдельный inventory var, либо проще — через factual check
      `stat: path=/etc/letsencrypt/live/.../fullchain.pem`).
    - В шаблоне `site.tmp.j2` добавить `{% if site.ssl_enabled %}{% set has_ssl = true %}{% endif %}`
      блок 443 с подключением сертификатов и `return 301 https://...` в 80-блоке.

    Этот шаг можно отложить — если в Stage 5a будем использовать `certbot --nginx`, он сам
    правит конфиги.
    Включи HSTS: `add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload";`.
13) **Redis**
    Доставка пароля в приложение не осуществлена. Способ доставки пароля в приложение Yii2. Для контекста: типовой паттерн —
    `/etc/yii2/env` (root:www-data, 0640), подключаемый в `php-fpm` через директиву `env[REDIS_PASSWORD]` в `www.conf.j2`,
    либо использование `EnvironmentFile=` в systemd-юните для queue workers. Файл создаётся тем же Ansible-плейбуком,
    переживает перезапуски сервера естественным образом.
14) 🔥🔥🔥 Сделать скорее всего получение приложением секретов через .env и АВТОМАТИЗИРОВАНТЬ ПРИ ПЕРЕЗАПУСКЕ СЕРВЕРА!!
15) ✅ **Обновления и патчи (unattended-upgrades)** — РЕАЛИЗОВАНО.
    Это критично, так как уязвимости в kernel или libs (например, CVE в glibc) могут привести к RCE (remote code
    execution).

    Обоснование (важно для модели «настроил и забыл на 3–5 лет»): для
    неуправляемого сервера в интернете доминирующая угроза — компрометация
    через непропатченный RCE (openssh/openssl/glibc/ядро), а НЕ поломка от
    бэкпортнутого security-патча. На LTS security-pocket ABI-стабилен, dpkg
    идёт с confold → конфиги не перетираются. Это решение СНИЖАЕТ риск, а не
    повышает. (`unattended-upgrades` ≠ release-upgrade — последний здесь
    отключён и не делается.)

    Сделано: роль `roles/system/unattended_upgrades`, подключена в stage-3.
    - Только `*-security` origins (`uu_security_only`, переопределяемо).
    - Ночной авто-ребут: `uu_auto_reboot_time=04:00`, `WithUsers=true`
      (фиксы ядра/glibc инертны без ребута; для fire-and-forget обязателен).
    - Гигиена диска: `Remove-Unused-Kernel-Packages` (главная причина тихого
      «загнивания» — забитый /boot валит apt).
    - `apt-config dump` как пост-проверка (битый apt.conf.d молча ломает ВЕСЬ
      apt → нет обновлений и нет apt вообще).
    - Все размеры/режимы — переменные в `defaults/main.yml`.
    - Enforcing Post-check в stage-3 (паттерн «post_tasks в конце стадии»):
      `APT::Periodic::Unattended-Upgrade == "1"`, `apt-daily-upgrade.timer`
      active, `unattended-upgrade --dry-run` rc 0 (end-to-end: конфиг
      парсится, origins резолвятся).

    ⚠️ ПРЕДУСЛОВИЕ ночного авто-ребута: ВСЕ сервисы должны быть `enabled` и
    чисто подниматься после boot (nginx, php-fpm, mysql, redis, yii2-queue).
    Иначе ночной ребут = тихий простой до звонка. Проверить отдельно:
    `systemctl is-enabled nginx php*-fpm mysql redis-server <queue-unit>` +
    один контрольный `reboot` после провижининга. (Связано с п.14 — секреты
    должны переживать ребут естественно, через файл, не ENV сессии.)
    Заметка: Ubuntu 24.04 ставит unattended-upgrades включённым по умолчанию
    (security) — роль делает поведение явным и управляемым, а не «как повезёт».
16) ⚠️ Операционная связка: при validate_timestamps=0 после деплоя кода обязателен рестарт php-fpm
    (handler Restart PHP-FPM это делает) — иначе сервер вечно отдаёт старый код.
    Это завязано на деплой-пайплайн (п.13/14), держи в голове.
17) ✅ **Мониторинг / OOM-защита (п.11)** — РЕШЕНО без мониторинг-демона.

    Важно: в п.11 смешаны ДВА разных «OOM». Системный OOM (ядро убивает
    жадный процесс) ≠ OPcache SHM-исчерпание (свой сегмент opcache переполнен;
    статья VK Habr 310054 — opcache НИКОГДА не освобождает память → лок-контеншн
    и обвал перфоманса, НЕ краш). Лечатся по-разному.

    Сделано:
    - **2a. Авто-рестарт сервисов** — роль `roles/system/service_restart`,
      подключена в stage-4 (после установки LEMP) + enforcing post-check.
      systemd drop-in `10-restart.conf` (Restart=on-failure, RestartSec=5s,
      поднятый StartLimitBurst) для nginx/php-fpm/mysql/redis/memcached.
      Нулевой overhead. Если OOM-kill/краш убил сервис — поднимется сам за
      секунды (главный fire-and-forget фикс; стыкуется со swap и ⚠-предусловием
      п.15 про ночной ребут unattended-upgrades).
    - **2b. OPcache sizing** (`opcache.ini`) — закрывает вопрос статьи:
      memory_consumption 64→128, interned_strings_buffer 8→16,
      max_accelerated_files 4000→10000, validate_timestamps=0 (оставлено).
      Сегмент ОБЩИЙ для всех fpm-воркеров (не ×pm.max_children) → цена
      ~+70МБ RAM однократно, не нагрузка. Связка с п.16 (рестарт после деплоя).

    Отклонено осознанно:
    - **SECURITY.md** (monit / check_ram.sh, рестарт php-fpm+mysql при
      «free RAM < 200МБ / >90%») — УДАЛЁН. Лекарство хуже болезни: скрипт
      берёт колонку `free`, а не `available` (в Linux почти вся RAM штатно
      под page-cache) → срабатывает на здоровом сервере постоянно → monit
      рестартит MySQL+php-fpm в цикле = рукотворный self-DoS. Рестарт MySQL
      ради RAM деструктивен (рвёт транзакции, остужает buffer pool). monit =
      лишний демон против «минимально/не нагружать/забыл на годы».

    2c. Проверка диска — отдельная НЕ нужна: рост уже ограничен (journald
    SystemMaxUse=100M, binlog expire 7д + max 100M, чистка ядер
    unattended-upgrades). Скрипт-WARNING в журнал, который никто не читает,
    для fire-and-forget бессмыслен; эффективный контроль = ограничивать рост
    (сделано), а не мониторить в пустоту.





















