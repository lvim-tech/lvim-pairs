# lvim-pairs

Everything "paired delimiters" for the **lvim-tech** set in one plugin, sharing **one**
pair-definition table: insert-mode **auto-pairing**, normal/visual **surround** operators, and
treesitter-driven HTML/JSX **tag auto-close + auto-rename**. Three independently toggleable modules
that read the same `defs`, so a pair you add once works in all of them.

- **autopairs** — open inserts the pair (cursor inside), a close skips over an existing one, quotes
  decide open / skip / literal by context (escape, contraction, treesitter string), `<BS>` deletes an
  empty pair, `<Space>` pads it, `<CR>` drops the close onto its own indented line, and **fastwrap**
  relocates the close around a labeled span.
- **surround** — `ys{motion}{char}` / `yss` / visual `S` add, `ds` delete, `cs` change; brackets and
  quotes plus treesitter `t` (tag) and `f` (function call); dot-repeatable; added/changed delimiters
  flash green.
- **autotag** — typing `>` closes an open HTML/JSX tag, `</` completes the nearest one, and editing a
  tag name renames its partner live.

Pairing decisions consult **lvim-ts** (the treesitter node at the cursor): a quote will not pair
inside a string or comment. Without a parser the check degrades to off (pairs anyway) — never an
error. The `t`/`f` surrounds prompt for a name through the canonical **lvim-ui** input.

## Requirements

Requires **Neovim >= 0.10** and [lvim-utils](https://github.com/lvim-tech/lvim-utils) (the palette +
the shared merge). [lvim-ts](https://github.com/lvim-tech/lvim-ts) provisions the treesitter parsers
the quote-context check, autotag and the `t`/`f` surrounds rely on;
[lvim-ui](https://github.com/lvim-tech/lvim-ui) provides the tag/function name prompt.

## Installation

### lvim-installer (recommended)

```vim
:LvimInstaller plugins
```

lvim-installer installs plugins through Neovim's built-in `vim.pack`, so no external plugin manager
is needed.

### Native (vim.pack)

```lua
vim.pack.add({
    { src = "https://github.com/lvim-tech/lvim-utils" },
    { src = "https://github.com/lvim-tech/lvim-pairs" },
})
require("lvim-pairs").setup({})
```

## Autopairs

Global insert-mode behaviour, one expr map per delimiter (nothing intercepts every keystroke):

| You type | Result |
| --- | --- |
| `(` before whitespace/EOL | `(` + `)`, cursor inside |
| `(` before a word | just `(` (no noise around existing text) |
| `)` at `(\|)` | steps over the `)` |
| `"` at `"\|"` | steps over the closing quote |
| `"` after a word / `\` / inside a string | a literal `"` (no pair) |
| `<BS>` at `(\|)` | deletes both — and both spaces of `( \| )` |
| `<Space>` at `(\|)` | pads to `( \| )` |
| `<CR>` at `{\|}` | splits to `{` ⏎ indented ⏎ `}` |
| `<M-e>` at `(\|)word next` | fastwrap: pick a labeled end, the `)` hops there |

`<` / `>` auto-pair **only** in generic-type languages (`rust`, `cpp`, `java`, `cs`, `scala`, `kotlin`),
where angle brackets are a delimiter. Everywhere else `<` is a comparison operator, so it stays a lone
`<` (no phantom `>`). It is deliberately **not** paired in the tag filetypes — there **autotag** owns
angle brackets (typing `>` closes the tag), so an autopaired `<>` would collide. A pair carries this
gate as `ft_allow` (pair only in these filetypes) / `ft_deny` (never in these); `<` remains a
**surround** target (`ys…<`, `ds<`) in every filetype regardless.

### The `<CR>` handshake with lvim-cmp

`<CR>` between a pair and `<CR>` confirming a completion are the same key. When **lvim-cmp** is
present, lvim-pairs does **not** map `<CR>` — cmp owns it and calls `require("lvim-pairs").cr()` as
its fallback (confirm a selection first, else the pairs newline, else a plain `<CR>`):

```lua
-- in the lvim-cmp <CR> mapping
if cmp.visible() and cmp.get_selected_entry() then
    cmp.confirm()
else
    return require("lvim-pairs").cr() -- expr string: pair-aware newline, or a plain <CR>
end
```

Without lvim-cmp, lvim-pairs maps `<CR>` itself (`autopairs.map_cr`).

## Surround

Normal and visual operators, all `<Plug>`-backed and dot-repeatable:

| Key | Action |
| --- | --- |
| `ys{motion}{char}` | surround the motion with `char` |
| `yss{char}` | surround the current line |
| `S{char}` (visual) | surround the selection |
| `ds{char}` | delete the surrounding `char` |
| `cs{old}{new}` | change surround `old` → `new` |

`{char}` is a delimiter or an alias: `(` `)` `b` → `()`, `{` `}` `B` → `{}`, `[` `]`, `<` `>` `a`,
`"` `'` `` ` ``, plus **`t`** (an HTML tag — prompts for the name, `<name>…</name>`) and **`f`** (a
function call — prompts for the name, `name(…)`). `dst` / `cst` operate on the enclosing tag via
treesitter (rename both sides); `dsf` / `csf` on the enclosing call. Added and changed delimiters
flash green (`LvimPairsFlash`) for ~120 ms.

## Autotag

In the configured filetypes (html, jsx/tsx, vue, svelte, astro, xml, php, markdown, …):

- Type `>` completing `<div>` → `</div>` is inserted after the cursor.
- Type `/` right after `<` → the nearest open tag's name completes the close.
- Edit either tag name → its partner is renamed live (debounced, treesitter-driven).

Void elements (`br`, `img`, `input`, …) and self-closing tags are never auto-closed.

## Default configuration

The full default `setup()` options, kept in sync with `lua/lvim-pairs/config.lua`:

```lua
require("lvim-pairs").setup({
    -- insert-mode auto-pairing
    autopairs = {
        enabled = true,
        fastwrap = "<M-e>", -- "" disables
        map_cr = true, -- ignored when lvim-cmp is present (it owns <CR>)
        map_bs = true,
        -- filetypes where auto-pairing yields the plain key (prompt / query buffers)
        disable_filetype = { "TelescopePrompt", "spectre_panel", "lvim-picker-prompt" },
    },
    -- normal/visual surround operators (ys / yss / S / ds / cs)
    surround = {
        enabled = true,
        flash_ms = 120, -- how long the added/changed delimiters flash
    },
    -- HTML/JSX tag auto-close + auto-rename
    autotag = {
        enabled = true,
        filetypes = {
            "html",
            "xml",
            "javascriptreact",
            "typescriptreact",
            "javascript",
            "typescript",
            "vue",
            "svelte",
            "astro",
            "markdown",
            "php",
            "xhtml",
            "rescript",
        },
    },
    -- consult treesitter (node at cursor) before pairing a quote — off = always pair
    ts_checks = true,
    -- extra user pairs, each { open, close, quote?, space_pad?, ts_not_in?, ft_allow?, ft_deny?,
    -- surround?, aliases? }, merged over the built-ins by `open`
    pairs = {},
})
```

Each module registers nothing while its `enabled` is `false`. A user pair with the same `open` as a
built-in replaces it; a new `open` is appended and becomes available to every engine at once.

## Health

`:checkhealth lvim-pairs` reports the treesitter / lvim-ui / lvim-utils dependency state, each
module's status, and whether the surround keys (`ys` / `ds` / `cs`) still resolve to lvim-pairs.

## License

BSD-3-Clause © lvim-tech
