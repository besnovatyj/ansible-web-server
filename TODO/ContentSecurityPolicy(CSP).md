### Что такое Content Security Policy (CSP)

Content Security Policy (CSP) — это механизм безопасности веб-приложений, который помогает предотвратить атаки вроде
межсайтового скриптинга (XSS), кликджекинга и инъекций вредоносного кода. CSP работает на уровне браузера: сервер
отправляет HTTP-заголовок, в котором указывает, откуда можно загружать ресурсы (скрипты, стили, изображения, шрифты и
т.д.). Браузер строго следует этим правилам и блокирует всё, что не соответствует политике.

CSP не решает все проблемы безопасности, но значительно снижает риски. Это стандарт W3C, поддерживается всеми
современными браузерами (Chrome, Firefox, Safari, Edge).

#### Самое необходимое в CSP

CSP состоит из директив, каждая из которых контролирует тип ресурса. Основные директивы:

- default-src: "Запасная" политика для всех ресурсов, если не указана конкретная. Обычно 'self' (только с текущего
  домена).
- script-src: Откуда загружать скрипты (JavaScript). Рекомендуется 'self' + nonce или hash для inline-скриптов, чтобы
  избежать 'unsafe-inline'.
- style-src: Откуда стили (CSS). Аналогично, избегайте 'unsafe-inline', если возможно.
- img-src: Изображения. Можно 'self data: blob:' для локальных.
- font-src: Шрифты.
- connect-src: Куда можно отправлять запросы (XHR, WebSockets, fetch).
- frame-ancestors: Кто может встраивать ваш сайт в iframe (защита от кликджекинга, альтернатива X-Frame-Options).
- form-action: Куда можно отправлять формы.
- base-uri: Базовый URI для относительных ссылок.
- object-src: Объекты вроде <object> или <embed> (часто 'none', чтобы запретить плагины).

Дополнительно:

- report-uri или report-to: Куда отправлять отчёты о нарушениях (для мониторинга).
- upgrade-insecure-requests: Автоматически обновляет HTTP-ссылки до HTTPS.

Значения директив:

- 'self': Текущий домен (включая поддомены? Нет, только точный origin).
- 'none': Запретить всё.
- https:: Только по HTTPS.
- data: blob: filesystem:: Для inline-данных.
- Конкретные домены: https://example.com.
- 'unsafe-inline': Разрешить inline-скрипты/стили (небезопасно, но иногда нужно для legacy-кода).
- 'unsafe-eval': Разрешить eval() (избегайте!).
- Nonce или sha256-хэш: Для безопасного inline (например, script-src 'nonce-abc123').

CSP имеет уровни: CSP1 (базовый), CSP2 (nonce, hash), CSP3 (строгие политики).

#### Как настроить CSP в Nginx

В вашем конфиге Nginx CSP добавляется через add_header Content-Security-Policy "директивы;" в блоке server или location.
Важно: все директивы должны быть в одном заголовке! Если добавить несколько add_header с тем же именем, последующий
перезапишет предыдущий. Это, вероятно, и была ваша проблема — браузер видел только последнюю директиву (form-action '
self').

Правильный способ: объедините всё в одну строку. Пример для вашего случая (с учётом поддоменов):

```
add_header Content-Security-Policy "default-src 'self'; img-src 'self' https://files.{{ domain_name }} data:; object-src 'self' https://files.{{ domain_name }}; script-src 'self'; style-src 'self' 'unsafe-inline'; frame-ancestors 'self' https://files.{{ domain_name }} https://adm.{{ domain_name }}; base-uri 'self'; form-action 'self';";
```

- Замените ${FILES_HOST} на https://files.{{ domain_name }} (или просто files.{{ domain_name }}, но лучше с протоколом
  для точности).
- Добавьте data: в img-src, если у вас есть base64-изображения.
- Для админки (adm) и основного сайта добавьте в frame-ancestors разрешения, если нужно встраивание.
- В блоке для files (статика) CSP может быть проще, т.к. там только файлы: default-src 'none'; img-src 'self'; (или
  вообще без CSP, если это чистая статика).

После изменения перезапустите Nginx: nginx -s reload.

Для HTTPS (рекомендуется): настройте SSL и используйте listen 443 ssl;, добавьте HSTS: add_header
Strict-Transport-Security "max-age=31536000; includeSubDomains; preload";.

#### Как не сломать приложение при настройке CSP

CSP может "сломать" сайт, если политика слишком строгая: скрипты не загрузятся, стили пропадут, изображения не
покажутся. Чтобы избежать этого:

1. Начните с режима report-only: Используйте Content-Security-Policy-Report-Only вместо Content-Security-Policy. Браузер
   будет отчитываться о нарушениях, но не блокировать. Пример:
   ```
   add_header Content-Security-Policy-Report-Only "default-src 'self'; ... report-uri https://your-report-endpoint.com/csp-reports;";
   ```
    - Настройте endpoint для отчётов (например, на вашем сервере скрипт, который логирует JSON-отчёты).
    - Мониторьте консоль браузера (DevTools > Console) — там будут ошибки вроде "Refused to load the script because it
      violates the following Content Security Policy directive".

2. Тестируйте поэтапно:
    - Начните с базовой политики: только default-src 'self';.
    - Добавляйте директивы одну за одной, проверяя сайт.
    - Проверьте все страницы: фронтенд, админку, загрузку файлов.
    - Учитывайте поддомены: для кросс-доменного контента добавьте https://adm.{{ domain_name }} или https://files.{{
      domain_name }} в нужные директивы (img-src, script-src и т.д.).
    - Если у вас inline-скрипты/стили (в HTML), используйте nonce: добавьте атрибут `<script nonce="random-string">`, и
      в CSP script-src 'nonce-random-string'. Генерируйте nonce динамически в PHP.

3. Общие ловушки:
    - Inline-код: 'unsafe-inline' — временное решение, но стремитесь к nonce/hash.
    - Внешние ресурсы: Если используете Google Fonts/CDN, добавьте их домены (например, font-src 'self'
      fonts.gstatic.com;).
    - AJAX/WebSockets: Добавьте в connect-src.
    - Формы: Если формы отправляются на другой домен, укажите в form-action.
    - Magento/WordPress-like apps (судя по вашему конфигу, похоже на Magento): Эти CMS часто имеют inline-скрипты.
      Проверьте исходный код страниц.
    - Кэш: Очистите кэш браузера после изменений.
    - Поддомены: 'self' — это текущий origin (протокол + домен + порт). Для files.{{ domain_name }} нужно явно указать.

4. Инструменты для проверки:
    - Browser DevTools: Смотрите ошибки CSP.
    - Онлайн-сканеры: securityheaders.com, observatory.mozilla.org.
    - CSP Evaluator от Google: csp-evaluator.withgoogle.com.

#### Рекомендации для вашего конфига

Ваш конфиг выглядит нормально (PHP-FPM, защита от .htaccess и т.д.), но добавьте CSP в каждый server блок:

- Для основного и adm: полная политика, как выше.
- Для files: минимальная, т.к. это статика (img-src, object-src на 'self').
- Удалите дублирующиеся add_header X-Frame-Options, если используете frame-ancestors в CSP (CSP приоритетнее).
- Если сайт на HTTPS, перенаправьте HTTP на HTTPS в блоке listen 80: return 301 https://$host$request_uri;.

Если после этого что-то сломается, опишите ошибку из консоли браузера — помогу донастроить!
