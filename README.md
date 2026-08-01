# nxvim-workspaces

Per-project editor configuration for [nxvim](https://github.com/davidrios/nxvim),
declared as a committable **`.nxvim/config.json`** instead of hand-written rc Lua.

Drop a `.nxvim/config.json` at the root of a project and nxvim-workspaces applies it on
start: it enables the project's **language servers**, wires a **`<C-s>` save-actions**
map per language (format / fix / write), and sets **vim options** — globally and
per-filetype. It is the declarative twin of the little per-workspace rc files you'd
otherwise write by hand.

```json
{
  "languages": {
    "python": {
      "lsps": { "basedpyright": {}, "ruff": {} },
      "save_actions": [
        {
          "require": "nx.lsp",
          "method": "code_action",
          "params": { "context": { "only": ["source.fixAll"] }, "apply": true }
        },
        { "require": "nx.lsp", "method": "format" }
      ],
      "settings": { "tabstop": 4, "shiftwidth": 4 }
    }
  },
  "settings": { "number": true, "relativenumber": true }
}
```

It is built entirely on the documented `nx.*` API — `nx.fs` (async config read),
`nx.json`, `nx.lsp`, `nx.autocmd`, `nx.keymap`, `vim.o`. There is **no neovim
compatibility layer**; nothing blocks and nothing is intercepted.

> **This is a workspace feature.** It only acts in a `--workspace` session (`nxvim
> --workspace [dir]`), reading `<workspace-root>/.nxvim/config.json`. In a bare editor it
> does nothing. (Force it anyway with an explicit `setup({ path = "…" })`.)

> **`.nxvim/config.json` runs code, so it is trust-gated.** The first apply of a given
> config prompts; the answer is remembered per path + content hash. See Trust in the
> docs.

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
automatically. Call `require("nxvim-workspaces").setup({ ... })` yourself only to
override the defaults (config path, save key, templates dir, trust).

## Documentation

Full docs — the complete `.nxvim/config.json` schema (`languages`, `save_actions`,
`settings`, the async `setup` hook), the `:Workspace*` commands, templates, the trust
model, every `setup()` option, and the module API — live in the help file. The same
source renders both on GitHub and in the editor:

- In editor: `:help nxvim-workspaces`
- On GitHub: [doc/nxvim-workspaces.md](./doc/nxvim-workspaces.md) (the help source)

## Trying it locally

```sh
cd examples
NXVIM_CONFIG=. nxvim --workspace . sample.lua
```

`examples/.nxvim/config.json` enables `lua_ls`/`pyright`/`ruff`, sets global number
columns, and gives Lua files a 2-space, format-on-`<C-s>` setup — all as data. The first
launch shows the trust dialog: press `y` to apply it.

## Development

```sh
nxvim --test-plugin .
```

The suite covers config validation, the save-action runner (ordering, promise-await,
write-after-settle, fail-loud), the applier, templates, trust, and an end-to-end pass
that loads a real on-disk config and asserts the wiring.

The vimdoc `doc/nxvim-workspaces.txt` is **generated** from `doc/nxvim-workspaces.md` via
[panvimdoc](https://github.com/kdheepak/panvimdoc): edit the `.md`, then run
`bash scripts/gen-vimdoc.sh` (needs `pandoc` + `git`). Never edit the `.txt` by hand — a
pre-push hook regenerates it and refuses a stale one.

## License

MIT © David Rios
