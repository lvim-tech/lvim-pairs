-- lvim-pairs.tags: module 3 — HTML/JSX/XML tag auto-close and auto-RENAME. Attaches per buffer to
-- the configured filetypes. Close-on-`>` uses a line REGEX (the just-typed `<div>` is still an
-- incomplete/ERROR node in every tag grammar, so a regex is the reliable seam for that instant);
-- `</`-completion and the live rename use TREESITTER on the settled tree (the enclosing element's
-- open/close tag-name nodes). Rename is debounced on TextChanged(I) and guarded by a per-buffer
-- `patching` flag so the buffer edit it makes does not re-trigger itself (the generation guard).
--
---@module "lvim-pairs.tags"

local api = vim.api

local config = require("lvim-pairs.config")
local ts = require("lvim-pairs.ts")

local M = {}

--- HTML void elements — never auto-closed (they take no end tag).
local VOID = {}
for _, v in ipairs({
    "area",
    "base",
    "br",
    "col",
    "embed",
    "hr",
    "img",
    "input",
    "link",
    "meta",
    "param",
    "source",
    "track",
    "wbr",
}) do
    VOID[v] = true
end

---@type table<integer, { patching: boolean, timer: uv.uv_timer_t? }>  per-buffer state
local state = {}
local RENAME_MS = 60

--- The enclosing element's open and close TAG nodes at the cursor (settled tree), or nils.
---@param buf integer
---@return TSNode?, TSNode?
local function enclosing_tags(buf)
    local cur = api.nvim_win_get_cursor(0)
    local node = ts.node_at(buf, cur[1] - 1, cur[2])
    local el = ts.ancestor(node, ts.ELEMENT_TYPES)
    if not el then
        return nil, nil
    end
    local ot, ct
    for child in el:iter_children() do
        local t = child:type()
        if ts.OPEN_TAG_TYPES[t] then
            ot = child
        elseif ts.CLOSE_TAG_TYPES[t] then
            ct = child
        end
    end
    return ot, ct
end

--- Close-on-`>`: insert `>` at the cursor, then if that completed an OPENING tag (`<name …>`, not a
--- close, self-close or void element) with no matching close, append `</name>` after the cursor and
--- leave the cursor between them.
---@return nil
local function on_gt()
    local buf = api.nvim_get_current_buf()
    local cur = api.nvim_win_get_cursor(0)
    local row, col = cur[1] - 1, cur[2]
    api.nvim_buf_set_text(buf, row, col, row, col, { ">" })
    api.nvim_win_set_cursor(0, { row + 1, col + 1 })
    if config.autotag.enabled == false then
        return
    end
    local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    local before = line:sub(1, col + 1) -- includes the just-typed '>'
    local seg = before:match("<[^<>]*>$")
    if not seg or seg:sub(1, 2) == "</" or seg:sub(-2) == "/>" then
        return
    end
    local name = seg:match("^<%s*([%w][%w%-%.:]*)")
    if not name or VOID[name:lower()] then
        return
    end
    -- don't double-close when a matching </name> already follows on the line
    if line:sub(col + 2):match("^%s*</" .. vim.pesc(name) .. ">") then
        return
    end
    api.nvim_buf_set_text(buf, row, col + 1, row, col + 1, { "</" .. name .. ">" })
    api.nvim_win_set_cursor(0, { row + 1, col + 1 })
end

