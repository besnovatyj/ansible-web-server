# Анализ и план реструктуризации Ansible-проекта

> Дата анализа: 2026-05-15
> Проект: LEMP-стек (Nginx, PHP 8.4, MySQL, Redis, Memcached) на Ubuntu 24.04 LTS, 2 GB RAM

## Условные обозначения в этом документе

- `> ⚠️ ЗАМЕЧАНИЕ:` — замечания и уточнения от пользователя (besnovatyj).
- `> 📝 ОТВЕТ AI:` — ответы AI на замечания пользователя, появились при повторном анализе 2026-05-15.
- `> ❌ ИСПРАВЛЕНИЕ AI:` — место, где AI признаёт ошибку в исходном анализе.

---

# Разбор проблемы SSH-доступа и пользователей (2026-05-15)

> Цель пользователя: в конфиге задаётся **только адрес сервера и пароль root**, дальше
> всё делают плейбуки — генерация ключей, доставка, создание пользователей, переход
> на вход только по ключам. Несколько пользователей — структурой, похожей на работу
> с доменами (декларативный список).

## 1. Диагноз: где сейчас рвётся автоматизм

Текущая реализация почти рабочая, но «бесшовного» прохода нет из-за трёх дыр:

### 1.1. Нет плейбука первичной доставки ключей (chicken-and-egg)

- `stage-0` генерирует ключи локально.
- `stage-2` сразу подключается `remote_user: root` и **ожидает, что ключ уже на сервере**
  (роли `ssh_remote_*` работают через уже установленное соединение).
- На свежем сервере ключа ещё нет → первое подключение возможно **только по паролю root**,
  но отдельного шага «зайти по паролю и положить ключи» в пайплайне нет.
- `inventory/hosts.yml` тянет и ключ, и пароль одновременно
  (`ansible_ssh_private_key_file` + `ansible_password`). Это неустойчивое поведение:
  Ansible не делает чистый fallback «ключ → пароль» так, как ожидается, особенно при
  `host key checking` и при уже отключённом позже пароле.

### 1.2. `vault_root_password` — «мёртвая, но нужная» переменная

- В `vault.yml:23` переменная есть, но рядом и в `secrets.yml` пометки «больше не
  используется».
- В то же время именно она — **единственный** способ автоматизировать первичную
  доставку ключей. Её надо «воскресить» и сделать опорной для bootstrap-этапа,
  а pre-flight assert на неё — оставить (он сейчас «завязан на мёртвую переменную»
  именно потому, что переменную преждевременно похоронили).

### 1.3. Один пользователь скаляром, нет структуры под несколько

- `ssh.yml:38` — `new_user: "bes"` это один скаляр.
- Роли `user_sudo_add_new`, `ssh_remote_user_keys`, `verify_ssh` жёстко завязаны на
  одного `new_user`. Под «много пользователей как домены» нужен декларативный список
  и цикл по нему.

## 2. Ключевое архитектурное решение (снимает боль с passphrase)

В `000.md` ты сам пришёл к зрелой модели. Свожу её к практическому правилу, которое
**полностью убирает мучения Ansible + passphrase**:

| Роль пользователя       | UNIX-пароль                                     | SSH passphrase у ключа      | Кто пользуется ключом                                  | sudo      |
|-------------------------|-------------------------------------------------|-----------------------------|--------------------------------------------------------|-----------|
| `root`                  | заблокирован для SSH (`prohibit-password`/`no`) | passphrase, лежит в KeePass | человек, только аварийно (консоль провайдера/recovery) | n/a       |
| `ansible` (automation)  | `!` (locked)                                    | **БЕЗ passphrase**          | только Ansible                                         | NOPASSWD  |
| `bes`, `ops`, … (human) | пароль есть (console/recovery)                  | **С passphrase**            | человек руками (Kitty/WinSCP/HeidiSQL)                 | с паролем |

Главная мысль: **Ansible всегда ходит ключом automation-пользователя без passphrase.**
Человеческие ключи с passphrase используются только руками и Ansible их в глаза не видит.

Следствия:

