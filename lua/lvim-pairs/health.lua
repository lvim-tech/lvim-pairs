-- lvim-pairs: :checkhealth lvim-pairs.
-- Diagnoses what makes the three engines misbehave invisibly: a missing treesitter parser (quotes
-- would pair inside strings, tags would not close/rename), an absent lvim-ui (the `t`/`f` prompted
-- surrounds have nowhere to ask), a surround key (`ys`/`ds`/`cs`) mapped over by another plugin, and
-- the lvim-utils dependency state (palette flash + array-replace merge, both with fallbacks).
-- Read-only reporting — never mutates config or state.
--
---@module "lvim-pairs.health"

local config = require("lvim-pairs.config")
local defs = require("lvim-pairs.defs")

local M = {}

--- Report whether a normal-mode default key still resolves to one of our surround <Plug> maps.
---@param health table
---@param lhs string
---@return nil
local function check_key(health, lhs)
    local rhs = vim.fn.maparg(lhs, "n")
    if rhs:find("lvim%-pairs") then
        health.ok(("n-mode %s → %s"):format(lhs, rhs))
    elseif rhs == "" then
        health.warn(("n-mode %s is unmapped — was surround enabled at setup()?"):format(lhs))
    else
        health.warn(("n-mode %s is mapped elsewhere: %s"):format(lhs, rhs))
    end
end

--- Run the health report.
---@return nil
function M.check()
    local health = vim.health
    health.start("lvim-pairs")

    if vim.fn.has("nvim-0.10") == 1 then
        health.ok("Neovim >= 0.10")
    else
        health.error("Neovim >= 0.10 is required (vim.uv, vim.islist, treesitter core API)")
    end

    local ok_utils = pcall(require, "lvim-utils.utils")
    local ok_hl, hl = pcall(require, "lvim-utils.highlight")
    if ok_utils and ok_hl and type(hl.bind) == "function" then
        health.ok("lvim-utils found (palette flash + array-replace merge)")
    else
        health.warn("lvim-utils not found — flash links to IncSearch, merge falls back to the bundled one")
    end

    if pcall(require, "lvim-ui") then
        health.ok("lvim-ui found (tag/function surround prompts)")
    else
        health.warn("lvim-ui not found — the `t` and `f` surrounds cannot prompt for a name")
    end

    if pcall(require, "lvim-ts") then
        health.ok("lvim-ts found (parsers provisioned for the ts_checks / autotag / tag+func surrounds)")
    else
        health.info("lvim-ts not found — treesitter still works if parsers are installed by other means")
    end

    -- module 1: autopairs
    if config.autopairs.enabled then
        local n = 0
        for _, d in ipairs(defs.all()) do
            if d.open ~= "" and not d.prompt then
                n = n + 1
            end
        end
        health.ok(
            ("autopairs on: %d pairs, fastwrap = %s"):format(
                n,
                config.autopairs.fastwrap ~= "" and config.autopairs.fastwrap or "off"
            )
        )
    else
        health.info("autopairs off")
    end

    -- module 2: surround
    if config.surround.enabled then
        health.ok("surround on")
        check_key(health, "ys")
        check_key(health, "ds")
        check_key(health, "cs")
    else
        health.info("surround off")
    end

    -- module 3: autotag
    if config.autotag.enabled then
        if vim.fn.exists(":TSInstall") == 0 and not pcall(require, "lvim-ts") then
            health.warn("autotag on but no treesitter installer detected — tags need a parser to close/rename")
        else
            health.ok(("autotag on: %d filetypes"):format(#(config.autotag.filetypes or {})))
        end
    else
        health.info("autotag off")
    end
end

return M
