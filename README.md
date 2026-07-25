# nxvim-workspaces

Per-project editor configuration for [nxvim](https://github.com/davidrios/nxvim),
declared as a committable **`.nxvim/config.json`** instead of hand-written rc Lua.

Drop a `.nxvim/config.json` at the root of a project and nxvim-workspaces applies it on
start: it enables the project's **language servers**, wires a **`<C-s>` save-actions**
map per language (format / fix / write), and sets **vim options** — globally and
per-filetype. It is the declarative twin of the little per-workspace rc files you'd
otherwise write by hand.

It is built entirely on the documented `nx.*` API — `nx.fs` (async config read),
`nx.json`, `nx.lsp`, `nx.autocmd`, `nx.keymap`, `vim.o`. There is **no neovim
compatibility layer**; nothing blocks and nothing is intercepted.

> **This is a workspace feature.** It only acts in a `--workspace` session (`nxvim
> --workspace [dir]`), reading `<workspace-root>/.nxvim/config.json`. In a bare editor it
> does nothing. (Force it anyway with an explicit `setup({ path = "…" })`.)

> This plugin only *configures* language servers — it does not install them. Install the
> server binaries yourself. A missing binary fails **loud** (nxvim never pretends a
> server that isn't there is working).

## Install

Declare it with the built-in `:Plugins` manager in your `init.lua`:

```lua
nx.plugins({
  {
    "nxvim/nxvim-workspaces",
    -- Supplies the `lsp/<name>.lua` presets a config's server NAMES resolve against.
    dependencies = { "nxvim/nxvim-lspconfig" },
  },
})
```

Run `:PluginSync` to clone them. That's all the setup there is: from then on, opening a
project as a workspace (`nxvim --workspace [dir]`) applies its `.nxvim/config.json`
automatically. (Opening the bare editor does nothing — this is a per-workspace feature.)

To override the defaults (config path, save key), call `setup()` yourself instead:

```lua
nx.plugins({
  {
    "nxvim/nxvim-workspaces",
    config = function()
      require("nxvim-workspaces").setup({
        save_key = "<C-s>", -- the save-actions keymap (default "<C-s>")
        -- path = "/abs/path/to/config.json", -- default: "<workspace-root>/.nxvim/config.json"
        -- notify_missing = false,           -- notify when no config file is found
        -- templates_dir = "…",              -- default: "<config>/workspace-templates"
        -- trust = true,                     -- prompt before applying (config runs code)
      })
    end,
  },
})
```

## `.nxvim/config.json`

```json
{
  "languages": {
    "python": {
      "lsps": {
        "basedpyright": {
          "settings": { "basedpyright": { "analysis": { "typeCheckingMode": "off" } } }
        },
        "ruff": {}
      },
      "save_actions": [
        {
          "require": "nx.lsp",
          "method": "code_action",
          "params": { "context": { "only": ["source.fixAll"] }, "apply": true }
        },
        { "require": "nx.lsp", "method": "format" }
      ],
      "settings": { "tabstop": 4, "shiftwidth": 4 }
    },

    "javascript,typescript,vue": {
      "lsps": { "ts_ls": {} },
      "save_actions": [
        { "require": "conform", "method": "format" }
      ]
    }
  },

  "settings": {
    "number": true,
    "relativenumber": true
  },

  "setup": { "require": "my.workspace", "method": "prepare", "params": {} }
}
```

### `languages`

A map of **filetype → per-language config**. The key is one filetype (`"python"`) or a
comma-joined list (`"javascript,typescript,vue"`), in which case the block applies to
each listed filetype.

| field          | when                | what it does                                                            |
| -------------- | ------------------- | ----------------------------------------------------------------------- |
| `lsps`         | once, at start      | `{ <server> = <nx.lsp config> }` — each server is registered + enabled  |
| `save_actions` | on `<C-s>`          | a list of actions run in order, then the buffer is written (see below)  |
| `settings`     | on the filetype     | `{ <option> = <value> }` applied **buffer-local** in a FileType autocmd |

`lsps` values are ordinary [`nx.lsp.config`](https://github.com/davidrios/nxvim) tables
(`cmd`, `filetypes`, `root_markers`, `settings`, …). Each named server is registered and
enabled — it attaches when you open a matching file (and immediately, if one is already
open).

**Several servers per language is the normal case**, and all of them attach: the
`pyright` + `ruff` pairing below runs both, each syncing the document and publishing its
own diagnostics. Requests go to a server that can answer them — a hover to the
type-checker, formatting to whichever advertises it — and code actions from *every*
server merge into one chooser, so a linter's quick-fixes and a type-checker's refactors
appear together. Pick the formatter explicitly when it matters:

```json
{ "require": "nx.lsp", "method": "format", "params": { "name": "ruff" } }
```

A bare `{}` leans entirely on the server's **bundled preset**: the runtimepath
`lsp/<name>.lua` that supplies its command, filetypes, and root markers. Those presets
are what [nxvim-lspconfig](https://github.com/nxvim/nxvim-lspconfig) ships, so install it
alongside this plugin if you want to name servers rather than spell them out:

```lua
nx.plugins({
  { "nxvim/nxvim-workspaces", dependencies = { "nxvim/nxvim-lspconfig" } },
})
```

Without a preset (or an explicit `cmd` in the JSON) there is nothing to spawn, and nxvim
says so loudly rather than pretending the server started.

### `save_actions` and `<C-s>`

Each language with `save_actions` installs a buffer-local **`<C-s>`** map. Pressing it
runs every action **in order**, then writes the buffer. An action is:

```json
{ "require": "<module-or-global>", "method": "<name>", "params": <any> }
```

which invokes `<module-or-global>.<method>(<params>)`. `require` resolves either a real
Lua module (`"conform"`) **or** a dotted global path — so the built-in editor verbs,
which live on global tables, work directly:

| `require`       | `method`                     | effect                                   |
| --------------- | ---------------------------- | ---------------------------------------- |
| `"nx.lsp"`      | `"format"`                   | LSP format the buffer                    |
| `"nx.lsp"`      | `"code_action"`              | run a code action — see the filter below |
| `"nx.lsp"`      | `"rename"`                   | rename the symbol under the cursor       |
| `"vim.lsp.buf"` | `"format"` / `"code_action"` | the neovim-shaped aliases of the above   |
| `"conform"`     | `"format"`                   | a plugin module's method                 |

A bad action fails **loud** — a module/global that can't be resolved, or a method that
isn't a function, raises with the offending name (never a silent no-op). Note the built-in
verbs live on `nx.lsp` itself: there is no `nx.lsp.buf`, and a config naming it fails loud
(the neovim-shaped spelling is `vim.lsp.buf`). `format` takes `{ "name": "<server>" }` to
choose among several attached servers; `code_action` takes the filter below. An option
neither models is rejected loudly rather than ignored.

The whole chain is **resolved before any of it runs**, so a typo in the last action fails
the save without half-applying the ones before it.

**Picking one code action (no menu on save).** A bare `code_action` is interactive: it
opens the chooser and the chain waits for your pick. `params` narrows it to the action
you actually mean, which is what makes it usable on `<C-s>`:

```json
{
  "require": "nx.lsp",
  "method": "code_action",
  "params": { "context": { "only": ["source.fixAll"] }, "apply": true }
}
```

`context.only` is a list of code-action kinds (matched down the LSP hierarchy, so
`source.fixAll` also picks up `source.fixAll.ruff`), and `apply` means *"if exactly one
action survives that filter, just run it"*. Two or more survivors still open the chooser
— there is a real choice to make — and none is a no-op that resolves quietly, so the
write is never blocked. Options nxvim doesn't model (neovim's `filter`, `range`) fail
loud rather than being silently dropped.

> **Async note.** Actions are **sequenced**: when one returns a promise it is awaited
> before the next runs, and the `:write` lands only after the last has settled. nxvim's
> built-in `nx.lsp` verbs return exactly such a promise — one that resolves when the
> round-trip completes **and its edit is applied** — so a `[code_action, format]` chain
> runs in order and the file is written with the server's last edit already in it.
>
> Those verbs are *resolve-only*: a no-op (no server attached, an empty result, a
> superseded request, a cancelled chooser) resolves quietly instead of failing, so it
> never blocks the write.

### `settings`

The top-level `settings` block is applied **once at start**, globally, through `vim.o`
(which routes each option to its proper scope). A `settings` block *inside* a language is
applied **on that language's buffers** — each option routed to the scope its name implies,
with the matching buffer installed as the current context, so a buffer-local name
(`tabstop`, `shiftwidth`, `expandtab`) lands on that buffer even when it isn't the focused
one. A **window**-scoped name (`number`, `wrap`, `colorcolumn`) has no buffer to land on,
so it applies to the current window — put those in the top-level `settings` instead.

Any vim option name works; an unmodeled name warns-but-stores (the lenient compat
surface), it never aborts the load.

### `setup` — an async hook, awaited first

The optional top-level `setup` is a `{ require, method, params }` call (same resolution
as a save action) run **before anything else in the config is applied**. If its method
returns a promise, it is **awaited** first — so a slow prepare step (compute a path,
install a dependency, register a custom module the rest of the config references)
finishes before the LSPs/settings/save-actions land.

```json
{ "setup": { "require": "my.workspace", "method": "prepare", "params": { "env": "dev" } } }
```

The referenced Lua lives in **your own config dir** (anything `require`-able, or a dotted
global) — the JSON only names it. It is the escape hatch for the bit of logic that can't
be plain data, mirroring the per-template `setup()` in a hand-written workspace rc. A
failing hook is reported loud and **aborts** the rest of the apply.

## Templates and commands

`setup()` registers five commands for editing the project config from inside the editor:

| command                     | what it does                                                     |
| --------------------------- | ---------------------------------------------------------------- |
| `:WorkspaceConfig`          | open `.nxvim/config.json` (creating an empty skeleton if absent) |
| `:WorkspaceTemplate {name}` | merge a template into `.nxvim/config.json`, then open it         |
| `:WorkspaceReload`          | re-apply the config from disk (after editing, without a restart) |
| `:WorkspaceTrust`           | trust + apply the config (e.g. after declining the prompt)       |
| `:WorkspaceUntrust`         | forget the trust decision (re-prompts on the next load)          |

`:WorkspaceReload` reports what it actually did — it says "reloaded" only when the config
was applied, and otherwise leaves the missing / untrusted / broken message standing. A
re-apply is idempotent: it clears the autocmds and the save maps the previous apply
installed, so keys never stack and a changed `save_key` doesn't strand the old binding.

**Templates** are ready-made JSON configs kept in your config dir under
`workspace-templates/<name>.json` (each a partial or full `.nxvim/config.json`).
`:WorkspaceTemplate <name>` tab-completes the available names, merges the chosen one into
the project config, validates the result, and writes it back — the JSON twin of copying a
per-workspace rc from a template. Override the templates dir with
`setup({ templates_dir = "…" })`.

The merge is **deep for objects, wholesale for lists**: a template can add a `python`
block without disturbing your `lua` one, and its `save_actions` **replace** the existing
chain rather than being spliced over it entry by entry. Where both sides set the same
scalar, the template wins.

## Behavior notes

- **No config, no problem.** A project without `.nxvim/config.json` is a silent no-op.
- **A broken config fails loud.** Invalid JSON, or a shape the plugin can't honor (a
  non-object `languages`, a `save_action` missing `require`/`method`, …) is reported —
  never silently skipped. Unknown keys are tolerated with a warning (forward-compat), as
  is a filetype claimed by two language blocks (they both wire it; the later block's
  `<C-s>` map wins on the shared buffer).
- **Files open at launch are covered.** The config loads asynchronously, after every
  already-open file's `FileType` has fired; the plugin catches up by walking the whole
  buffer list and applying each language's settings and `<C-s>` map to every loaded
  buffer of that type. That matters in a `--workspace` session, which restores a full
  layout — several buffers are typically open before the config lands, not just one.
- **`.nxvim/config.json` runs code — so it is trust-gated.** It spawns language-server
  commands, runs save actions, and calls the `setup` hook, so the **first** apply of a
  given config prompts (a floating **Trust and apply / Don't trust** popup). The answer is remembered in a local
  store keyed by the file's content hash; a config that **changes** on disk (e.g. after a
  pull) re-prompts. See [Trust](#trust) below.
- **Remote (`--connect-daemon`) sessions work.** The project config lives in the workspace,
  which is remote in a daemon session, so it is read/written through `nx.fs` (the same seam
  that opens the file) at `nx.workspace.dir()`. Templates live in the config dir, which is
  always local to the editor, so they are read through `nx.fs_local` (the local-always
  seam) — never crossing to the daemon. The two seams are identical in a bare/local session.

## Trust

Applying `.nxvim/config.json` executes code (language-server commands, save actions, the
`setup` hook), so opening an unreviewed one from a cloned repo would be a code-execution
vector. The plugin therefore asks before the **first** apply, in a centered modal popup:

```
╭─ nxvim-workspaces — trust this config? ────────────────────╮
│ This workspace wants to apply its config:                  │
│   /path/.nxvim/config.json                                 │
│                                                            │
│ Applying it RUNS CODE — language servers, save             │
│ actions, and the setup hook.                               │
│                                                            │
│   [y] Trust and apply      [N] Don't trust (default)       │
╰────────────────────────────────────────────────────────────╯
```

Only `y` trusts and applies; **anything else** — `n`/`q`/`<Esc>`, or `<CR>` — declines, so
No is the default and trusting is always a deliberate `y`.

- **The answer is remembered**, keyed by the config's absolute path **and a SHA-256 of its
  content**. Trust once and it applies silently thereafter — until the file changes, at
  which point it re-prompts (a pulled-in edit can't slip through on an old decision). A
  declined config is also remembered (it won't nag every launch).
- **The store is local, one file per config, written atomically.** Each config's decision
  is its own file under `stdpath("state")/nxvim-workspaces/trust/` (named by a hash of the
  config's **absolute** path — so the same config reached through a relative path is the
  same record, not a second unprompted one), so unrelated workspaces never contend on a
  shared file; each write goes to a temp file and is renamed into place (atomic on a POSIX
  fs), so a concurrent reader never sees a half-written record, and a failed write takes
  its temp file with it. The directory is created **0700** — these are security decisions,
  not shared state. It is written to the **client's** disk through `nx.fs_local`, so a
  remote daemon can never pre-trust its own config. The gate runs **before** the `setup`
  hook, so nothing from an untrusted config executes.
- `:WorkspaceTrust` trusts + applies the current config (use it after declining, or to
  approve a changed one non-interactively); `:WorkspaceUntrust` forgets the decision.
- To opt out of prompting entirely (trust your own machine), pass `setup({ trust = false })`
  — the config then applies without asking.

## Example

A runnable demo lives in [`examples/`](examples). From the repo root:

```sh
cd examples
NXVIM_CONFIG=. nxvim --workspace . sample.lua
```

`examples/.nxvim/config.json` enables `lua_ls`/`pyright`/`ruff`, sets global number
columns, and gives Lua files a 2-space, format-on-`<C-s>` setup — all as data. The first
launch shows the trust dialog: press `y` to apply it.

## Tests

The plugin carries a Lua test suite (`test/*_spec.lua`) on nxvim's native `nx.test`
framework — config validation, the save-action runner (ordering, promise-await,
write-after-settle, fail-loud), the applier, and an end-to-end pass that loads a real
on-disk config and asserts the wiring. Run them headlessly:

```sh
nxvim --test-plugin .
```

## License

MIT © David Rios
