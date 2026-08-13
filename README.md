# bemtvi-workspaces

Per-project editor configuration for [bemtvi](https://github.com/bemtvi/bemtvi),
declared as a committable **`.bemtvi/config.json`** instead of hand-written rc Lua.

Drop a `.bemtvi/config.json` at the root of a project and bemtvi-workspaces applies it on
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
          "require": "btv.lsp",
          "method": "code_action",
          "params": { "context": { "only": ["source.fixAll"] }, "apply": true }
        },
        { "require": "btv.lsp", "method": "format" }
      ],
      "settings": { "tabstop": 4, "shiftwidth": 4 }
    }
  },
  "settings": { "number": true, "relativenumber": true }
}
```

It is built entirely on the documented `btv.*` API — `btv.fs` (async config read),
`btv.json`, `btv.lsp`, `btv.autocmd`, `btv.keymap`, `vim.o`. There is **no neovim
compatibility layer**; nothing blocks and nothing is intercepted.

> **This is a workspace feature.** It only acts in a `--workspace` session (`bemtvi
> --workspace [dir]`), reading `<workspace-root>/.bemtvi/config.json`. In a bare editor it
> does nothing. (Force it anyway with an explicit `setup({ path = "…" })`.)

> **`.bemtvi/config.json` runs code, so it is trust-gated.** The first apply of a given
> config prompts; the answer is remembered per path + content hash. See Trust in the
> docs.

> This plugin only *configures* language servers — it does not install them. Install the
> server binaries yourself. A missing binary fails **loud** (bemtvi never pretends a
> server that isn't there is working).

## Install

Declare it with the built-in `:Plugins` manager in your `init.lua`:

```lua
btv.plugins({
  {
    "bemtvi/bemtvi-workspaces",
    -- Supplies the `lsp/<name>.lua` presets a config's server NAMES resolve against.
    dependencies = { "bemtvi/bemtvi-lspconfig" },
  },
})
```

Run `:PluginSync` to clone them. That's all the setup there is: from then on, opening a
project as a workspace (`bemtvi --workspace [dir]`) applies its `.bemtvi/config.json`
automatically. Call `require("bemtvi-workspaces").setup({ ... })` yourself only to
override the defaults (config path, save key, templates dir, trust).

## Documentation

Full docs — the complete `.bemtvi/config.json` schema (`languages`, `save_actions`,
`settings`, the async `setup` hook), the `:Workspace*` commands, templates, the trust
model, every `setup()` option, and the module API — live in the help file. The same
source renders both on GitHub and in the editor:

- In editor: `:help bemtvi-workspaces`
- On GitHub: [doc/bemtvi-workspaces.md](./doc/bemtvi-workspaces.md) (the help source)

## Trying it locally

```sh
cd examples
BEMTVI_CONFIG=. bemtvi --workspace . sample.lua
```

`examples/.bemtvi/config.json` enables `lua_ls`/`pyright`/`ruff`, sets global number
columns, and gives Lua files a 2-space, format-on-`<C-s>` setup — all as data. The first
launch shows the trust dialog: press `y` to apply it.

## Development

```sh
bemtvi --test-plugin .
```

The suite covers config validation, the save-action runner (ordering, promise-await,
write-after-settle, fail-loud), the applier, templates, trust, and an end-to-end pass
that loads a real on-disk config and asserts the wiring.

The vimdoc `doc/bemtvi-workspaces.txt` is **generated** from `doc/bemtvi-workspaces.md` via
[panvimdoc](https://github.com/kdheepak/panvimdoc): edit the `.md`, then run
`bash scripts/gen-vimdoc.sh` (needs `pandoc` + `git`). Never edit the `.txt` by hand — a
pre-push hook regenerates it and refuses a stale one.

## License

MIT © David Rios
