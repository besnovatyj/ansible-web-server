Заходить через терминал лучше от Ansible пользователя, потому что деплоим из-под него же?

Через терминал модули устанавливаем от пользователя `www-data`:

```bash
sudo -u www-data php yii Modman/modules/install User
```

После этого требуется запустить: `sudo systemctl reload php8.4-fpm` для сброса OpCache

Запуск CMS команд от `www-data` из-за того что секреты (`roles/web-server/app_secrets`):
файлы `/etc/bescms/secrets/*` ← симлинк `/run/secrets`, права `root:www-data 0640`, каталог `0750`.
То есть читать их может только root и группа www-data.
При запуске CMS команд под юзером ansible `SecretReader::get('MYSQL_USER')` в CLI:

1. файл `/run/secrets/MYSQL_USER` — `is_readable()` = false (ansible не в группе www-data);
2. `getenv('MYSQL_USER')` — пусто (env есть только в пуле FPM, `clear_env=no`);
3. default → ''.

В итоге под ansible юзером ничего не работает, надо запускать от имени `www-data`, который имеет доступ к секретам.

-----------------------------------

Порядок после переустановки сервера прежний: `make full-deploy` (stage-4 теперь ставит и composer), затем
`make release`, потом `stage-5a` (certbot), `stage-5b` (queue) и `stage-6`. Скелет web-корней, который nginx-роль
создаст до релиза, release-роль сама уберёт перед первым клоном.

-------------------------

Следующий уровень (упоминаю, раз «без скидок»)

Канонический деплой — не `clone-in-place`, а схема `releases + symlink` (Deployer/Capistrano): каждая выкладка в
`/var/www/<domain>/releases/N`, атомарное переключение симлинка current, мгновенный откат. Требует поменять nginx-корни
на `.../current/app/...` и чуть усложнить роль. Для одного сервера и первой выкладки `clone-in-place` — полноценное
рабочее решение, а `releases/symlink` стоит заложить как целевую архитектуру, когда деплой станет регулярным.
                                                               
---

Готово. Сделал всё три части: роль `composer` в `stage-4`, отдельную `release-роль` с плейбуком `stage-5d` и make-цель
`release`. YAML всех файлов проверен, `make syntax-check` подхватит новый плейбук автоматически (глоб `stage-*.yml`).

Что создано и изменено:

- `roles/web-server/composer/tasks/main.yml` — Composer из apt (2.7 в noble; обновления подхватит unattended-upgrades,
  что ложится в вашу `fire-and-forget-политику`). Подключён в `stage-4-webserver.yml` после `php`, в
  `post-checks stage-4` добавлен `assert composer --version`.
- `roles/web-server/release/` — роль релиза:
  `git` (ставится при отсутствии)
  → `clone/pull https://github.com/besnovatyj/yii2-cms.git` в `/var/www/{{ domain_name }}`
  → `composer install --no-dev --optimize-autoloader`
  → `php init --env=Production --overwrite=n --delete=n`
  → права записываемых каталогов. Хэндлер — `graceful reload php-fpm` (сброс OPcache) при любом изменении кода.
- `playbooks/stage-5d-release.yml` — `pre-flight` (php-fpm активен, composer есть), роль, `post-checks` в вашем стиле:
  `vendor/autoload.php` и `pub/index.php` существуют, автозагрузчик грузится под `www-data`, writable-каталоги реально
  записываемы `www-data`.
- Makefile — цель `release` (с `agent-up`), в `full-deploy` не входит.

Ключевые решения внутри роли:

- Модель прав: весь код принадлежит `ansible` (деплой-пользователь), `www-data` только читает — PHP не может переписать
  собственный код. Записываемые каталоги (`backend/pub/assets`, `frontend/pub/assets`, `static`, `var/config`,
  `var/runtime`) — `ansible:www-data` с `setgid 2775`: `git` пишет как владелец, приложение — через группу. Это снимает
  конфликт «git не может создать файл в каталоге www-data».
- Идемпотентность `init`: я прочитал ваш `init` — при `--overwrite=n` существующие локальные конфиги не перетираются, а
  `cookieValidationKey` подставляется только в пустое значение, значит повторный релиз не сбрасывает сессии и куки.
  `chmod 0777` из `init` на `www-data`-каталогах не пройдёт и перекрывается задачей роли — сообщения «Error. Operation
  chmod not permitted» в его выводе ожидаемы.
- Защита от прежней выкладки: если `/var/www/bes-v.ru` не пуст и не git-клон (например, остатки rsync-экспериментов) —
  роль останавливается с понятным сообщением, ничего не удаляя.

---

Исправлено. Итог разбора лога и правок:

Что случилось. Composer три минуты пытался скачать пакеты и упал: сначала на каждом дисте `allow_url_fopen must be
enabled in php.ini`, затем на fallback-загрузке из исходников — `The Process class relies on proc_open, which is not
available`. Оба ограничения пришли из вашего `security.ini` (роль php), который задача `Copy PHP configuration files to
cli/conf.d` копировала в CLI-конфиг вместе со всеми остальными ini. Для FPM этот hardening правильный, но CLI — это
composer, php init, yii-консоль: им proc_open и https-обёртка нужны легитимно. Именно поэтому в Ubuntu у fpm и cli
отдельные php.ini.

