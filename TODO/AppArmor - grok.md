Да, конечно, возможно написать Ansible playbook для настройки AppArmor поверх уже установленного стека (Nginx, PHP-FPM,
MySQL и Redis). AppArmor обычно предустановлен в дистрибутивах вроде Ubuntu, но для полноценной работы потребуется
установить утилиты (apparmor-utils) и дополнительные профили (apparmor-profiles), создать или настроить профили для
каждого сервиса, а затем перевести их в режим enforce для принудительного применения правил. Это добавит слой
безопасности, ограничив доступ сервисов к файлам, процессам и ресурсам.

Поскольку сервер имеет ограниченную память (2 ГБ), настройка AppArmor не должна существенно повлиять на
производительность, так как она работает на уровне ядра без значительного overhead. Однако тестируйте в complain-режиме
сначала, чтобы избежать блокировок легитимных операций.

Ниже приведен пример playbook, основанный на стандартных практиках для Ubuntu 20.04/22.04. Он предполагает, что сервисы
уже установлены (как в вашем существующем playbook). Playbook:

- Устанавливает необходимые пакеты AppArmor.
- Создает/настраивает профили с помощью шаблонов (Jinja2) для Nginx, PHP-FPM, MySQL и Redis.
- Переводит профили в enforce-режим.
- Перезагружает AppArmor.

Для профилей я использовал базовые примеры из документации и руководств: для Nginx — из DigitalOcean, для MySQL — из
Severalnines, для PHP-FPM — из специализированных руководств, для Redis — адаптированный стандартный профиль (поскольку
готового нет, он ограничивает доступ к /var/lib/redis/ и конфигурации). Вы можете доработать профили под свои нужды,
используя aa-logprof для генерации на основе логов.

### Пример Ansible Playbook (apparmor-setup.yml)

```yaml
---
-   name: Configure AppArmor for Nginx, PHP-FPM, MySQL, and Redis
    hosts: all
    become: true
    vars:
        php_version: "7.4"  # Укажите вашу версию PHP

    tasks:
        -   name: Install AppArmor packages
            apt:
                name: "{{ item }}"
                state: present
            loop:
                - apparmor
                - apparmor-utils
                - apparmor-profiles

        # Профиль для Nginx
        -   name: Create AppArmor profile for Nginx
            template:
                src: templates/usr.sbin.nginx.j2
                dest: /etc/apparmor.d/usr.sbin.nginx
                mode: '0644'
            notify: Reload AppArmor

        -   name: Enforce Nginx profile
            command: aa-enforce /etc/apparmor.d/usr.sbin.nginx
            ignore_errors: true  # Если уже в enforce, игнорировать
            notify: Reload AppArmor

        # Профиль для PHP-FPM (основной процесс)
        -   name: Create AppArmor profile for PHP-FPM
            template:
                src: templates/usr.sbin.php-fpm.j2
                dest: /etc/apparmor.d/usr.sbin.php-fpm{{ php_version }}
                mode: '0644'
            notify: Reload AppArmor

        -   name: Enforce PHP-FPM profile
            command: aa-enforce /etc/apparmor.d/usr.sbin.php-fpm{{ php_version }}
            ignore_errors: true
            notify: Reload AppArmor

        # Профиль для MySQL
        -   name: Create AppArmor profile for MySQL
            template:
                src: templates/usr.sbin.mysqld.j2
                dest: /etc/apparmor.d/usr.sbin.mysqld
                mode: '0644'
            notify: Reload AppArmor

        -   name: Enforce MySQL profile
            command: aa-enforce /etc/apparmor.d/usr.sbin.mysqld
            ignore_errors: true
            notify: Reload AppArmor

        # Профиль для Redis
        -   name: Create AppArmor profile for Redis
            template:
                src: templates/usr.bin.redis-server.j2
                dest: /etc/apparmor.d/usr.bin.redis-server
                mode: '0644'
            notify: Reload AppArmor

        -   name: Enforce Redis profile
            command: aa-enforce /etc/apparmor.d/usr.bin.redis-server
            ignore_errors: true
            notify: Reload AppArmor

    handlers:
        -   name: Reload AppArmor
            service:
                name: apparmor
                state: reloaded
```

