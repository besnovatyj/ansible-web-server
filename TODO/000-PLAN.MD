### Общая последовательность работы с удалённым сервером

Документировать в `ansible/TODO/Readme.md` процедуру архивирования ключей в KeePass после завершения
настройки сервера, чтобы через год не забыть.
Заодно настрою сразу доступ на сервер через HeidiSql, Kitty и WinCSP, они будут в любом случае нужны.
HeidiSQL/Kitty/WinSCP подключаются по ключу `key_{{ domain_name }}` для пользователя `{{ new_user }}` через порт
`{{ target_ssh_port }}`. WinSCP-протокол SCP/SFTP, MySQL через "SSH tunnel" в HeidiSQL на `127.0.0.1:3306`.

- Безопасность обеспечивается тем, что приватный ключ `ansible` хранится только в
  зашифрованном KeePass, а на сервере он `password-locked` (В файле /etc/shadow в поле пароля появляется символ ! или *.
  Это делает невозможным хеширование любой введенной строки так, чтобы она совпала с записью.) + ограничен `restrict`
  смотри ⚠️ ЗАМЕЧАНИЕ

> ⚠️ ЗАМЕЧАНИЕ: Если вы используете `restrict`, убедитесь, что Ansible может исполнять свои задачи.
> Часто вместо чистого `restrict` для автоматизации используют связку:
> `no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty`
> Это оставляет возможность передавать файлы и исполнять команды, но закрывает «интерактивные» дыры.

## 0. Целевой пайплайн (что задаёт пользователь и что делают плейбуки)

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
                       Идемпотентен (см. 5.2 — авто-детект «уже по ключу»).

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


---

### Общие замечания

- Не настроен контроль Fail2Ban для ошибок аутентификации в приложении yii2. **Можно ли через Monolog писать в syslog?**
  Да, у Monolog есть готовый `Monolog\Handler\SyslogHandler` (через функцию PHP `openlog/syslog`) и
  `Monolog\Handler\SyslogUdpHandler` (через `udp://`). На системе с journald `SyslogHandler` положит сообщения прямо в
  `systemd-journald` под тегом, который укажешь. **Как настроить в Yii2:** в `common/config/main.php` добавляешь
  канал `auth` с `SyslogHandler` (`ident: yii2-auth`, `facility: LOG_AUTH`, `level: NOTICE`). В контроллере
  `SiteController::actionLogin` или в `User::onAfterLogin` отправляешь сообщение
  `"Failed login from {ip} for {username}"` или `"Successful login from {ip} for {username}"`.
  Дальше — фильтр fail2ban с regex по этой строке.
- AppArmor работает в режиме `complain`. Подробнее в отдельном файле [AppArmor.md](AppArmor.md)
- Лимиты на загрузку файлов. Разобраться. PHP: `upload_max_filesize`; Nginx: `client_max_body_size`. Загрузка нужна
  пока что только в админке.
- MySQL: что за логи `general_log` и `binlog`? Вкл иил выкл? Общие логи в syslog нужны, текстовые логи отключаем.
- Redis конфиг. Можно как-то оптимизировать конфигурирование? Должен быть способ задания логов безопасных при
  обновлении, чтобы инсталлятор не перезаписывал мой конфиг. В PHP, например, пользовательские конфиги не перезаписывают
  существующие, а инклюдятся в дефолтные, перезаписывая настройки по умолчанию своими.
- Systemd Override: Вы создаете **Systemd override-файлы** для Nginx, Redis, SSH вручную через `copy`. Это работает, но
  в Ansible есть модуль `ansible.builtin.systemd_service` (или просто `systemd` в старых версиях), который умеет делать
  перезагрузку демона, но для создания override-файлов лучше использовать `template` или `blockinfile`, чтобы управлять
  контентом более гибко. Текущий подход `copy` приемлем, но при изменении параметров придется менять весь блок текста.
- ContentSecurityPolicy(CSP) [ContentSecurityPolicy.md](ContentSecurityPolicy(CSP).md)
- Поменять порт SSH. Наверное, в том же плейбуке что отвечает за создание SSH keys с passphrase. То есть, максимальная
  защита сервера после того как больше не предвидится работа с Ansible.

---

### Claude замечания. Мой анализ.

#### Финальная архитектура stage-плейбуков сохраняет ровно столько разделений, сколько даёт практическую пользу:

- **Stage 0** — отдельно потому что выполняется на localhost (другой `hosts:`).
- **Stage 1 Bootstrap** Копирование ключей на удалённый хост с помощью root с обычным паролем.
- **Stage 1 (OS) + Stage 2 (access)** — разделены ради того, чтобы между ними можно было сходить ssh-ом руками и
  убедиться что ключи работают, перед тем как Stage 3 отключит пароль.
- **Stage 3 (security)** — отделён от Stage 4 (LEMP), чтобы при пере-настройке LEMP не трогать sshd/UFW.
- **Stage 4 (LEMP)** — единым блоком, как ты и хотел.
- **Stage 5 (Certbot/Queue)** — отдельно, потому что зависит от DNS и от наличия исходников приложения.
- **Stage 6 (verification)** — отдельно, потому что запускается независимо для проверки "всё ли живо".

