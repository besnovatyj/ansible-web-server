
### 4. MySQL: Нет шифрования (SSL) в шаблоне — добавьте для prod. Ведь у меня MySQL только на локалхосте, зачем ssl?

В вашем шаблоне `mysqld.cnf.j2` нет настроек для SSL (например, `ssl-ca`, `ssl-cert`, `ssl-key`). SSL в MySQL шифрует трафик между клиентом (PHP) и сервером, даже на localhost.

**Зачем SSL на localhost?**
- **Безопасность**: Даже локально трафик может быть перехвачен (например, через compromised процессы или kernel-эксплойты). SSL защищает пароли, данные от sniffing (tools вроде tcpdump). В prod (особенно с sensitive data) это стандарт (GDPR/HIPAA compliance).
- **Лучшие практики**: MySQL 8+ рекомендует SSL по умолчанию. Без него логины/данные в plaintext — риск, если сервер взломан.
- **Низкий overhead**: На 2 ГБ RAM SSL добавляет ~5-10% CPU, но для локального трафика (127.0.0.1) это минимально. Если только local, overhead близок к нулю.

**Но если только localhost, то не обязательно**: Если сервер изолирован (нет remote доступа к MySQL, bind-address=127.0.0.1), риски низкие. SSL полезен для паранойи или compliance. Если не нужно — оставьте как есть.

**Как добавить в шаблон** (в `roles/mysql/templates/mysqld.cnf.j2`):
```ini
[mysqld]
ssl-ca=/etc/mysql/ssl/ca.pem
ssl-cert=/etc/mysql/ssl/server-cert.pem
ssl-key=/etc/mysql/ssl/server-key.pem
require_secure_transport=ON  # Требовать SSL для всех подключений
```
- Генерация ключей: В роли mysql добавьте задачи для openssl (self-signed для prod OK, или используйте Certbot/Let's Encrypt).
- В PHP: В PDO/PDO_MYSQL добавьте `PDO::MYSQL_ATTR_SSL_CA` для verification.
