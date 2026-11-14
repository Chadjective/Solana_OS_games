-- Solana Monkey Bomb (SMB): two monkeys on the London skyline take turns
-- lobbing bombs at each other. Set the angle and power, mind the wind, and
-- blow holes in the Shard, the Gherkin, the Cheesegrater and the
-- Walkie-Talkie on the way. First to win 3 rounds wins the match.
--
-- Modes: 1 player vs a CPU monkey (Easy / Hard), 2 players passing one
-- badge, and 2 players on two badges over the mesh radio.
--
-- Two badges stay in sync without sending pictures: both build the same
-- skyline from the same seed (a starting number for the random choices),
-- and a throw is just "angle, power". Each badge then flies the bomb with
-- the same fixed-step physics, so the flight, the hole it blows and the
-- result come out the same on both.

local W, H = ui.W, ui.H              -- 320 x 218
local SCALE = 2                      -- every canvas pixel is 2 x 2 on screen
local CW, CH = 160, 101              -- the city canvas (320 x 202 on screen, above the hint strip)
local WIN_ROUNDS = 3

local G = 80                         -- gravity, canvas px / s^2
local POWER_TO_SPEED = 1.35          -- power 1..100 -> launch speed (canvas px / s)
local STEP_MS = 8                    -- physics step: the same on every badge
local STEP = STEP_MS / 1000
local BLAST = 6                      -- explosion radius (canvas px)
local SAFE_STEPS = 30                -- a bomb can't hit its thrower for this many steps

-- Mesh radio (two-badge games).
local HELLO_EVERY = 1200
local KEEPALIVE_EVERY = 2000
local RESEND_EVERY = 700
local LOST_AFTER = 15000

local has_led = led ~= nil
local has_mesh = mesh ~= nil

---------------------------------------------------------------------------
-- Colours
---------------------------------------------------------------------------
local SKY = 0x120B2B
local STAR = 0x5A5488
local MOON = 0xE8E4C9
local MOON_SHADE = 0xBDB79A
local GROUND = 0x1B1B24
local LIT = 0xF2C14E
local DARK_WIN = 0x262A3A
local BODIES = { 0x6E3B32, 0x8A8270, 0x3B4C66, 0x55586A, 0x4A3F5C }
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
local BOMB = {
  "...y.",
  "..o..",
  ".kkk.",
  "kkwkk",
  "kkkkk",
  ".kkk.",
}
local BOMB_W, BOMB_H = 5, 6