Правки:

1. `roles/web-server/php/tasks/main.yml` — копирование в `cli/conf.d` теперь пофайловое через `fileglob` с исключением
   `security.ini` (FPM-копирование не тронуто — там hardening остаётся полностью). Плюс задача-чистильщик, удаляющая уже
   задеплоенный `cli/conf.d/security.ini` — так что полная переустановка сервера не обязательна: достаточно
   `make stage-4`,
   затем `make release`.
2. `playbooks/stage-4-webserver.yml` — в `post-checks` добавлен `assert php -r` на `proc_open + allow_url_fopen`: если
   `security.ini` когда-нибудь снова попадёт в CLI, это поймается на `stage-4` за секунду, а не трёхминутным падением
   composer в середине релиза.

Две попутные заметки из лога, не требующие действий: поток Deprecation Notice в stderr — это apt-шный Composer 2.7 под
PHP 8.4, шумно, но безвредно (на логику changed_when не влияет); и скелет-удаление каталогов в начале лога корректно
отработало в режиме skip — значит, клон на сервере уже есть, повторный `make release` просто обновит его.

---

Разобрался и переставил. Полная картина второй ошибки и что изменено:

Что было в логе. Фикс CLI сработал — все 130 пакетов скачались и установились за 14 секунд. Упал уже `post-install-cmd`
из вашего `composer.json`: `php yii Modman/modules/recompile` → `Could not open input file: yii`. Это `chicken-and-egg`
моего порядка задач: yii-скрипт и локальные конфиги генерирует `php init`, а он в роли шёл после `composer`.

Правка (`release/tasks/main.yml`, порядок задач):

1. `git clone/pull`
2. импорт дампа БД (opt-in) — теперь до composer
3. `php init` — сам он автономный, vendor ему не нужен, зато создаёт yii, *-local.php и cookie key
4. writable-каталоги — до composer, потому что recompile пишет merge-plan в var/config
5. `composer install` — его post-install-скрипт теперь получает готовые yii, конфиги и записываемый `var/config`

Я проверил по коду modman в vendor: реестр модулей — файловый (`var/config/modules-state.php`, `@config-dyn-gen`), БД
для recompile не нужна, так что порядок закрывает проблему полностью.

Важный heads-up на следующий шаг. В репозитории `var/` содержит только `runtime` — `var/config/modules-state.php`
(реестр установленных модулей) на чистый сервер не приезжает. `ModuleRegistry` при отсутствии lock-файла молча стартует
с пустым реестром, то есть первый релиз пройдёт зелёным, но `recompile` соберёт `merge-plan` без единого активного
модуля — сайт поднимется «голым ядром». Судя по коду вашего `ModulesController`, штатное восстановление —
`php yii Modman/modules/sync` (пересборка реестра из каталога composer + истории миграций, которая приедет с дампом БД).
Рекомендую после первого `make release-db` выполнить `sync` на сервере разово; если скажете — добавлю его в роль
опциональным шагом (не делаю сам, потому что семантика `adopt/sync` — ваша предметная область: не хочу молча
активировать лишние модули).

---

Готово. Что сделано и как этим пользоваться:

1. Лишние www убраны

В `ansible/inventory/group_vars/all/webserver.yml` у `backend` и `static` теперь только основные имена:

```nginx
server_name: "{{ app_hosts.adm }}"
server_name: "{{ app_hosts.files }}"
```

У frontend www.bes-demo.ru оставлен — он в DNS есть. Certbot строит -d из этой же переменной, так что для выпуска
сертификата больше ничего не нужно. Но nginx-конфиги на сервере уже отрендерены со старыми server_name (их рендерит роль
nginx в stage-4) — это безвредно, однако для синхронизации стоит перегнать make stage-4 перед 5a.

2. `--staging` — уже был, добавил только удобство

Флаг `certbot_staging` уже реализован в роли, менять код не пришлось. Я добавил три вещи:

- `make stage-5a-staging` — прогон против `staging CA` (не жжёт прод-квоты, сертификат недоверенный).
- `make stage-5a-force` — новый флаг `certbot_force_renewal` в роли. Он нужен из-за неочевидной ловушки: после успешного
  staging-теста в `/etc/letsencrypt/live/` лежит валидный неистёкший staging-сертификат, и обычный `make stage-5a` из-за
  `--keep-until-expiring` его не заменит — просто переустановит в nginx, и браузер продолжит ругаться. Force-запуск
  разово перевыпускает у боевого CA.
- Комментарий в `defaults/main.yml` роли, объясняющий этот сценарий.

Рабочий порядок, если хочешь сначала проверить:

`make stage-4` # обновить `server_name` в `nginx`
`make stage-5a-staging` # проверка DNS/пайплайна без расхода квот
`make stage-5a-force` # разовый боевой выпуск поверх staging-серта

Дальше по жизни — обычный `make stage-5a`.

К слову: прямо сейчас сертификата на сервере нет вообще (выпуск упал целиком), а валидацию не прошли только два
www-домена — остальные четыре LE проверил без претензий. Так что после правки www можно и сразу make stage-4 && make
stage-5a без staging-этапа — риск минимальный. Staging-путь оставлен на случай, если хочешь перестраховаться или ещё
будешь крутить DNS.















