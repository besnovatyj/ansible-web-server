### Общая последовательность работы с удалённым сервером

Ansible имеет проблемы с запуском команд при аутентификации по ключу с passphrase
Как вариант, настроить аутентификацию по ключу, но вначале без passphrase
А после полной настройки сервера можно переделать на аутентификацию по ключу с passphrase

1) Настройка доступа по ключу без passphrase
2) Настройка Веб-сервера
3) Проверка настроек веб-сервера
4) Настройка доступа по ключу через passphrase

> ⚠️ ЗАМЕЧАНИЕ: В Ansible 2.18+ есть `ansible_ssh_private_key_passphrase` / расширения community.crypto
> Можно повторить мучения, может получиться перевести всю работу Ansible на SSH keys with passphrase.
> Да ещё и не от root, а от sudo юзера.

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