#### Замечания

**Certbot**
Нет проверки существования сертификата (rate limit risk)

**Docker**
Устаревший: Ubuntu Jammy вместо Noble, Docker Compose 1.25 (актуально 2.x)

**Queue workers**
Нет лимитов ресурсов
Добавить `MemoryMax`, `CPUQuota`, `RestartSec=5` в systemd unit

**Nginx gzip**
Нет сжатия, трафик передаётся несжатым
Добавить `gzip on; gzip_types text/plain text/css ...`

**Nginx rate limiting**
Нет `limit_req_zone`, fail2ban обнаруживает, но не предотвращает

**Backup стратегия**
Нет mysqldump, нет бэкапа конфигов, нет off-site хранения

**Мониторинг**
Нет алертинга, нет OOM-защиты (out of memory, особенно непонятно с opcache (смотри статью на Хабре)), нет проверки диска

**Redis**
Доставка пароля в приложение не осуществлена. Способ доставки пароля в приложение Yii2. Для контекста: типовой паттерн —
`/etc/yii2/env` (root:www-data, 0640), подключаемый в `php-fpm` через директиву `env[REDIS_PASSWORD]` в `www.conf.j2`,
либо использование `EnvironmentFile=` в systemd-юните для queue workers. Файл создаётся тем же Ansible-плейбуком,
переживает перезапуски сервера естественным образом.

**Certbot**
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

**AppArmor**
Убрал критичные запреты. Все профили переведены временно из режима `enforce` в режим `complain`.
После недели работы под `complain` смотрим `journalctl -u apparmor` / `dmesg | grep DENIED` и на основе
реальных нарушений уже принимаем решение о переключении в `enforce`. Эти шаги — задача за рамками автоматизации
Ansible, скорее ручная итерация.

**Fail2ban**
Подготовлено к переходу на логирование Monolog -> syslog.

**MySQL**
Сделан whitelist keep_mysql_root_hosts в конфиге `inventory/group_vars/all/webserver.yml`.
Нет проверки на то что после установки MySQL в нём "из коробки" имеется необходимый пользователь
`root@localhost` или `root@127.0.0.1`.

**vault**
⚠️ ЗАМЕЧАНИЕ: Но есть нюанс: любой inventory автоматически подхватит этот vault. Если потом
появится: dev prod staging, то secrets начнут течь между окружениями.
Лучше сразу (даже если сейчас один сервер).

 ```yaml
   inventory/
   prod/group_vars/all/
   dev/group_vars/all/
 ```

**stage-0-local-init.yml**

Assert-проверки:

- Vault расшифрован и переменные определены
- Ключи созданы и имеют правильные права (0600 / 0644)

**stage-1-server-base.yml**

Swap размер хардкод - Вынести в переменную
Лимиты journald (размер через переменные)

Assert-проверки:

- Swap активен (`swapon -s`)
- Локаль установлена
- Timezone корректен

**stage-3-server-security.yml**

Один нюанс по порядку шагов: fail2ban с `[sshd]` jail включаем **после** post-check SSH, не до — иначе во время
exhaustive проверки SSH сам контроллер может попасть в бан, если что-то пойдёт не так с ключами.

Assert-проверки:

- UFW active
- fail2ban running
- SSH подключение работает после hardening

**stage-4-webserver.yml**

Assert-проверки:

- Все сервисы running: redis, memcached, mysql, nginx, php-fpm
- Порты открыты: 80, 443 !!! Но HTTPS появляется только после Stage 5a.
- PHP-FPM socket существует

**stage-5a-certbot.yml**

Предусловия для запуска: Stage 4 успешно прошёл, DNS на доменах указывает на этот сервер, проверь руками
`dig +short {{ domain_name }}` показывает IP сервера.

Assert-проверки: сертификат существует (`/etc/letsencrypt/live/{{ domain_name }}/fullchain.pem`), `nginx -t` проходит,
HTTPS-эндпоинт отдаёт 200/404 (не 5xx).

**stage-5b-queue.yml**

Нерабочая роль, нужна настройка

Не реализовано:

- Включает количество workers по `queue_workers_count`
- Добавляет ресурсные лимиты (MemoryMax, CPUQuota)

Предусловия: исходники проекта уже задеплоены (`{{ web_root }}/{{ domain_name }}/yii` существует).
**Никакого автоматического старта**: на момент Stage 5b workers могут падать (нет .env у Yii2) — это нормально. Юниты
оставляем в `disabled` состоянии до ручного `systemctl enable --now yii-queue@1` после первого деплоя кода.

**Дублирование логики**
`host_ip` (main.yml) и `target_host` (ssh.yml) — одно и то же выражение**
Обе тянут `hostvars[groups['site'][0]]['ansible_host']`. Не баг, но дублирование — при смене инвентаря синхронизировать
два места.










