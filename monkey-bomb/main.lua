-- Solana Monkey Bomb (SMB): two monkeys on the London skyline take turns
-- lobbing weapons at each other. Walk and climb to a good spot, pick up
-- what's lying on the rooftops, aim, pick a weapon, hold SELECT to charge the
-- throw, mind the wind and the weather, and blow holes in London's landmarks
-- for points. A monkey out of health (or in the Thames) loses the round.
-- First to win 3 rounds wins the match.
--
-- Modes: 1 player vs a CPU monkey (Easy / Hard), 2 players passing one
-- badge, and 2 players on two badges over the mesh radio.
--
-- Two badges stay in sync without sending pictures: both build the same
-- skyline from the same seed (a starting number for the random choices),
-- and a throw is just "angle, power, weapon". Each badge then flies it with
-- the same fixed-step physics, so the flight, the holes, the points and
-- the result come out the same on both.

local sky = require("skyline")

local W, H = ui.W, ui.H              -- 320 x 218
local SCALE = 2                      -- every canvas pixel is 2 x 2 on screen
local CW, CH = sky.CW, sky.CH        -- the city canvas: 160 x 101 (320 x 202 on screen)
local GROUND_Y = CH - 2
local WIN_ROUNDS = 3

local STEP_MS = 8                    -- physics step: the same on every badge
local STEP = STEP_MS / 1000
local SAFE_STEPS = 30                -- a throw can't hit its thrower for this many steps
local CHARGE_MS = 1500               -- holding SELECT from 0 to full power

-- Moving about: each turn starts with some energy to walk, climb and jump.
local ENERGY = 70                    -- per turn
local MV = {
  WALK_COST = 1, CLIMB_COST = 2, JUMP_COST = 8,   -- energy
  WALK_MS = 40, CLIMB_MS = 70,                    -- ms per pixel walked / climbed
  FALL_SPEED = 90,                                -- canvas px/s
  JUMP_VX = 38, JUMP_VY = -62, JUMP_G = 170,
}

-- Points
local DESTROYED_AT = 0.55            -- share of a building gone to count as destroyed
local PTS = {
  PIXEL = 1,                         -- per pixel of an ordinary block destroyed
  ICON_PIXEL = 1,                    -- times a landmark's value (1..3), per pixel
  BLOCK_DOWN = 20,
  ICON_DOWN = 100,                   -- times the landmark's value
  KO = 250,                          -- knocking the other monkey out
  HP = 2,                            -- per point of damage to the other monkey
}

-- Health
local MAX_HP = 100
local HEALTH_PACK = 35

-- Weather: rain makes throws heavier, snow makes walking harder, fog hides
-- the aiming guide beyond its first dots.
local WX = { RAIN_GRAV = 12, SNOW_EXTRA = 1 }   -- SNOW_EXTRA: energy per pixel walked or climbed

-- Pickups lying on the rooftops at the start of each round.
local ITEM_KINDS = { "health", "umbrella", "crate" }
local ITEMS_PER_ROUND = 3

-- Mesh radio (two-badge games).
local NET = { HELLO_EVERY = 1200, KEEPALIVE_EVERY = 2000, RESEND_EVERY = 700, LOST_AFTER = 15000 }

local has_led = led ~= nil
local has_mesh = mesh ~= nil
local has_keys = sys.keys ~= nil

local CAP = { 0x9945FF, 0x14F195 }   -- player 1 purple, player 2 green

---------------------------------------------------------------------------
-- Pixel art (one character per pixel; "." is see-through)
---------------------------------------------------------------------------
local MONKEY_STAND = {
  "..hhhh..",
  ".hhhhhhh",
  ".nnnnnn.",
  "nnffffnn",
  ".nfkfkn.",
  ".nffffn.",
  "..nffn..",
  ".nnnnnn.",
  "n.nnnn.n",
  "..n..n..",
}
local MONKEY_THROW = {
  "..hhhh.n",
  ".hhhhhhn",
  ".nnnnnnn",
  "nnffffnn",
  ".nfkfkn.",
  ".nffffn.",
  "..nffn..",
  ".nnnnnn.",
  "n.nnnn..",
  "..n..n..",
}

local ART = {
  bomb = { "...y.", "..o..", ".kkk.", "kkwkk", "kkkkk", ".kkk." },
  bunch = { "....g.", "..yyg.", ".yyyy.", "yyyyy.", "yyyy..", ".yy..." },
  banana = { "y...y", ".yyy." },
  rocket = { "y.....", "oqqqqm", "y....." },
  coconut = { "..y..", ".ccc.", "cdcdc", "ccccc", "ccdcc", ".ccc." },
  health = { "wwwwww", "wwrrww", "wrrrrw", "wrrrrw", "wwrrww", "wwwwww" },
  umbrella = { "..mm..", ".mmmm.", "mmmmmm", "...k..", "...k..", "..kk.." },
  crate = { "dddddd", "dcpgcd", "dcccdd", "ddcccd", "dcgpcd", "dddddd" },
}
local ART_PAL = { palette = { q = 0x9AA0A6, c = 0x6B4423, d = 0x3B2412, r = 0xE5383B }, scale = SCALE }

