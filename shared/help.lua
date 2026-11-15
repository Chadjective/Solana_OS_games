-- "How to play" pages for Solana OS games: a few screens of short lines,
-- LEFT/RIGHT to turn the page, CANCEL to go back.
--
-- This file is shared by all the games: the copy in shared/ is the one to
-- edit, and tools/sync_shared.py copies it into each game's folder.
--
--   local help = require("help").new({
--     { title = "HOW TO PLAY", lines = { "...", "..." } },   -- up to 11 lines a page
--     { title = "2 BADGES", lines = { ... } },
--   })
--   help:open(on_close)      -- show the first page; on_close runs when it's closed
--   help:key(key, rep)       -- while open
--   help:is_open()

local Help = {}
Help.__index = Help

local LINES = 11            -- lines per page that fit above the hint bar

function Help.new(pages)
  return setmetatable({ pages = pages, page = 1, shown = false }, Help)
end

function Help:is_open() return self.shown end

function Help:draw()
  local p = self.pages[self.page]
  self.title:text(p.title)
  local n = #self.pages
  self.counter:text(n > 1 and (self.page .. "/" .. n) or "")
  for i = 1, LINES do self.lines[i]:text(p.lines[i] or "") end
  ui.hint(n > 1 and "L/R page   CANCEL back" or "CANCEL back")
end

function Help:open(on_close)
  self.shown, self.on_close, self.page = true, on_close, 1
  self.back = ui.rect(0, 0, ui.W, ui.H, { color = 0x0B0B14 })
  self.title = ui.label(12, 6, "", { size = 20, color = 0x14F195 })
  self.counter = ui.label(ui.W - 52, 10, "", { size = 12, color = "dim", w = 40, align = "right" })
  self.lines = {}
  for i = 1, LINES do
    self.lines[i] = ui.label(12, 24 + i * 15, "", { size = 12, color = 0xFFFFFF, w = ui.W - 24 })
  end
  self:draw()
end

function Help:close()
  for _, l in ipairs(self.lines or {}) do l:remove() end
  for _, k in ipairs({ "counter", "title", "back" }) do
    if self[k] then self[k]:remove() self[k] = nil end
  end
  self.lines, self.shown = nil, false
  if self.on_close then self.on_close() end
end

function Help:key(key, rep)
  if key == "back" and not rep then
    self:close()
  elseif (key == "left" or key == "right") and not rep and #self.pages > 1 then
    self.page = (self.page - 1 + (key == "right" and 1 or -1)) % #self.pages + 1
    self:draw()
  end
  return true
end

return Help