### Шаблоны (Jinja2) для профилей

Создайте папку `templates/` и добавьте эти файлы. Это базовые профили; настройте пути под вашу конфигурацию (например,
если data-dir MySQL не /var/lib/mysql/).

1. **templates/usr.sbin.nginx.j2** (для Nginx, адаптировано из ):
   ```
   #include <tunables/global>
   
   /usr/sbin/nginx {
     #include <abstractions/base>
     #include <abstractions/nameservice>
   
     capability net_bind_service,
     capability dac_override,
     capability setgid,
     capability setuid,
   
     /etc/nginx/** r,
     /var/www/** r,
     /var/log/nginx/** rw,
     /run/nginx.pid rw,
     /usr/sbin/nginx ix,
     deny /etc/passwd r,  # Пример ограничения
   }
   ```

2. **templates/usr.sbin.php-fpm.j2** (для PHP-FPM, адаптировано из ):
   ```
   #include <tunables/global>
   
   /usr/sbin/php-fpm{{ php_version }} {
     #include <abstractions/base>
     #include <abstractions/php>
   
     capability dac_override,
     capability sys_resource,
   
     /etc/php/{{ php_version }}/fpm/** r,
     /var/www/** rwk,  # Доступ к веб-файлам
     /run/php/php{{ php_version }}-fpm.sock rw,
     /usr/sbin/php-fpm{{ php_version }} ix,
     deny /etc/shadow r,  # Ограничение чувствительных файлов
   }
   ```

3. **templates/usr.sbin.mysqld.j2** (для MySQL, адаптировано из ):
   ```
   #include <tunables/global>
   
   /usr/sbin/mysqld {
     #include <abstractions/base>
     #include <abstractions/mysql>
   
     capability sys_resource,
     capability dac_override,
   
     /etc/mysql/** r,
     /var/lib/mysql/** rwk,
     /var/log/mysql/** rw,
     /run/mysqld/mysqld.sock rw,
     /usr/sbin/mysqld ix,
     deny /home/** r,  # Ограничение доступа
   }
   ```

4. **templates/usr.bin.redis-server.j2** (для Redis, базовый кастомный):
   ```
   #include <tunables/global>
   
   /usr/bin/redis-server {
     #include <abstractions/base>
   
     capability net_bind_service,
     capability dac_override,
   
     /etc/redis/redis.conf r,
     /var/lib/redis/** rwk,
     /var/log/redis/** rw,
     /run/redis/redis.sock rw,
     /usr/bin/redis-server ix,
     deny /etc/passwd r,
   }
   ```

### Рекомендации по использованию

1. **Тестирование**: Сначала переведите профили в complain-режим (`aa-complain /path/to/profile`) и мониторьте логи (
   `dmesg | grep apparmor` или `/var/log/syslog`). Используйте `aa-logprof` для автоматической генерации правил на
   основе логов. Затем переключайтесь на enforce.

2. **Запуск**: Используйте тот же inventory, что и для вашего основного playbook:
   ```
   ansible-playbook -i inventory.yml apparmor-setup.yml
   ```

3. **Дополнительная оптимизация**: Если профили блокируют операции, добавьте разрешения (например, для репликации
   MySQL — доступ к дополнительным директориям). Для PHP-FPM учтите, что профиль может быть общим для пула или отдельным
   для каждого сайта.

4. **Проверка**: После применения проверьте статус: `sudo aa-status`. Сервисы должны быть в enforce-режиме.

Если нужны более сложные профили (например, для многосайтовых конфигураций) или интеграция с вашим существующим
playbook, дайте дополнительные детали — я доработаю.
