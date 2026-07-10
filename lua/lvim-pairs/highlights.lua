-- lvim-pairs.highlights: the two accents this plugin paints. LvimPairsFlash — a subtle green
-- background (blend(green, bg, 0.3)) laid over an added/changed surround delimiter for ~120 ms, the
-- lvim-cycle confirmation pattern. LvimPairsHint — the fastwrap target label, the shared label canon
-- (accent fg on an mtint(accent, 0.3) chip, bold). build() reads the LIVE palette on every call; init
-- binds it via lvim-utils.highlight.bind so both re-derive on ColorScheme / palette sync.
--
---@module "lvim-pairs.highlights"

local c = require("lvim-utils.colors")
local hl = require("lvim-utils.highlight")

local M = {}

--- The two highlights from the live palette.
---@return table<string, table>
function M.build()
    return {
        LvimPairsFlash = { bg = hl.blend(c.green, c.bg, 0.3) },
        LvimPairsHint = { fg = c.orange, bg = hl.blend(c.orange, c.bg, 0.3), bold = true },
    }
end

return M
