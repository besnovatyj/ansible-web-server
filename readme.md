# Деплой с нуля — краткий порядок действий

Развёртывание Yii2-cms на чистый Ubuntu-сервер (без Docker) этим Ansible-проектом.
Формат: «запускаем это — оно делает то». Детали ролей — в самих плейбуках.

---

## 0. Один раз на управляющей машине (контроллере)

```bash
make init-ansible     # ставит ansible-core, sshpass, pexpect, nano
make galaxy-install   # ставит коллекции community.mysql / community.crypto
```

---

## 1. Заполнить вручную ПЕРЕД запуском

| Файл | Что вписать |
|---|---|
| `.env` | `DOMAIN=<домен>` |
| `inventory/group_vars/all/main.yml` | `domain_name` (тот же, что в `.env`), `time_zone` |
| `inventory/hosts.yml` | `ansible_host:` — IP сервера |
| `inventory/group_vars/all/webserver.yml` | `mysql_db_name`, `mysql_db_user`, `certbot_email` |
| `secrets/!vault_pass.txt` | пароль от vault (скопировать из `!vault_pass.txt.example`, вписать свой) |

### Секреты (зашифрованный vault)

Взять шаблон `secrets/secrets.yml.example`, заполнить значения, зашифровать:

```bash
cp secrets/secrets.yml.example secrets/secrets.yml   # заполнить значения (см. ниже)
make vault-encrypt                                    # → inventory/group_vars/all/secrets
```

Значения, которые нужно сгенерировать/придумать:

```bash
openssl rand -hex 32     # vault_altcha_hmac_key (менять НЕЛЬЗЯ после прод — сбросит challenge)
```

Остальные `vault_*` (пароли MySQL/Redis/root, SSH-passphrase) — задать своими стойкими строками.
Позже отредактировать секреты: `make vault-edit`.

---

## 2. Развёртывание

Первый `make stage-*` один раз за сессию спросит passphrase SSH-ключей (ssh-agent).
`make agent-up` один раз в начале сессии (или само подхватится первым `remote-make stage-*`).

### Всё сразу

```bash
make full-deploy   # = stage-0 → 1b → 1 → 2 → 3 → 4 → 6
```

### Или по шагам

| Команда | Что делает |
|---|---|
| `make stage-0` | Локально: генерит SSH-ключи, добавляет сервер в known_hosts |
| `make stage-1b` | Доставляет ключи на сервер по паролю root (единственный вход по паролю) |
| `make stage-1` | Базовая настройка ОС: пакеты, локали, swap, systemd |
| `make stage-2` | Пользователи, деплой ключей, проверка SSH-доступа |
| `make stage-3` | Безопасность: UFW, hardening SSH, fail2ban |
| `make stage-4` | LEMP-стек (Redis, MySQL, Nginx, PHP) + секреты приложения в `/run/secrets` |
| `make stage-6` | Проверки, что всё поднялось |

---

## 3. После деплоя — исходники и остальное

1. **Залить исходники приложения** в `/var/www/<домен>/` (git-pull на сервере или `make stage-5c` — резервный rsync).
2. `make stage-5a` — SSL-сертификаты Let's Encrypt.
   ⚠️ Сначала DNS домена должен указывать на сервер (проверить: `dig +short <домен>`).
3. `make stage-5b` — queue-воркеры Yii2 (запускать только после заливки исходников).

---

## Полезное

```bash
make help            # список всех команд
make syntax-check    # проверка синтаксиса плейбуков
make vault-view      # посмотреть расшифрованные секреты
make agent-status    # состояние ssh-agent и загруженных ключей
```
