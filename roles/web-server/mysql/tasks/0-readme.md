## Общий план

1) Установка сервера баз данных
   - Устанавливаем сервер
   - Удостоверяемся в том что он запущен
2) Применение правил безопасности
   По сути, mysql_secure_installation делает следующее:
   - Удаляет тестовую базу данных
      - Устанавливает пароль root пользователя
      - Удаляет анонимных пользователей
      - Убирает возможность удалённого доступа для пользователя root
3) Создание рабочей базы данных и пользователя с выданными на неё правами
   - Создаем базу данных из под root
   - Создаем пользователя и выдаем ему привилегии из под root

## `/root/.my.cnf`

NB: Файл `/root/.my.cnf` используется MySQL (или его форками, такими как MariaDB) для хранения конфигурационных настроек
клиента MySQL. Этот файл обычно содержит учетные данные и параметры подключения к базе данных, такие как имя
пользователя, пароль и хост, чтобы упростить доступ к MySQL без необходимости каждый раз вводить их вручную.
Основное назначение:

- Автоматизация аутентификации: В файле можно указать логин и пароль для подключения к MySQL, чтобы команды, такие как
  mysql или mysqldump, не запрашивали их повторно.
- Настройки клиента: Можно задать параметры, такие как порт, хост, протокол или другие опции для MySQL-клиента.

## Мой изначальный файл:

```yaml
---
##########################################################
#
# Мой изначальный файл, писал сам, с пояснениями и ссылками.
# Здесь не везде вижу логику, поэтому запросил у Грока второй файл,
# который на данный момент и используется.
# В общем, можно оставить этот файл как подсказку того что вообще
# изначально планировалось делать для настройки защиты.
#
##########################################################

# https://stackoverflow.com/a/25140114/5031893
# Этот пакет необходим для работы Ansible-модулей `mysql_user` и `mysql_db`
# Эти модули взаимодействуют с MySQL через Python, и для этого требуется библиотека MySQLdb
# (или её Python 3-версия python3-mysqldb на Debian/Ubuntu).
-  name: Adds Python MySQL support on Debian/Ubuntu
   apt:
      name: "python3-mysqldb"
      state: present
   when: ansible_os_family == 'Debian'

# https://stackoverflow.com/a/50563846/5031893
# MariaDB: Set up secure root password
# Set up (and save) secure root password
# Check for /root/.my.cnf
# All the other things are skipped if this file already exists
-  name: "Check if we already have a root password config"
   stat:
      path: /root/.my.cnf
   register: root_pass_status # Показывает статус существование файла с паролем root

# Generate password
# This uses https://docs.ansible.com/ansible/latest/plugins/lookup/password.html
# to generate a 32 character random alphanumeric password
-  name: "Generate database root password if needed"
   #  no_log: yes # TODO после отладки раскомментировать
   set_fact:
      mysql_root_password: "{{ lookup('password','/dev/null chars=ascii_letters,digits,punctuation length=32') }}"
   when: root_pass_status.stat.exists == False  # Только если ещё не сгенерирован файл с паролем root

# Generate /root/.my.cnf.new
# A temporary file is used to keep it from breaking further commands
# It also ensures that the password is on the server if the critical
# parts are interrupted
# Временный файл используется для предотвращения прерывания дальнейших команд.
# Он также гарантирует, что пароль останется на сервере, если критические шаги будут прерваны.
-  name: "Save new root password in temporary file"
   #  no_log: yes # TODO после отладки раскомментировать
   template:
      src: my_passwd.cnf.j2
      dest: /root/.my.cnf.new
      owner: root
      group: root
      mode: 0644 # Лучше 600
   when: root_pass_status.stat.exists == False  # Только если ещё не сгенерирован файл с паролем root
   loop: # Грок изменил `with_items` на `loop` (Ansible 2.5+).
      -  user: root
         password: "{{ mysql_root_password }}"

# START of area that you don't want to interrupt - !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
# If this is interrupted after the first task
# it can be fixed by manually running this on the server
# mv /root/.my.cnf.new /root/.my.cnf
# If the playbook is rerun before that. The password would be lost!
# Add DB user
-  name: "Add database root user"
   #  no_log: yes # TODO после отладки раскомментировать
   mysql_user:
      name: root
      password: "{{ mysql_root_password }}"
      host: "{{ item }}"
      check_implicit_admin: yes # Проверка доступа рута без пароля перед попыткой применить переданные логин и пароль
      priv: "*.*:ALL,GRANT"
      state: present
   when: root_pass_status.stat.exists == False  # Только если ещё не сгенерирован файл с паролем root
   loop: # Грок изменил `with_items` на `loop` (Ansible 2.5+).
      - localhost

# Now move the config in place
-  name: "Rename config with root password to correct name - Step 1 - link"
   file:
      state: hard
      src: /root/.my.cnf.new
      dest: /root/.my.cnf
      force: yes
   when: root_pass_status.stat.exists == False  # Только если ещё не сгенерирован файл с паролем root
# END of area that you don't want to interrupt - !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

# Interrupting before this task will leave a temporary file around
# Everything will work as it should though
-  name: "Rename config with root password to correct name - Step 2 - unlink"
   file:
      state: absent
      path: /root/.my.cnf.new
   when: root_pass_status.stat.exists == False  # Только если ещё не сгенерирован файл с паролем root

-  name: Removes the MySQL test database
   mysql_db:
      name: test
      state: absent

-  name: Removes all anonymous user accounts
   mysql_user:
      name: ''
      host_all: yes
      state: absent
#    check_implicit_admin: yes # Проверка доступа рута без пароля перед попыткой применить переданные логин и пароль

# Remove additional root users - these don't have the password set
# You might want to ensure that none of these variables are `localhost`
# All return somewhat different values on my test system

#- name: "Clean up additional root users" TODO надо не удалять юзеров, а задать им пароль
#  mysql_user:
#    name: root
#    host: "{{ item }}"
#    check_implicit_admin: yes # Проверка доступа рута без пароля перед попыткой применить переданные логин и пароль
#    state: absent
#  with_items:
#    - "::1"
#    - 127.0.0.1
#    - "{{ ansible_fqdn }}"
#    - "{{ inventory_hostname }}"
#    - "{{ ansible_hostname }}"

# Писал Грок. Вместо удаления юзеров, задаём им пароль.
-  name: "Set password for additional root users"
   no_log: yes
   mysql_user:
      name: root
      password: "{{ mysql_root_password }}"
      host: "{{ item }}"
      check_implicit_admin: yes
      priv: "*.*:ALL,GRANT"
      state: present
   with_items:
      - "::1"
      - 127.0.0.1
      - "{{ ansible_fqdn }}"
      - "{{ inventory_hostname }}"
      - "{{ ansible_hostname }}"
   when: root_pass_status.stat.exists == False  # Только если ещё не сгенерирован файл с паролем root

```

## Вариант mysql_secure_installation

```yaml
-  name: Защита MySQL (установка root-пароля и удаление тестовых баз)
   command: mysql_secure_installation --use-default
   args:
      stdin: |
         n  # Валидация пароля
         {{ mysql_root_password }}
         {{ mysql_root_password }}
         y  # Удалить анонимных пользователей
         y  # Запретить root-login remotely
         y  # Удалить test DB
         y  # Перезагрузить привилегии
```
