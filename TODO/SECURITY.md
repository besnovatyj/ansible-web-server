## Аспекты безопасности настройки сервера

Теперь подробно о безопасности. Установка LEMP-стека на сервер с 1 ГБ RAM требует баланса между производительностью и
защитой. Я опишу все ключевые аспекты: от базовой ОС до каждого компонента. Общие рекомендации: всегда используй сильные
пароли (минимум 16 символов, с символами), мониторь логи (/var/log/), используй инструменты вроде Fail2Ban и регулярно
обновляй систему (`apt update && apt upgrade`). С 1 ГБ RAM избегай тяжёлых фоновых задач.

#### 1. **Безопасность ОС (Ubuntu 24.04 LTS)**

- ❌**Обновления и патчи**: Автоматизируй обновления безопасности с помощью `unattended-upgrades`. Установи пакет:
  `apt install unattended-upgrades`. Настрой в `/etc/apt/apt.conf.d/50unattended-upgrades` для ежедневных обновлений.
  Это критично, так как уязвимости в kernel или libs (например, CVE в glibc) могут привести к RCE (remote code
  execution).
- ✅**Firewall (UFW)**: В playbook я включил UFW с разрешением только SSH (22), HTTP (80), HTTPS (443). Запрети всё
  остальное: `ufw default deny incoming`. Для 1 ГБ RAM это не нагружает систему. Альтернатива: nftables для более тонкой
  настройки.
- ✅**Пользователи и права**: Не используй root для SSH. Создай пользователя с sudo:
  `adduser youruser; usermod -aG sudo youruser`. Отключи root-login в `/etc/ssh/sshd_config`: `PermitRootLogin no`.
  Используй SSH-ключи вместо паролей: `PubkeyAuthentication yes; PasswordAuthentication no`. Перезапусти SSH:
  `systemctl restart ssh`.
- ✅**SELinux/AppArmor**: Ubuntu использует AppArmor по умолчанию. Убедись, что профили для Nginx/PHP/MySQL активны:
  `aa-status`. Для MySQL/Redis добавь custom profiles если нужно.
- 🔥**Fail2Ban**: Установи `apt install fail2ban`. Настрой jail для SSH, Nginx, PHP (блокировка brute-force). В
  `/etc/fail2ban/jail.local` добавь [sshd], [nginx-http-auth]. Это защитит от DDoS и сканов, но на 1 ГБ RAM установи
  bantime=3600, findtime=600.
- 🔥**Kernel hardening**: Включи sysctl: `sysctl -w net.ipv4.tcp_syncookies=1; net.ipv4.icmp_echo_ignore_broadcasts=1`.
  Добавь в `/etc/sysctl.conf` для персистентности. Это защищает от SYN-flood и ping-of-death.

#### 2. **Безопасность Nginx**

- 🔥**Конфигурация**: В шаблоне я добавил `server_tokens off` (скрывает версию, чтобы усложнить reconnaissance). Ограничь
  client_max_body_size=1M для предотвращения DoS через большие uploads. Добавь security headers в virtual host:
  `add_header X-Frame-Options "SAMEORIGIN"; add_header X-XSS-Protection "1; mode=block"; add_header X-Content-Type-Options "nosniff";`.
- 🔥**SSL/TLS**: Certbot автоматически настраивает HTTPS с Let's Encrypt. Используй только TLS 1.2+ в
  `/etc/nginx/sites-available/default`: `ssl_protocols TLSv1.2 TLSv1.3;`. Включи HSTS:
  `add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload";`. Автообновление сертификатов
  через cron (в playbook).
- 🔥**Защита от атак**: Ограничь rate limiting: `limit_req_zone $binary_remote_addr zone=one:10m rate=1r/s;`. Блокируй
  подозрительные User-Agents в server block. Логируй ошибки в `/var/log/nginx/error.log` и мониторь на атаки (SQLi,
  XSS).
- 🔥**Permissions**: Файлы Nginx — owner www-data, 644 для conf, 750 для directories. Не храни sensitive data в webroot.

#### 3. **Безопасность PHP**

- 🔥**Конфигурация**: В php.ini (`/etc/php/8.3/fpm/php.ini`):
  `disable_functions = phpinfo, system, exec, shell_exec, passthru` (запрет опасных функций). `expose_php = Off` (скрыть
  версию). `allow_url_fopen = Off` для предотвращения RFI (remote file inclusion).
- 🔥**FPM**: Запуск от www-data, chroot если возможно. С 1 ГБ RAM ограничь процессы (как в шаблоне). Используй OPCache
  для производительности, но с memory_consumption=64M.
- 🔥**Безопасность скриптов**: Всегда валидируй input в коде (фильтры, prepared statements). Установи open_basedir для
  ограничения доступа PHP к файлам.
