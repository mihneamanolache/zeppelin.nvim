# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**zeppelin.nvim** is a Neovim plugin for interacting with Apache Zeppelin notebooks directly from Neovim. It communicates with the Zeppelin REST API via curl (executed asynchronously through `plenary.job`). There is no build step, no test suite, and no linter configuration — it is a pure Lua plugin.

## Development

- **Plugin manager:** lazy.nvim
- **External dependency:** `plenary.nvim` (for async job execution), `telescope.nvim` (optional, for `:ZeppelinSearch`)
- **No build/compile step** — Lua files are loaded directly by Neovim
- **No tests or CI** — manual testing in Neovim is the only verification method
- To test changes locally, symlink or point lazy.nvim to the local directory and reload Neovim (`:Lazy reload zeppelin.nvim` or restart)

## User's Neovim Config

- **Neovim config directory:** `~/.config/nvim/`
- **Plugin config (zeppelin + dashboard):** `~/.config/nvim/lua/plugins/user.lua`
- **Dashboard:** snacks.nvim dashboard with menu items (Projects, Recent Files, Lazy, Config, Zeppelin)
- **Zeppelin dashboard entry:** key `z`, action `:ZeppelinLogin`

## Architecture

All source code lives under `lua/`:

- **`lua/zeppelin.lua`** — Entry point. Registers all user commands, calls `setup()` which initializes config and highlight groups.
- **`lua/zeppelin/api.lua`** — Centralized HTTP client. Wraps curl via `plenary.job` with proxy support, cookie auth, JSON encode/decode. Exports `get`, `post`, `put`, `delete`, `authenticate`. Callback signature: `callback(err, data)`.
- **`lua/zeppelin/config.lua`** — Stores plugin configuration. Only `ZEPPELIN_URL` is required; `SOCKS5_PROXY` defaults to `""`.
- **`lua/zeppelin/auth.lua`** — Authenticates via `api.authenticate()`, auto-opens tree sidebar on success.
- **`lua/zeppelin/tree.lua`** — Tree sidebar (left vsplit, width 35). Parses flat notebook list into nested folder hierarchy. Supports expand/collapse, create notebook, refresh.
- **`lua/zeppelin/notebook.lua`** — Unified paragraph buffer. All paragraphs in one buffer with extmark-tracked boundaries, virtual line separators, inline output via `virt_lines`. Handles save, run, restart interpreter, output toggle.
- **`lua/zeppelin/search.lua`** — Telescope integration for fuzzy notebook search by path.
- **`lua/zeppelin/ui.lua`** — Simple auto-closing popup notifications. Defines all `Zeppelin*` highlight groups.

### Commands

| Command | Action |
|---------|--------|
| `:ZeppelinLogin <user> <pass>` | Authenticate, auto-open tree |
| `:Zeppelin` / `:ZeppelinTree` | Toggle tree sidebar |
| `:ZeppelinSearch` | Telescope notebook search |
| `:ZeppelinRun` | Run paragraph under cursor |
| `:ZeppelinSave` | Save current paragraph |
| `:ZeppelinSaveAll` | Save all modified paragraphs |
| `:ZeppelinRestartInterpreter` | Restart current interpreter |

### Buffer Keymaps (notebook buffers)

| Key | Action |
|-----|--------|
| `<leader>r` | Run paragraph under cursor |
| `<leader>w` | Save current paragraph |
| `<leader>W` | Save all modified paragraphs |
| `<leader>o` | Toggle output visibility |
| `<leader>R` | Restart interpreter |

### Tree Keymaps

| Key | Action |
|-----|--------|
| `<CR>` | Toggle folder / open notebook |
| `a` | Create new notebook |
| `R` | Refresh tree |
| `q` | Close tree |

### Key Patterns

- **Module pattern:** Every file exports an `M` table.
- **Async HTTP:** All network calls go through `api.lua` which uses `plenary.job` with curl + cookie auth, wrapped in `vim.schedule()` for safe Neovim API access.
- **Extmarks:** Namespace `"zeppelin_paragraphs"` tracks paragraph boundaries, separators, and inline output.
- **Buffer state:** Per-buffer notebook state stored in module-level `_buffers[bufnr]` table in `notebook.lua`.
- **Language detection:** `detect_interpreter()` maps `%spark`→scala, `%pyspark`/`%python`→python, `%sql`→sql, `%sh`→sh, `%md`→markdown, `.conf`→python. Dominant filetype set on buffer open.
- **SOCKS5 proxy:** All curl calls in `api.lua` conditionally include `--socks5-hostname` when configured.
