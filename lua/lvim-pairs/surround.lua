-- lvim-pairs.surround: module 2 — the normal/visual surround operators (add `ys`/`yss`/visual `S`,
-- delete `ds`, change `cs`). Everything rides ONE native seam: a normal-mode expr trigger stashes the
-- action, arms 'operatorfunc' and returns `g@`/`g@l`, so `.` replays the exact operation with no
-- repeat.vim and no feedkeys — the opfunc re-reads the stash and REUSES the cached surround char /
-- prompted name on a repeat (it only reads fresh input when the trigger set `read`). Bracket targets
-- resolve via searchpair, quotes by scanning the line, and `t`(tag)/`f`(func) via treesitter; the
-- prompted `t`/`f` names come from `lvim-ui.input` (async — the wrap runs in its callback). Added or
-- changed delimiters flash briefly (LvimPairsFlash), the lvim-cycle confirmation pattern.
--
---@module "lvim-pairs.surround"

local api = vim.api
local fn = vim.fn

local config = require("lvim-pairs.config")
local defs = require("lvim-pairs.defs")
local ts = require("lvim-pairs.ts")

local M = {}

local ns = api.nvim_create_namespace("lvim-pairs-surround-flash")
---@type uv.uv_timer_t|nil
local flash_timer = nil

--- Treesitter node types denoting a function/method CALL across the common grammars — the `f`
--- surround target (name + parentheses around arguments).
local CALL_TYPES = {
    call_expression = true,
    call = true,
    function_call = true,
    method_invocation = true,
    macro_invocation = true,
    invocation_expression = true,
}

--- The dot-repeat stash. `read` is true only when a fresh trigger armed the op; on `.` the opfunc
--- re-runs with `read` false and reuses `def`/`new_def`/`cached`, so no input is re-read.
---@type { action: string?, read: boolean, def: LvimPairsDef?, new_def: LvimPairsDef?, cached: string? }
local S = { action = nil, read = false }

-- ── flash ────────────────────────────────────────────────────────────────────

--- Briefly tint a single-line span [scol, ecol) on `row` (0-based) with LvimPairsFlash. One shared
--- one-shot timer clears every pending flash — a wrap tints two delimiters with one sweep.
---@param buf integer
---@param row integer
---@param scol integer
---@param ecol integer
---@return nil
local function flash(buf, row, scol, ecol)
    if ecol <= scol then
        return
    end
    pcall(api.nvim_buf_set_extmark, buf, ns, row, scol, { end_col = ecol, hl_group = "LvimPairsFlash", priority = 500 })
    if not flash_timer then
        flash_timer = assert(vim.uv.new_timer())
    end
    flash_timer:stop()
    flash_timer:start(
        config.surround.flash_ms,
        0,
        vim.schedule_wrap(function()
            if api.nvim_buf_is_valid(buf) then
                api.nvim_buf_clear_namespace(buf, ns, 0, -1)
            end
        end)
    )
end

-- ── input ──────────────────────────────────────────────────────────────────--

--- Prompt for a name through the canonical lvim-ui input (never vim.fn.input); `done(value)` runs
--- with the trimmed non-empty value, or not at all on cancel/empty. Falls back to a notify when
--- lvim-ui is somehow absent (the plugin still loads).
---@param title string
---@param done fun(value: string)
---@return nil
local function prompt(title, done)
    local ok, ui = pcall(require, "lvim-ui")
    if not ok then
        vim.notify("lvim-pairs: lvim-ui required for tag/function surrounds", vim.log.levels.WARN)
        return
    end
    ui.input({
        title = title,
        callback = function(confirmed, value)
            value = confirmed and vim.trim(value or "") or ""
            if value ~= "" then
                done(value)
            end
        end,
    })
end

-- ── ranges ───────────────────────────────────────────────────────────────────

--- The operated range from the `'[` / `']` marks (charwise inclusive → exclusive end); for a
--- linewise motion, the whole span of lines.
---@param motion string  "char"|"line"|"block"
---@return { srow: integer, scol: integer, erow: integer, ecol: integer }
local function marks_range(motion)
    local sp = api.nvim_buf_get_mark(0, "[")
    local ep = api.nvim_buf_get_mark(0, "]")
    local srow, scol, erow, ecol = sp[1] - 1, sp[2], ep[1] - 1, ep[2]
    if motion == "line" then
        scol = 0
        ecol = #(api.nvim_buf_get_lines(0, erow, erow + 1, false)[1] or "")
    else
        ecol = ecol + 1
    end
    return { srow = srow, scol = scol, erow = erow, ecol = ecol }
end

