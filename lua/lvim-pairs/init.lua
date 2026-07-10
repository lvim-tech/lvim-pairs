-- lvim-pairs: everything "paired delimiters" in one plugin sharing ONE pair-definition table —
-- insert-mode auto-pairing (module `auto`/`cr`), normal/visual surround operators (module
-- `surround`), and treesitter-driven HTML/JSX tag auto-close + auto-rename (module `tags`). This is
-- the public entry point: setup() merges user opts into the live config, rebuilds the shared `defs`
-- (so config.pairs reach all three engines), self-themes the flash + fastwrap-hint from the
-- lvim-utils palette, and starts each ENABLED module. `M.cr` is re-exported so the lvim-cmp <CR>
-- mapping can call it as its fallback (the documented handshake — see the README).
--
---@module "lvim-pairs"

local config = require("lvim-pairs.config")
local defs = require("lvim-pairs.defs")

-- shared merge (clean array REPLACE) when lvim-utils is installed; the fallback keeps the same
-- semantics so a user pair list always replaces the default wholesale.
local ok_utils, uu = pcall(require, "lvim-utils.utils")

local M = {}

---@type boolean  one-time registration (module maps, highlight bind) done
local registered = false

--- Array-replacing deep merge (mirrors lvim-utils.utils.merge) for a standalone install.
---@param target table
---@param opts? table
---@return table target
local function merge(target, opts)
    for k, v in pairs(opts or {}) do
        if type(v) == "table" and type(target[k]) == "table" and not vim.islist(v) then
            merge(target[k], v)
        else
            target[k] = v
        end
    end
    return target
end

--- Self-theme LvimPairsFlash + LvimPairsHint from the lvim-utils palette (re-derived on ColorScheme
--- / palette sync); plain links keep them visible without lvim-utils.
---@return nil
local function set_highlights()
    local ok_hl, hl = pcall(require, "lvim-utils.highlight")
    if ok_hl and type(hl.bind) == "function" then
        hl.bind(require("lvim-pairs.highlights").build)
    else
        vim.api.nvim_set_hl(0, "LvimPairsFlash", { link = "IncSearch", default = true })
        vim.api.nvim_set_hl(0, "LvimPairsHint", { link = "Search", default = true })
    end
end

--- The <CR>-between-a-pair expr helper, re-exported for the lvim-cmp <CR> fallback handshake.
---@return string
function M.cr()
    return require("lvim-pairs.cr").cr()
end

--- Configure and start. Idempotent: a second call re-merges config and rebuilds `defs`, but the
--- module maps and highlight bind are installed once (matching the lvim-tech registered-once pattern).
---@param opts? LvimPairsConfig
---@return nil
function M.setup(opts)
    opts = opts or {}
    if ok_utils then
        uu.merge(config, opts)
    else
        merge(config, opts)
    end
    defs.rebuild() -- fold config.pairs into the shared definition table BEFORE the engines read it
    if registered then
        return
    end
    registered = true
    set_highlights()
    require("lvim-pairs.auto").setup()
    require("lvim-pairs.cr").setup()
    require("lvim-pairs.surround").setup()
    require("lvim-pairs.tags").setup()
end

return M
