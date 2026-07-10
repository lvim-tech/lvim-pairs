-- lvim-pairs.auto: module 1 — insert-mode auto-pairing. The clean, inspectable seam is one
-- per-key INSERT-MODE EXPR mapping generated from `defs` (no global InsertCharPre interception): the
-- mapping's function inspects the cursor context and RETURNS the keys to type, so every decision is a
-- pure function of (char before, char after, treesitter node) and nothing is fed behind the editor's
-- back. Open inserts the pair with the cursor inside; a close skips over an existing one; a quote
-- decides open / skip / literal by context; <BS> deletes an empty pair (and its space padding); a
-- padded pair grows a matching space on <Space>. Global maps — auto-pairing is not per buffer; a
-- per-def `ft_deny`/`ts_not_in` gate handles the exceptions.
--
---@module "lvim-pairs.auto"

local api = vim.api

local config = require("lvim-pairs.config")
local defs = require("lvim-pairs.defs")
local ts = require("lvim-pairs.ts")

local M = {}

--- Single-char labels offered for fastwrap targets, in preference order (home row first).
local FASTWRAP_LABELS = "asdghklqwertyuiopzxcvbnmfj"

--- The cursor context an expr decision reads: the buffer, 0-based row + byte col, the line, and the
--- single char immediately BEFORE and AFTER the cursor ("" at the line ends).
---@return { bufnr: integer, row: integer, col: integer, line: string, before: string, after: string }
local function ctx()
    local pos = api.nvim_win_get_cursor(0)
    local row, col = pos[1] - 1, pos[2]
    local line = api.nvim_get_current_line()
    return {
        bufnr = api.nvim_get_current_buf(),
        row = row,
        col = col,
        line = line,
        before = col > 0 and line:sub(col, col) or "",
        after = line:sub(col + 1, col + 1),
    }
end

--- A char is "word-like" (alnum, underscore, or a multibyte lead byte) — pairing avoids gluing a
--- delimiter onto such a char (a bracket before a word, a quote in a contraction).
---@param ch string
---@return boolean
local function wordish(ch)
    return ch ~= "" and ch:match("[%w_\128-\255]") ~= nil
end

--- Whether auto-pairing is suppressed in the current buffer (a prompt/query filetype). The expr
--- decisions fall back to the literal key here, so a typed `(` in a picker prompt stays a lone `(`.
---@return boolean
local function denied()
    return vim.tbl_contains(config.autopairs.disable_filetype or {}, vim.bo.filetype)
end

--- Open-bracket decision: insert the PAIR (cursor inside) unless the next char is word-like — then a
--- lone open, so `(word` does not become `(word)` noise around existing text.
---@param def LvimPairsDef
---@return fun(): string
local function open_expr(def)
    return function()
        if denied() then
            return def.open
        end
        local c = ctx()
        if wordish(c.after) then
            return def.open
        end
        return def.open .. def.close .. "<Left>"
    end
end

--- Close-bracket decision: SKIP over an already-present close (so typing `)` at `(|)` steps past it),
--- else insert the close literally.
---@param def LvimPairsDef
---@return fun(): string
local function close_expr(def)
    return function()
        if denied() then
            return def.close
        end
        local c = ctx()
        if c.after == def.close then
            return "<Right>"
        end
        return def.close
    end
end

