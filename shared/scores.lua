-- Nearby leaderboards for Solana OS games: every badge with the game open
-- announces its own best scores over the mesh radio now and then, and each
-- badge keeps a list of the bests it has heard (saved, so players who walk
-- away stay on it, marked "earlier").
--
-- This file is shared by all the games: the copy in shared/ is the one to
-- edit, and tools/sync_shared.py copies it into each game's folder.
--
--   local Scores = require("scores")
--   local board = Scores.new({
--     game = "Proof of Stack",
--     send = radio_send,          -- the game's own radio, so it shares the 4-a-second budget
--     name_of = name_of,          -- a badge id -> its display name
--     categories = {              -- one per kind of best score
--       { label = "MARATHON LAMPORTS" },                      -- higher is better
--       { label = "SPRINT 40 TIME", low = true, fmt = clock }, -- lower is better
--     },
--     mine = function() return { best_lamports, best_time } end,  -- 0 = none yet
--     day = function() return today end,   -- optional: the day number, for daily categories
--   })
--
-- A category with `daily = true` (e.g. today's daily challenge) only lists
-- scores from the same day: each announcement carries its day.
--   board:tick(ms, quiet)    -- every tick; quiet = true while the radio is busy (a 2-badge game)
--   board:handle(from, msg)  -- in on_mesh, first: true when it was a score message
--   board:open(on_close)     -- show the leaderboard screen; on_close runs when it's closed
--   board:key(key, rep)      -- while open: LEFT/RIGHT switch category, CANCEL closes
--   board:is_open()

local Scores = {}
Scores.__index = Scores

local ANNOUNCE_EVERY = 3000     -- ms between this badge's announcements
local HERE_FOR = 15000          -- ms after the last announcement a badge counts as "here now"
local KEEP = 30                 -- most badges remembered
local SAVE_EVERY = 10000        -- ms at least between saves

local function commas(n)
  local s = tostring(math.floor(n))
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  if out:sub(1, 1) == "," then out = out:sub(2) end
  return out
end

function Scores.new(opts)
  local self = setmetatable({ opts = opts, t = 0, next_announce = 1000, cat = 1,
    saved_at = -100000, dirty = false, shown = false }, Scores)
  -- Remembered bests: [badge id] = { n = name, v = { scores }, at = when heard (ms, this run) }
  self.known = storage.get("nearby") or {}
  for _, e in pairs(self.known) do e.at = nil end    -- heard in an earlier run: not "here now"
  return self
end

function Scores:is_open() return self.shown end

local function better(cat, a, b)
  if cat.low then return a < b end
  return a > b
end

-- Forget the badges heard longest ago when there are too many.
function Scores:trim()
  local ids = {}
  for id in pairs(self.known) do ids[#ids + 1] = id end
  if #ids <= KEEP then return end
  table.sort(ids, function(a, b) return (self.known[a].at or -1) < (self.known[b].at or -1) end)
  for i = 1, #ids - KEEP do self.known[ids[i]] = nil end
end

function Scores:save()
  local out = {}
  for id, e in pairs(self.known) do out[id] = { n = e.n, v = e.v, d = e.d } end
  storage.set("nearby", out)
  self.saved_at, self.dirty = self.t, false
end

function Scores:tick(ms, quiet)
  self.t = self.t + ms
  if not quiet and mesh and self.t >= self.next_announce then
    local v = self.opts.mine()
    local any = false
    for _, x in ipairs(v) do if x > 0 then any = true end end
    local msg = { t = "sc", v = v }
    if self.opts.day then msg.d = self.opts.day() end
    if any and self.opts.send("*", msg) then
      self.next_announce = self.t + ANNOUNCE_EVERY
    end
  end
  if self.dirty and self.t - self.saved_at >= SAVE_EVERY then self:save() end
end

function Scores:handle(from, m)
  if m.t ~= "sc" then return false end
  if type(m.v) ~= "table" then return true end
  local v = {}
  for i = 1, #self.opts.categories do v[i] = tonumber(m.v[i]) or 0 end
  local e = self.known[from] or {}
  e.n, e.v, e.at, e.d = self.opts.name_of(from), v, self.t, tonumber(m.d)
  self.known[from] = e
  self:trim()
  self.dirty = true
  if self.shown then self:refresh() end
  return true
end

-- The list for the current category: everyone with a score in it, best first.
function Scores:rows()
  local cat = self.opts.categories[self.cat]
  local rows = {}
  local mine = self.opts.mine()[self.cat] or 0
  if mine > 0 then
    rows[#rows + 1] = { name = "YOU", score = mine, here = true, me = true }
  end
  local today = self.opts.day and self.opts.day()
  for _, e in pairs(self.known) do
    local s = e.v and e.v[self.cat] or 0
    if cat.daily and e.d ~= today then s = 0 end      -- another day's score
    if s > 0 then
      rows[#rows + 1] = { name = e.n or "?", score = s, here = e.at ~= nil and self.t - e.at < HERE_FOR }
    end
  end
  table.sort(rows, function(a, b)
    if a.score ~= b.score then return better(cat, a.score, b.score) end
    return a.name < b.name
  end)
  return rows
end

function Scores:refresh()
  local cat = self.opts.categories[self.cat]
  local n = #self.opts.categories
  self.cat_label:text((n > 1 and "< " or "") .. cat.label .. (n > 1 and " >" or ""))
  local items = {}
  local fmt = cat.fmt or commas
  for i, r in ipairs(self:rows()) do
    items[i] = { title = i .. ". " .. r.name, sub = r.me and "this badge" or (r.here and "here now" or "earlier"),
      right = fmt(r.score) }
  end
  self.list:items(items)
  self.info:show(#items == 0)
  self.info:text("No scores yet. Play a game, and open " .. self.opts.game .. " near other badges to see theirs.")
end

function Scores:open(on_close)
  self.shown, self.on_close = true, on_close
  self.back = ui.rect(0, 0, ui.W, ui.H, { color = 0x0B0B14 })
  self.title = ui.label(0, 4, "NEARBY LEADERBOARD", { size = 20, color = 0xFFFFFF, w = ui.W, align = "center" })
  self.cat_label = ui.label(0, 30, "", { size = 12, color = 0x14F195, w = ui.W, align = "center" })
  self.panel = ui.rect(24, 48, ui.W - 48, 154, { color = 0x15102A, radius = 8, border = "border" })
  self.list = ui.list(30, 52, ui.W - 60, 146, {}, {})
  self.info = ui.label(40, 96, "", { size = 12, color = "dim", w = ui.W - 80, align = "center" })
  ui.hint(#self.opts.categories > 1 and "L/R category   UP/DN scroll   CANCEL back" or "UP/DN scroll   CANCEL back")
  self:refresh()
end

function Scores:close()
  for _, k in ipairs({ "list", "info", "panel", "cat_label", "title", "back" }) do
    if self[k] then self[k]:remove() self[k] = nil end
  end
  self.shown = false
  if self.on_close then self.on_close() end
end

function Scores:key(key, rep)
  local n = #self.opts.categories
  if key == "back" and not rep then
    self:close()
  elseif (key == "left" or key == "right") and not rep and n > 1 then
    self.cat = (self.cat - 1 + (key == "right" and 1 or -1)) % n + 1
    self:refresh()
  end
  return true
end

return Scores
