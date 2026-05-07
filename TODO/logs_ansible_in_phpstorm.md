### Настройки для Log Format Ansible в PhpStorm (Ideolog)

Благодарю за уточнения и примеры экспорта. Я проанализировал предоставленные вами файлы экспорта (symfony.xml и другие),
которые выглядят как минимальные заглушки (возможно, с версией "13" внутри, что может указывать на внутреннюю версию
настроек Ideolog или PhpStorm). На основе этого, документации
(включая вики https://github.com/JetBrains/ideolog/wiki/Highlighting-Patterns) и примеров конфигураций из внешних
источников (StackOverflow, где описаны аналогичные поля), я создал XML для импорта только **Log Format** (без patterns,
как вы предложили). Patterns добавим вручную через GUI, так как вики подчёркивает, что они применяются к capture groups
из формата, и импорт patterns может не всегда работать корректно (или требовать отдельной настройки).

#### Почему предыдущие XML не импортировались

- Ideolog (встроенный в Log Highlighting PhpStorm) использует специфический формат экспорта/импорта, который не всегда
  документирован. Ваши примеры экспорта (с "13") предполагают, что XML может включать версию или быть минимальным.
- Если XML слишком сложный или с неверными тегами, импорт игнорируется (как указано в вики: "If your pattern is invalid,
  it will simply be ignored").
- Patterns лучше добавлять вручную, так как они зависят от распознанного формата (Log Format) и применяются к его
  capture groups.
- Я добавил атрибут `version="13"` в XML, чтобы соответствовать вашим экспортам (возможно, это внутренняя версия
  Ideolog).

#### XML для импорта (только Log Format "Ansible Log")

Сохраните следующий код как `ansible_log_format.xml` и импортируйте через **Settings** (Ctrl+Alt+S) → **Editor** → **Log
Highlighting** → **Import**. После импорта формат "Ansible Log" должен появиться в списке **Log Formats**.

```xml

<log-highlighting version="13">
    <log-format>
        <name>Ansible Log</name>
        <message-pattern>^(?&lt;time>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3}) p=\d+ u=\w+ n=ansible \| (?:(?&lt;severity>ok|fatal|ERROR!|changed|skipped|unreachable):?)?(?:\s*(?&lt;categoria>TASK|PLAY|PLAY
            RECAP|ansible-playbook|ansible-inventory) )?(?&lt;message>.*)$
        </message-pattern>
        <message-start-pattern>^</message-start-pattern>
        <time-format>yyyy-MM-dd HH:mm:ss,SSS</time-format>
        <time-capture-group>1</time-capture-group>
        <severity-capture-group>2</severity-capture-group>
        <category-capture-group>3</category-capture-group>
        <apply-to-all-message-lines>true</apply-to-all-message-lines>
    </log-format>
</log-highlighting>
```

- **Разъяснение настроек в XML** (на основе вики и ваших полей):
    - **Name**: "Ansible Log" — имя формата.
    - **Message Pattern**: Регулярное выражение для парсинга строки. Захватывает:
        - Группа 1 (`time`): Время (`2025-10-05 00:36:49,857`).
        - Группа 2 (`severity`): Статус (`ok`, `fatal`, `ERROR!` и т.д.).
        - Группа 3 (`category`): Категория (`TASK`, `PLAY` и т.д.).
        - Группа 4 (`message`): Сообщение (включая JSON).
    - **Message start pattern**: `^` — для начала строк, обеспечивает обработку многострочных сообщений (как в вики: "
      Make sure to begin your pattern with ^").
    - **Time format**: `yyyy-MM-dd HH:mm:ss,SSS` — формат времени с миллисекундами.
    - **Time capture group**: `1` — индекс группы для времени (вики: "Capture groups are numbered starting with 1").
    - **Severity capture group**: `2`.
    - **Category capture group**: `3`.
    - **Apply message pattern to all message lines**: `true` — включено для многострочных JSON (вики: помогает с
      производительностью, но для ваших логов нужно, чтобы парсить все строки).

После импорта откройте ваш `.log`-файл — PhpStorm должен распознать формат автоматически (если в первых 25 строках >=5
совпадений, как в примерах из источников). Если не распознаёт, перезагрузите файл или IDE.

#### Добавление Patterns вручную

После импорта формата перейдите в **Settings → Editor → Log Highlighting → Patterns** и добавьте правила подсветки (
нажмите **+** для каждого). Patterns применяются к capture groups из формата "Ansible Log" (вики: "The pattern is
applied to capture groups from Log Format").

Для каждого паттерна заполните поля:

- **Pattern**: Регулярное выражение для совпадения.
- **Action**: Выберите из выпадающего списка (`Highlight match`, `Highlight line` или `Highlight field`).
- **Log format**: Выберите "Ansible Log" из выпадающего списка (теперь он доступен после импорта).
- **Capture group**: Числовое значение (1 для времени, 2 для severity, 3 для category, 4 для message; вики: "If you
  don't have a capture group... select 0").
- **Bold/Italic**: Галочки для жирного/курсива (вики: "for multi-line messages, these will be applied only to the first
  line").
- **Foreground/Background**: Выберите цвета (кликните на поле, откроется диалог; используйте HEX-коды ниже).
- **Show on stripe**: Галочка для меток на скроллбаре (вики: "add a mark to error stripe").

Рекомендуемые Patterns (добавьте по одному):

1. **Для времени (time)**:
    - Pattern: `^(?<time>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3})`
    - Action: Highlight match
    - Log format: Ansible Log
    - Capture group: 1
    - Bold: ✅
    - Italic: ❌
    - Foreground: #5EB4FF
    - Background: Нет
    - Show on stripe: ✅

2. **Для успешного статуса (ok)**:
    - Pattern: `ok:`
    - Action: Highlight field
    - Log format: Ansible Log
    - Capture group: 2
    - Bold: ✅
    - Italic: ❌
    - Foreground: Нет
    - Background: #90EE90 (зелёный)
    - Show on stripe: ✅

3. **Для ошибок (fatal, ERROR!, unreachable)**:
    - Pattern: `fatal:|ERROR!|unreachable:`
    - Action: Highlight field
    - Log format: Ansible Log
    - Capture group: 2
    - Bold: ✅
    - Italic: ❌
    - Foreground: Нет
    - Background: #FFB6C1 (красный)
    - Show on stripe: ✅

4. **Для изменений (changed)**:
    - Pattern: `changed:`
    - Action: Highlight field
    - Log format: Ansible Log
    - Capture group: 2
    - Bold: ✅
    - Italic: ❌
    - Foreground: Нет
    - Background: #FFFFE0 (жёлтый)
    - Show on stripe: ✅

5. **Для пропусков (skipped)**:
    - Pattern: `skipped:`
    - Action: Highlight field
    - Log format: Ansible Log
    - Capture group: 2
    - Bold: ✅
    - Italic: ❌
    - Foreground: Нет
    - Background: #D3D3D3 (серый)
    - Show on stripe: ✅

6. **Для категорий (TASK, PLAY и т.д.)**:
    - Pattern: `TASK|PLAY|PLAY RECAP|ansible-playbook|ansible-inventory`
    - Action: Highlight field
    - Log format: Ansible Log
    - Capture group: 3
    - Bold: ✅
    - Italic: ❌
    - Foreground: Нет
    - Background: #FFDAB9 (персиковый)
    - Show on stripe: ✅

7. **Для сообщений с JSON**:
    - Pattern: `\{.*\}`
    - Action: Highlight match
    - Log format: Ansible Log
    - Capture group: 4
    - Bold: ❌
    - Italic: ✅
    - Foreground: #808080 (серый)
    - Background: #F5F5F5 (светло-серый)
    - Show on stripe: ❌

#### Устранение неполадок

- **Если импорт не работает**: Создайте формат вручную в **Log Formats** (нажмите **+**), скопируйте значения из XML
  выше. Это гарантирует работу, так как вики фокусируется на ручной настройке.
- **Подсветка не применяется**: Убедитесь, что в **Patterns** выбран правильный "Log format" ("Ansible Log"). Проверьте
  regex на regex101.com с вашим логом.
- **Filters**: Если нужно, в разделе **Filters** добавьте фильтры (вики не детализирует, но это для скрытия строк,
  например, по severity).
- **Производительность**: Если логи большие, отключите "Apply message pattern to all message lines" (в формате) —
  вики: "leaving this checkbox unselected helps significantly improve performance".
- **Версия PhpStorm**: Убедитесь, что у вас 2025.2 или совместимая (вики от 2024, но актуальна).

После добавления протестируйте на вашем логе. Если формат не появляется или patterns не работают, пришлите скриншот
настроек или ошибку — уточню!
