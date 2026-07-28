-- lvim-pairs.config: the live configuration table for the three paired-delimiter engines
-- (autopairs / surround / autotag). setup() merges user overrides into THIS table in place, so
-- every require("lvim-pairs.config") reader sees the effective values — the modules read `enabled`
-- flags live, so the control center can flip a module without a restart. Each module registers
-- nothing while its `enabled` is false at setup time.
--
---@module "lvim-pairs.config"

---@class LvimPairsAutopairs
---@field enabled          boolean   Insert-mode auto-pairing (open inserts the pair, close skips over it)
---@field fastwrap         string    Key that wraps the next word/til-end in the just-typed pair ("" disables)
---@field map_cr           boolean   Map <CR> so a newline between an empty pair drops the close onto its own line
---@field map_bs           boolean   Map <BS> so deleting the open of an empty pair deletes the close too
---@field disable_filetype string[]  Filetypes where auto-pairing yields the plain key (prompt/query buffers)

---@class LvimPairsSurround
---@field enabled boolean  Normal/visual surround operators (ys / ds / cs / S)
---@field flash_ms integer  how long (ms) the LvimPairsFlash surround-highlight stays on

---@class LvimPairsAutotag
---@field enabled   boolean   Auto-close and auto-rename HTML/JSX/XML tags (needs a treesitter parser)
---@field filetypes string[]  Filetypes the tag engine attaches to

---@class LvimPairsConfig
---@field autopairs LvimPairsAutopairs
---@field surround  LvimPairsSurround
---@field autotag   LvimPairsAutotag
---@field ts_checks boolean          Consult lvim-ts (node at cursor) before pairing/closing — off = always pair
---@field pairs     LvimPairsDef[]    Extra user pair definitions, merged over the built-in `defs`

---@type LvimPairsConfig
return {
    -- Insert-mode auto-pairing. `fastwrap` wraps the NEXT word (or til end of line) in the pair you
    -- just opened — candidate spots are hinted with single-char labels, you pick one (getcharstr).
    autopairs = {
        enabled = true,
        fastwrap = "<M-e>",
        map_cr = true,
        map_bs = true,
        -- Prompt / query buffers where a typed opener must stay a lone character. Only lvim-tech
        -- filetypes: this plugin ships no knowledge of other ecosystems' prompts.
        disable_filetype = { "lvim-picker-prompt" },
    },
    -- Normal/visual surround operators: `ys{motion}{char}` add, `yss` line, visual `S{char}`,
    -- `ds{char}` delete, `cs{old}{new}` change. All dot-repeatable via the native operatorfunc seam.
    surround = {
        enabled = true,
        flash_ms = 120,
    },
    -- HTML/JSX tag auto-close on `>` and auto-RENAME (editing one side renames the other). Needs a
    -- treesitter parser for the buffer (provisioned by lvim-ts in the lvim-tech set).
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
    -- Consult lvim-ts (the node type at the cursor) before pairing a quote or closing a tag — so a
    -- quote does not pair inside a string/comment, etc. Without lvim-ts the check degrades to OFF
    -- (pairs always), never to an error.
    ts_checks = true,
    -- Extra user pairs, each an `LvimPairsDef` (see defs.lua), merged OVER the built-ins by `open`.
    pairs = {},
}