- Проблема «Ansible не умеет в passphrase» исчезает в принципе, а не обходится.
- **Stage 7 (миграция на passphrase) удаляется** (решение 2026-05-15, см. §11).
  Безопасность обеспечивается тем, что приватный ключ `ansible` хранится только в
  зашифрованном KeePass, а на сервере он `password-locked` + ограничен `restrict`
  (см. §7). Это и есть твой «приемлемый уровень при зашифрованном KeePass» из плана.
- Двухфазный подход «Фаза A без passphrase → Фаза B с passphrase» из `000-PLAN.MD`
  заменяется на «один ключ automation без passphrase навсегда + отдельные human-ключи
  с passphrase сразу с passphrase, т.к. их Ansible не трогает».

## 3. «Доменоподобная» структура пользователей

Объявляем пользователей декларативным списком в
`inventory/group_vars/all/ssh.yml` — по аналогии с тем, как ты держишь домены/сайты:

```yaml
# --- кто подключается Ansible-ом (ровно один, type: automation) ---
ssh_automation_user: ansible

# --- декларативный список всех аккаунтов на сервере ---
server_users:
    -   name: ansible
        type: automation          # ключ без passphrase, password locked, sudo NOPASSWD
        sudo: nopasswd
        groups: [ sudo ]

    -   name: bes
        type: human               # ключ с passphrase, пароль в /etc/shadow, sudo с паролем
        sudo: password
        groups: [ sudo ]
        unix_password_vault_key: vault_user_bes_password
        key_passphrase_vault_key: vault_user_bes_passphrase

    # добавление нового человека = +1 блок здесь, как +1 домен
    # - name: ops
    #   type: human
    #   sudo: password
    #   groups: [sudo]
    #   unix_password_vault_key: vault_user_ops_password
    #   key_passphrase_vault_key: vault_user_ops_passphrase
```

Производные пути ключей (генерируются из имени, как домены из `domain_name`):

```yaml
# для каждого u в server_users:
#   приватный:  {{ local_ssh_keys_dir }}/key_{{ domain_name }}_{{ u.name }}
#   публичный:  ...pub
# emergency root остаётся отдельным: key_{{ domain_name }}_emergency_root
```

Все роли переписываются с одиночного `new_user` на `loop: "{{ server_users }}"`.
`verify_ssh` тоже гоняется циклом по списку (по нужному ключу для каждого).

> Решение 2026-05-15: **переменную `new_user` выпиливаем сразу**, алиас не держим.
> Все роли, которые её использовали (`user_sudo_add_new` → новая `users_provision`,
> `ssh_remote_user_keys` → `ssh_push_keys`, `verify_ssh`, а также `web-server/*` и
> `data_transfer`), переводятся на `server_users[]` / `ssh_automation_user` в рамках
> этого же рефакторинга. Места, где раньше брался «тот самый sudo-юзер» (деплой кода,
> владелец `web_root`, SSH-профиль HeidiSQL/WinSCP), теперь явно указывают нужного
> человека: `deploy_user: bes` (или вычисляют первого `type: human` из списка).

## 4. Целевой пайплайн (что задаёт пользователь и что делают плейбуки)

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

## 5. Реализация bootstrap-плейбука (узловой момент)

### 5.1. Изоляция парольного подключения

`hosts.yml` НЕ должен одновременно держать ключ и пароль. Делаем так: соединение
по умолчанию — ключ automation-пользователя; парольное подключение root
описываем **только внутри bootstrap-плейбука** через `vars:` на уровне play,
а не в инвентаре:

```yaml
# playbooks/stage-1b-bootstrap-keys.yml
-   name: Pre-flight (localhost)
    hosts: localhost
    gather_facts: false
    tasks:
        -   assert:
                that:
                    - vault_root_password is defined
                    - vault_root_password | length > 0
                fail_msg: "vault_root_password не задан — bootstrap по паролю невозможен"

-   name: Bootstrap users & keys over root password
    hosts: site
    gather_facts: false
    vars:
        ansible_user: root
        ansible_ssh_pass: "{{ vault_root_password }}"
        ansible_ssh_private_key_file: ""        # явно НЕ ключ
        ansible_ssh_common_args: >-
            -o PreferredAuthentications=password
            -o PubkeyAuthentication=no
            -o StrictHostKeyChecking=accept-new
    roles:
        - ../roles/system/users_provision   # loop по server_users: user + sudo + pass
        - ../roles/system/ssh_push_keys     # loop: public key каждому + emergency root
```

