-- Solana Monkey Bomb (SMB): two monkeys on the London skyline take turns
-- lobbing weapons at each other. Aim, pick a weapon, hold SELECT to charge
-- the throw, mind the wind, and blow holes in London's landmarks for points.
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

-- Points
local PTS_PIXEL = 1                  -- per pixel of an ordinary block destroyed
local PTS_ICON_PIXEL = 1             -- times a landmark's value (1..3), per pixel
local DESTROYED_AT = 0.55            -- share of a building gone to count as destroyed
local PTS_BLOCK_DOWN = 20
local PTS_ICON_DOWN = 100            -- times the landmark's value
local PTS_MONKEY = 250

-- Mesh radio (two-badge games).
local HELLO_EVERY = 1200
local KEEPALIVE_EVERY = 2000
local RESEND_EVERY = 700
local LOST_AFTER = 15000

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
}
local ART_PAL = { palette = { q = 0x9AA0A6, c = 0x6B4423, d = 0x3B2412 }, scale = SCALE }

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
--   ammo: per player per round (-1 = unlimited); split: bananas it bursts into.
---------------------------------------------------------------------------
local WEAPONS = {
  { name = "BOMB",         ammo = -1, speed = 1.35, grav = 80, wind = 1.0, blast = 6,  art = "bomb" },
  { name = "BANANA BUNCH", ammo = 2,  speed = 1.35, grav = 80, wind = 1.0, blast = 4,  art = "bunch", split = 5 },
  { name = "BAZOOKA",      ammo = 3,  speed = 1.9,  grav = 28, wind = 1.6, blast = 7,  art = "rocket" },
  { name = "COCONUT",      ammo = 1,  speed = 1.25, grav = 90, wind = 0.7, blast = 11, art = "coconut" },
}
local BANANA = { name = "banana", speed = 1, grav = 80, wind = 1.0, blast = 4, art = "banana" }
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
for _, c in ipairs({ sky.SKY, sky.STAR, sky.MOON, sky.MOON_SHADE }) do
  city:pixel(0, 0, c)
  EMPTY[city:get(0, 0)] = true
end

local monkeys = {}
for i = 1, 2 do
  local pal = { palette = { h = CAP[i], n = 0x8B5A2B, f = 0xE0B98A }, scale = SCALE }
  local m = { x = 0, y = 0, alive = true }
  m.stand = ui.image(0, 0, i == 1 and MONKEY_STAND or mirror(MONKEY_STAND, 8), pal)
  m.throw = ui.image(0, 0, i == 1 and MONKEY_THROW or mirror(MONKEY_THROW, 8), pal)
  m.stand:show(false)
  m.throw:show(false)
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
local now = 0
local acc = 0            -- ms not yet simulated
local flying = {}        -- projectiles in the air
local throw_info = nil   -- what this throw has done so far: { thrower, hit = {}, pts, news }
local shots = 0          -- throws so far this match (both badges count the same)
local cpu_plan = nil
local cpu_misses = 0
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
local lobby_list, lobby_title, lobby_info = nil, nil, nil
local lobby_ids, seen = {}, {}
local invited, asking, hello_timer = nil, nil, nil

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
  if now - sent_at[1] < 1000 then return false end   -- at most 4 a second
  table.remove(sent_at, 1)
  sent_at[4] = now
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
  local sx, sy = m.x * SCALE, m.y * SCALE
  m.stand:pos(sx, sy)
  m.throw:pos(sx, sy)
  m.stand:show(m.alive and not throwing)
  m.throw:show(m.alive and throwing)
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
      monkeys[i].stand:show(false)
      monkeys[i].throw:show(false)
    end
  end
  for _, l in ipairs(hud) do l:show(on) end
  popup:show(false)
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
  if i == 1 then return m.x + 8, m.y - 1 end
  return m.x - 1, m.y - 1
end

local function launch_velocity(i, a, p, wp)
  local v = p * wp.speed
  local rad = math.rad(a)
  local dir = i == 1 and 1 or -1
  return dir * v * math.cos(rad), -v * math.sin(rad)
end

