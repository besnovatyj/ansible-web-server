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
   максимальная
   защита сервера после того как больше не предвидится работа с Ansible.
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
10) **Backup стратегия** Нет mysqldump, нет бэкапа конфигов, нет off-site хранения
11) **Мониторинг** Нет алертинга, нет OOM-защиты (out of memory, особенно непонятно с opcache (смотри статью на Хабре)),
    нет проверки диска
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
13) **Redis**
    Доставка пароля в приложение не осуществлена. Способ доставки пароля в приложение Yii2. Для контекста: типовой паттерн —
    `/etc/yii2/env` (root:www-data, 0640), подключаемый в `php-fpm` через директиву `env[REDIS_PASSWORD]` в `www.conf.j2`,
    либо использование `EnvironmentFile=` в systemd-юните для queue workers. Файл создаётся тем же Ansible-плейбуком,
    переживает перезапуски сервера естественным образом.





















