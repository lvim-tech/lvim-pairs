-- lvim-pairs.ts: the shared treesitter helpers all three engines consult. Uses the CORE
-- vim.treesitter API only (get_node / get_parser / language_for_range) — lvim-ts is not required
-- for the plugin to load, it merely guarantees the parsers are installed; every entry point here
-- degrades to a safe default (node-less → "no context", so the caller pairs/closes anyway) when no
-- parser is attached, so a buffer without treesitter never errors and never silently blocks pairing.
--
---@module "lvim-pairs.ts"

local ts = vim.treesitter

local config = require("lvim-pairs.config")

local M = {}

--- Whether treesitter checks should run: the config flag is on AND the buffer has a parser. A
--- missing parser (or checks off) means "no context available" — callers then take the neutral path
--- (pair the quote, etc.) rather than blocking on an unknown.
---@param bufnr integer
---@return boolean
function M.available(bufnr)
    if config.ts_checks == false then
        return false
    end
    local ok, parser = pcall(ts.get_parser, bufnr)
    return ok and parser ~= nil
end

--- The named node at (row, col) — 0-based — via the buffer's parsed tree (injections included), or
--- nil when there is no parser / no node there.
---@param bufnr integer
---@param row integer  0-based
---@param col integer  0-based byte col
---@return TSNode|nil
function M.node_at(bufnr, row, col)
    local ok, node = pcall(ts.get_node, { bufnr = bufnr, pos = { row, col } })
    if not ok then
        return nil
    end
    return node
end

--- Whether the node at (row, col) — or any of its ancestors — has a `type()` listed in `types`.
--- Used for the `ts_not_in` guard (a quote must not auto-open inside a string/comment). Returns
--- false when no parser / no node (the neutral "no such context" answer), so the caller proceeds.
---@param bufnr integer
---@param row integer  0-based
---@param col integer  0-based byte col
---@param types string[]
---@return boolean
function M.in_types(bufnr, row, col, types)
    if not M.available(bufnr) or not types or #types == 0 then
        return false
    end
    local set = {}
    for _, t in ipairs(types) do
        set[t] = true
    end
    local node = M.node_at(bufnr, row, col)
    while node do
        if set[node:type()] then
            return true
        end
        node = node:parent()
    end
    return false
end

--- Named-node types (across the tag grammars) that denote an HTML/JSX element, its open tag, close
--- tag and the tag-name node — a superset covering html / tsx / vue / svelte / astro / php.
M.ELEMENT_TYPES = { element = true, jsx_element = true, style_element = true, script_element = true }
M.OPEN_TAG_TYPES = { start_tag = true, jsx_opening_element = true, self_closing_tag = true }
M.CLOSE_TAG_TYPES = { end_tag = true, jsx_closing_element = true }
M.NAME_TYPES = { tag_name = true, identifier = true, ["nested_identifier"] = true }

--- The nearest ANCESTOR node whose `type()` is a key of `set` (inclusive of the start node), or nil.
---@param node TSNode|nil
---@param set table<string, boolean>
---@return TSNode|nil
function M.ancestor(node, set)
    while node do
        if set[node:type()] then
            return node
        end
        node = node:parent()
    end
    return nil
end

--- The tag-NAME child node of an open/close tag node (first child whose type is a name type), or nil.
---@param tag TSNode|nil
---@return TSNode|nil
function M.name_of(tag)
    if not tag then
        return nil
    end
    for child in tag:iter_children() do
        if M.NAME_TYPES[child:type()] then
            return child
        end
    end
    return nil
end

--- Buffer text of a node (single-line names only — tag names never span lines).
---@param bufnr integer
---@param node TSNode|nil
---@return string
function M.text(bufnr, node)
    if not node then
        return ""
    end
    local ok, s = pcall(ts.get_node_text, node, bufnr)
    return ok and s or ""
end

--- 0-based (srow, scol, erow, ecol) range of a node, or nil.
---@param node TSNode|nil
---@return integer?, integer?, integer?, integer?
function M.range(node)
    if not node then
        return nil
    end
    return node:range()
end

--- Force a fresh parse of the buffer's tree (with injections) — call before a lookup right after an
--- edit so the tree reflects the just-typed character. No-op without a parser.
---@param bufnr integer
---@return nil
function M.parse(bufnr)
    local ok, parser = pcall(ts.get_parser, bufnr)
    if ok and parser then
        pcall(parser.parse, parser, true)
    end
end

return M