- 🔥**Модули**: Только необходимые (как в playbook). Регулярно сканируй на уязвимости (например, с помощью `php -v` и
  проверкой CVE).

#### 4. **Безопасность Redis**

- 🔥**Конфигурация**: Bind только на localhost (127.0.0.1), protected-mode yes. Установи пароль:
  `requirepass your_strong_pass` в redis.conf. Maxmemory-policy для eviction, чтобы не съедать всю RAM.
- 🔥**Доступ**: Не exposing на публичный IP. Используй ACL (в Redis 7+): `aclfile /etc/redis/acl.conf` с user-specific
  правилами.
- 🔥**Защита**: Отключи опасные команды: `rename-command CONFIG ""`. Мониторь логи на unauthorized access. На 1 ГБ RAM
  избегай больших datasets.

#### 5. **Безопасность MySQL**

- 🔥**Установка**: В playbook используется mysql_secure_installation — удаляет анонимных пользователей, test DB,
  запрещает remote root.
- 🔥**Конфигурация**: Bind на 127.0.0.1, max_connections=50 для RAM. Используй strong root password. Включи
  validate_password plugin: `INSTALL PLUGIN validate_password SONAME 'validate_password.so';`.
- 🔥**Пользователи**: Создавай dedicated users для приложений:
  `CREATE USER 'appuser'@'localhost' IDENTIFIED BY 'strongpass'; GRANT ALL ON appdb.* TO 'appuser'@'localhost';`.
- 🔥**Шифрование**: Включи SSL для соединений: generate keys и настрой в mysqld.cnf. Backup базы регулярно с mysqldump.
- 🔥**Аудит**: Включи general_log для мониторинга queries, но выключи в проде (нагружает RAM).

#### 6. **Общие аспекты безопасности**

- 🔥**Мониторинг**: Установи `apt install htop net-tools logwatch`. Настрой email-уведомления для ошибок (postfix +
  logwatch).
- 🔥**Backups**: Автоматизируй с rsync или duplicity. Храни off-site.
- 🔥**Сканирование**: Регулярно запускай `rkhunter`, `clamav` для malware. Проверь на открытые порты: `nmap localhost`.
- 🔥**Compliance**: Следуй OWASP для web, CIS benchmarks для Ubuntu. Для 1 ГБ RAM тестируй нагрузку (ab или siege).
- 🔥**Риски с низкой RAM**: OOM может привести к crash — настрой swap (1-2 ГБ:
  `fallocate -l 1G /swapfile; mkswap /swapfile; swapon /swapfile`), но используй sparingly.
- 🔥Добавьте swap-файл (например, 1 ГБ) для предотвращения сбоев при нехватке памяти:
  ```shell 
  sudo fallocate -l 1G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
  ```
- 🔥Все проверки сделать с флагом:
  `changed_when: false  # Проверка не считается изменением`
- 🔥Поменять порт SSH

🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥
🔥 Отдать всё гроку на анализ после написания
🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥🔥

### 7. Мониторь: Установите monit или systemd-таймеры для проверки free RAM и рестарта при <200 МБ

Это о мониторинге RAM, чтобы сервер не "падал" от OOM. При <200 МБ свободной RAM (критично для 2 ГБ) — рестарт "жадных"
сервисов (PHP-FPM, MySQL) для освобождения.

**Monit** (простой мониторинг): Установите `apt install monit`. В `/etc/monit/monitrc`:

```ini
check system $HOST
if memory usage > 90% then exec "/bin/bash -c 'systemctl restart php8.3-fpm mysql'"  # Рестарт при >90% (оставит ~200 МБ)
```

- Включите: `systemctl enable monit; systemctl start monit`. Monit проверяет каждые 30 сек.

**Systemd-timer** (встроенный, без доп. пакетов): Создайте таймер для скрипта.

- Скрипт `/usr/local/bin/check_ram.sh`:
  ```bash
  #!/bin/bash
  FREE_RAM=$(free -m | awk '/Mem:/ {print $4}')
  if [ $FREE_RAM -lt 200 ]; then
    systemctl restart php8.3-fpm mysql
  fi
  ```
- Unit `/etc/systemd/system/check-ram.timer`:
  ```ini
  [Unit] Description=Check RAM every 5 min
  [Timer] OnUnitActiveSec=5m Persistent=true
  [Install] WantedBy=timers.target
  ```
- Service `/etc/systemd/system/check-ram.service`: `ExecStart=/usr/local/bin/check_ram.sh`.
- Активируйте: `systemctl daemon-reload; systemctl enable --now check-ram.timer`.

**Зачем?** Автоматически освобождает RAM, предотвращая краш. Логи в journalctl.
