-- The two-badge lobby: find other badges running the same game nearby,
-- invite one, accept an invite, and start a game with a shared id.
-- Also the radio itself, limited to the mesh's 4 messages a second.
--
-- Written once, for all the games: the copy in shared/ is the one to edit,
-- and tools/sync_shared.py copies it into each game's folder.
--
--   local Lobby = require("lobby")
--   local lobby = Lobby.new({
--     title = "2 PLAYERS",            -- the lobby screen's heading
--     game = "Monkey Bomb",           -- for "... wants to play Monkey Bomb"
--     on_start = function(peer_id, game_id, host) end,
--     far = "far: laggy",             -- optional: shown next to players reached
--                                     -- through a server bridge (1-3 s slower)
--   })
--   lobby:open()  /  lobby:close()  /  lobby:is_open()
--   Lobby.send(to, msg)               -- every radio message goes through here
--   Lobby.name_of(id)                 -- a badge's display name
--
-- and in on_mesh: `if lobby:handle(from, msg) then return end` first.
--
-- How a game starts: A invites B ("inv", repeated until answered). B's
-- player accepts: B makes up a game id, sends "go" (twice) and starts as the
-- guest. A starts as the host on the "go", or on B's first game message if
-- every "go" was lost. If both invite each other, the badge with the smaller
-- id accepts.

local Lobby = {}
Lobby.__index = Lobby

local HELLO_EVERY = 1200       -- ms between "I'm here" broadcasts
local FORGET_AFTER = 4000      -- ms without a hello before a badge leaves the list

-- The radio: at most 4 messages in any second (the mesh's limit). Returns
-- false when a message had to be skipped; games repeat what matters.
local sent_at = { -100000, -100000, -100000, -100000 }
function Lobby.send(to, m)
  local t = sys.millis()        -- the badge's clock: exact inside timers too
  if t - sent_at[1] < 1000 then return false end
  table.remove(sent_at, 1)
  sent_at[4] = t
  mesh.send(to, m)
  return true
end

-- A badge's display name (its owner's handle), or its id.
function Lobby.name_of(id)
  if mesh then
    for _, p in ipairs(mesh.nearby()) do
      if p.id == id then
        if p.name and p.name ~= "" then return p.name end
        break
      end
    end
  end
  return id
end

-- Is this badge reached through a server bridge (rather than the radio)?
function Lobby.bridged(id)
  if mesh then
    for _, p in ipairs(mesh.nearby()) do
      if p.id == id then return p.bridged end
    end
  end
  return false
end

function Lobby.new(opts)
  return setmetatable({ opts = opts, shown = false, seen = {}, ids = {} }, Lobby)
end

function Lobby:is_open() return self.shown end

function Lobby:refresh()
  if not self.shown then return end
  local t = sys.millis()
  self.ids = {}
  for id, at in pairs(self.seen) do
    if t - at < FORGET_AFTER then self.ids[#self.ids + 1] = id end
  end
  table.sort(self.ids)
  local items = {}
  for i, id in ipairs(self.ids) do
    local right = nil
    if self.invited == id then right = "invited"
    elseif self.opts.far and Lobby.bridged(id) then right = self.opts.far end
    items[i] = { title = Lobby.name_of(id), right = right }
  end
  self.list:items(items)
  -- Short: the badge's small text is fixed-width, about 40 characters a line.
  self.info:text(#items == 0 and "Looking for players nearby..."
    or "SELECT a player to invite them.")
end

function Lobby:open()
  self.shown, self.invited, self.asking, self.seen = true, nil, nil, {}
  self.title = ui.label(0, 8, self.opts.title or "2 PLAYERS", { size = 20, color = 0xFFFFFF, w = ui.W, align = "center" })
  self.info = ui.label(16, 36, "", { size = 12, color = "dim", w = ui.W - 32, align = "center" })
  self.list = ui.list(40, 60, ui.W - 80, 140, {}, {
    on_select = function(i)
      local id = self.ids[i]
      if not id then return end
      self.invited = id
      Lobby.send(id, { t = "inv" })
      ui.toast("Invite sent to " .. Lobby.name_of(id))
      self:refresh()
    end,
  })
  ui.hint("SELECT invite   CANCEL back")
  Lobby.send("*", { t = "hi" })
  self.timer = timer.every(HELLO_EVERY, function()
    if not self.shown then return end
    Lobby.send("*", { t = "hi" })
    if self.invited then Lobby.send(self.invited, { t = "inv" }) end   -- in case it got lost
    self:refresh()
  end)
  self:refresh()
end

function Lobby:close()
  if self.timer then timer.cancel(self.timer) self.timer = nil end
  for _, k in ipairs({ "list", "title", "info" }) do
    if self[k] then self[k]:remove() self[k] = nil end
  end
  self.shown = false
end

-- Accept an invite from badge id: this badge is the guest.
function Lobby:accept(id)
  local g = math.random(1, 2147483000)
  Lobby.send(id, { t = "go", g = g })
  timer.after(400, function() Lobby.send(id, { t = "go", g = g }) end)
  self:close()
  self.opts.on_start(id, g, false)
end

-- Handles the lobby's own messages. Returns true when the message was one of
-- them (the game can ignore it); game messages return false.
function Lobby:handle(from, m)
  if m.t == "hi" then
    local is_new = self.seen[from] == nil
    self.seen[from] = sys.millis()
    if is_new then self:refresh() end
    return true
  elseif m.t == "inv" then
    self.seen[from] = sys.millis()
    if self.shown and self.asking == nil then
      if self.invited == from then
        -- We invited each other: the smaller id accepts.
        if badge.id() and badge.id() < from then self:accept(from) end
        return true
      end
      self.asking = from
      ui.confirm(Lobby.name_of(from) .. " wants to play " .. self.opts.game .. ". Play?", function(yes)
        self.asking = nil
        if yes and self.shown then self:accept(from) end
      end)
    end
    return true
  end
  -- "go" (or, if every "go" was lost, any game message) from the badge we
  -- invited: the game is on, and this badge is the host.
  if self.shown and self.invited == from and m.g then
    self:close()
    self.opts.on_start(from, m.g, true)
  end
  return m.t == "go"
end

return Lobby