local function mirror(rows)
  local out = {}
  for i, r in ipairs(rows) do
    local padded = r .. string.rep(".", 8 - #r)
    out[i] = padded:reverse()
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

local function monkey_palette(i)
  return { palette = { h = CAP[i], n = 0x8B5A2B, f = 0xE0B98A }, scale = SCALE }
end

---------------------------------------------------------------------------
-- A random number generator that gives the same numbers on every badge for
-- the same seed (Park-Miller; every step stays below 2^31, so 32-bit
-- badges and 64-bit computers agree).
---------------------------------------------------------------------------
local function new_rng(seed)
  local s = seed % 2147483646 + 1
  local r = {}
  function r.next()
    local hi = s // 127773
    local lo = s % 127773
    s = 16807 * lo - 2836 * hi
    if s <= 0 then s = s + 2147483647 end
    return s
  end
  function r.int(a, b) return a + r.next() % (b - a + 1) end
  function r.chance(p) return r.next() % 1000 < p * 1000 end
  return r
end

---------------------------------------------------------------------------
-- Screen objects (drawn in the order they are made)
---------------------------------------------------------------------------
ui.bg(SKY)
local city = ui.canvas(0, 0, CW, CH, { scale = SCALE, color = "bg" })

-- Colours as the canvas stores them (the screen has 65,536 colours, so a
-- colour can come back slightly different): anything in EMPTY is sky.
local EMPTY = {}
for _, c in ipairs({ SKY, STAR, MOON, MOON_SHADE }) do
  city:pixel(0, 0, c)
  EMPTY[city:get(0, 0)] = true
end

local monkeys = {}
for i = 1, 2 do
  local stand = i == 1 and MONKEY_STAND or mirror(MONKEY_STAND)
  local throw = i == 1 and MONKEY_THROW or mirror(MONKEY_THROW)
  local m = { x = 0, y = 0, alive = true }
  m.stand = ui.image(0, 0, stand, monkey_palette(i))
  m.throw = ui.image(0, 0, throw, monkey_palette(i))
  m.throw:show(false)
  monkeys[i] = m
end

local bomb_img = ui.image(0, 0, BOMB, { scale = SCALE })
bomb_img:show(false)
local boom_img = ui.image(0, 0, explosion_rows(), { scale = SCALE })
boom_img:show(false)
local top_marker = ui.rect(0, 0, 4, 3, { color = "yellow" })
top_marker:show(false)

local aim_dots = {}
for i = 1, 5 do
  local d = ui.rect(0, 0, 4, 4, { color = 0xFFFFFF, radius = 2 })
  d:show(false)
  aim_dots[i] = d
end

local hud_l = ui.label(4, 2, "", { size = 12, color = CAP[1] })
local hud_r = ui.label(W - 104, 2, "", { size = 12, color = CAP[2], w = 100, align = "right" })
local hud_wind = ui.label(0, 2, "", { size = 12, color = "dim", w = W, align = "center" })
local hud_aim = ui.label(0, 16, "", { size = 12, color = 0xFFFFFF, w = W, align = "center" })
local hud = { hud_l, hud_r, hud_wind, hud_aim }

local panel = ui.rect(40, 62, W - 80, 74, { color = "panel", radius = 8, border = "border" })
local msg = ui.label(40, 74, "", { size = 20, color = 0xFFFFFF, w = W - 80, align = "center" })
local sub = ui.label(40, 106, "", { size = 14, color = "dim", w = W - 80, align = "center" })

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local state = "menu"     -- menu | lobby | aim | wait | cpu | fly | boom | between | over
local mode = "cpu"       -- cpu | hot (pass the badge) | duo (two badges)
local level = 1          -- CPU: 1 easy, 2 hard
local menu_i = 1
local turn = 1           -- whose throw: 1 (left) or 2 (right)
local wins = { 0, 0 }    -- rounds won this match
local round = 0
local game_seed = 0
local wind = 0
local aim = { { a = 45, p = 50 }, { a = 45, p = 50 } }
local now = 0
local acc = 0            -- ms not yet simulated
local bomb = nil         -- { x, y, vx, vy, steps, thrower }
local shots = 0          -- throws so far this match (both badges count the same)
local cpu_plan = nil
local cpu_misses = 0
local last_landing = nil

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

---------------------------------------------------------------------------
-- The skyline
---------------------------------------------------------------------------
local function solid(x, y)
  local c = city:get(x, y)
  return c ~= nil and not EMPTY[c]
end

local function windows(r, x, top, w, h)
  for wy = top + 2, CH - 4, 3 do
    for wx = x + 1, x + w - 3, 2 do
      city:pixel(wx, wy, r.chance(0.4) and LIT or DARK_WIN)
    end
  end
end

-- An ordinary office block. Returns the roof's y.
local function block(r, x, w, h)
  local top = CH - 2 - h
  city:rect(x, top, w - 1, h, BODIES[r.int(1, #BODIES)])
  windows(r, x, top, w - 1, h)
  return top
end

-- The Shard: a tall glass pyramid with a split tip.
local function shard(r, x, w)
  local h = 84 + r.int(-3, 2)
  local base = CH - 2
  for i = 0, h - 1 do
    local y = base - i
    local t = 1 - i / h                        -- 1 at the bottom, 0 at the top
    local half = math.max(1, math.floor((w / 2) * t + 0.5))
    local cx = x + w // 2
    if i > h - 7 then
      -- the open, splintered tip
      city:pixel(cx - 1, y, 0xB9CCDD)
      if i % 2 == 0 then city:pixel(cx + 1, y, 0x8EA4BA) end
    else
      city:rect(cx - half, y, half, 1, 0xA9BFD4)   -- the lit face
      city:rect(cx, y, half, 1, 0x7D93AA)          -- the face in shadow
      if i % 5 == 0 then city:rect(cx - half, y, half * 2, 1, 0x6A7F96) end
    end
  end
end

-- The Gherkin: a rounded bullet with spiralling dark glass.
local function gherkin(r, x, w)
  local h = 56 + r.int(-3, 3)
  for i = 0, h - 1 do
    local u = i / h                            -- 0 at the top, 1 at the bottom
    local k = (u - 0.6) / 0.6
    local half = (w / 2) * math.sqrt(math.max(0, 1 - k * k))
    if u > 0.6 then half = (w / 2) * math.max(0.72, math.sqrt(math.max(0, 1 - k * k))) end
    local hw = math.max(1, math.floor(half + 0.5))
    local y = CH - 2 - h + i
    local cx = x + w // 2
    city:rect(cx - hw, y, hw * 2, 1, 0x2F6E78)
    for px = cx - hw, cx + hw - 1 do
      if (px + i * 2) % 7 < 2 then city:pixel(px, y, 0x1C4650) end
    end
  end
end

-- The Cheesegrater: a steel wedge, upright at the back, sloping at the front.
local function cheesegrater(r, x, w)
  local h = 66 + r.int(-3, 3)
  for i = 0, h - 1 do
    local u = i / h                            -- 0 at the top
    local rw = math.max(2, math.floor(w * (0.25 + 0.75 * u) + 0.5))
    local y = CH - 2 - h + i
    city:rect(x + w - rw, y, rw, 1, 0xC6C9CF)
    city:pixel(x + w - rw, y, 0x8E939C)        -- the sloping edge
    if i % 5 == 0 then city:rect(x + w - rw, y, rw, 1, 0x8E939C) end
    city:pixel(x + w - 2, y, 0xE3B341)         -- yellow bracing at the back
  end
end

-- The Walkie-Talkie: wider at the top than at the bottom, with a green roof garden.
local function walkie(r, x, w)
  local h = 52 + r.int(-3, 3)
  local base_w = w - 8
  for i = 0, h - 1 do
    local u = i / h                            -- 0 at the top
    local rw = math.floor(base_w + (w - base_w) * (1 - u) + 0.5)
    if i < 3 then rw = rw - (3 - i) * 2 end    -- the curved roof
    local y = CH - 2 - h + i
    local cx = x + w // 2
    local col = i < 5 and 0x9FE3C4 or 0x3E6B66
    city:rect(cx - rw // 2, y, rw, 1, col)
    if i >= 5 and i % 3 == 0 then city:rect(cx - rw // 2, y, rw, 1, 0x2C504C) end
  end
end

local LANDMARKS = {
  { draw = shard, w = 20 },
  { draw = gherkin, w = 18 },
  { draw = cheesegrater, w = 22 },
  { draw = walkie, w = 20 },
}

-- Builds the whole city for a round from its seed, places the monkeys and
-- returns the wind. Every badge given the same seed builds the same city.
local function build_city(seed)
  local r = new_rng(seed)
  city:rect(0, 0, CW, CH, SKY)
  for _ = 1, 28 do city:pixel(r.int(0, CW - 1), r.int(0, 55), STAR) end
  -- the moon
  local mx, my = r.int(14, 40), r.int(10, 18)
  for dy = -5, 5 do
    local half = math.floor(math.sqrt(25 - dy * dy) + 0.5)
    city:rect(mx - half, my + dy, half * 2 + 1, 1, MOON)
  end
  city:rect(mx + 1, my - 2, 2, 2, MOON_SHADE)
  city:pixel(mx - 2, my + 2, MOON_SHADE)

  -- left edge filler, left monkey's block, the middle, right monkey's block, right filler
  local x = 0
  local fill_l, fill_r = r.int(8, 13), r.int(8, 13)
  block(r, x, fill_l, r.int(18, 34))
  x = x + fill_l
  local lw = r.int(15, 18)
  local roof_l = block(r, x, lw, r.int(28, 44))
  local monkey_l = x + lw // 2 - 4
  x = x + lw

  local rw = r.int(15, 18)
  local right_start = CW - fill_r - rw
  local mid_w = right_start - x

  -- Three or four landmarks, shuffled, with ordinary blocks between them.
  local order = { 1, 2, 3, 4 }
  for i = #order, 2, -1 do
    local j = r.int(1, i)
    order[i], order[j] = order[j], order[i]
  end
  local picks, used = {}, 0
  for _, k in ipairs(order) do
    if used + LANDMARKS[k].w <= mid_w - 4 * (#picks + 2) and #picks < 4 then
      picks[#picks + 1] = LANDMARKS[k]
      used = used + LANDMARKS[k].w
    end
  end
  local gap = mid_w - used
  local slots = #picks + 1
  for i = 1, slots do
    local gw = (i == slots) and gap or math.max(4, math.floor(gap / (slots - i + 1)) + r.int(-2, 2))
    gw = math.min(gw, gap)
    if gw >= 3 then block(r, x, gw, r.int(16, 46)) end
    x = x + gw
    gap = gap - gw
    if picks[i] then
      picks[i].draw(r, x, picks[i].w)
      x = x + picks[i].w
    end
  end

  local roof_r = block(r, right_start, rw, r.int(28, 44))
  local monkey_r = right_start + rw // 2 - 4
  block(r, right_start + rw, fill_r, r.int(18, 34))
  city:rect(0, CH - 2, CW, 2, GROUND)

  monkeys[1].x, monkeys[1].y = monkey_l, roof_l - 10
  monkeys[2].x, monkeys[2].y = monkey_r, roof_r - 10
  return r.int(-12, 12)
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

local function set_play_visible(on)
  city:show(on)
  for i = 1, 2 do
    if on then draw_monkey(i, false) else
      monkeys[i].stand:show(false)
      monkeys[i].throw:show(false)
    end
  end
  for _, l in ipairs(hud) do l:show(on) end
  if not on then
    bomb_img:show(false)
    boom_img:show(false)
    top_marker:show(false)
    for _, d in ipairs(aim_dots) do d:show(false) end
  end
end

-- Where a throw starts: just above the thrower's raised hand.
local function launch_point(i)
  local m = monkeys[i]
  if i == 1 then return m.x + 8, m.y - 1 end
  return m.x - 1, m.y - 1
end

local function launch_velocity(i, a, p)
  local v = p * POWER_TO_SPEED
  local rad = math.rad(a)
  local dir = i == 1 and 1 or -1
  return dir * v * math.cos(rad), -v * math.sin(rad)
end

local function draw_aim()
  local show = state == "aim"
  for _, d in ipairs(aim_dots) do d:show(show) end
  if not show then return end
  local a = aim[turn]
  local x, y = launch_point(turn)
  local vx, vy = launch_velocity(turn, a.a, a.p)
  local len = math.sqrt(vx * vx + vy * vy)
  for k, d in ipairs(aim_dots) do
    local dist = k * (4 + a.p * 0.12)
    d:pos(math.floor((x + vx / len * dist) * SCALE) - 2, math.floor((y + vy / len * dist) * SCALE) - 2)
  end
end

local function update_hud()
  hud_l:text(player_name(1) .. "  " .. wins[1])
  hud_r:text(wins[2] .. "  " .. player_name(2))
  if wind == 0 then
    hud_wind:text("WIND calm")
  else
    local arrows = string.rep(wind > 0 and ">" or "<", math.abs(wind) // 4 + 1)
    hud_wind:text("WIND " .. arrows)
  end
  local a = aim[turn]
  if state == "aim" then
    hud_aim:text(player_name(turn) .. ":  angle " .. a.a .. "   power " .. a.p)
  elseif state == "wait" then
    hud_aim:text(peer_name .. " is aiming...")
  elseif state == "cpu" then
    hud_aim:text("CPU is aiming...")
  else
    hud_aim:text("")
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

local function begin_turn()
  local who = controller(turn)
  if who == "human" then
    state = "aim"
    ui.hint("UP/DN angle  LEFT/RIGHT power  SELECT throw")
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
  for i = 1, 2 do monkeys[i].alive = true end
  wind = build_city(seed)
  set_play_visible(true)
  show_message(nil)
  cpu_misses = 0
  last_landing = nil
  turn = (round % 2 == 1) and 1 or 2      -- players take turns going first
  begin_turn()
end

local function start_match()
  wins = { 0, 0 }
  round = 0
  shots = 0
  aim = { { a = 45, p = 50 }, { a = 45, p = 50 } }
  new_round()
end

local function end_round(winner)
  wins[winner] = wins[winner] + 1
  update_hud()
  if wins[winner] >= WIN_ROUNDS then
    state = "over"
    local mine = (mode == "cpu" and winner == 1) or (mode == "duo" and winner == me)
    if mine then
      local k = mode == "duo" and 3 or level
      match_wins[k] = (match_wins[k] or 0) + 1
      storage.set("match_wins", match_wins)
    end
    local title
    if mode == "hot" then title = "P" .. winner .. " WINS!"
    elseif mine then title = "YOU WIN!"
    else title = player_name(winner) .. " WINS" end
    show_message(title, wins[1] .. " - " .. wins[2] .. "   SELECT again")
    ui.hint("SELECT play again   CANCEL menu")
  else
    state = "between"
    show_message(player_name(winner) .. (player_name(winner) == "YOU" and " WIN THE ROUND" or " WINS THE ROUND"),
      wins[1] .. " - " .. wins[2])
    timer.after(2200, function()
      if state == "between" then new_round() end
    end)
  end
end

---------------------------------------------------------------------------
-- Throwing and exploding
---------------------------------------------------------------------------
-- Carves a hole in the city and returns which monkeys were caught.
local function explode(x, y)
  x, y = math.floor(x + 0.5), math.floor(y + 0.5)
  for dy = -BLAST, BLAST do
    local half = math.floor(math.sqrt(BLAST * BLAST - dy * dy) + 0.5)
    city:rect(x - half, y + dy, half * 2 + 1, 1, SKY)
  end
  local hit = {}
  for i = 1, 2 do
    local m = monkeys[i]
    local cx, cy = m.x + 4, m.y + 5
    local dx, dy = x - cx, y - cy
    if m.alive and dx * dx + dy * dy <= (BLAST + 4) * (BLAST + 4) then hit[#hit + 1] = i end
  end
  return hit
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

-- One physics step for a bomb table b. Returns nil while it flies, or
-- "off" (left the screen at a side), "ground", "city" or "monkey".
local function step_bomb(b, check)
  b.vx = b.vx + wind * STEP
  b.vy = b.vy + G * STEP
  b.x = b.x + b.vx * STEP
  b.y = b.y + b.vy * STEP
  b.steps = b.steps + 1
  if b.x < 0 or b.x >= CW then return "off" end
  if b.y >= CH - 2 then return "ground" end
  if b.y < 0 or not check then return nil end
  if monkey_at(b.x, b.y, b.thrower, b.steps) then return "monkey" end
  if solid(math.floor(b.x), math.floor(b.y)) then return "city" end
  return nil
end

local function after_throw(hit)
  if #hit > 0 then
    for _, i in ipairs(hit) do monkeys[i].alive = false draw_monkey(i, false) end
    flash(0xFF, 0x75, 0x4A, 400)
    -- If the thrower got caught in their own blast, the other monkey wins.
    local thrower = bomb.thrower
    local winner = thrower
    for _, i in ipairs(hit) do
      if i == thrower then winner = 3 - thrower end
    end
    timer.after(500, function() end_round(winner) end)
    state = "boom"
    return
  end
  turn = 3 - turn
  state = "boom"
  timer.after(450, function()
    if state == "boom" then begin_turn() end
  end)
end

local function land(kind)
  local b = bomb
  bomb_img:show(false)
  top_marker:show(false)
  draw_monkey(b.thrower, false)
  if b.thrower == 2 then last_landing = b.x end
  if kind == "off" then
    after_throw({})
    return
  end
  local hit = explode(b.x, b.y)
  boom_img:pos(math.floor(b.x * SCALE) - 13, math.floor(b.y * SCALE) - 13)
  boom_img:show(true)
  timer.after(350, function() boom_img:show(false) end)
  if #hit == 0 then flash(0xFF, 0xD8, 0x4D, 100) end
  after_throw(hit)
end

local function throw(i, a, p)
  local x, y = launch_point(i)
  local vx, vy = launch_velocity(i, a, p)
  bomb = { x = x, y = y, vx = vx, vy = vy, steps = 0, thrower = i }
  shots = shots + 1
  acc = 0
  state = "fly"
  draw_monkey(i, true)
  for _, d in ipairs(aim_dots) do d:show(false) end
  ui.hint(mode == "duo" and "CANCEL quit" or "CANCEL menu")
  hud_aim:text(player_name(i) .. ":  angle " .. a .. "   power " .. p)
end

local function draw_bomb()
  if not bomb then return end
  if bomb.y < 0 then
    bomb_img:show(false)
    top_marker:pos(math.floor(bomb.x * SCALE) - 2, 0)
    top_marker:show(true)
  else
    top_marker:show(false)
    bomb_img:pos(math.floor(bomb.x * SCALE) - BOMB_W, math.floor(bomb.y * SCALE) - BOMB_H)
    bomb_img:show(true)
  end
end

---------------------------------------------------------------------------
-- The CPU monkey
---------------------------------------------------------------------------
-- Where would a throw land, ignoring buildings (x where it drops to the
-- target's height)? Coarse steps: this is the CPU "thinking", not the real throw.
local function landing_x(a, p, target_y)
  local x, y = launch_point(2)
  local vx, vy = launch_velocity(2, a, p)
  local dt = 1 / 40
  for _ = 1, 400 do
    vx = vx + wind * dt
    vy = vy + G * dt
    x = x + vx * dt
    y = y + vy * dt
    if vy > 0 and y >= target_y then return x end
    if x < -40 or x > CW + 40 then return x end
  end
  return x
end

-- Does this throw get to the target without hitting a building first?
local function clear_path(a, p)
  local x, y = launch_point(2)
  local vx, vy = launch_velocity(2, a, p)
  local b = { x = x, y = y, vx = vx, vy = vy, steps = 0, thrower = 2 }
  local target = monkeys[1]
  for _ = 1, 250 do
    -- 3 steps at a time: good enough to see a building in the way
    local r
    for _ = 1, 3 do
      r = step_bomb(b, false)
      if r then break end
    end
    if r then return false end
    if b.y >= 0 and monkey_at(b.x, b.y, 2, 999) == 1 then return true end
    if b.y >= 0 and solid(math.floor(b.x), math.floor(b.y)) then
      return math.abs(b.x - (target.x + 4)) < 6
    end
  end
  return false
end

-- Plans one angle per tick (a coroutine), so the thinking never runs into
-- the badge's per-callback instruction limit.
local function plan()
  local target = monkeys[1]
  local tx, ty = target.x + 4, target.y + 5
  local best, best_err = nil, math.huge
  for a = 30, 75, 5 do
    -- More power lands further left (towards the target): binary search.
    local lo, hi = 5, 100
    for _ = 1, 14 do
      local mid = (lo + hi) / 2
      if landing_x(a, mid, ty) > tx then lo = mid else hi = mid end
    end
    local p = (lo + hi) / 2
    local err = math.abs(landing_x(a, p, ty) - tx)
    coroutine.yield()
    if err < 3 and clear_path(a, p) then best = { a = a, p = p } break end
    if err < best_err then best, best_err = { a = a, p = p }, err end
    coroutine.yield()
  end
  -- Aim like a monkey, not a computer: a mistake that shrinks every miss.
  local spread = level == 1 and 15 * (0.78 ^ cpu_misses) or 5 * (0.55 ^ cpu_misses)
  local p = clamp(math.floor(best.p + (math.random() * 2 - 1) * spread + 0.5), 1, 100)
  local a = clamp(best.a + math.random(-2, 2), 5, 85)
  return a, p
end

function start_cpu_turn()
  cpu_plan = coroutine.create(plan)
  if last_landing then cpu_misses = cpu_misses + 1 end
end

local function cpu_tick()
  if not cpu_plan then return end
  local ok, a, p = coroutine.resume(cpu_plan)
  if not ok then error(a) end
  if coroutine.status(cpu_plan) == "dead" then
    cpu_plan = nil
    aim[2].a, aim[2].p = a, p
    update_hud()
    timer.after(600, function()
      if state == "cpu" then throw(2, a, p) end
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
  if (state ~= "over") and now - last_heard > LOST_AFTER then
    peer = nil
    state = "over"
    set_play_visible(true)
    show_message("CONNECTION LOST", "Can't hear " .. peer_name)
    ui.hint("SELECT lobby   CANCEL menu")
  end
end

local function local_throw()
  local a = aim[turn]
  throw(turn, a.a, a.p)
  if mode == "duo" then
    pending = { t = "th", g = game_id, n = shots, a = a.a, p = a.p }
    send_throw()
  end
end

-- The other badge's throw number n (count of throws including it).
local function remote_throw(m)
  if m.n == shots + 1 and state == "wait" then
    aim[turn].a, aim[turn].p = m.a, m.p
    throw(turn, m.a, m.p)
  elseif m.n == shots + 1 then
    queued = m                          -- still finishing the last throw here
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
    { title = "2 players: pass the badge" },
    { title = "2 players: 2 badges", right = right(match_wins[3] or 0) },
  }
end

local function open_menu()
  state = "menu"
  peer, pending, queued = nil, nil, nil
  show_message(nil)
  if has_led then led.off() end
  -- A fresh skyline behind the menu.
  wind = build_city(math.random(1, 2147483000))
  set_play_visible(true)
  for _, l in ipairs(hud) do l:show(false) end
  menu_panel = ui.rect(0, 0, W, 36, { color = 0x120B2B })
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
      bomb_img:show(false)
      show_message("PLAYER LEFT", peer_name .. " quit the game")
      ui.hint("SELECT lobby   CANCEL menu")
    end
  end
end

function on_tick(ms)
  now = now + ms
  if mode == "duo" and state ~= "menu" and state ~= "lobby" then net_tick() end

  if state == "cpu" then
    cpu_tick()
  elseif state == "wait" and queued then
    local m = queued
    queued = nil
    remote_throw(m)
  elseif state == "fly" then
    acc = acc + math.min(ms, 100)
    while acc >= STEP_MS and state == "fly" do
      acc = acc - STEP_MS
      local r = step_bomb(bomb, true)
      if r then land(r) end
    end
    if state == "fly" then draw_bomb() end
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
    bomb = nil
    open_menu()
    return true
  end

  if state == "aim" then
    local a = aim[turn]
    local step = rep and 2 or 1
    if key == "up" then a.a = clamp(a.a + step, 0, 90)
    elseif key == "down" then a.a = clamp(a.a - step, 0, 90)
    elseif key == "right" then a.p = clamp(a.p + step, 1, 100)
    elseif key == "left" then a.p = clamp(a.p - step, 1, 100)
    elseif key == "select" and not rep then local_throw() return true end
    update_hud()
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