--- Quote decision: skip an existing same quote; stay LITERAL when escaped (`\`), glued to a word (a
--- contraction), or inside a string/comment per treesitter; otherwise open the pair.
---@param def LvimPairsDef
---@return fun(): string
local function quote_expr(def)
    return function()
        if denied() then
            return def.open
        end
        local c = ctx()
        local q = def.open
        if c.after == q then
            return "<Right>"
        end
        if c.before == "\\" then
            return q
        end
        if wordish(c.before) then
            return q
        end
        if def.ts_not_in and ts.in_types(c.bufnr, c.row, c.col, def.ts_not_in) then
            return q
        end
        return q .. q .. "<Left>"
    end
end

--- <BS> decision: delete BOTH sides of an empty pair (`(|)` → ``), and both spaces of a padded pair
--- (`( | )` → `(|)`); otherwise a plain backspace.
---@return string
local function bs_expr()
    if denied() then
        return "<BS>"
    end
    local c = ctx()
    local def = defs.for_open(c.before)
    if def and c.after == def.close then
        return "<BS><Del>"
    end
    if c.before == " " and c.after == " " then
        local b2 = c.col >= 2 and c.line:sub(c.col - 1, c.col - 1) or ""
        local a2 = c.line:sub(c.col + 2, c.col + 2)
        local d = defs.for_open(b2)
        if d and d.space_pad and a2 == d.close then
            return "<BS><Del>"
        end
    end
    return "<BS>"
end

--- <Space> decision: grow a matching trailing space when the cursor sits inside a padded pair
--- (`(|)` → `( | )`); otherwise a plain space.
---@return string
local function space_expr()
    if denied() then
        return " "
    end
    local c = ctx()
    local def = defs.for_open(c.before)
    if def and def.space_pad and c.after == def.close then
        return "  <Left>"
    end
    return " "
end

--- Install one INSERT-mode expr map; expr maps replace keycodes in the returned string, so `<Left>`
--- etc. resolve. Overwrites are intentional (a fresh setup re-registers the same lhs).
---@param lhs string
---@param rhs fun(): string
local function imap(lhs, rhs)
    vim.keymap.set("i", lhs, rhs, { expr = true, replace_keycodes = true, silent = true, desc = "lvim-pairs" })
end

-- ── fastwrap ────────────────────────────────────────────────────────────────
-- After the auto-inserted pair (cursor at `(|)`), fastwrap moves the CLOSE to the end of a chosen
-- word ahead on the line: candidate end positions get a single-char LABEL extmark (LvimPairsHint),
-- the user picks one with getcharstr, and the close hops there — wrapping that span. ESC / no
-- candidate cancels (the close stays put).

local ns = api.nvim_create_namespace("lvim-pairs-fastwrap")

--- End-of-word byte columns ahead of the cursor on the current line (after each run of word chars),
--- plus end-of-line — the fastwrap candidate targets.
---@param line string
---@param from integer  0-based byte col to search after
---@return integer[]  0-based byte cols (the position the close would move BEFORE)
local function wrap_targets(line, from)
    local out = {}
    local i = from + 1
    while i <= #line do
        local s, e = line:find("[%w_\128-\255]+", i)
        if not s then
            break
        end
        out[#out + 1] = e -- byte col AFTER the word (0-based == e, since e is 1-based last char)
        i = e + 1
    end
    out[#out + 1] = #line
    -- dedup consecutive equal targets
    local seen, uniq = {}, {}
    for _, c in ipairs(out) do
        if not seen[c] then
            seen[c] = true
            uniq[#uniq + 1] = c
        end
    end
    return uniq
end

--- Fastwrap: relocate the just-opened pair's close to a labeled target ahead on the line.
---@return nil
function M.fastwrap()
    local c = ctx()
    local def = defs.for_open(c.before)
    if not (def and c.after == def.close) then
        return -- not sitting inside a fresh pair — nothing to wrap
    end
    local targets = wrap_targets(c.line, c.col)
    if #targets == 0 then
        return
    end
    local labels = FASTWRAP_LABELS
    local by_label, order = {}, {}
    for i, tcol in ipairs(targets) do
        local lbl = labels:sub(i, i)
        if lbl == "" then
            break
        end
        by_label[lbl] = tcol
        order[#order + 1] = { col = tcol, label = lbl }
    end
    api.nvim_buf_clear_namespace(c.bufnr, ns, c.row, c.row + 1)
    for _, t in ipairs(order) do
        pcall(api.nvim_buf_set_extmark, c.bufnr, ns, c.row, math.min(t.col, #c.line), {
            virt_text = { { t.label, "LvimPairsHint" } },
            virt_text_pos = "overlay",
            priority = 1000,
        })
    end
    vim.cmd("redraw")
    local ok, ch = pcall(vim.fn.getcharstr)
    api.nvim_buf_clear_namespace(c.bufnr, ns, c.row, c.row + 1)
    if not ok or not by_label[ch] then
        vim.cmd("redraw")
        return
    end
    local dest = by_label[ch]
    -- remove the auto close at the cursor, re-insert it at the destination, keep the cursor after open
    local line = api.nvim_get_current_line()
    local without = line:sub(1, c.col) .. line:sub(c.col + 2) -- drop the close right after the cursor
    local wrapped = without:sub(1, dest - 1) .. def.close .. without:sub(dest)
    api.nvim_set_current_line(wrapped)
    api.nvim_win_set_cursor(0, { c.row + 1, c.col })
    vim.cmd("redraw")
end

--- Register the module-1 insert-mode maps from `defs` (open / close / quote) plus <BS> / <Space> /
--- fastwrap per config. No-op when autopairs is disabled.
---@return nil
function M.setup()
    if not config.autopairs.enabled then
        return
    end
    for _, def in ipairs(defs.all()) do
        if def.open ~= "" and not def.prompt then
            if def.quote then
                imap(def.open, quote_expr(def))
            else
                imap(def.open, open_expr(def))
                if def.close ~= def.open then
                    imap(def.close, close_expr(def))
                end
            end
        end
    end
    if config.autopairs.map_bs then
        imap("<BS>", bs_expr)
    end
    imap("<Space>", space_expr)
    local fw = config.autopairs.fastwrap
    if type(fw) == "string" and fw ~= "" then
        vim.keymap.set("i", fw, M.fastwrap, { silent = true, desc = "lvim-pairs: fastwrap the next span" })
    end
end

return M