`inventory/hosts.yml` упрощается до connection-профиля automation-пользователя:

```yaml
server:
    ansible_host: 000.000.000.000
    ansible_port: "{{ target_ssh_port }}"
    ansible_user: "{{ ssh_automation_user }}"
    ansible_ssh_private_key_file: "{{ local_ssh_keys_dir }}/key_{{ domain_name }}_{{ ssh_automation_user }}"
    # пароль здесь больше НЕ светим
```

Требуется `sshpass` на контроллере (для парольного bootstrap). Это документировать
в `TODO/Readme.md` как зависимость стадии.

### 5.2. Идемпотентность / повторный прогон

Bootstrap должен переживать повторный запуск, когда пароль уже отключён. Решение —
авто-детект режима подключения отдельным play на старте:

```yaml
-   name: Detect connectivity mode
    hosts: site
    gather_facts: false
    tasks:
        -   name: Probe key-based login as automation user
            delegate_to: localhost
            command: >
                ssh -i {{ local_ssh_keys_dir }}/key_{{ domain_name }}_{{ ssh_automation_user }}
                    -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new
                    -p {{ target_ssh_port }} {{ ssh_automation_user }}@{{ ansible_host }} true
            register: key_probe
            failed_when: false
            changed_when: false
        -   set_fact:
                bootstrap_needed: "{{ key_probe.rc != 0 }}"
```

И весь парольный play оборачиваем в `when: hostvars[...].bootstrap_needed`.
Тогда `make` цель «всё с нуля» и повторный прогон на уже настроенном сервере ведут
себя одинаково корректно (на настроенном — bootstrap просто пропускается).

### 5.3. Аккуратность с UNIX-паролями

В `users_provision`:

- `type: automation` → `password: '!'` (как сейчас в `user_sudo_add_new`).
- `type: human` → `password: "{{ vault[ u.unix_password_vault_key ] | password_hash('sha512') }}"`,
  `update_password: on_create` (чтобы повторный прогон не перетирал смену пароля,
  сделанную руками на сервере).
- sudo: для `nopasswd` — drop-in `/etc/sudoers.d/{{ u.name }}` с
  `validate: 'visudo -cf %s'`; для `password` — просто членство в `sudo`/`wheel`,
  без NOPASSWD-строки.

## 6. Кого слушать: root-connection vs automation-user connection

В `000-PLAN.MD` (стр. 24-25) зафиксировано «все remote-плейбуки ходят как root».
В `000.md` — более зрелая модель с отдельным `ansible`-пользователем. Решение:
**automation-user** (`become: true`, sudo NOPASSWD):

- Меньше площадь атаки: рутинно под root по сети никто не ходит.
- Ansible-роли получают `become: true` один раз на уровне play — правок ролей минимум.
- **root по сети остаётся `PermitRootLogin prohibit-password`** (решение 2026-05-15):
  emergency-ключ root имеет passphrase, поэтому сетевой вход по нему уже защищён
  двумя факторами (файл ключа + passphrase), и `prohibit-password` даёт рабочий
  сетевой recovery-путь, если консоль провайдера недоступна. До `no` НЕ добиваем.

Это правка плана: пункт «remote-плейбуки как root» заменить на «stage-1b как root по
паролю (bootstrap) → stage-2+ как `ansible` с become». root-ключ остаётся как emergency
(sshd/`authorized_keys` сломан): доступен и через консоль провайдера, и по сети по
passphrase-ключу, но **не по паролю**.

## 7. Дополнительное усиление automation-ключа (без passphrase, но безопасно)

Раз automation-ключ без passphrase, компенсируем ограничением в `authorized_keys`.
**Решение 2026-05-15: контроллер всегда с динамическим IP**, поэтому `from="IP"`
неприменим. Используем `restrict` (отключает forwarding/pty/X11 разом) + явный
комментарий-владелец:

```
restrict ssh-ed25519 AAAA... ansible@controller-dynamic-ip
```

`restrict` снимает agent/X11/port-forwarding и pty — automation-сессии это не нужно,
а площадь злоупотребления украденным ключом сужается. Дополнительные рубежи при
динамическом IP: fail2ban[sshd], нестандартный SSH-порт (план, стр. 83) и хранение
приватного ключа только в зашифрованном KeePass. Для homelab/small infra — приемлемо.

## 8. Конкретный список правок (чек-лист реализации)

1. `secrets.yml` / `vault.yml`: снять пометки «не используется» с `vault_root_password`;
   добавить `vault_user_<name>_password` / `vault_user_<name>_passphrase` на human-юзеров.
2. `ssh.yml`: ввести `ssh_automation_user`, `server_users[]`; вывести пути ключей
   из имени пользователя. **`new_user` удалить полностью** (без алиаса).
3. `ssh_generate_local_keys`: цикл по `server_users` + emergency root; passphrase
   брать из `u.key_passphrase_vault_key` (automation → пустой, human/root → из vault).
4. Новые роли: `users_provision` (user+sudo+pass, loop), `ssh_push_keys` (loop).
5. Новый плейбук `stage-1b-bootstrap-keys.yml` (детект режима + парольный bootstrap).
6. `stage-2`/`stage-3`: `remote_user: "{{ ssh_automation_user }}"`, `become: true`;
   `verify_ssh` — циклом по `server_users`.
7. `ssh_remote_security`: `PermitRootLogin` оставить `prohibit-password` (НЕ `no`);
   automation-ключ в `authorized_keys` — с префиксом `restrict`. Коммент-обоснование
   пользователя сохранить.
8. `hosts.yml`: убрать `ansible_password`, оставить connection-профиль automation.
9. Перевести на `server_users`/`ssh_automation_user` зависящие роли:
   `web-server/data_transfer`, владелец `web_root`, deploy-пути (`deploy_user`),
   SSH-профиль HeidiSQL/WinSCP/Kitty — всё в этом же заходе, синхронно с п.2.
10. `Makefile`-цель `provision`: stage-0 → stage-1 → stage-1b → stage-2 → stage-3 → 4…
11. `TODO/Readme.md`: зависимость `sshpass`; процедура выгрузки ВСЕХ приватных
    ключей (automation без passphrase, human с passphrase, emergency root) в KeePass.
12. **Stage 7 удалить** из `000-PLAN.MD` и из списка плейбуков (`stage-7-key-hardening.yml`),
    включая фазы L/L1/L2 — больше не нужен (см. §11).

## 9. Что это даёт по твоему критерию «максимальный автоматизм»

- Пользователь редактирует 1 строку IP + N паролей в vault → одна `make`-цель.
- Passphrase-боль с Ansible устранена архитектурно (Ansible не трогает passphrase-ключи).
- Новый человек = +1 блок в `server_users` (как +1 домен) + его пароль/passphrase в vault.
- Повторный прогон безопасен (авто-детект уже-по-ключу).
- Stage 7 удалён; финальная модель безопасности = модель из `000.md`.

## 10. Решения по открытым вопросам (зафиксировано 2026-05-15)

1. **root по сети** → `PermitRootLogin prohibit-password`. root-ключ с passphrase,
   сетевой emergency-вход по ключу остаётся, по паролю — нет. До `no` не добиваем.
2. **Контроллер IP** → всегда динамический. `from="IP"` не используем; вместо него
   `restrict` в `authorized_keys` automation-ключа + fail2ban + нестандартный порт.
3. **sudo для human** → с паролем (`sudo` спрашивает пароль). NOPASSWD только у
   automation. Это «лучший баланс» из `000.md`.
4. **Stage 7** → удаляем совсем (плейбук + фазы L/L1/L2 из `000-PLAN.MD`). Обоснование
   в §11.
5. **`new_user`** → выпиливаем сразу, без переходного алиаса; зависящие роли
   (web-server/data_transfer/deploy) переводим на `server_users` синхронно (чек-лист п.9).

