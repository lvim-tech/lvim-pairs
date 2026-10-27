-- What typing a delimiter does, as the editor sees it.
--
-- auto.lua says "every decision is a pure function of (char before, char after, treesitter node)
-- and nothing is fed behind the editor's back" -- the decisions are insert-mode EXPR mappings
-- that RETURN the keys to type. So the honest way to test them is to type: feed the key, read
-- the line and the cursor back. That measures the mapping, the keycodes it returns and the
-- editor's own reaction to them in one go, which three separate unit tests would not.

local pairs_mod = require("lvim-pairs")
local cr = require("lvim-pairs.cr")
local config = require("lvim-pairs.config")

-- The baseline has already called setup(), so the insert maps are installed. Make sure, because
-- the order specs run in is not this spec's business.
pcall(pairs_mod.setup, {})

--- Type `keys` in insert mode into a fresh buffer holding `line`, with the cursor at byte `col`
--- (0-based), and hand back the resulting line and cursor column.
---@param line string
---@param col integer
---@param keys string
---@param ft? string
---@return string line
---@return integer col  0-based byte column after typing
local function typing(line, col, keys, ft)
    vim.cmd("enew!")
    vim.bo.filetype = ft or "text"
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { line })
    -- `col` is where the text is INSERTED. Normal mode cannot put the cursor past the last
    -- character, so inserting at the end of a line means appending: entering insert with `i` at a
    -- clamped column would type one character too far left, which is how three of these cases
    -- first "failed".
    local enter = "i"
    if col >= #line and #line > 0 then
        vim.api.nvim_win_set_cursor(0, { 1, #line - 1 })
        enter = "a"
    else
        vim.api.nvim_win_set_cursor(0, { 1, col })
    end
    -- 'x' executes the typeahead immediately so the assertions below see the finished state.
    vim.api.nvim_feedkeys(enter .. vim.api.nvim_replace_termcodes(keys, true, true, true), "x", false)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, true, true), "x", false)
    local after = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    return after[1], vim.api.nvim_win_get_cursor(0)[2]
end

--- The whole buffer after typing, for the cases that create lines.
---@param line string
---@param col integer
---@param keys string
---@return string[]
local function typing_lines(line, col, keys)
    vim.cmd("enew!")
    vim.bo.filetype = "text"
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { line })
    vim.api.nvim_win_set_cursor(0, { 1, col })
    vim.api.nvim_feedkeys("i" .. vim.api.nvim_replace_termcodes(keys, true, true, true), "x", false)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, true, true), "x", false)
    return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

describe("lvim-pairs: an opening delimiter")

it("inserts the pair with the cursor inside", function()
    local line, col = typing("", 0, "(")
    eq("()", line)
    eq(0, col, "after <Esc> the cursor sits ON the character it was before, i.e. inside the pair")
end)

it("stays alone before a word, so existing text is not wrapped in noise", function()
    eq("(word", (typing("word", 0, "(")))
    eq("(заглавие", (typing("заглавие", 0, "(")), "a multibyte lead byte is word-like too")
end)

it("pairs before a non-word character", function()
    eq("() foo", (typing(" foo", 0, "(")))
    eq("[]", (typing("", 0, "[")))
    eq("{}", (typing("", 0, "{")))
end)

describe("lvim-pairs: a closing delimiter")

it("steps over a close that is already there rather than doubling it", function()
    local line, col = typing("()", 1, ")")
    eq("()", line, "one pair, not ())")
    eq(1, col, "and the cursor moved past the close")
end)

it("is inserted when there is nothing to step over", function()
    eq(")", (typing("", 0, ")")))
    eq("a)b", (typing("ab", 1, ")")), "a close in the middle of text is just a close")
end)

describe("lvim-pairs: a quote decides by context")

it("opens a pair on its own", function()
    eq('""', (typing("", 0, '"')))
    eq("``", (typing("", 0, "`")))
end)

it("steps over the closing quote", function()
    local line, col = typing('""', 1, '"')
    eq('""', line)
    eq(1, col)
end)

it("stays literal after a backslash", function()
    eq('\\"', (typing("\\", 1, '"')), "an escaped quote is one character, never a pair")
end)

it("stays literal glued to a word", function()
    eq("don'", (typing("don", 3, "'")), "a contraction is not an opening quote")
end)

describe("lvim-pairs: backspace and space inside a pair")

it("backspace in an empty pair deletes both sides", function()
    eq("", (typing("()", 1, "<BS>")))
    eq("", (typing("[]", 1, "<BS>")))
end)

it("space inside a padded pair grows a matching space", function()
    local line, col = typing("()", 1, "<Space>")
    eq("(  )", line, "one space typed, two spaces written, cursor between them")
    eq(1, col)
end)

it("backspace between those two spaces removes both", function()
    eq("()", (typing("(  )", 2, "<BS>")))
end)

it("backspace elsewhere is a plain backspace", function()
    eq("ac", (typing("abc", 2, "<BS>")))
    eq("( )", (typing("(  )", 3, "<BS>")), "only the pair's OWN padding is special")
end)

describe("lvim-pairs: the filetype gates")

it("a prompt filetype gets the plain key", function()
    local was = config.autopairs.disable_filetype
    config.autopairs.disable_filetype = { "lvim-pairs-spec-prompt" }
    eq("(", (typing("", 0, "(", "lvim-pairs-spec-prompt")), "a picker prompt must not grow a close bracket")
    eq('"', (typing("", 0, '"', "lvim-pairs-spec-prompt")))
    config.autopairs.disable_filetype = was
end)

it("angle brackets pair only in the generic-type languages", function()
    eq("<>", (typing("", 0, "<", "rust")), "Vec<…> -- here they are a delimiter")
    eq("<>", (typing("", 0, "<", "java")))
    eq("<", (typing("", 0, "<", "lua")), "in Lua a < is a comparison; pairing it injects a phantom >")
    eq(
        "<",
        (typing("", 0, "<", "html")),
        "and NOT in the tag filetypes either: there the autotag engine owns angle brackets, and an "
            .. "autopaired <> would collide with it"
    )
end)

describe("lvim-pairs: a newline between a pair")

it("splits the delimiters onto their own lines", function()
    vim.cmd("enew!")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "{}" })
    vim.api.nvim_win_set_cursor(0, { 1, 1 })
    eq("<CR><Esc>O", cr.cr(), "inside an empty pair")

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    eq("<CR>", cr.cr(), "anywhere else it is a plain newline")
end)

it("is a plain newline when the pair is not empty", function()
    vim.cmd("enew!")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "{a}" })
    vim.api.nvim_win_set_cursor(0, { 1, 1 })
    eq("<CR>", cr.cr())
end)

it("and typing it really does leave three lines", function()
    -- lvim-pairs installs its own <CR> map only when lvim-cmp is absent: cmp owns that key and
    -- calls cr() as its fallback (the documented handshake). With the sibling checkouts on the
    -- runtimepath cmp IS present, so there is nothing of ours on <CR> to measure.
    local mapped = vim.fn.maparg("<CR>", "i", false, true)
    if type(mapped) ~= "table" or not (mapped.desc or ""):match("lvim%-pairs") then
        skip("typing <CR> between a pair", "lvim-cmp is present, so it owns <CR> and calls cr() as its fallback")
        return
    end
    local lines = typing_lines("{}", 1, "<CR>")
    eq(3, #lines, "open, an empty line to type on, close: " .. vim.inspect(lines))
    eq("{", lines[1])
    eq("}", lines[3])
end)
