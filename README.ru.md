# lazyvim-agent

Панель ИИ-агента для [LazyVim](https://www.lazyvim.org) в стиле Cursor и
инструменты git, чтобы проверять, что агент сделал.

[English](README.md) · **Русский**

```
┌────────────────────────────────┬──────────────────────┐
│ твой код                       │ Claude Code          │
│                                │                      │
│ ── когда Claude правит файл ── │ видит открытый файл  │
│ правка показана как diff:      │ и выделенный код     │
│   <leader>aa  принять          │                      │
│   <leader>ad  отклонить        │ <C-h> назад к коду   │
└────────────────────────────────┴──────────────────────┘
```

Это не новый плагин, а готовый проверенный набор спецификаций
[lazy.nvim](https://github.com/folke/lazy.nvim). Он связывает три существующих
плагина и даёт им клавиши, которые не конфликтуют друг с другом:

- **[claudecode.nvim](https://github.com/coder/claudecode.nvim)**: Claude Code
  в панели справа (40% ширины). Подключается к Neovim так же, как расширение
  для VS Code: знает текущий файл и выделение, а свои правки показывает как
  diff прямо в Neovim. Правку можно принять, отклонить или поправить руками
  перед тем, как принять.
- **[sidekick.nvim](https://github.com/folke/sidekick.nvim)**: любой другой
  агент, который у тебя установлен (Codex, OpenCode, Cursor Agent, Copilot CLI,
  Gemini, Aider и другие), в такой же панели. Есть меню готовых запросов:
  объяснить, исправить, проверить код, написать тесты, исправить ошибки.
  Когда агент меняет файлы на диске, открытые буферы перечитываются сами.
- **[diffview.nvim](https://github.com/sindrets/diffview.nvim)**: все
  незакоммиченные изменения в одной вкладке, чтобы проверить работу агента до
  коммита. Ещё история файла и репозитория, подписи «кто менял строку» и
  подсветка для сообщений коммитов и списков rebase.

Всё это работает поверх того, что для git уже есть в LazyVim: lazygit,
gitsigns и пикеры Snacks.

## Что нужно

- Neovim **0.11.2** или новее (этого требует sidekick.nvim)
- LazyVim (спецификации используют Snacks и группы which-key из LazyVim)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`claude`)
  для основной панели; другие агенты по желанию
- `git`; [lazygit](https://github.com/jesseduffield/lazygit) для `<leader>gg`

API-ключи не нужны: каждый агент работает через свой логин или подписку.

## Установка

Создай файл `~/.config/nvim/lua/plugins/agent.lua`:

```lua
return {
  { "dszhlt/lazyvim-agent", import = "lazyvim-agent.plugins" },
}
```

Перезапусти Neovim, lazy.nvim сам всё установит при первом запуске.

Если нужна только одна часть, подключи один файл:

```lua
{ "dszhlt/lazyvim-agent", import = "lazyvim-agent.plugins.ai" },  -- только агенты
{ "dszhlt/lazyvim-agent", import = "lazyvim-agent.plugins.git" }, -- только git
```

> **Важно:** не включай одновременно extra LazyVim `ai.sidekick`: его клавиши
> `<leader>aa`, `<leader>as`, `<leader>ad` и `<leader>af` пересекаются с
> клавишами Claude отсюда. Extra `ai.claudecode` включать можно, у него те же
> клавиши.

## Как пользоваться

1. Открой проект и нажми `<leader>ac` (или набери `:ClaudeCode`). Справа
   откроется Claude. В новой папке он сначала спросит, доверяешь ли ты ей, и
   только потом подключится к Neovim.
2. Выдели код и нажми `<leader>as`. Курсор перейдёт в Claude, и можно сразу
   написать, что сделать с этим кодом.
3. Когда Claude хочет изменить файл, открывается diff: `<leader>aa` (или `:w`)
   принимает правку, `<leader>ad` отклоняет.
4. Нажми `<leader>gv`, чтобы посмотреть все изменения, и закоммить их через
   lazygit (`<leader>gg`).

`<C-h>` переводит из агента в код, `<C-l>` обратно. Чтобы прокрутить или
скопировать текст в окне агента, выйди из режима ввода через `<C-\><C-n>`,
а `i` вернёт к вводу.

## Клавиши

### Claude Code

| Клавиши | Что делает |
|---|---|
| `<leader>ac` | открыть или закрыть Claude |
| `<leader>af` | перейти в Claude |
| `<leader>ar` | вернуться к старой сессии |
| `<leader>aC` | продолжить последнюю сессию |
| `<leader>am` | выбрать модель |
| `<leader>aq` | закрыть Claude |
| `<leader>ab` | добавить текущий файл в контекст |
| `<leader>as` | отправить выделенное (в visual) / добавить файл (в дереве файлов) |
| `<leader>aa` | принять предложенный diff |
| `<leader>ad` | отклонить предложенный diff |

### Другие агенты

| Клавиши | Что делает |
|---|---|
| `<leader>ao` | выбрать установленного агента или запущенную сессию |
| `<leader>aO` | показать или скрыть окно агента |
| `<leader>ap` | меню запросов: объяснить, исправить, проверить, тесты, ошибки |
| `<leader>av` | отправить выделенное (в visual) |
| `<leader>aF` | отправить текущий файл |

### Git

| Клавиши | Что делает |
|---|---|
| `<leader>gv` | Diffview: все незакоммиченные изменения (открыть/закрыть, `q` закрывает) |
| `<leader>gF` | Diffview: история этого файла или выделенных строк |
| `<leader>gV` | Diffview: история репозитория |
| `<leader>gt` | показывать или скрыть, кто менял строку |

В самом LazyVim уже есть `<leader>gg` lazygit, `<leader>gs` статус,
`<leader>gd` diff, `<leader>gl` лог, `]h` / `[h` переход между изменёнными
блоками и `<leader>ghs` / `<leader>ghr` / `<leader>ghp`, чтобы застейджить,
откатить или посмотреть блок.

## Настройка

Добавь спецификацию того плагина, который хочешь поменять. Твои значения
всегда главнее здешних:

```lua
return {
  { "dszhlt/lazyvim-agent", import = "lazyvim-agent.plugins" },

  -- Claude слева, 35% ширины
  {
    "coder/claudecode.nvim",
    opts = { terminal = { split_side = "left", split_width_percentage = 0.35 } },
  },

  -- другие агенты в плавающем окне
  { "folke/sidekick.nvim", opts = { cli = { win = { layout = "float" } } } },
}
```

Все параметры описаны в README самих плагинов:
[claudecode.nvim](https://github.com/coder/claudecode.nvim#advanced-configuration),
[sidekick.nvim](https://github.com/folke/sidekick.nvim#%EF%B8%8F-configuration),
[diffview.nvim](https://github.com/sindrets/diffview.nvim#configuration).

## Благодарности

Вся настоящая работа сделана в
[coder/claudecode.nvim](https://github.com/coder/claudecode.nvim),
[folke/sidekick.nvim](https://github.com/folke/sidekick.nvim),
[sindrets/diffview.nvim](https://github.com/sindrets/diffview.nvim),
[LazyVim](https://github.com/LazyVim/LazyVim) и его настройке git. Этот
репозиторий только настраивает их на совместную работу.

## Лицензия

[MIT](LICENSE)