## 11. Может ли Ansible сам открывать passphrase-ключ (вопрос по `000-PLAN.MD`)

В плане (стр. 18, 21-22) было замечание: *«В Ansible 2.18+ есть
`ansible_ssh_private_key_passphrase` / расширения community.crypto»*. Разбираю по
фактам из официальной документации (проверено 2026-05-15):

### Что есть на самом деле

- **`community.crypto` тут ни при чём.** Параметр `passphrase` у
  `community.crypto.openssh_keypair` — это passphrase для **генерации/управления**
  ключом локально (мы его и так используем в `ssh_generate_local_keys`). К
  *подключению* Ansible по защищённому ключу он отношения не имеет. Это
  распространённое заблуждение, зафиксированное в плане.
- **Версия не 2.18, а ansible-core 2.19.** Именно в 2.19 у дефолтного
  connection-плагина `ansible.builtin.ssh` появились:
    - `private_key` — содержимое приватного ключа (PEM) прямо в переменной;
    - `private_key_passphrase` — passphrase к нему;
    - `password_mechanism` — `ssh_askpass` / `sshpass` / `disable`.
- **Критичное ограничение:** `private_key_passphrase` работает **только вместе с
  `private_key`** (PEM в переменной, загружается через управляемый Ansible
  `ssh-agent`, требует включённого `SSH_AGENT`). С `private_key_file` (путь к файлу
  — то, что у нас) **`private_key_passphrase` не действует вообще**. Цитата из
  доков: *«This does NOT have any effect when used with private_key_file»*.
- Старый обходной путь — connection-плагин `paramiko`: его `password`
  (`ansible_password`) paramiko умеет использовать как passphrase к зашифрованному
  ключу, т.к. читает ключ внутри процесса. Минус: paramiko вместо системного ssh.

### Ответ на твой вопрос

Да, технически современный Ansible (core **2.19+**) *может* ходить
passphrase-ключом automation-юзера — но не «задать passphrase к файлу ключа», а
только так: положить **сам ключ (PEM)** в vault-переменную `private_key` и
passphrase в `private_key_passphrase`, с включённым `SSH_AGENT`. Либо перейти на
paramiko и передавать passphrase как `ansible_password`.

### Почему это всё равно НЕ меняет архитектуру (и почему Stage 7 удаляем)

Это **не повышает безопасность** относительно нашей схемы:

- Чтобы Ansible работал неинтерактивно, passphrase обязан лежать в vault **рядом**
  с ключом (или сам ключ — в vault). Граница безопасности ровно одна и та же:
  **расшифрованный vault/KeePass**. Кто пробил эту границу — получает и ключ, и
  passphrase. Passphrase поверх vault-ключа = второй замок на той же двери с тем же
  ключом под ковриком.
- Зависимость от ansible-core ≥ 2.19 (у тебя Ansible в Docker — версию надо
  проверить: `docker compose exec <ansible-сервис> ansible --version`), плюс
  обязательный `SSH_AGENT`/PEM-в-переменной — больше движущихся частей и хрупкости
  ради нулевого выигрыша.
- Поэтому: **automation-ключ остаётся без passphrase навсегда**, защита =
  зашифрованный KeePass + `restrict` + locked-пароль юзера + fail2ban. Боль
  «Ansible и passphrase» снимается тем, что Ansible вообще не касается
  passphrase-ключей (они только у людей, для рук). **Stage 7 не нужен — удаляем**
  (чек-лист п.12). Если когда-нибудь захочется hardware-ключи (YubiKey/FIDO2 из
  `000.md`) — это отдельная история и касается только human-ключей, не automation.
- Источники: ansible.builtin.ssh connection plugin
  (https://docs.ansible.com/projects/ansible/latest/collections/ansible/builtin/ssh_connection.html), 
  Connection methods and details
  (https://docs.ansible.com/projects/ansible/latest/inventory_guide/connection_details.html),
  community.crypto.openssh_keypair
  (https://docs.ansible.com/projects/ansible/latest/collections/community/crypto/openssh_keypair_module.html).
