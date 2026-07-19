-- lvim-pairs.defs: the ONE pair-definition table shared by all three engines (autopairs, surround,
-- autotag). Each entry describes a delimiter pair once; the engines read the fields relevant to
-- them, so a user who adds a pair here (via config.pairs) gets it in insert-mode pairing AND as a
-- surround target with no per-engine wiring. `resolve()` merges the user's config.pairs over the
-- built-ins (by `open`) and indexes them for fast lookup.
--
---@module "lvim-pairs.defs"

---@class LvimPairsDef
---@field open        string    The opening delimiter (also the identity key)
---@field close       string    The closing delimiter (== open for quotes)
---@field quote?      boolean   Same-char open/close (auto-pairing needs the skip/run heuristics)
---@field space_pad?  boolean   A leading <Space> inside the pair inserts a matching trailing one
---@field ts_not_in?  string[]  Treesitter node types the pair must NOT auto-open inside (quotes: strings)
---@field ft_allow?   string[]  Auto-pair ONLY in these filetypes (nil = every filetype); surround ignores it
---@field ft_deny?    string[]  Never auto-pair in these filetypes (nil = none); surround ignores it
---@field surround?   string    The surround KEY (what you type after ys/ds/cs); nil = not a surround target
---@field aliases?    string[]  Extra surround keys that resolve to this pair
---@field prompt?     "tag"|"func"  A surround-only pair whose delimiters are PROMPTED for (tag name / func name)

local config = require("lvim-pairs.config")

local M = {}

--- The built-in pairs. Brackets and quotes are shared by all engines; `t`/`f` are surround-only
--- (prompted). Aliases follow the vim-surround convention (`b`=(), `B`={}, `q`=any quote…).
---@type LvimPairsDef[]
M.builtin = {
    { open = "(", close = ")", space_pad = true, surround = "(", aliases = { "b", ")" } },
    { open = "[", close = "]", space_pad = true, surround = "[", aliases = { "]" } },
    { open = "{", close = "}", space_pad = true, surround = "{", aliases = { "B", "}" } },
    -- `<` auto-pairs ONLY in generic-type languages (`Vec<…>`, `List<…>`), where angle brackets are a
    -- delimiter. Everywhere else `<` is a comparison operator, so pairing it would inject a phantom `>`
    -- after `x < `. Deliberately NOT the tag filetypes (html/jsx/…): there the autotag engine owns
    -- angle brackets — typing `>` closes the tag — so an autopaired `<>` would collide with it and
    -- leave a stray `>`. `<` stays a SURROUND target (`ys…<`, `ds<`) in every filetype regardless.
    {
        open = "<",
        close = ">",
        space_pad = true,
        surround = "<",
        aliases = { ">", "a" },
        ft_allow = {
            "rust",
            "cpp",
            "java",
            "cs",
            "scala",
            "kotlin",
        },
    },
    { open = '"', close = '"', quote = true, ts_not_in = { "string", "comment" }, surround = '"' },
    { open = "'", close = "'", quote = true, ts_not_in = { "string", "comment", "char" }, surround = "'" },
    { open = "`", close = "`", quote = true, ts_not_in = { "string", "comment" }, surround = "`" },
    -- surround-only, prompted
    { open = "", close = "", surround = "t", prompt = "tag" },
    { open = "", close = "", surround = "f", prompt = "func" },
}

---@type LvimPairsDef[]|nil resolved (merged) list, rebuilt on first use / after setup
local resolved = nil
---@type table<string, LvimPairsDef>|nil open → def
local by_open = nil
---@type table<string, LvimPairsDef>|nil surround key / alias → def
local by_surround = nil

--- (Re)build the merged definition list from the built-ins + config.pairs (user pairs replace a
--- built-in with the SAME `open`, else append) and the fast-lookup indexes. Idempotent; call after
--- setup mutates config.pairs.
---@return nil
function M.rebuild()
    resolved = {}
    by_open = {}
    by_surround = {}
    local seen = {} ---@type table<string, integer>  open → index in `resolved`
    local function add(def)
        if def.open ~= "" and seen[def.open] then
            resolved[seen[def.open]] = def -- user override of a built-in `open`
        else
            resolved[#resolved + 1] = def
            if def.open ~= "" then
                seen[def.open] = #resolved
            end
        end
    end
    for _, def in ipairs(M.builtin) do
        add(def)
    end
    for _, def in ipairs(config.pairs or {}) do
        add(def)
    end
    for _, def in ipairs(resolved) do
        if def.open ~= "" then
            by_open[def.open] = def
        end
        if def.surround then
            by_surround[def.surround] = def
            for _, a in ipairs(def.aliases or {}) do
                by_surround[a] = def
            end
        end
    end
end

--- The merged definition list (rebuilds lazily on first access).
---@return LvimPairsDef[]
function M.all()
    if not resolved then
        M.rebuild()
    end
    return resolved or {}
end

--- The pair whose OPEN delimiter is `open`, or nil.
---@param open string
---@return LvimPairsDef|nil
function M.for_open(open)
    if not by_open then
        M.rebuild()
    end
    return (by_open or {})[open]
end

--- The pair a surround KEY (or alias) resolves to, or nil.
---@param key string
---@return LvimPairsDef|nil
function M.for_surround(key)
    if not by_surround then
        M.rebuild()
    end
    return (by_surround or {})[key]
end

return M
