## Исходные данные

Сервер с 2 Гб оперативной памяти.  
Устанавливаем только стабильные версии из [репозиториев Ubuntu](https://packages.ubuntu.com/) (данные на 05.09.2025):  
Текущая версия ОС: `ubuntu server 24.04.3 lts`.

| Название                                                  | Версия                    | Ссылка                              |
|-----------------------------------------------------------|---------------------------|-------------------------------------|
| Ubuntu                                                    | 24.04 LTS                 | https://packages.ubuntu.com/        |
| Nginx                                                     | 1.24.0-2ubuntu7.5         | см. Ubuntu                          |
| PHP                                                       | 8.3                       | см. Ubuntu                          |
| Mysql                                                     | 8.0.43-0ubuntu0.24.04.2   | см. Ubuntu                          |
| Redis                                                     | 5:7.0.15-1ubuntu0.24.04.1 | https://download.redis.io/releases/ |
| memcached                                                 | 1.6.24-1build3            | см. Ubuntu                          |
| fail2ban                                                  | 1.0.2-3                   | см. Ubuntu                          |
| Certbot Let's Encrypt client application plugin for Nginx | 2.11.0                    |                                     |

NB: fail2ban версии 1.0.2 предустановлен в `ubuntu server 24.04.3 lts`. Последняя версия на 07.10.2025 = 1.1.0.

🔥TODO: Переделать на сервер с 2Гб RAM.

Для сервера с 1 ГБ RAM, playbook включает оптимизации (Это поможет избежать OOM (out-of-memory) ошибок):

- уменьшение worker-процессов в Nginx (до 1-2)
- ограничение пула PHP-FPM max_children=5
- настройку MySQL на низкое потребление innodb_buffer_pool_size=128M
- Redis сmaxmemory=256MB и eviction-policy.

## Актуальный порядок (2026-05-15, см. `000-ANALYSIS.md`)

> Эта секция — авторитетная. Список «Общий план» ниже оставлен как история.

### Что задать руками (всего две вещи)

1. `inventory/hosts.yml` → `ansible_host: <IP сервера>`
2. Секреты. Plaintext-шаблон — `secrets/secrets.yml`; рабочие значения Ansible
   подхватывает из зашифрованного `inventory/group_vars/all/secrets.vault`
   (см. комментарий в `group_vars/all/vault.yml`). Заполнить и зашифровать
   (`ansible-vault`, пароль — `secrets/!vault_pass.txt`):
   - `vault_root_password` — пароль root от провайдера (нужен ТОЛЬКО stage-1b);
   - `vault_user_<name>_password` / `vault_user_<name>_passphrase` — на каждого
     `type: human` из `server_users` (`group_vars/all/ssh.yml`).

Новый человек = +1 блок в `server_users` + пара `vault_user_*` в `secrets.yml`.

### Зависимость контроллера: `sshpass`

`stage-1b` (единственный заход по паролю root) использует парольную SSH-аутентификацию,
для которой Ansible требует `sshpass` на машине-контроллере:

```bash
sudo apt-get install -y sshpass     # Debian/Ubuntu
```

Без `sshpass` stage-1b упадёт с `to use the 'ssh' connection type with passwords, you must install the sshpass program`.

### Запуск

Цели — в `ansible/Makefile` (запускать из директории `ansible/`):

```bash
make full-deploy            # stage-0 → stage-1b → stage-1 → 2 → 3 → 4 → 6
# или по стадиям:
make stage-0                # генерация ключей локально
make stage-1b               # bootstrap: юзеры + ключи по паролю root
make stage-1                # дальше — automation-пользователем по ключу
make stage-2 stage-3 stage-4 stage-5a stage-5b stage-6
make help                   # список всех целей
```

`stage-1b` идемпотентен: если automation-ключ уже работает, bootstrap
пропускается (повторный прогон безопасен).

### Архивирование ключей в KeePass (сделать сразу после первого успешного прогона!)

Чтобы через год не искать ключи. Все приватные ключи лежат в
`ansible/secrets/ssh/` (`local_ssh_keys_dir`):

| Файл                          | passphrase | Назначение                              |
|-------------------------------|------------|-----------------------------------------|
| `key_<domain>_<automation>`   | НЕТ        | ходит Ansible; хранить ТОЛЬКО в KeePass |
| `key_<domain>_<human>`        | ДА         | человек руками (Kitty/WinSCP/HeidiSQL)  |
| `key_<domain>_emergency_root` | ДА         | аварийный вход root, обычно не нужен    |

Процедура:

1. После успешного `make provision-stage-6` создать в KeePass запись на каждый
   приватный ключ (вложением — сам файл ключа; в поле пароля — passphrase, если есть).
2. Туда же: `vault_root_password`, все `vault_user_*`, пароль Ansible Vault
   (`secrets/!vault_pass.txt`).
3. Сделать **две** копии базы KeePass в разные места (правило из плана).
4. Проверить, что вход по ключам реально работает (`make provision-stage-6`),
   и только потом считать ключи «архивными».

Подключение клиентов: HeidiSQL/Kitty/WinSCP — по `key_<domain>_<human>` под
именем человека (`type: human`) на порт `target_ssh_port`; MySQL — через SSH-туннель
на `127.0.0.1:3306`. Ansible-ключом (`key_<domain>_<automation>`) руками не ходим.

## Общий план (🔥TODO - проверить все шаги)

1) Отредактировать данные в соответствии с настраиваемым хостом
    - IP адрес удалённого хоста
    - Название домена
    - Пароль root (Ansible Vault)
    - Имя пользователя базы данных
    - Пароль для базы данных (Ansible Vault)
    - Парольная фраза для генерируемых ключей (Ansible Vault)
    - Часовой пояс сервера
    - Список пользователей `server_users` (бывш. «имя нового пользователя sudo») — см. актуальную секцию выше
    - Проверить версии устанавливаемых компонентов
    - Проверить пароль Ansible Vault хранилища
    - Удостовериться что все пароли продублированы и надёжно сохранены как минимум еще в 2-х местах
2) Зашифровать новые пароли для сервера в Ansible Vault
3) Сгенерировать ключи на localhost
4) Добавить ECDSA-записи удалённого хоста в known_hosts
5) Обновить Ubuntu
6) Базовая настройка ОС:
    - Временная зона
    - Региональные настройки (locale)
    - hostname
    - swap
    - systemd limits
7) Настройка доступа
    - Настройка доступа для root
    - Добавление пользователя sudo
    - Настройка доступа SSH о ключам
    - Настройка SSH (client alive)
    - Настройка SSH логирования в journald
    - Тестирование SSH доступа по ключам для root и для созданного пользователя
8) Настройка веб-сервера
    - nginx
    - php
    - mysql
    - redis
    - копирование файлов??????
    - Настройка очередей через redis и systemd
9) Настройки безопасности
    - ufw
    - file2ban
    - AppArmor
10) Очистка ОС
11) Тестирование

## Ansible Playbook

### Установка Ansible

```bash
make init-ansible
```

Проверка синтаксиса: Перед запуском playbook убедитесь, что синтаксис корректен:

```bash
make syntax-check
```

Тестирование: Запустите playbook с флагом --check для сухого прогона:

```bash
ansible-playbook -i inventory/hosts.yml playbook.yml --check
```