local function mirror(rows, width)
  local out = {}
  for i, r in ipairs(rows) do
    out[i] = (r .. string.rep(".", width - #r)):reverse()
  end
  return out
end

local function explosion_rows()
  local rows = {}
  for y = -6, 6 do
    local row = {}
    for x = -6, 6 do
      local d = math.sqrt(x * x + y * y)
      local ch = "."
      if d < 2.5 then ch = "w"
      elseif d < 4.2 then ch = "y"
      elseif d < 5.6 then ch = "o"
      elseif d < 6.6 and (x + y) % 2 == 0 then ch = "m" end
      row[#row + 1] = ch
    end
    rows[#rows + 1] = table.concat(row)
  end
  return rows
end

---------------------------------------------------------------------------
-- Weapons
--   speed: launch speed per point of power; grav: gravity (canvas px/s^2);
--   wind: how much the wind pushes it; blast: explosion radius (canvas px);
--   dmg: damage to a monkey right at the centre of the blast (less further out);
--   ammo: per player per round (-1 = unlimited); split: bananas it bursts into.
---------------------------------------------------------------------------
local WEAPONS = {
  { name = "BOMB",         ammo = -1, speed = 1.35, grav = 80, wind = 1.0, blast = 6,  dmg = 40, art = "bomb" },
  { name = "BANANA BUNCH", ammo = 2,  speed = 1.35, grav = 80, wind = 1.0, blast = 4,  dmg = 15, art = "bunch", split = 5 },
  { name = "BAZOOKA",      ammo = 3,  speed = 1.9,  grav = 28, wind = 1.6, blast = 7,  dmg = 45, art = "rocket" },
  { name = "COCONUT",      ammo = 1,  speed = 1.25, grav = 90, wind = 0.7, blast = 11, dmg = 65, art = "coconut" },
}
local BANANA = { name = "banana", speed = 1, grav = 80, wind = 1.0, blast = 4, dmg = 18, art = "banana" }
-- Where the bananas of a bunch fly when it bursts (canvas px/s): fixed, so
-- both badges agree.
local SPLIT_V = { { -45, -55 }, { -22, -75 }, { 0, -85 }, { 22, -75 }, { 45, -55 } }

---------------------------------------------------------------------------
-- Screen objects (drawn in the order they are made)
---------------------------------------------------------------------------
ui.bg(sky.SKY)
local city = ui.canvas(0, 0, CW, CH, { scale = SCALE, color = "bg" })

-- Colours as the canvas stores them (the screen has 65,536 colours, so a
-- colour can come back slightly different): anything in EMPTY is sky.
local EMPTY = {}
for _, c in ipairs({ sky.SKY, sky.STAR, sky.MOON, sky.MOON_SHADE, sky.WATER, sky.WATER_LIGHT }) do
  city:pixel(0, 0, c)
  EMPTY[city:get(0, 0)] = true
end

local monkeys = {}
for i = 1, 2 do
  local pal = { palette = { h = CAP[i], n = 0x8B5A2B, f = 0xE0B98A }, scale = SCALE }
  local m = { x = 0, y = 0, alive = true }
  -- face: 1 = looking right, -1 = looking left; a monkey throws the way it faces.
  m.face = i == 1 and 1 or -1
  m.img = {
    stand_r = ui.image(0, 0, MONKEY_STAND, pal), throw_r = ui.image(0, 0, MONKEY_THROW, pal),
    stand_l = ui.image(0, 0, mirror(MONKEY_STAND, 8), pal), throw_l = ui.image(0, 0, mirror(MONKEY_THROW, 8), pal),
  }
  for _, img in pairs(m.img) do img:show(false) end
  m.hp, m.umbrella = MAX_HP, false
  m.bar_bg = ui.rect(0, 0, 14, 3, { color = 0x2A2A3A })
  m.bar = ui.rect(0, 0, 14, 3, { color = "green" })
  m.brolly = ui.image(0, 0, { "..mm..", ".mmmm.", "mmmmmm", "...k..", "..kk.." }, { scale = 1 })
  m.bar_bg:show(false) m.bar:show(false) m.brolly:show(false)
  monkeys[i] = m
end

-- One sprite per projectile that can be in the air at once.
local function sprite(rows)
  local img = ui.image(0, 0, rows, ART_PAL)
  img:show(false)
  return img
end
local SPRITES = {
  bomb = sprite(ART.bomb),
  bunch = sprite(ART.bunch),
  rocket = sprite(ART.rocket),
  rocket_l = sprite(mirror(ART.rocket, 6)),
  coconut = sprite(ART.coconut),
}
local banana_sprites = {}
for i = 1, #SPLIT_V do banana_sprites[i] = sprite(ART.banana) end

-- Pickups: one picture per kind per slot, shown for whichever kind lies there.
local items = {}         -- this round's: { x, y, kind, weapon, alive, img }
local item_imgs = {}
for k = 1, ITEMS_PER_ROUND do
  item_imgs[k] = {}
  for _, kind in ipairs(ITEM_KINDS) do item_imgs[k][kind] = sprite(ART[kind]) end
end

-- Weather: falling drops or flakes, and fog banks.
local drops = {}
for i = 1, 18 do
  drops[i] = { r = ui.rect(0, 0, 1, 5, { color = 0x6F86C8 }), x = 0, y = 0 }
  drops[i].r:show(false)
end
local fog_rows = {}
for row = 1, 9 do
  local line = {}
  for col = 1, 160 do line[col] = ((col + row) % 2 == 0 and row % 3 ~= 0) and "z" or "." end
  fog_rows[row] = table.concat(line)
end
local fogs = {}
for i = 1, 3 do
  fogs[i] = ui.image(0, 0, fog_rows, { palette = { z = 0x8B86A8 }, scale = SCALE })
  fogs[i]:show(false)
end

local booms, boom_busy = {}, {}
local BOOM_ROWS = explosion_rows()
for i = 1, 6 do
  booms[i] = ui.image(0, 0, BOOM_ROWS, { scale = SCALE })
  booms[i]:show(false)
end
local top_marker = ui.rect(0, 0, 4, 3, { color = "yellow" })
top_marker:show(false)

local aim_dots = {}
for i = 1, 5 do
  local d = ui.rect(0, 0, 4, 4, { color = 0xFFFFFF, radius = 2 })
  d:show(false)
  aim_dots[i] = d
end

local hud_l = ui.label(4, 2, "", { size = 12, color = CAP[1] })
local hud_r = ui.label(W - 124, 2, "", { size = 12, color = CAP[2], w = 120, align = "right" })
local hud_wind = ui.label(0, 2, "", { size = 12, color = "dim", w = W, align = "center" })
local hud_aim = ui.label(0, 16, "", { size = 12, color = 0xFFFFFF, w = W, align = "center" })
local power_bar = ui.bar(W // 2 - 50, 31, 100, 5, 0)
local popup = ui.label(0, 40, "", { size = 14, color = "yellow", w = W, align = "center" })
local hud = { hud_l, hud_r, hud_wind, hud_aim, popup }

local panel = ui.rect(30, 62, W - 60, 74, { color = "panel", radius = 8, border = "border" })
local msg = ui.label(30, 74, "", { size = 20, color = 0xFFFFFF, w = W - 60, align = "center" })
local sub = ui.label(30, 106, "", { size = 14, color = "dim", w = W - 60, align = "center" })

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local state = "menu"     -- menu | lobby | aim | charge | wait | cpu | fly | boom | between | over
local mode = "cpu"       -- cpu | hot (pass the badge) | duo (two badges)
local level = 1          -- CPU: 1 easy, 2 hard
local menu_i = 1
local turn = 1           -- whose throw: 1 (left) or 2 (right)
local wins = { 0, 0 }    -- rounds won this match
local points = { 0, 0 }  -- points this match
local round = 0
local game_seed = 0
local wind = 0
local town = nil         -- this round's city: buildings and who owns each column
local aim = { { a = 45, p = 50, w = 1 }, { a = 45, p = 50, w = 1 } }
local ammo = { {}, {} }
local power = 0          -- while charging
local energy = 0         -- left this turn for walking, climbing and jumping
local jump = nil         -- { vx, vy } while the monkey is in the air
local move_acc = 0       -- ms towards the next pixel walked
local moved_at = 0       -- two badges: when we last told the other badge where we are
local now = 0
local acc = 0            -- ms not yet simulated
local flying = {}        -- projectiles in the air
local throw_info = nil   -- what this throw has done so far: { thrower, hit = {}, pts, news }
local shots = 0          -- throws so far this match (both badges count the same)
-- The CPU monkey: its thinking (a coroutine), misses this round, where it's walking to.
local CPU = { plan = nil, misses = 0, goal = nil, phase = "scout" }
local weather = "clear"
local river = nil        -- this round's Thames: { x0, x1, surface } or nil
local picked = {}        -- items picked up this turn (sent with the throw)
local popup_timer = nil

-- Two badges
local me = 1             -- which monkey this badge plays
local peer, peer_name, game_id = nil, "", 0
local pending = nil      -- my last throw, resent until the other badge confirms it
local pending_at = 0
local queued = nil       -- the other badge's throw, if it arrived early
local last_heard, last_keepalive = 0, 0
local sent_at = { -100000, -100000, -100000, -100000 }

-- Menus
local menu, menu_title, menu_panel = nil, nil, nil
-- The two-badge lobby: its screen objects, who we've heard, who we invited.
local LB = { list = nil, title = nil, info = nil, ids = {}, seen = {}, invited = nil, asking = nil, hello_timer = nil }

local match_wins = storage.get("match_wins") or { 0, 0, 0 }   -- easy, hard, two badges
local best_points = storage.get("best_points") or 0

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi end
  return v
end

local function show_message(a, b)
  local on = a ~= nil
  panel:show(on)
  msg:show(on)
  sub:show(on)
  if on then
    msg:text(a)
    sub:text(b or "")
  end
end

local function show_popup(text)
  popup:text(text)
  popup:show(true)
  if popup_timer then timer.cancel(popup_timer) end
  popup_timer = timer.after(2200, function()
    popup:show(false)
    popup_timer = nil
  end)
end

local function flash(r, g, b, ms)
  if not has_led then return end
  led.fill(r, g, b)
  timer.after(ms or 120, led.off)
end

local function name_of(id)
  if has_mesh then
    for _, p in ipairs(mesh.nearby()) do
      if p.id == id then
        if p.name and p.name ~= "" then return p.name end
        break
      end
    end
  end
  return id
end

local function player_name(i)
  if mode == "cpu" then return i == 1 and "YOU" or "CPU" end
  if mode == "duo" then return i == me and "YOU" or peer_name end
  return "P" .. i
end

local function radio_send(to, m)
  -- The badge's own clock: unlike `now`, it's exact inside timers too.
  local t = sys.millis()
  if t - sent_at[1] < 1000 then return false end   -- at most 4 a second
  table.remove(sent_at, 1)
  sent_at[4] = t
  mesh.send(to, m)
  return true
end

local function solid(x, y)
  local c = city:get(x, y)
  return c ~= nil and not EMPTY[c]
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------
local function draw_monkey(i, throwing)
  local m = monkeys[i]
  local want = (throwing and "throw_" or "stand_") .. (m.face > 0 and "r" or "l")
  for k, img in pairs(m.img) do
    if k == want and m.alive then
      img:pos(m.x * SCALE, m.y * SCALE)
      img:show(true)
    else
      img:show(false)
    end
  end
  -- health bar above the head, and the umbrella if it has one
  local sx, sy = m.x * SCALE + 1, m.y * SCALE - 5
  m.bar_bg:pos(sx, sy)
  m.bar_bg:show(m.alive)
  local w = math.max(1, math.floor(14 * m.hp / MAX_HP + 0.5))
  m.bar:size(math.min(14, w), 3)
  m.bar:color(m.hp > 60 and "green" or (m.hp > 30 and "yellow" or "orange"))
  m.bar:pos(sx, sy)
  m.bar:show(m.alive)
  m.brolly:pos(sx + 4, sy - 7)
  m.brolly:show(m.alive and m.umbrella)
end

local function draw_items()
  for k, it in ipairs(items) do
    for kind, img in pairs(item_imgs[k]) do
      if kind == it.kind and it.alive then
        img:pos(it.x * SCALE, it.y * SCALE)
        img:show(true)
      else
        img:show(false)
      end
    end
  end
end

local function hide_items()
  for k = 1, ITEMS_PER_ROUND do
    for _, img in pairs(item_imgs[k]) do img:show(false) end
  end
end

local function hide_weather()
  for _, d in ipairs(drops) do d.r:show(false) end
  for _, f in ipairs(fogs) do f:show(false) end
end

-- Moves the rain, snow and fog along (just for show).
local function weather_tick(ms)
  if weather == "rain" or weather == "snow" then
    local fall = weather == "rain" and 0.35 or 0.05
    local drift = wind * (weather == "rain" and 0.01 or 0.006)
    for _, d in ipairs(drops) do
      d.y = d.y + fall * ms
      d.x = d.x + drift * ms
      if d.y > 202 or d.x < -4 or d.x > W + 4 then
        d.x, d.y = math.random(0, W), math.random(-30, 0)
      end
      d.r:pos(math.floor(d.x), math.floor(d.y))
    end
  elseif weather == "fog" then
    for i, f in ipairs(fogs) do
      local t = now / (2400 + i * 700)
      f:pos(math.floor(math.sin(t) * 20) - 20, 40 + i * 44)
    end
  end
end

local function hide_projectiles()
  for _, s in pairs(SPRITES) do s:show(false) end
  for _, s in ipairs(banana_sprites) do s:show(false) end
  top_marker:show(false)
end

local function set_play_visible(on)
  city:show(on)
  for i = 1, 2 do
    if on then draw_monkey(i, false) else
      local m = monkeys[i]
      for _, img in pairs(m.img) do img:show(false) end
      m.bar:show(false) m.bar_bg:show(false) m.brolly:show(false)
    end
  end
  for _, l in ipairs(hud) do l:show(on) end
  popup:show(false)
  if on then draw_items() else hide_items() hide_weather() end
  if not on then
    power_bar:show(false)
    hide_projectiles()
    for _, b in ipairs(booms) do b:show(false) end
    for _, d in ipairs(aim_dots) do d:show(false) end
  end
end

-- Where a throw starts: just above the thrower's raised hand.
local function launch_point(i)
  local m = monkeys[i]
  if m.face > 0 then return m.x + 8, m.y - 1 end
  return m.x - 1, m.y - 1
end

local function launch_velocity(i, a, p, wp)
  local v = p * wp.speed
  local rad = math.rad(a)
  return monkeys[i].face * v * math.cos(rad), -v * math.sin(rad)
end

local function draw_aim()
  local show = state == "aim" or state == "charge"
  for _, d in ipairs(aim_dots) do d:show(show) end
  power_bar:show(show or state == "move")
  if state == "move" then power_bar:set(math.floor(energy * 100 / ENERGY)) end
  if not show then return end
  local a = aim[turn]
  local x, y = launch_point(turn)
  local vx, vy = launch_velocity(turn, a.a, 50, WEAPONS[1])
  local len = math.sqrt(vx * vx + vy * vy)
  local p = state == "charge" and power or a.p
  for k, d in ipairs(aim_dots) do
    if weather == "fog" and k > 2 then d:show(false) end     -- the fog hides the rest
    local dist = k * (4 + p * 0.12)
    d:pos(math.floor((x + vx / len * dist) * SCALE) - 2, math.floor((y + vy / len * dist) * SCALE) - 2)
  end
  power_bar:set(math.floor(p))
end

local function ammo_text(i, w)
  local n = ammo[i][w]
  if n < 0 then return WEAPONS[w].name end
  return WEAPONS[w].name .. " x" .. n
end

local function update_hud()
  hud_l:text(player_name(1) .. " " .. wins[1] .. "  " .. points[1] .. "pt")
  hud_r:text(points[2] .. "pt  " .. wins[2] .. " " .. player_name(2))
  local wx = weather == "clear" and "" or (weather:upper() .. "  ")
  if wind == 0 then
    hud_wind:text(wx .. "WIND calm")
  else
    hud_wind:text(wx .. "WIND " .. string.rep(wind > 0 and ">" or "<", math.abs(wind) // 4 + 1))
  end
  local a = aim[turn]
  if state == "move" then
    hud_aim:text(player_name(turn) .. ": walk, climb, jump   energy " .. math.floor(energy))
  elseif state == "aim" then
    hud_aim:text(player_name(turn) .. ": " .. ammo_text(turn, a.w) .. "  angle " .. a.a .. "  last " .. a.p)
  elseif state == "charge" then
    hud_aim:text(player_name(turn) .. ": " .. ammo_text(turn, a.w) .. "  power " .. math.floor(power))
  elseif state == "wait" then
    hud_aim:text(peer_name .. " is aiming...")
  elseif state == "cpu" or state == "cpumove" then
    hud_aim:text(state == "cpumove" and "CPU is on the move..." or "CPU is aiming...")
  end
  draw_aim()
end

---------------------------------------------------------------------------
-- Pickups
---------------------------------------------------------------------------
-- Lays this round's pickups on top of buildings. Uses its own random
-- numbers from the round's seed, so two badges place the same items.
local function place_items(seed)
  local r = sky.new_rng(seed + 17)
  items = {}
  local starts = { town.monkeys[1].x, town.monkeys[2].x }
  local tries = 0
  while #items < ITEMS_PER_ROUND and tries < 30 do
    tries = tries + 1
    local col = r.int(6, CW - 12)
    local ok = math.abs(col - starts[1]) > 10 and math.abs(col - starts[2]) > 10
    if river and col + 6 >= river.x0 - 1 and col <= river.x1 + 1 then ok = false end
    for _, it in ipairs(items) do
      if math.abs(it.x - col) < 10 then ok = false end
    end
    if ok then
      local top = nil
      for row = 4, GROUND_Y - 1 do
        local hit = false
        for c = col, col + 5 do
          if solid(c, row) then hit = true break end
        end
        if hit then top = row break end
      end
      if top and top > 24 then             -- not on a spire tip, under the score
        local kind = ITEM_KINDS[r.int(1, #ITEM_KINDS)]
        items[#items + 1] = { x = col, y = top - 6, kind = kind, weapon = r.int(2, #WEAPONS), alive = true }
      end
    end
  end
end

---------------------------------------------------------------------------
-- Turns and rounds
---------------------------------------------------------------------------
local function controller(i)
  if mode == "cpu" then return i == 1 and "human" or "cpu" end
  if mode == "duo" then return i == me and "human" or "remote" end
  return "human"
end

local start_cpu_turn   -- defined below

local function aim_hint()
  if has_keys then return "UP/DN aim  L/R weapon  hold SELECT  CANCEL walk" end
  return "UP/DN aim  L/R weapon  SELECT x2 throw  CANCEL walk"
end

local MOVE_HINT = "L/R walk + climb   UP jump   SELECT aim"

local function begin_turn()
  local who = controller(turn)
  picked = {}
  energy = ENERGY
  jump = nil
  if who == "human" then
    state = "move"
    ui.hint(MOVE_HINT)
  elseif who == "cpu" then
    state = "cpu"
    ui.hint("CANCEL menu")
    start_cpu_turn()
  else
    state = "wait"
    ui.hint("CANCEL quit")
  end
  update_hud()
end

local function new_round()
  round = round + 1
  local seed
  if mode == "duo" then
    seed = (game_seed + round * 7919) % 2147483646
  else
    seed = math.random(1, 2147483000)
  end
  town = sky.build(city, seed)
  wind = town.wind
  weather = town.weather
  river = town.river
  place_items(seed)
  for i = 1, 2 do
    local m = monkeys[i]
    m.x, m.y, m.alive = town.monkeys[i].x, town.monkeys[i].y, true
    m.face = i == 1 and 1 or -1
    m.cling = false
    m.hp, m.umbrella = MAX_HP, false
    for w, wp in ipairs(WEAPONS) do ammo[i][w] = wp.ammo end
    aim[i].w = 1
  end
  set_play_visible(true)
  show_message(nil)
  hide_weather()
  for _, d in ipairs(drops) do
    d.x, d.y = math.random(0, W), math.random(0, 200)
    if weather == "snow" then d.r:size(2, 2) d.r:color(0xF4F6FF) else d.r:size(1, 5) d.r:color(0x6F86C8) end
    d.r:show(weather == "rain" or weather == "snow")
  end
  for _, f in ipairs(fogs) do f:show(weather == "fog") end
  CPU.misses = 0
  turn = (round % 2 == 1) and 1 or 2      -- players take turns going first
  begin_turn()
end

local function start_match()
  wins = { 0, 0 }
  points = { 0, 0 }
  round = 0
  shots = 0
  aim = { { a = 45, p = 50, w = 1 }, { a = 45, p = 50, w = 1 } }
  new_round()
end

local function end_round(winner)
  wins[winner] = wins[winner] + 1
  update_hud()
  local line = "Rounds " .. wins[1] .. "-" .. wins[2] .. "   Points " .. points[1] .. "-" .. points[2]
  if wins[winner] >= WIN_ROUNDS then
    state = "over"
    local mine = (mode == "cpu" and winner == 1) or (mode == "duo" and winner == me)
    if mine then
      local k = mode == "duo" and 3 or level
      match_wins[k] = (match_wins[k] or 0) + 1
      storage.set("match_wins", match_wins)
    end
    local my_pts = mode == "duo" and points[me] or (mode == "cpu" and points[1] or math.max(points[1], points[2]))
    if my_pts > best_points then
      best_points = my_pts
      storage.set("best_points", best_points)
    end
    local title
    if mode == "hot" then title = "P" .. winner .. " WINS!"
    elseif mine then title = "YOU WIN!"
    else title = player_name(winner) .. " WINS" end
    show_message(title, line)
    ui.hint("SELECT play again   CANCEL menu")
  else
    state = "between"
    local who = player_name(winner)
    show_message(who .. (who == "YOU" and " WIN THE ROUND" or " WINS THE ROUND"), line)
    timer.after(2400, function()
      if state == "between" then new_round() end
    end)
  end
end

---------------------------------------------------------------------------
-- Throws, explosions and points
---------------------------------------------------------------------------
---------------------------------------------------------------------------
-- Moving about: walking, climbing, clinging and jumping
---------------------------------------------------------------------------
-- A monkey's body is columns x+1..x+6 and rows y..y+9 of the canvas.
local function body_free(x, y)
  if x + 1 < 0 or x + 6 >= CW or y < 0 or y + 9 >= GROUND_Y then return false end
  for row = y, y + 9 do
    for col = x + 1, x + 6 do
      if solid(col, row) then return false end
    end
  end
  return true
end

local function on_ground(m)
  if m.y + 10 >= GROUND_Y then return true end
  for col = m.x + 1, m.x + 6 do
    if solid(col, m.y + 10) then return true end
  end
  return false
end

-- Monkeys can hang on to a wall they have climbed (the wall on the side
-- they face). Falling past a wall doesn't count: only climbing grabs on.
local function clinging(m)
  if not m.cling then return false end
  local col = m.face > 0 and m.x + 7 or m.x
  for row = m.y, m.y + 9 do
    if solid(col, row) then return true end
  end
  return false
end

local function supported(m)
  return on_ground(m) or clinging(m)
end

-- One pixel of walking towards dir (-1 or 1): along the ground, up a small
-- step, or, against a wall, climbing it. Returns its energy cost and how
-- long it takes, or nil when there's no way on.
local function walk_step(m, dir)
  m.face = dir
  local extra = weather == "snow" and WX.SNOW_EXTRA or 0
  if body_free(m.x + dir, m.y) then
    m.x = m.x + dir
    m.cling = false
    return MV.WALK_COST + extra, MV.WALK_MS
  end
  for up = 1, 3 do
    if body_free(m.x + dir, m.y - up) then
      m.x, m.y = m.x + dir, m.y - up
      m.cling = false
      return MV.WALK_COST + up + extra, MV.WALK_MS
    end
  end
  if body_free(m.x, m.y - 1) then
    m.y = m.y - 1
    m.cling = true
    return MV.CLIMB_COST + extra, MV.CLIMB_MS
  end
  return nil
end

-- In the Thames? Monkeys can't swim.
local function drowned(m)
  return river ~= nil and m.x + 4 >= river.x0 and m.x + 4 <= river.x1 and m.y + 10 > river.surface
end

-- Picking things up: item k goes to monkey i.
local function take_item(i, k)
  local it = items[k]
  if not it or not it.alive then return end
  it.alive = false
  local m = monkeys[i]
  local text
  if it.kind == "health" then
    m.hp = math.min(MAX_HP, m.hp + HEALTH_PACK)
    text = "+" .. HEALTH_PACK .. " HEALTH"
  elseif it.kind == "umbrella" then
    m.umbrella = true
    text = "UMBRELLA! Blocks the next blast"
  else
    if ammo[i][it.weapon] >= 0 then ammo[i][it.weapon] = ammo[i][it.weapon] + 1 end
    text = "CRATE! +1 " .. WEAPONS[it.weapon].name
  end
  flash(0x14, 0xF1, 0x95, 150)
  show_popup(player_name(i) .. ": " .. text)
  draw_items()
  draw_monkey(i, false)
end

-- Anything monkey i is touching? record: note it for the other badge.
local function try_pickups(i, record)
  local m = monkeys[i]
  if not m.alive then return end
  for k, it in ipairs(items) do
    if it.alive and it.x + 5 >= m.x + 1 and it.x <= m.x + 6 and it.y + 5 >= m.y and it.y <= m.y + 9 then
      take_item(i, k)
      if record then picked[#picked + 1] = tostring(k) end
    end
  end
end

-- Pickups whose roof was blown away fall too (and sink in the river).
local function settle_items()
  for _, it in ipairs(items) do
    while it.alive and it.y + 6 < GROUND_Y do
      local under = false
      for c = it.x, it.x + 5 do
        if solid(c, it.y + 6) then under = true break end
      end
      if under then break end
      it.y = it.y + 1
    end
    if it.alive and river and it.x + 3 >= river.x0 and it.x + 3 <= river.x1 and it.y + 6 > river.surface then
      it.alive = false
    end
  end
  draw_items()
end

-- A monkey whose ground (or wall) was blown away drops until it stands on
-- something. Only depends on the city, so both badges agree.
local function settle_monkeys()
  for i = 1, 2 do
    local m = monkeys[i]
    if m.alive then
      local fell = false
      while not supported(m) and m.y + 10 < GROUND_Y do
        m.y = m.y + 1
        m.cling = false
        fell = true
      end
      if fell then draw_monkey(i, false) end
    end
  end
end

local function show_boom(x, y, blast)
  for k, b in ipairs(booms) do
    if not boom_busy[k] then
      local sc = blast <= 4 and 1 or (blast <= 7 and 2 or 3)
      b:scale(sc)
      b:pos(math.floor(x * SCALE) - 6 * sc - 3, math.floor(y * SCALE) - 6 * sc - 3)
      b:show(true)
      boom_busy[k] = true
      timer.after(350, function() b:show(false) boom_busy[k] = false end)
      return
    end
  end
end

-- Blows a hole, scores the damage for the thrower and notes which monkeys
-- were caught. Everything here only depends on the throw, so both badges
-- get the same numbers.
local function explode(x, y, wp)
  local blast = wp.blast
  x, y = math.floor(x + 0.5), math.floor(y + 0.5)
  local t = throw_info
  local bs = town.buildings
  for dy = -blast, blast do
    local yy = y + dy
    if yy >= 0 and yy < GROUND_Y then
      local half = math.floor(math.sqrt(blast * blast - dy * dy) + 0.5)
      for xx = x - half, x + half do
        if solid(xx, yy) then
          local k = town.owner[xx]
          local b = k and bs[k]
          if b then
            b.removed = b.removed + 1
            t.pts = t.pts + (b.value > 0 and PTS.ICON_PIXEL * b.value or PTS.PIXEL)
          end
        end
      end
      city:rect(x - half, yy, half * 2 + 1, 1, sky.SKY)
    end
  end
  for _, b in ipairs(bs) do
    if not b.destroyed and b.total > 0 and b.removed >= b.total * DESTROYED_AT then
      b.destroyed = true
      if b.value > 0 then
        t.pts = t.pts + PTS.ICON_DOWN * b.value
        t.news[#t.news + 1] = b.name .. " DESTROYED!"
        flash(0xFF, 0xD8, 0x4D, 300)
      else
        t.pts = t.pts + PTS.BLOCK_DOWN
      end
    end
  end
  -- Monkeys in reach take damage: all of it at the centre, 40% at the edge.
  for i = 1, 2 do
    local m = monkeys[i]
    local dx, dy = x - (m.x + 4), y - (m.y + 5)
    local reach = blast + 6               -- the blast, plus the monkey's own size
    local d = math.sqrt(dx * dx + dy * dy)
    if m.alive and d <= reach then
      if m.umbrella then
        m.umbrella = false
        local who = player_name(i)
        t.news[#t.news + 1] = (who == "YOU" and "YOUR" or who .. "'S") .. " UMBRELLA SAVED THEM"
      else
        t.dmg[i] = (t.dmg[i] or 0) + math.floor(wp.dmg * (1 - 0.6 * d / reach) + 0.5)
      end
    end
  end
  -- Pickups caught in the blast are gone.
  for _, it in ipairs(items) do
    local dx, dy = x - (it.x + 3), y - (it.y + 3)
    if it.alive and dx * dx + dy * dy <= (blast + 2) * (blast + 2) then it.alive = false end
  end
  show_boom(x, y, blast)
end

local function monkey_at(x, y, thrower, steps)
  for i = 1, 2 do
    local m = monkeys[i]
    if m.alive and (i ~= thrower or steps > SAFE_STEPS)
        and x >= m.x and x < m.x + 8 and y >= m.y and y < m.y + 10 then
      return i
    end
  end
  return nil
end

-- One physics step for a projectile p. Returns nil while it flies, or
-- "off" (left the screen at a side), "splash" (into the Thames), "ground",
-- "city" or "monkey".
local function step_projectile(p, check)
  local wp = p.wp
  p.vx = p.vx + wind * wp.wind * STEP
  p.vy = p.vy + (wp.grav + (weather == "rain" and WX.RAIN_GRAV or 0)) * STEP
  p.x = p.x + p.vx * STEP
  p.y = p.y + p.vy * STEP
  p.steps = p.steps + 1
  if p.x < 0 or p.x >= CW then return "off" end
  if river and p.x >= river.x0 and p.x < river.x1 + 1 and p.y >= river.surface
      and not solid(math.floor(p.x), math.floor(p.y)) then
    return "splash"
  end
  if p.y >= GROUND_Y then return "ground" end
  if p.y < 0 or not check then return nil end
  if monkey_at(p.x, p.y, p.thrower, p.steps) then return "monkey" end
  if solid(math.floor(p.x), math.floor(p.y)) then return "city" end
  return nil
end

local function resolve_throw()
  local t = throw_info
  hide_projectiles()
  draw_monkey(t.thrower, false)
  settle_monkeys()
  settle_items()
  for i = 1, 2 do try_pickups(i, false) end     -- fell onto something

  local lines = {}
  for i = 1, 2 do
    local m = monkeys[i]
    if m.alive then
      local dmg = math.min(m.hp, t.dmg[i] or 0)
      if drowned(m) then
        dmg = m.hp
        t.news[#t.news + 1] = "SPLASH! " .. player_name(i) .. " FELL IN THE THAMES"
      end
      if dmg > 0 then
        m.hp = m.hp - dmg
        if i ~= t.thrower then t.pts = t.pts + PTS.HP * dmg end
        lines[#lines + 1] = player_name(i) .. " -" .. dmg
      end
      if m.hp <= 0 then
        m.alive = false
        if i ~= t.thrower then t.pts = t.pts + PTS.KO end
      end
      draw_monkey(i, false)
    end
  end
  points[t.thrower] = points[t.thrower] + t.pts

  local text = t.news[1] or table.concat(lines, "  ")
  if t.pts > 0 then text = text .. (text ~= "" and "  " or "") .. "+" .. t.pts end
  if text ~= "" then show_popup(text) end
  update_hud()

  state = "boom"
  local out1, out2 = not monkeys[1].alive, not monkeys[2].alive
  if out1 or out2 then
    flash(0xFF, 0x75, 0x4A, 400)
    -- Both out (or the thrower knocked themselves out): the other monkey wins.
    local winner
    if out1 and out2 then winner = 3 - t.thrower else winner = out1 and 2 or 1 end
    timer.after(900, function() end_round(winner) end)
    return
  end
  if t.landed_near then CPU.misses = CPU.misses + 1 end
  turn = 3 - turn
  timer.after(600, function()
    if state == "boom" then begin_turn() end
  end)
end

-- A projectile has landed (or flown off a side).
local function land(p, kind)
  p.img:show(false)
  if kind == "splash" then
    flash(0x3A, 0x66, 0xB0, 120)
  elseif kind ~= "off" then
    explode(p.x, p.y, p.wp)
    flash(0xFF, 0xD8, 0x4D, 80)
    if p.wp.split then
      -- The bunch bursts into bananas, flying out from just above the hole.
      for k, v in ipairs(SPLIT_V) do
        flying[#flying + 1] = {
          x = p.x, y = p.y - p.wp.blast - 1, vx = v[1], vy = v[2],
          steps = SAFE_STEPS + 1, thrower = p.thrower, wp = BANANA, img = banana_sprites[k],
        }
      end
    end
  end
  throw_info.landed_near = true
end

local function throw(i, a, pw, w)
  local wp = WEAPONS[w]
  if ammo[i][w] == 0 then w, wp = 1, WEAPONS[1] end
  if ammo[i][w] > 0 then ammo[i][w] = ammo[i][w] - 1 end
  local x, y = launch_point(i)
  local vx, vy = launch_velocity(i, a, pw, wp)
  local img = SPRITES[wp.art]
  if wp.art == "rocket" and i == 2 then img = SPRITES.rocket_l end
  flying = { { x = x, y = y, vx = vx, vy = vy, steps = 0, thrower = i, wp = wp, img = img } }
  throw_info = { thrower = i, dmg = {}, pts = 0, news = {} }
  shots = shots + 1
  acc = 0
  state = "fly"
  draw_monkey(i, true)
  for _, d in ipairs(aim_dots) do d:show(false) end
  power_bar:show(false)
  hud_aim:text(player_name(i) .. ": " .. wp.name .. "  angle " .. a .. "  power " .. pw)
  ui.hint(mode == "duo" and "CANCEL quit" or "CANCEL menu")
end

local function draw_projectiles()
  local high = nil
  for _, p in ipairs(flying) do
    if p.y < 0 then
      p.img:show(false)
      high = p
    else
      p.img:pos(math.floor(p.x * SCALE) - 5, math.floor(p.y * SCALE) - 5)
      p.img:show(true)
    end
  end
  if high then
    top_marker:pos(math.floor(high.x * SCALE) - 2, 0)
    top_marker:show(true)
  else
    top_marker:show(false)
  end
end

local function fly_tick(ms)
  acc = acc + math.min(ms, 100)
  while acc >= STEP_MS and state == "fly" do
    acc = acc - STEP_MS
    local still = {}
    -- New bananas from a burst join the list during the loop: walk a copy.
    local list = flying
    flying = {}
    for _, p in ipairs(list) do
      local r = step_projectile(p, true)
      if r then land(p, r) else still[#still + 1] = p end
    end
    for _, p in ipairs(flying) do still[#still + 1] = p end
    flying = still
    if #flying == 0 then resolve_throw() end
  end
  if state == "fly" then draw_projectiles() end
end

---------------------------------------------------------------------------
-- The CPU monkey
---------------------------------------------------------------------------
-- Where would a throw land, ignoring buildings (x where it drops to the
-- target's height)? Coarse steps: this is the CPU "thinking", not the real throw.
local function landing_x(a, p, wp, target_y)
  local x, y = launch_point(2)
  local vx, vy = launch_velocity(2, a, p, wp)
  local dt = 1 / 40
  for _ = 1, 400 do
    vx = vx + wind * wp.wind * dt
    vy = vy + (wp.grav + (weather == "rain" and WX.RAIN_GRAV or 0)) * dt
    x = x + vx * dt
    y = y + vy * dt
    if vy > 0 and y >= target_y then return x end
    if x < -40 or x > CW + 40 then return x end
  end
  return x
end

-- Does this throw get to the target without hitting a building first?
local function clear_path(a, p, wp)
  local x, y = launch_point(2)
  local vx, vy = launch_velocity(2, a, p, wp)
  local b = { x = x, y = y, vx = vx, vy = vy, steps = 0, thrower = 2, wp = wp }
  local target = monkeys[1]
  for _ = 1, 250 do
    local r
    for _ = 1, 3 do                       -- 3 steps at a time is enough to see a wall
      r = step_projectile(b, false)
      if r then break end
    end
    if r then return false end
    if b.y >= 0 and monkey_at(b.x, b.y, 2, 999) == 1 then return true end
    if b.y >= 0 and solid(math.floor(b.x), math.floor(b.y)) then
      return math.abs(b.x - (target.x + 4)) < wp.blast
    end
  end
  return false
end

local function choose_weapon()
  local roll = math.random()
  local a = ammo[2]
  if a[4] > 0 and roll < 0.15 then return 4 end
  if a[3] > 0 and roll < 0.40 then return 3 end
  if a[2] > 0 and roll < 0.60 then return 2 end
  return 1
end

-- Plans one angle per tick (a coroutine), so the thinking never runs into
-- the badge's per-callback instruction limit.
local function plan()
  local me_m, target_m = monkeys[2], monkeys[1]
  me_m.face = (target_m.x > me_m.x) and 1 or -1
  draw_monkey(2, false)
  local face = me_m.face
  local w = choose_weapon()
  local wp = WEAPONS[w]
  local target = monkeys[1]
  local tx, ty = target.x + 4, target.y + 5
  local best, best_err = nil, math.huge
  local angles = wp.grav < 50 and { 10, 20, 30, 40, 50, 60 } or { 30, 40, 50, 60, 65, 70, 75 }
  for _, a in ipairs(angles) do
    -- Binary search on power for this angle.
    local lo, hi = 5, 100
    for _ = 1, 14 do
      local mid = (lo + hi) / 2
      -- short of the target (on our side of it): more power
      if (landing_x(a, mid, wp, ty) - tx) * face < 0 then lo = mid else hi = mid end
    end
    local p = (lo + hi) / 2
    local err = math.abs(landing_x(a, p, wp, ty) - tx)
    coroutine.yield()
    if err < 3 and clear_path(a, p, wp) then best = { a = a, p = p } break end
    if err < best_err then best, best_err = { a = a, p = p }, err end
    coroutine.yield()
  end
  -- Aim like a monkey, not a computer: a mistake that shrinks every miss.
  local spread = level == 1 and 15 * (0.78 ^ CPU.misses) or 5 * (0.55 ^ CPU.misses)
  local p = clamp(math.floor(best.p + (math.random() * 2 - 1) * spread + 0.5), 1, 100)
  local a = clamp(best.a + math.random(-2, 2), 5, 85)
  return a, p, w
end

-- How good is spot c (a monkey position) for the CPU monkey? Higher ground,
-- a wall between it and the player (cover), and pickups all count.
local function spot_score(c)
  local target = monkeys[1]
  local sc = (GROUND_Y - c.y) * 0.8
  local dir = target.x > c.x and 1 or -1
  for k = 3, 16 do
    if solid(c.x + 4 + dir * k, c.y - 3) then sc = sc + 14 break end
  end
  for _, it in ipairs(items) do
    if it.alive and math.abs(it.x - c.x) < 6 and math.abs(it.y - c.y) < 10 then
      sc = sc + ((it.kind == "health" and monkeys[2].hp < 80) and 40 or 15)
    end
  end
  if c.x < 4 or c.x > CW - 12 then sc = sc - 20 end
  return sc
end

-- Walks an imaginary monkey both ways as far as its energy goes and keeps
-- the best spot. A coroutine: it yields every few steps, so it never runs
-- into the per-callback instruction limit. Easy picks more randomly.
local function scout()
  local m = monkeys[2]
  local noise = level == 1 and 25 or 4
  local best = { x = m.x, dir = 0, score = spot_score(m) + 6 }    -- staying put is slightly favoured
  for _, dir in ipairs({ -1, 1 }) do
    local c = { x = m.x, y = m.y, face = m.face, cling = m.cling }
    local e, n = ENERGY, 0
    while e > 0 do
      local cost = walk_step(c, dir)
      if not cost then break end
      e = e - cost
      while not supported(c) and c.y + 10 < GROUND_Y do
        c.y = c.y + 1
        c.cling = false
      end
      if drowned(c) then break end
      n = n + 1
      if n % 3 == 0 then
        local sc = spot_score(c) - n * 0.15 + (math.random() * 2 - 1) * noise
        if sc > best.score then best = { x = c.x, dir = dir, score = sc } end
        coroutine.yield()
      end
    end
  end
  return best
end


local function start_planning()
  CPU.phase = "plan"
  CPU.plan = coroutine.create(plan)
  state = "cpu"
  update_hud()
end

function start_cpu_turn()
  CPU.phase = "scout"
  CPU.plan = coroutine.create(scout)
end

local function cpu_tick()
  if not CPU.plan then return end
  local ok, a, p, w = coroutine.resume(CPU.plan)
  if not ok then error(a) end
  if coroutine.status(CPU.plan) == "dead" and CPU.phase == "scout" then
    CPU.plan = nil
    local goal = a
    if goal.dir ~= 0 and goal.x ~= monkeys[2].x then
      CPU.goal = { x = goal.x, dir = goal.dir, since = now, last_move = now }
      state = "cpumove"
      update_hud()
    else
      start_planning()
    end
    return
  end
  if coroutine.status(CPU.plan) == "dead" then
    CPU.plan = nil
    aim[2].a, aim[2].p, aim[2].w = a, p, w
    hud_aim:text("CPU: " .. WEAPONS[w].name)
    timer.after(700, function()
      if state == "cpu" then throw(2, a, p, w) end
    end)
  end
end

---------------------------------------------------------------------------
-- Two badges: throws over the radio
---------------------------------------------------------------------------
local function send_throw()
  if pending and peer then
    radio_send(peer, pending)
    pending_at = now
  end
end

local function net_tick()
  if not peer then return end
  if pending and now - pending_at >= NET.RESEND_EVERY then send_throw() end
  if now - last_keepalive >= NET.KEEPALIVE_EVERY then
    if radio_send(peer, { t = "k", g = game_id, n = shots }) then last_keepalive = now end
  end
  if state ~= "over" and now - last_heard > NET.LOST_AFTER then
    peer = nil
    state = "over"
    set_play_visible(true)
    show_message("CONNECTION LOST", "Can't hear " .. peer_name)
    ui.hint("SELECT lobby   CANCEL menu")
  end
end

local function local_throw()
  local a = aim[turn]
  a.p = clamp(math.floor(power + 0.5), 1, 100)
  throw(turn, a.a, a.p, a.w)
  if mode == "duo" then
    local m = monkeys[turn]
    pending = { t = "th", g = game_id, n = shots, a = a.a, p = a.p, w = a.w,
      x = m.x, y = m.y, f = m.face, c = m.cling and 1 or 0, k = table.concat(picked) }
    send_throw()
  end
end

-- The monkey whose turn it is walked (or fell) into the Thames: the turn
-- ends without a throw. On two badges this goes out as a "throw" with
-- weapon 0, so the other badge sees the same.
local function sink(i)
  local m = monkeys[i]
  shots = shots + 1
  if mode == "duo" and controller(i) == "human" then
    pending = { t = "th", g = game_id, n = shots, a = 0, p = 0, w = 0,
      x = m.x, y = m.y, f = m.face, c = 0, k = table.concat(picked) }
    send_throw()
  end
  throw_info = { thrower = i, dmg = {}, pts = 0, news = {} }
  resolve_throw()
end

-- The other badge's throw number n (count of throws including it).
local function remote_throw(m)
  if m.n == shots + 1 and state == "wait" then
    local mk = monkeys[turn]
    if m.x then mk.x, mk.y, mk.face, mk.cling = m.x, m.y, m.f, m.c == 1 end
    for ch in tostring(m.k or ""):gmatch("%d") do take_item(turn, tonumber(ch)) end
    draw_monkey(turn, false)
    if m.w == 0 then                      -- they fell in the Thames
      shots = shots + 1
      throw_info = { thrower = turn, dmg = {}, pts = 0, news = {} }
      resolve_throw()
      return
    end
    aim[turn].a, aim[turn].p, aim[turn].w = m.a, m.p, m.w or 1
    throw(turn, m.a, m.p, m.w or 1)
  elseif m.n == shots + 1 then
    queued = m                          -- still finishing the last throw here
  end
end

-- LEFT/RIGHT: the next weapon that still has ammo.
local function cycle_weapon(dir)
  local a = aim[turn]
  for _ = 1, #WEAPONS do
    a.w = (a.w - 1 + dir) % #WEAPONS + 1
    if ammo[turn][a.w] ~= 0 then return end
  end
end

---------------------------------------------------------------------------
-- Menus
---------------------------------------------------------------------------
local close_menu, close_lobby, open_lobby

local function menu_items()
  local function right(n) return n > 0 and ("wins " .. n) or nil end
  return {
    { title = "1 player: Easy", right = right(match_wins[1] or 0) },
    { title = "1 player: Hard", right = right(match_wins[2] or 0) },
    { title = "2 players: pass the badge", right = best_points > 0 and ("best " .. best_points) or nil },
    { title = "2 players: 2 badges", right = right(match_wins[3] or 0) },
  }
end

local function open_menu()
  state = "menu"
  peer, pending, queued = nil, nil, nil
  flying = {}
  show_message(nil)
  if has_led then led.off() end
  -- A fresh skyline behind the menu.
  town = sky.build(city, math.random(1, 2147483000))
  river, weather, items = town.river, "clear", {}
  hide_weather()
  for i = 1, 2 do
    monkeys[i].x, monkeys[i].y, monkeys[i].alive = town.monkeys[i].x, town.monkeys[i].y, true
    monkeys[i].hp, monkeys[i].umbrella = MAX_HP, false
  end
  set_play_visible(true)
  for _, l in ipairs(hud) do l:show(false) end
  power_bar:show(false)
  menu_panel = ui.rect(0, 0, W, 36, { color = sky.SKY })
  menu_title = ui.label(0, 8, "SOLANA MONKEY BOMB", { size = 20, color = 0xFFFFFF, w = W, align = "center" })
  menu = ui.list(40, 52, W - 80, 144, menu_items(), {
    on_select = function(i)
      menu_i = i
      if i <= 2 then
        close_menu()
        mode, level = "cpu", i
        start_match()
      elseif i == 3 then
        close_menu()
        mode = "hot"
        start_match()
      elseif not has_mesh then
        ui.toast("Two-badge games need the mesh radio")
      else
        close_menu()
        open_lobby()
      end
    end,
  })
  menu:select(menu_i)
  ui.hint("SELECT play   CANCEL exit")
end

function close_menu()
  if menu then menu:remove() menu = nil end
  if menu_title then menu_title:remove() menu_title = nil end
  if menu_panel then menu_panel:remove() menu_panel = nil end
end

local function refresh_lobby()
  if not LB.list then return end
  LB.ids = {}
  for id, t in pairs(LB.seen) do
    if now - t < 4000 then LB.ids[#LB.ids + 1] = id end
  end
  table.sort(LB.ids)
  local items = {}
  for i, id in ipairs(LB.ids) do
    items[i] = { title = name_of(id), right = LB.invited == id and "invited" or nil }
  end
  LB.list:items(items)
  LB.info:text(#items == 0 and "Looking for players... Open Monkey Bomb on another badge."
    or "Pick a player and press SELECT to invite them.")
end

function open_lobby()
  state = "lobby"
  LB.invited, LB.asking, LB.seen = nil, nil, {}
  set_play_visible(false)
  show_message(nil)
  LB.title = ui.label(0, 8, "2 PLAYERS", { size = 20, color = 0xFFFFFF, w = W, align = "center" })
  LB.info = ui.label(16, 36, "", { size = 12, color = "dim", w = W - 32, align = "center" })
  LB.list = ui.list(40, 60, W - 80, 140, {}, {
    on_select = function(i)
      local id = LB.ids[i]
      if not id then return end
      LB.invited = id
      radio_send(id, { t = "inv" })
      ui.toast("Invite sent to " .. name_of(id))
      refresh_lobby()
    end,
  })
  ui.hint("SELECT invite   CANCEL back")
  radio_send("*", { t = "hi" })
  LB.hello_timer = timer.every(NET.HELLO_EVERY, function()
    if state == "lobby" then
      radio_send("*", { t = "hi" })
      if LB.invited then radio_send(LB.invited, { t = "inv" }) end
      refresh_lobby()
    end
  end)
  refresh_lobby()
end

function close_lobby()
  if LB.hello_timer then timer.cancel(LB.hello_timer) LB.hello_timer = nil end
  if LB.list then LB.list:remove() LB.list = nil end
  if LB.title then LB.title:remove() LB.title = nil end
  if LB.info then LB.info:remove() LB.info = nil end
end

-- host: the badge that sent the invite plays the left monkey.
local function start_duo(id, g, host)
  close_lobby()
  mode = "duo"
  peer, peer_name, game_id, game_seed = id, name_of(id), g, g
  me = host and 1 or 2
  pending, queued = nil, nil
  last_heard = now
  start_match()
end

local function accept_invite(id)
  local g = math.random(1, 2147483000)
  radio_send(id, { t = "go", g = g })
  timer.after(400, function() radio_send(id, { t = "go", g = g }) end)
  start_duo(id, g, false)
end

---------------------------------------------------------------------------
-- Callbacks
---------------------------------------------------------------------------
function on_mesh(from, m)
  if type(m) ~= "table" then return end
  if m.t == "hi" then
    local is_new = LB.seen[from] == nil
    LB.seen[from] = now
    if state == "lobby" and is_new then refresh_lobby() end
  elseif m.t == "inv" then
    LB.seen[from] = now
    if state == "lobby" and LB.asking == nil then
      if LB.invited == from then
        if badge.id() and badge.id() < from then accept_invite(from) end
        return
      end
      LB.asking = from
      ui.confirm(name_of(from) .. " wants to play Monkey Bomb. Play?", function(yes)
        LB.asking = nil
        if yes and state == "lobby" then accept_invite(from) end
      end)
    end
  elseif m.t == "go" or m.t == "k" or m.t == "th" or m.t == "ok" then
    if state == "lobby" and LB.invited == from and m.g then
      start_duo(from, m.g, true)       -- also covers a lost "go"
    end
    if mode ~= "duo" or from ~= peer or m.g ~= game_id then return end
    last_heard = now
    if m.t == "th" then
      if m.n <= shots + 1 then radio_send(peer, { t = "ok", g = game_id, n = m.n }) end
      remote_throw(m)
    elseif m.t == "ok" then
      if pending and m.n >= pending.n then pending = nil end
    end
  elseif m.t == "mv" then
    if mode == "duo" and from == peer and m.g == game_id and state == "wait" then
      local mk = monkeys[turn]
      mk.x, mk.y, mk.face = m.x, m.y, m.f
      draw_monkey(turn, false)
      last_heard = now
    end
  elseif m.t == "bye" then
    if mode == "duo" and from == peer and m.g == game_id and state ~= "over" then
      peer = nil
      state = "over"
      hide_projectiles()
      show_message("PLAYER LEFT", peer_name .. " quit the game")
      ui.hint("SELECT lobby   CANCEL menu")
    end
  end
end

-- Two badges: let the other badge see us moving (only for show: the throw
-- message carries the real position).
local function tell_position(m)
  if mode == "duo" and peer and now - moved_at >= 400 then
    if radio_send(peer, { t = "mv", g = game_id, x = m.x, y = m.y, f = m.face }) then moved_at = now end
  end
end

local function move_tick(ms, forced_dir)
  local m = monkeys[turn]
  local before_x, before_y = m.x, m.y
  ms = math.min(ms, 100)
  if jump then
    -- In the air: fixed small steps, at most a pixel each way per step.
    jump.t = jump.t + ms
    while jump and jump.t >= STEP_MS do
      jump.t = jump.t - STEP_MS
      jump.vy = jump.vy + MV.JUMP_G * STEP
      jump.fx = jump.fx + jump.vx * STEP
      jump.fy = jump.fy + jump.vy * STEP
      local nx, ny = math.floor(jump.fx + 0.5), math.floor(jump.fy + 0.5)
      if nx ~= m.x then
        local d = nx > m.x and 1 or -1
        if body_free(m.x + d, m.y) then m.x = m.x + d else jump.vx = 0 jump.fx = m.x end
      end
      if ny > m.y then
        if body_free(m.x, m.y + 1) then m.y = m.y + 1 else jump = nil end
      elseif ny < m.y then
        if body_free(m.x, m.y - 1) then m.y = m.y - 1 else jump.vy = 0 jump.fy = m.y end
      end
    end
  elseif not supported(m) then
    -- Falling.
    move_acc = move_acc + ms
    while move_acc >= 1000 / MV.FALL_SPEED and not supported(m) do
      move_acc = move_acc - 1000 / MV.FALL_SPEED
      m.y = m.y + 1
    end
    if supported(m) then move_acc = 0 end
  else
    local dir = forced_dir
    if dir == nil then
      local k = has_keys and sys.keys() or {}
      dir = (k.right and not k.left) and 1 or ((k.left and not k.right) and -1 or 0)
    end
    if dir ~= 0 and energy > 0 then
      move_acc = move_acc + ms
      while move_acc >= MV.WALK_MS and energy > 0 do
        local cost, took = walk_step(m, dir)
        if not cost then move_acc = 0 break end
        energy = math.max(0, energy - cost)
        move_acc = move_acc - took
        if not supported(m) then break end     -- walked off an edge: fall
      end
    else
      move_acc = 0
    end
  end
  if m.x ~= before_x or m.y ~= before_y then
    draw_monkey(turn, false)
    tell_position(m)
    try_pickups(turn, true)
    update_hud()
    if drowned(m) then sink(turn) end
  end
end

-- The CPU monkey walking to the spot it picked.
local function cpu_move_tick(ms)
  local m, g = monkeys[2], CPU.goal
  local bx, by = m.x, m.y
  move_tick(ms, (m.x ~= g.x) and g.dir or 0)
  if state ~= "cpumove" then return end            -- it fell in the river
  if m.x ~= bx or m.y ~= by then g.last_move = now end
  local arrived = m.x == g.x and supported(m) and not jump
  if arrived or energy <= 0 or now - g.last_move > 600 or now - g.since > 6000 then
    if supported(m) then start_planning() end
  end
end

function on_tick(ms)
  now = now + ms
  if mode == "duo" and state ~= "menu" and state ~= "lobby" then net_tick() end
  if state ~= "menu" and state ~= "lobby" then weather_tick(ms) end

  if state == "charge" then
    power = math.min(100, power + ms * 100 / CHARGE_MS)
    local held = has_keys and sys.keys().select
    if (has_keys and not held) or power >= 100 then
      local_throw()
    else
      update_hud()
    end
  elseif state == "cpu" then
    cpu_tick()
  elseif state == "wait" and queued then
    local m = queued
    queued = nil
    remote_throw(m)
  elseif state == "fly" then
    fly_tick(ms)
  elseif state == "move" then
    move_tick(ms)
  elseif state == "cpumove" then
    cpu_move_tick(ms)
  end
end

local function leave_duo()
  if peer then
    radio_send(peer, { t = "bye", g = game_id })
    peer = nil
  end
end

function on_key(key, rep)
  if state == "menu" then return key ~= "back" end

  if state == "lobby" then
    if key == "back" and not rep then
      close_lobby()
      open_menu()
    end
    return true
  end

  if key == "back" and (state == "aim" or state == "charge") then
    if not rep and state == "aim" then        -- back to walking
      state = "move"
      ui.hint(MOVE_HINT)
      update_hud()
    end
    return true
  end

  if state == "move" then
    local m = monkeys[turn]
    if key == "select" and not rep then
      if supported(m) and not jump then
        state = "aim"
        ui.hint(aim_hint())
        update_hud()
      end
      return true
    elseif key == "up" and not rep then
      if supported(m) and not jump and energy >= MV.JUMP_COST then
        energy = energy - MV.JUMP_COST
        m.cling = false
        jump = { vx = m.face * MV.JUMP_VX, vy = MV.JUMP_VY, fx = m.x, fy = m.y, t = 0 }
        update_hud()
      end
      return true
    elseif key == "left" or key == "right" then
      local dir = key == "right" and 1 or -1
      if m.face ~= dir then
        m.face = dir
        draw_monkey(turn, false)
        tell_position(m)
      elseif not has_keys and supported(m) and energy > 0 then
        local cost = walk_step(m, dir)               -- older badges: a step per press
        if cost then energy = math.max(0, energy - cost) draw_monkey(turn, false) end
      end
      update_hud()
      return true
    end
  end

  if key == "back" then
    if rep then return true end
    if mode == "duo" then leave_duo() end
    CPU.plan = nil
    flying = {}
    open_menu()
    return true
  end

  if state == "aim" then
    local a = aim[turn]
    if key == "up" then a.a = clamp(a.a + (rep and 2 or 1), 0, 90)
    elseif key == "down" then a.a = clamp(a.a - (rep and 2 or 1), 0, 90)
    elseif (key == "right" or key == "left") and not rep then cycle_weapon(key == "right" and 1 or -1)
    elseif key == "select" and not rep then
      state = "charge"                  -- the power meter starts filling
      power = 0
    end
    update_hud()
    return true
  end

  if state == "charge" then
    -- Without sys.keys (older badges) a second SELECT throws.
    if key == "select" and not has_keys and not rep then local_throw() end
    return true
  end

  if state == "over" and key == "select" and not rep then
    if mode == "duo" then
      leave_duo()
      open_lobby()
    else
      start_match()
    end
  end
  return true
end

function on_exit()
  if mode == "duo" then leave_duo() end
  if has_led then led.off() end
end

---------------------------------------------------------------------------
show_message(nil)
open_menu()
