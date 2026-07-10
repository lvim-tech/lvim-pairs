-- lvim-pairs.cr: the <CR>-between-a-pair behaviour, split out because it is the ONE key another
-- plugin (lvim-cmp) also owns. `M.cr()` is a pure expr helper — it returns the keys to type — so the
-- cmp <CR> mapping can call it as its FALLBACK when no completion is selected (the documented
-- compose order: cmp confirm first, else `pairs.cr()`, else a plain <CR>). When lvim-pairs owns <CR>
-- itself (config.autopairs.map_cr, and cmp absent), `M.setup()` installs the expr map directly.
--
---@module "lvim-pairs.cr"

local api = vim.api

local config = require("lvim-pairs.config")
local defs = require("lvim-pairs.defs")

local M = {}

--- The keys <CR> should type at the cursor: when it sits inside an EMPTY pair (`{|}`), split the
--- delimiters onto their own lines with an indented blank line between (`{\n  |\n}`) via `<CR><Esc>O`
--- (autoindent/indentexpr places the cursor); otherwise a plain `<CR>`. Pure — safe for cmp to call.
---@return string
function M.cr()
    local pos = api.nvim_win_get_cursor(0)
    local col = pos[2]
    local line = api.nvim_get_current_line()
    local before = col > 0 and line:sub(col, col) or ""
    local after = line:sub(col + 1, col + 1)
    local def = defs.for_open(before)
    if def and def.close ~= "" and after == def.close then
        return "<CR><Esc>O"
    end
    return "<CR>"
end

--- Install lvim-pairs' own <CR> expr map — ONLY when `map_cr` is on. Skip it if lvim-cmp is present:
--- cmp owns <CR>, and its mapping is expected to fall back to `M.cr()` (see README handshake), so a
--- second map here would fight it. A user who wants pairs to own <CR> regardless can force it off cmp.
---@return nil
function M.setup()
    if not config.autopairs.enabled or not config.autopairs.map_cr then
        return
    end
    if pcall(require, "lvim-cmp") then
        return -- cmp owns <CR>; it calls M.cr() as its fallback
    end
    vim.keymap.set("i", "<CR>", M.cr, {
        expr = true,
        replace_keycodes = true,
        silent = true,
        desc = "lvim-pairs: newline between an empty pair",
    })
end

return M
