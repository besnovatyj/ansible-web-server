# Ansible LEMP Stack Deployment

Ansible-проект для автоматического развёртывания и настройки LEMP-стека на Ubuntu 24.04 (Noble Numbat).

## Стек технологий

| Компонент | Версия    |
|-----------|-----------|
| Ubuntu    | 24.04 LTS |
| Nginx     | 1.24.0    |
| MySQL     | 8.0.43    |
| PHP       | 8.3       |
| Redis     | 7.0.15    |
| Memcached | 1.6.24    |

## Структура проекта

```
.
├── ansible.cfg              # Конфигурация Ansible
├── environments.sh          # Переменные окружения
├── Makefile                 # Команды для деплоя
├── group_vars/
│   └── global.yml           # Глобальные переменные
├── inventory/
│   └── hosts.yml            # Инвентарь хостов
├── playbooks/
│   ├── local-init.yml       # Генерация SSH-ключей (локально)
│   ├── remote-base.yml      # Базовая настройка сервера
│   ├── remote-security.yml  # Настройка безопасности SSH
│   ├── remote-webserver.yml # Установка веб-сервера
│   └── remote-test-security.yml  # Тесты подключения
├── roles/
│   ├── system/              # Системные роли
│   ├── web-server/          # Роли веб-сервера
│   └── tests/               # Тестовые роли
├── secrets/
│   ├── !vault_pass.txt      # Пароль от Vault (НЕ коммитить!)
│   ├── secrets.vault        # Зашифрованные секреты
│   └── secrets.yml          # Шаблон секретов
└── mysql_dump/
    └── dump.sql             # SQL-дамп для восстановления
```

## Быстрый старт

### 1. Подготовка локальной машины

```bash
# Установка Ansible и зависимостей
make init-ansible-and-other

# Установка Ansible Galaxy коллекций
make galaxy-mysql-crypto
```

### 2. Настройка переменных

Отредактируйте `group_vars/global.yml`:

```yaml
DOMAIN_NAME: your-domain.ru
time_zone: Europe/Moscow  # или Asia/Yekaterinburg
new_user: your_username   # sudo-пользователь вместо root
```

### 3. Настройка секретов

```bash
# Создание нового Vault
make vault-create

# Или редактирование существующего
make vault-edit
```

Секреты в Vault:

```yaml
vault_root_password: "пароль_root_ssh"
vault_ssh_key_passphrase: "пароль_для_ssh_ключа"
vault_mysql_root_password: "пароль_mysql_root"
vault_mysql_db_user_password: "пароль_пользователя_mysql"
```

### 4. Настройка инвентаря

Отредактируйте `inventory/hosts.yml`:

```yaml
all:
    children:
        site:
            hosts:
                server:
                    ansible_host: 123.45.67.89  # IP вашего сервера
                    ansible_port: 22
```

### 5. Деплой

```bash
# Полный деплой (рекомендуется для нового сервера)
make full-deploy

# Или поэтапно:
make local-init        # Генерация SSH-ключей
make remote-base       # Базовая настройка
make remote-webserver  # Установка веб-сервера
make remote-security   # Настройка безопасности SSH
```

## Команды Makefile

| Команда                     | Описание                                                |
|-----------------------------|---------------------------------------------------------|
| `make local-init`           | Генерация SSH-ключей на локальной машине                |
| `make remote-base`          | Базовая настройка сервера (locale, swap, ufw, fail2ban) |
| `make remote-webserver`     | Установка Nginx, MySQL, PHP, Redis, Memcached           |
| `make remote-security`      | Создание sudo-юзера, настройка SSH-безопасности         |
| `make remote-test-security` | Проверка подключения по ключам                          |
| `make full-deploy`          | Выполняет local-init → remote-base → remote-webserver   |
| `make vault-edit`           | Редактирование секретов                                 |
| `make vault-view`           | Просмотр секретов                                       |

## Что устанавливается и настраивается