local function draw_aim()
  local show = state == "aim" or state == "charge"
  for _, d in ipairs(aim_dots) do d:show(show) end
  power_bar:show(show)
  if not show then return end
  local a = aim[turn]
  local x, y = launch_point(turn)
  local vx, vy = launch_velocity(turn, a.a, 50, WEAPONS[1])
  local len = math.sqrt(vx * vx + vy * vy)
  local p = state == "charge" and power or a.p
  for k, d in ipairs(aim_dots) do
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
  if wind == 0 then
    hud_wind:text("WIND calm")
  else
    hud_wind:text("WIND " .. string.rep(wind > 0 and ">" or "<", math.abs(wind) // 4 + 1))
  end
  local a = aim[turn]
  if state == "aim" then
    hud_aim:text(player_name(turn) .. ": " .. ammo_text(turn, a.w) .. "  angle " .. a.a .. "  last " .. a.p)
  elseif state == "charge" then
    hud_aim:text(player_name(turn) .. ": " .. ammo_text(turn, a.w) .. "  power " .. math.floor(power))
  elseif state == "wait" then
    hud_aim:text(peer_name .. " is aiming...")
  elseif state == "cpu" then
    hud_aim:text("CPU is aiming...")
  end
  draw_aim()
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
  if has_keys then return "UP/DN aim  L/R weapon  hold SELECT throw" end
  return "UP/DN aim  L/R weapon  SELECT power, SELECT throw"
end

local function begin_turn()
  local who = controller(turn)
  if who == "human" then
    state = "aim"
    ui.hint(aim_hint())
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
  for i = 1, 2 do
    local m = monkeys[i]
    m.x, m.y, m.alive = town.monkeys[i].x, town.monkeys[i].y, true
    for w, wp in ipairs(WEAPONS) do ammo[i][w] = wp.ammo end
    aim[i].w = 1
  end
  set_play_visible(true)
  show_message(nil)
  cpu_misses = 0
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
-- A monkey whose roof was blown away drops until it stands on something.
local function settle_monkeys()
  for i = 1, 2 do
    local m = monkeys[i]
    if m.alive then
      local fell = false
      while m.y + 10 < GROUND_Y do
        local under = false
        for fx = m.x + 1, m.x + 6 do
          if solid(fx, m.y + 10) then under = true break end
        end
        if under then break end
        m.y = m.y + 1
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
local function explode(x, y, blast)
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
            t.pts = t.pts + (b.value > 0 and PTS_ICON_PIXEL * b.value or PTS_PIXEL)
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
        t.pts = t.pts + PTS_ICON_DOWN * b.value
        t.news[#t.news + 1] = b.name .. " DESTROYED!"
        flash(0xFF, 0xD8, 0x4D, 300)
      else
        t.pts = t.pts + PTS_BLOCK_DOWN
      end
    end
  end
  for i = 1, 2 do
    local m = monkeys[i]
    local dx, dy = x - (m.x + 4), y - (m.y + 5)
    local reach = blast + 2               -- the blast, plus the monkey's own size
    if m.alive and dx * dx + dy * dy <= reach * reach then t.hit[i] = true end
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
-- "off" (left the screen at a side), "ground", "city" or "monkey".
local function step_projectile(p, check)
  local wp = p.wp
  p.vx = p.vx + wind * wp.wind * STEP
  p.vy = p.vy + wp.grav * STEP
  p.x = p.x + p.vx * STEP
  p.y = p.y + p.vy * STEP
  p.steps = p.steps + 1
  if p.x < 0 or p.x >= CW then return "off" end
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

  local hit = {}
  for i = 1, 2 do
    if t.hit[i] then
      hit[#hit + 1] = i
      monkeys[i].alive = false
      draw_monkey(i, false)
    end
  end
  if #hit > 0 and not t.hit[t.thrower] then t.pts = t.pts + PTS_MONKEY end
  points[t.thrower] = points[t.thrower] + t.pts

  local news = t.news[1]
  if news then
    show_popup(news .. "  +" .. t.pts)
  elseif t.pts > 0 then
    show_popup("+" .. t.pts .. " pts")
  end
  update_hud()

  state = "boom"
  if #hit > 0 then
    flash(0xFF, 0x75, 0x4A, 400)
    -- If the thrower got caught in their own blast, the other monkey wins.
    local winner = t.hit[t.thrower] and (3 - t.thrower) or t.thrower
    timer.after(700, function() end_round(winner) end)
    return
  end
  if t.landed_near then cpu_misses = cpu_misses + 1 end
  turn = 3 - turn
  timer.after(600, function()
    if state == "boom" then begin_turn() end
  end)
end

-- A projectile has landed (or flown off a side).
local function land(p, kind)
  p.img:show(false)
  if kind ~= "off" then
    explode(p.x, p.y, p.wp.blast)
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
  throw_info = { thrower = i, hit = {}, pts = 0, news = {} }
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
    vy = vy + wp.grav * dt
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
  local w = choose_weapon()
  local wp = WEAPONS[w]
  local target = monkeys[1]
  local tx, ty = target.x + 4, target.y + 5
  local best, best_err = nil, math.huge
  local angles = wp.grav < 50 and { 10, 20, 30, 40, 50, 60 } or { 30, 40, 50, 60, 65, 70, 75 }
  for _, a in ipairs(angles) do
    -- More power lands further left (towards the target): binary search.
    local lo, hi = 5, 100
    for _ = 1, 14 do
      local mid = (lo + hi) / 2
      if landing_x(a, mid, wp, ty) > tx then lo = mid else hi = mid end
    end
    local p = (lo + hi) / 2
    local err = math.abs(landing_x(a, p, wp, ty) - tx)
    coroutine.yield()
    if err < 3 and clear_path(a, p, wp) then best = { a = a, p = p } break end
    if err < best_err then best, best_err = { a = a, p = p }, err end
    coroutine.yield()
  end
  -- Aim like a monkey, not a computer: a mistake that shrinks every miss.
  local spread = level == 1 and 15 * (0.78 ^ cpu_misses) or 5 * (0.55 ^ cpu_misses)
  local p = clamp(math.floor(best.p + (math.random() * 2 - 1) * spread + 0.5), 1, 100)
  local a = clamp(best.a + math.random(-2, 2), 5, 85)
  return a, p, w
end

function start_cpu_turn()
  cpu_plan = coroutine.create(plan)
end

local function cpu_tick()
  if not cpu_plan then return end
  local ok, a, p, w = coroutine.resume(cpu_plan)
  if not ok then error(a) end
  if coroutine.status(cpu_plan) == "dead" then
    cpu_plan = nil
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
  if pending and now - pending_at >= RESEND_EVERY then send_throw() end
  if now - last_keepalive >= KEEPALIVE_EVERY then
    if radio_send(peer, { t = "k", g = game_id, n = shots }) then last_keepalive = now end
  end
  if state ~= "over" and now - last_heard > LOST_AFTER then
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
    pending = { t = "th", g = game_id, n = shots, a = a.a, p = a.p, w = a.w }
    send_throw()
  end
end

-- The other badge's throw number n (count of throws including it).
local function remote_throw(m)
  if m.n == shots + 1 and state == "wait" then
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
  for i = 1, 2 do
    monkeys[i].x, monkeys[i].y, monkeys[i].alive = town.monkeys[i].x, town.monkeys[i].y, true
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
  if not lobby_list then return end
  lobby_ids = {}
  for id, t in pairs(seen) do
    if now - t < 4000 then lobby_ids[#lobby_ids + 1] = id end
  end
  table.sort(lobby_ids)
  local items = {}
  for i, id in ipairs(lobby_ids) do
    items[i] = { title = name_of(id), right = invited == id and "invited" or nil }
  end
  lobby_list:items(items)
  lobby_info:text(#items == 0 and "Looking for players... Open Monkey Bomb on another badge."
    or "Pick a player and press SELECT to invite them.")
end

function open_lobby()
  state = "lobby"
  invited, asking, seen = nil, nil, {}
  set_play_visible(false)
  show_message(nil)
  lobby_title = ui.label(0, 8, "2 PLAYERS", { size = 20, color = 0xFFFFFF, w = W, align = "center" })
  lobby_info = ui.label(16, 36, "", { size = 12, color = "dim", w = W - 32, align = "center" })
  lobby_list = ui.list(40, 60, W - 80, 140, {}, {
    on_select = function(i)
      local id = lobby_ids[i]
      if not id then return end
      invited = id
      radio_send(id, { t = "inv" })
      ui.toast("Invite sent to " .. name_of(id))
      refresh_lobby()
    end,
  })
  ui.hint("SELECT invite   CANCEL back")
  radio_send("*", { t = "hi" })
  hello_timer = timer.every(HELLO_EVERY, function()
    if state == "lobby" then
      radio_send("*", { t = "hi" })
      if invited then radio_send(invited, { t = "inv" }) end
      refresh_lobby()
    end
  end)
  refresh_lobby()
end

function close_lobby()
  if hello_timer then timer.cancel(hello_timer) hello_timer = nil end
  if lobby_list then lobby_list:remove() lobby_list = nil end
  if lobby_title then lobby_title:remove() lobby_title = nil end
  if lobby_info then lobby_info:remove() lobby_info = nil end
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
    local is_new = seen[from] == nil
    seen[from] = now
    if state == "lobby" and is_new then refresh_lobby() end
  elseif m.t == "inv" then
    seen[from] = now
    if state == "lobby" and asking == nil then
      if invited == from then
        if badge.id() and badge.id() < from then accept_invite(from) end
        return
      end
      asking = from
      ui.confirm(name_of(from) .. " wants to play Monkey Bomb. Play?", function(yes)
        asking = nil
        if yes and state == "lobby" then accept_invite(from) end
      end)
    end
  elseif m.t == "go" or m.t == "k" or m.t == "th" or m.t == "ok" then
    if state == "lobby" and invited == from and m.g then
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

function on_tick(ms)
  now = now + ms
  if mode == "duo" and state ~= "menu" and state ~= "lobby" then net_tick() end

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

  if key == "back" then
    if rep then return true end
    if mode == "duo" then leave_duo() end
    cpu_plan = nil
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
