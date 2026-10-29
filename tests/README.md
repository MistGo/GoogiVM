# Полный набор тестов для `custom_loadstring_full.lua`

Целевая среда — Lua 5.1 / LuaJIT 2.1. Тесты также проходят на Lua 5.4;
часть проверок, зависящих от `setfenv`/`getfenv`, на 5.4 автоматически
пропускается.

## Запуск

Из корня проекта:

```bash
luajit run_all_tests.lua
```

или:

```bash
lua run_all_tests.lua
```

Код возврата `0` — все проверки прошли, `1` — есть падения.

## Что проверяется

| Файл | Покрытие |
|---|---|
| `test_lexer.lua` | пробелы, `--` и длинные комментарии, CRLF/CR, все виды чисел, hex, экспоненты, короткие/длинные строки, escape-последовательности, UTF-8, операторные токены, ошибки лексера |
| `test_syntax.lua` | все операторы языка, `if/elseif/else`, `while`, `repeat`, оба `for`, `do`, `break`, `return`, `local`, `local function`, `function`, методы, присваивания, табличные конструкторы, call sugar (`f{}`, `f''`), валидные и невалидные программы, проверка отсутствия bitwise/goto/`//`/атрибутов 5.2+ |
| `test_expressions.lua` | приоритеты, right-assoc `^` и `..`, унарные операторы, арифметика, строковая коэрция, сравнения, `and/or/not`, short-circuit, `#`, runtime-ошибки, дифференциальные проверки с нативным `loadstring` |
| `test_statements.lua` | локальные/глобальные переменные, множественное присваивание, `if`, `while`, `repeat`, числовой `for`, generic `for`, `break`, `return`, области видимости, closures-loop-переменных, false/nil в generic for, раскрытие multi-return в generic for, varargs как explist |
| `test_functions.lua` | функции, параметры, рекурсия, `local function`, анонимные функции, `function`-присваивания, методы, `self`, замыкания, upvalue-цепочки, захват параметров, замыкания в циклах, shared cells, немедленный вызов, цепочки вызовов/полей |
| `test_tables.lua` | пустые/списковые/именованные/keyed-таблицы, вложенность, дубликаты ключей, `;`/`,`/trailing, multi-return в последнем поле, keyed-поля с multi-return, доступ/присваивание полей и индексов, методы, call sugar, `function t.a.b.c()` |
| `test_varargs_multiret.lua` | `...`, vararg-параметры, top-level varargs, `select`, multi-return в return/assignment/call args/table/generic for, скобки, nil-значения, native/custom interop |
| `test_metatables.lua` | `__index`, `__newindex`, `__add/sub/mul/div/mod/pow/unm`, `__concat`, `__len`, `__eq`, `__lt`, `__le` (включая fallback), `__call`, метаметоды-замыкания и нативные метаметоды, `__tostring`, `__metatable` |
| `test_environment.lua` | `env`-таблица, `__index`/`__newindex` окружения, изоляция от `_G`/`os`/`io`/`debug`, независимые окружения, `getfenv`/`setfenv` для функций и уровней, наследование окружения замыканиями, запрет `setfenv(0)` |
| `test_errors.lua` | API-валидация, `nil, error` на синтаксисе, номера строк, runtime-ошибки через `pcall`, ошибки метаметодов/итераторов, error-объекты, побочные эффекты до runtime-ошибки, default env |
| `test_host_interop.lua` | `pcall`, `xpcall`, `table.sort`, `string.gsub`, корутины (`create`/`wrap`/`resume`/`yield` через вложенные вызовы), higher-order native functions, `type`, `tostring`, string-методы, nil-аргументы |
| `test_regressions.lua` | найденные при разработке пограничные случаи: generic for `false`, независимость control-переменной, per-iteration cells, backpatch upvalues, repeat-scope, trailing multi-field, последний аргумент, false-ключи, parenthesized call, field call, >60 upvalues, upvalue propagation, порядок вычислений, vararg в середине/конце return |
| `test_superinstructions.lua` | fused/super-инструкции и peephole-оптимизатор: локальные move/assign, арифметика и сравнения с константами, табличные чтения/записи, переходы, числовой `for`; проверка, что оптимизации не меняют семантику на границах jump targets и захваченных переменных |
| `test_fuzz.lua` | 15 000 случайных выражений и 3 000 случайных программ с дифференциальной проверкой против нативного `loadstring` |
| `test_stress.lua` | рекурсия 5 000, 150 локальных, 100 upvalues, таблица на 1 000 элементов, 2 000 инструкций, цикл на 100 000, строки/комментарии 100 КБ, 200 вложенных блоков/скобок, 120 параметров, 100 возвратов, 100 замыканий |
| `test_limits.lua` | отказ `getfenv`/`setfenv` для native-функций, лимиты исходника, байткода, инструкций, глубины вызовов, стека, аргументов и возвратов, sourceName, runtime line/traceback |
| `test_tailcalls.lua` | tail recursion и mutual recursion с малым `maxCallDepth`, multi-return, native/method/vararg/table `__call`, non-tail return, ошибки и корутины |

Итого: **18 678 проверок** на LuaJIT и **18 660 проверок** на Lua 5.4;
на 5.4 часть проверок `setfenv`/`getfenv` и `__len`-зависимостей
автоматически пропускается.

## Примечания

- Дифференциальные тесты используют `loadstring` (LuaJIT/5.1) или `load` (5.2+)
  и сравнивают результаты с нативным Lua. Ошибки сравниваются по факту
  падения, а не по тексту сообщения.
- Для нативных чанков в дифференциальных тестах выставляется тот же `env`
  через `setfenv`, если хост это поддерживает.
- Поведение метаметодов, `#` и некоторых деталей стандартной библиотеки
  наследуется от хоста. Целевой хост — LuaJIT/Lua 5.1.
- Тесты используют `dofile`, `print`, `os.clock` и `os.exit`; это
  инфраструктура тестов, а не интерпретируемый код.