--- `</`-completion: insert `/`, then if it followed a `<` inside an unclosed element, complete the
--- nearest enclosing open tag's name + `>`.
---@return nil
local function on_slash()
    local buf = api.nvim_get_current_buf()
    local cur = api.nvim_win_get_cursor(0)
    local row, col = cur[1] - 1, cur[2]
    api.nvim_buf_set_text(buf, row, col, row, col, { "/" })
    api.nvim_win_set_cursor(0, { row + 1, col + 1 })
    if config.autotag.enabled == false then
        return
    end
    local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    if line:sub(col, col) ~= "<" then
        return -- only complete right after a '<'
    end
    ts.parse(buf)
    local node = ts.node_at(buf, row, col)
    local el = ts.ancestor(node, ts.ELEMENT_TYPES)
    local ot = el
        and (function()
            for child in el:iter_children() do
                if ts.OPEN_TAG_TYPES[child:type()] then
                    return child
                end
            end
        end)()
    local name = ts.text(buf, ts.name_of(ot))
    if name == "" then
        return
    end
    api.nvim_buf_set_text(buf, row, col + 1, row, col + 1, { name .. ">" })
    api.nvim_win_set_cursor(0, { row + 1, col + 1 + #name + 1 })
end

--- Whether the cursor sits within node `n` (inclusive of its end).
---@param n TSNode
---@param row integer
---@param col integer
---@return boolean
local function cursor_in(n, row, col)
    local sr, sc, er, ec = n:range()
    local after_start = row > sr or (row == sr and col >= sc)
    local before_end = row < er or (row == er and col <= ec)
    return after_start and before_end
end

--- Live rename: when the open and close tag names of the cursor's element diverge, patch the side
--- NOT under the cursor to match the side that was just edited. Guarded by `patching` so the patch
--- edit does not re-enter.
---@param buf integer
---@return nil
local function rename(buf)
    local st = state[buf]
    if not st or st.patching or config.autotag.enabled == false then
        return
    end
    ts.parse(buf)
    local ot, ct = enclosing_tags(buf)
    local on, cn = ts.name_of(ot), ts.name_of(ct)
    if not (on and cn) then
        return
    end
    local os, cs = ts.text(buf, on), ts.text(buf, cn)
    if os == cs or os == "" or cs == "" then
        return
    end
    local cur = api.nvim_win_get_cursor(0)
    local row, col = cur[1] - 1, cur[2]
    st.patching = true
    if cursor_in(on, row, col) then
        local sr, sc, er, ec = cn:range()
        pcall(api.nvim_buf_set_text, buf, sr, sc, er, ec, { os })
    else
        local sr, sc, er, ec = on:range()
        pcall(api.nvim_buf_set_text, buf, sr, sc, er, ec, { cs })
    end
    vim.schedule(function()
        if state[buf] then
            state[buf].patching = false
        end
    end)
end

--- Debounced rename trigger for TextChanged(I).
---@param buf integer
---@return nil
local function schedule_rename(buf)
    local st = state[buf]
    if not st then
        return
    end
    if not st.timer then
        st.timer = assert(vim.uv.new_timer())
    end
    st.timer:stop()
    st.timer:start(
        RENAME_MS,
        0,
        vim.schedule_wrap(function()
            if api.nvim_buf_is_valid(buf) then
                rename(buf)
            end
        end)
    )
end

--- Attach the tag engine to a buffer: buffer-local `>` and `/` insert maps plus a debounced
--- rename on TextChanged(I). Idempotent per buffer.
---@param buf integer
---@return nil
local function attach(buf)
    if state[buf] then
        return
    end
    state[buf] = { patching = false }
    local opts = { buffer = buf, silent = true, desc = "lvim-pairs: autotag" }
    vim.keymap.set("i", ">", on_gt, opts)
    vim.keymap.set("i", "/", on_slash, opts)
    local group = api.nvim_create_augroup("lvim-pairs-tags-" .. buf, { clear = true })
    api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        group = group,
        buffer = buf,
        callback = function()
            schedule_rename(buf)
        end,
    })
    api.nvim_create_autocmd("BufWipeout", {
        group = group,
        buffer = buf,
        callback = function()
            local st = state[buf]
            if st and st.timer then
                st.timer:stop()
                st.timer:close()
            end
            state[buf] = nil
        end,
    })
end

--- Install the FileType autocmd that attaches the tag engine to the configured filetypes; attach to
--- already-open matching buffers too. No-op when the module is disabled.
---@return nil
function M.setup()
    if not config.autotag.enabled then
        return
    end
    local set = {}
    for _, ft in ipairs(config.autotag.filetypes or {}) do
        set[ft] = true
    end
    api.nvim_create_autocmd("FileType", {
        group = api.nvim_create_augroup("lvim-pairs-tags", { clear = true }),
        callback = function(ev)
            if set[vim.bo[ev.buf].filetype] then
                attach(ev.buf)
            end
        end,
    })
    for _, buf in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_loaded(buf) and set[vim.bo[buf].filetype] then
            attach(buf)
        end
    end
end

return M