--- The current line's content span (first non-blank byte → end) — the `yss` target.
---@return { srow: integer, scol: integer, erow: integer, ecol: integer }
local function line_range()
    local row = api.nvim_win_get_cursor(0)[1] - 1
    local line = api.nvim_get_current_line()
    local first = line:find("%S")
    return { srow = row, scol = (first or 1) - 1, erow = row, ecol = #line }
end

--- The visual selection span (from the `'<` / `'>` marks), end made exclusive.
---@return { srow: integer, scol: integer, erow: integer, ecol: integer }
local function visual_range()
    local sp = api.nvim_buf_get_mark(0, "<")
    local ep = api.nvim_buf_get_mark(0, ">")
    local erow = ep[1] - 1
    local elen = #(api.nvim_buf_get_lines(0, erow, erow + 1, false)[1] or "")
    return { srow = sp[1] - 1, scol = sp[2], erow = erow, ecol = math.min(ep[2] + 1, elen) }
end

-- ── add ──────────────────────────────────────────────────────────────────────

--- Resolve the open/close delimiter STRINGS for a surround def, prompting for `t`/`f` (reusing a
--- cached name on repeat). Calls `done(open, close)` when ready — synchronously for plain pairs,
--- after the input callback for prompted ones.
---@param def LvimPairsDef
---@param done fun(open: string, close: string)
---@return nil
local function resolve_delims(def, done)
    if def.prompt == "tag" then
        if S.cached then
            return done("<" .. S.cached .. ">", "</" .. S.cached .. ">")
        end
        prompt("Tag name", function(name)
            S.cached = name
            done("<" .. name .. ">", "</" .. name .. ">")
        end)
    elseif def.prompt == "func" then
        if S.cached then
            return done(S.cached .. "(", ")")
        end
        prompt("Function name", function(name)
            S.cached = name
            done(name .. "(", ")")
        end)
    else
        done(def.open, def.close)
    end
end

--- Wrap [srow,scol .. erow,ecol) with `open`/`close`, inserting the CLOSE first so the open insertion
--- does not shift the recorded close position, then flash both delimiters.
---@param buf integer
---@param r { srow: integer, scol: integer, erow: integer, ecol: integer }
---@param open string
---@param close string
---@return nil
local function apply_add(buf, r, open, close)
    api.nvim_buf_set_text(buf, r.erow, r.ecol, r.erow, r.ecol, { close })
    api.nvim_buf_set_text(buf, r.srow, r.scol, r.srow, r.scol, { open })
    flash(buf, r.srow, r.scol, r.scol + #open)
    local cshift = (r.srow == r.erow) and #open or 0
    flash(buf, r.erow, r.ecol + cshift, r.ecol + cshift + #close)
    api.nvim_win_set_cursor(0, { r.srow + 1, r.scol })
end

-- ── find (for delete / change) ─────────────────────────────────────────────--

--- Enclosing bracket pair for `def` around the cursor via searchpair, or nil.
---@param def LvimPairsDef
---@return { o_row: integer, o_col: integer, o_len: integer, c_row: integer, c_col: integer, c_len: integer }|nil
local function find_bracket(def)
    local o = fn.escape(def.open, "[]\\/~")
    local c = fn.escape(def.close, "[]\\/~")
    local save = fn.getpos(".")
    local sp = fn.searchpairpos(o, "", c, "bcnW")
    local ep = fn.searchpairpos(o, "", c, "cnW")
    fn.setpos(".", save)
    if sp[1] == 0 or ep[1] == 0 then
        return nil
    end
    return {
        o_row = sp[1] - 1,
        o_col = sp[2] - 1,
        o_len = #def.open,
        c_row = ep[1] - 1,
        c_col = ep[2] - 1,
        c_len = #def.close,
    }
end

--- Enclosing same-quote pair on the current line around the cursor, or nil (quotes do not span
--- lines here). Escaped quotes are skipped; positions are paired left-to-right.
---@param def LvimPairsDef
---@return { o_row: integer, o_col: integer, o_len: integer, c_row: integer, c_col: integer, c_len: integer }|nil
local function find_quote(def)
    local row = api.nvim_win_get_cursor(0)[1] - 1
    local col = api.nvim_win_get_cursor(0)[2]
    local line = api.nvim_get_current_line()
    local q = def.open
    local pos = {}
    local i = 1
    while true do
        local p = line:find(q, i, true)
        if not p then
            break
        end
        if p == 1 or line:sub(p - 1, p - 1) ~= "\\" then
            pos[#pos + 1] = p - 1
        end
        i = p + 1
    end
    for k = 1, #pos - 1, 2 do
        local a, b = pos[k], pos[k + 1]
        if col >= a and col <= b then
            return { o_row = row, o_col = a, o_len = 1, c_row = row, c_col = b, c_len = 1 }
        end
    end
    return nil
end

--- The enclosing element's open/close TAG nodes (for `t`), or nil when not inside an element.
---@param buf integer
---@return TSNode?, TSNode?
local function enclosing_tags(buf)
    local cur = api.nvim_win_get_cursor(0)
    local node = ts.node_at(buf, cur[1] - 1, cur[2])
    local el = ts.ancestor(node, ts.ELEMENT_TYPES)
    if not el then
        return nil, nil
    end
    local open_tag, close_tag
    for child in el:iter_children() do
        local t = child:type()
        if ts.OPEN_TAG_TYPES[t] then
            open_tag = child
        elseif ts.CLOSE_TAG_TYPES[t] then
            close_tag = child
        end
    end
    return open_tag, close_tag
end

--- The enclosing call node (for `f`), or nil.
---@param buf integer
---@return TSNode|nil
local function enclosing_call(buf)
    local cur = api.nvim_win_get_cursor(0)
    local node = ts.node_at(buf, cur[1] - 1, cur[2])
    return ts.ancestor(node, CALL_TYPES)
end

--- Delete a resolved delimiter pair (close first so the open delete keeps its coordinates), flashing
--- nothing (the text is gone). Cursor lands where the open was.
---@param buf integer
---@param p { o_row: integer, o_col: integer, o_len: integer, c_row: integer, c_col: integer, c_len: integer }
---@return nil
local function delete_pair(buf, p)
    api.nvim_buf_set_text(buf, p.c_row, p.c_col, p.c_row, p.c_col + p.c_len, {})
    api.nvim_buf_set_text(buf, p.o_row, p.o_col, p.o_row, p.o_col + p.o_len, {})
    api.nvim_win_set_cursor(0, { p.o_row + 1, p.o_col })
end

--- Replace a resolved pair's delimiters with `open`/`close` (close first), flashing both.
---@param buf integer
---@param p table
---@param open string
---@param close string
---@return nil
local function replace_pair(buf, p, open, close)
    api.nvim_buf_set_text(buf, p.c_row, p.c_col, p.c_row, p.c_col + p.c_len, { close })
    api.nvim_buf_set_text(buf, p.o_row, p.o_col, p.o_row, p.o_col + p.o_len, { open })
    flash(buf, p.o_row, p.o_col, p.o_col + #open)
    local cshift = (p.o_row == p.c_row) and (#open - p.o_len) or 0
    flash(buf, p.c_row, p.c_col + cshift, p.c_col + cshift + #close)
end

--- Resolve the enclosing pair for a surround `def` around the cursor (brackets / quotes only — tag
--- and func are handled directly in the delete/change paths because they are not simple pairs).
---@param def LvimPairsDef
---@return table|nil
local function find_pair(def)
    if def.quote then
        return find_quote(def)
    end
    return find_bracket(def)
end

-- ── the operatorfunc dispatcher ──────────────────────────────────────────────

--- The single 'operatorfunc' target for every surround action. Public because operatorfunc needs a
--- reachable v:lua name. Reads fresh input only when a trigger set `read`; otherwise (a `.` repeat)
--- reuses the stash.
---@param motion string  "char"|"line"|"block" (from g@)
---@return nil
function M.opfunc(motion)
    local buf = api.nvim_get_current_buf()
    if S.action == "add" or S.action == "add_line" then
        if S.read then
            S.def = defs.for_surround(fn.getcharstr())
            S.cached = nil
            S.read = false
        end
        if not S.def then
            return
        end
        local r = (S.action == "add_line") and line_range() or marks_range(motion)
        resolve_delims(S.def, function(open, close)
            apply_add(buf, r, open, close)
        end)
    elseif S.action == "delete" then
        if S.read then
            S.def = defs.for_surround(fn.getcharstr())
            S.read = false
        end
        if not S.def then
            return
        end
        if S.def.prompt == "tag" then
            local ot, ct = enclosing_tags(buf)
            if ot and ct then
                local osr, osc, oer, oec = ot:range()
                local csr, csc, cer, cec = ct:range()
                api.nvim_buf_set_text(buf, csr, csc, cer, cec, {})
                api.nvim_buf_set_text(buf, osr, osc, oer, oec, {})
                api.nvim_win_set_cursor(0, { osr + 1, osc })
            end
        elseif S.def.prompt == "func" then
            local call = enclosing_call(buf)
            if call then
                local name = call:field("function")[1] or call:child(0)
                local args = call:field("arguments")[1]
                if name and args then
                    local _, _, aer, aec = args:range()
                    local nsr, nsc = name:range()
                    -- keep only the argument text, minus its own outer parens; split on newlines so a
                    -- multi-line argument list survives nvim_buf_set_text (replacement items are per-line)
                    local inner = ts.text(buf, args):gsub("^%s*%(", ""):gsub("%)%s*$", "")
                    local csr = select(1, call:range())
                    api.nvim_buf_set_text(
                        buf,
                        csr,
                        select(2, call:range()),
                        aer,
                        aec,
                        vim.split(inner, "\n", { plain = true })
                    )
                    api.nvim_win_set_cursor(0, { nsr + 1, nsc })
                end
            end
        else
            local p = find_pair(S.def)
            if p then
                delete_pair(buf, p)
            end
        end
    elseif S.action == "change" then
        if S.read then
            S.def = defs.for_surround(fn.getcharstr())
            S.new_def = defs.for_surround(fn.getcharstr())
            S.cached = nil
            S.read = false
        end
        if not (S.def and S.new_def) then
            return
        end
        -- tag → tag: rename both tag names in place
        if S.def.prompt == "tag" and S.new_def.prompt == "tag" then
            local ot, ct = enclosing_tags(buf)
            local on, cn = ts.name_of(ot), ts.name_of(ct)
            if on and cn then
                local apply = function(name)
                    S.cached = name
                    local csr, csc, cer, cec = cn:range()
                    api.nvim_buf_set_text(buf, csr, csc, cer, cec, { name })
                    local osr, osc, oer, oec = on:range()
                    api.nvim_buf_set_text(buf, osr, osc, oer, oec, { name })
                    flash(buf, osr, osc, osc + #name)
                end
                if S.cached then
                    apply(S.cached)
                else
                    prompt("New tag name", apply)
                end
            end
            return
        end
        local p = find_pair(S.def)
        if not p then
            return
        end
        resolve_delims(S.new_def, function(open, close)
            replace_pair(buf, p, open, close)
        end)
    end
end

--- Arm an action on 'operatorfunc' and return the motion keys `.` will replay. `read` marks that the
--- opfunc must consume fresh input this time (a `.` replay leaves it false).
---@param action string
---@param motionkeys string  "g@" (ys) or "g@l" (ds/cs/yss)
---@return string
local function begin(action, motionkeys)
    S.action = action
    S.read = true
    vim.go.operatorfunc = "v:lua.require'lvim-pairs.surround'.opfunc"
    return motionkeys
end

--- Surround a visual selection with the chosen delimiters (visual `S`). Invoked AFTER the mapping's
--- <Esc> has left visual mode, so `'<`/`'>` hold the just-ended selection; read directly (visual
--- operations are not dot-repeated through operatorfunc).
---@return nil
function M.visual()
    S.action = "add"
    S.read = false
    S.def = defs.for_surround(fn.getcharstr())
    S.cached = nil
    if not S.def then
        return
    end
    local buf = api.nvim_get_current_buf()
    local r = visual_range()
    resolve_delims(S.def, function(open, close)
        apply_add(buf, r, open, close)
    end)
end

--- Install the surround <Plug> maps (and buffer-agnostic default keys). No-op when disabled.
---@return nil
function M.setup()
    if not config.surround.enabled then
        return
    end
    local nx = { silent = true }
    -- add
    vim.keymap.set("n", "<Plug>(lvim-pairs-add)", function()
        return begin("add", "g@")
    end, { expr = true, silent = true, desc = "Surround a motion" })
    vim.keymap.set("n", "<Plug>(lvim-pairs-add-line)", function()
        return begin("add_line", "g@l")
    end, { expr = true, silent = true, desc = "Surround the line" })
    -- <Esc> LEAVES visual mode first: `'<`/`'>` only commit to the just-ended selection on exit, so a
    -- bare <Cmd> (which stays in visual mode) would make visual_range() read the PREVIOUS session's
    -- stale marks — wrapping the wrong span (or erroring with no prior marks). Esc-then-Cmd is the seam.
    vim.keymap.set("x", "<Plug>(lvim-pairs-add)", "<Esc><Cmd>lua require('lvim-pairs.surround').visual()<CR>", nx)
    -- delete / change
    vim.keymap.set("n", "<Plug>(lvim-pairs-delete)", function()
        return begin("delete", "g@l")
    end, { expr = true, silent = true, desc = "Delete a surround" })
    vim.keymap.set("n", "<Plug>(lvim-pairs-change)", function()
        return begin("change", "g@l")
    end, { expr = true, silent = true, desc = "Change a surround" })
    -- default keys
    vim.keymap.set("n", "ys", "<Plug>(lvim-pairs-add)", { silent = true, desc = "Add surround" })
    vim.keymap.set("n", "yss", "<Plug>(lvim-pairs-add-line)", { silent = true, desc = "Add surround (line)" })
    vim.keymap.set("x", "S", "<Plug>(lvim-pairs-add)", { silent = true, desc = "Add surround" })
    vim.keymap.set("n", "ds", "<Plug>(lvim-pairs-delete)", { silent = true, desc = "Delete surround" })
    vim.keymap.set("n", "cs", "<Plug>(lvim-pairs-change)", { silent = true, desc = "Change surround" })
end

return M