### Системные настройки (`remote-base`)

- **Локаль и таймзона**: ru_RU.UTF-8, en_US.UTF-8
- **Swap**: 2GB swapfile
- **Systemd**: лимиты журналирования (100MB max)
- **UFW**: открыты порты 22, 80, 443 (всё остальное reject)
- **Fail2ban**: защита SSH, Nginx, PHP с прогрессивными банами

### Веб-сервер (`remote-webserver`)

- **Redis**: слушает только localhost, 128MB памяти
- **Memcached**: слушает только localhost, 64MB памяти
- **MySQL**: secure installation, удаление test-БД и анонимных пользователей
- **Nginx**: базовая конфигурация
- **PHP 8.3**: FPM + основные модули (mysql, redis, gd, mbstring, curl, opcache и др.)

### Безопасность (`remote-security`)

- Создание sudo-пользователя с SSH-ключом
- Отключение входа по паролю
- Современные криптоалгоритмы (ed25519, chacha20-poly1305)
- Таймаут сессии: 15 минут

## SSH-ключи

Проект создаёт две пары ключей:

1. **Обычный ключ** (`~/.ssh/key_<domain>`) — для sudo-пользователя
2. **Аварийный ключ** (`~/.ssh/key_<domain>_emergency_root`) — для root (на случай проблем)

Оба ключа защищены парольной фразой из Vault.

## Fail2ban Jails

Включены по умолчанию:

- `sshd` — защита SSH
- `nginx-http-auth` — basic auth nginx
- `nginx-botsearch` — поиск уязвимостей
- `nginx-bad-request` — плохие запросы
- `nginx-forbidden` — запрещённые страницы
- `php-url-fopen` — атаки через PHP
- `recidive` — повторные нарушители (длинный бан)

Настройки в `global.yml`:

```yaml
banTime: 3600   # 1 час начального бана
findTime: 600   # окно 10 минут
maxRetry: 5     # попыток до бана
```

## Проверка работоспособности

После деплоя:

```bash
# Проверка SSH-подключения
make remote-test-security

# На сервере:
systemctl status nginx php8.3-fpm mysql redis memcached
fail2ban-client status
ufw status
```

## Требования

### Локальная машина

- Ansible Core 2.15+
- Python 3.10+
- SSH-клиент

### Удалённый сервер

- Ubuntu 24.04 LTS
- Минимум 2GB RAM
- Доступ по SSH от root (первичное подключение)

## Решение проблем

### Ошибка подключения при первом запуске

Если сервер новый, добавьте его в known_hosts:

```bash
ssh-keyscan -H <IP_сервера> >> ~/.ssh/known_hosts
```

Или используйте `make local-init` — он сделает это автоматически.

### Таймаут при подключении

Проверьте:

1. IP-адрес в `inventory/hosts.yml`
2. Порт SSH (по умолчанию 22)
3. Пароль root в Vault (`vault_root_password`)

### Ошибка "Permission denied"

После настройки безопасности вход по паролю отключён. Используйте SSH-ключ:

```bash
ssh -i ~/.ssh/key_<domain> <user>@<server>
```

## Безопасность

⚠️ **Важно:**

1. **Никогда не коммитьте** `secrets/!vault_pass.txt`
2. Добавьте в `.gitignore`:
   ```
   secrets/!vault_pass.txt
   *.retry
   logs/
   ```
3. После деплоя **ротируйте пароли**, если они могли утечь
4. Используйте уникальные пароли для каждого проекта

## Расширение проекта

### Добавление Certbot (SSL)

Роль `roles/web-server/certbot` готова к использованию. Добавьте в плейбук:

```yaml
roles:
    - ../roles/web-server/certbot
```

### Добавление очередей (Yii2 Queue)

Роль `roles/web-server/queue/systemd` настраивает systemd-юнит для воркеров.

## Лицензия

MIT

## Автор

Проект для автоматизации развёртывания веб-серверов на базе Ubuntu 24.04.
