-- The London skyline for Solana Monkey Bomb.
--
-- S.build(canvas, seed) draws a whole city for one round and returns where
-- the monkeys stand, the wind, and a list of buildings (so the game can
-- score damage to each one). The same seed always gives the same city, on
-- every badge: all the random choices come from S.new_rng(seed).
--
-- Each landmark is a table { name, w, value, draw }:
--   name   shown when it's destroyed, e.g. "THE SHARD"
--   w      its width in canvas pixels
--   value  how iconic it is, 1..3 (points per pixel of damage, and the bonus)
--   draw   function(r, x, w): draws it standing on the ground at column x.
--          Use body() for its main shape (counted towards its size, so the
--          game knows when most of it is gone) and paint()/dot() for
--          details drawn on top of the body.

local S = {}

S.CW, S.CH = 160, 101
S.SKY = 0x120B2B
S.STAR = 0x5A5488
S.MOON = 0xE8E4C9
S.MOON_SHADE = 0xBDB79A
S.GROUND = 0x1B1B24
S.WATER = 0x1E3A6E                     -- the Thames (not solid: bombs splash, monkeys sink)
S.WATER_LIGHT = 0x3A66B0
S.SNOW = 0xF4F6FF
S.RIVER_W = 26
local BRIDGES = { "LONDON BRIDGE", "WATERLOO BRIDGE", "BLACKFRIARS BRIDGE", "MILLENNIUM BRIDGE" }
local CW, CH = S.CW, S.CH
local GROUND_Y = CH - 2                -- first row of the ground
local LIT, DARK_WIN = 0xF2C14E, 0x262A3A
local BODIES = { 0x6E3B32, 0x8A8270, 0x3B4C66, 0x55586A, 0x4A3F5C }

---------------------------------------------------------------------------
-- Random numbers that are the same on every badge for the same seed
-- (Park-Miller; every step stays below 2^31, so 32-bit badges and 64-bit
-- computers agree).
---------------------------------------------------------------------------
function S.new_rng(seed)
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
-- Drawing helpers (set up by S.build)
---------------------------------------------------------------------------
local city, cur
local snowing = false

local function body(x, y, w, h, c)
  if w <= 0 or h <= 0 then return end
  city:rect(x, y, w, h, c)
  if cur then cur.total = cur.total + w * h end
end

local function paint(x, y, w, h, c)
  if w > 0 and h > 0 then city:rect(x, y, w, h, c) end
end

local function dot(x, y, c) city:pixel(x, y, c) end

-- A filled circle (body), e.g. a dome or a wheel's hub.
local function disc(cx, cy, rad, c)
  for dy = -rad, rad do
    local half = math.floor(math.sqrt(rad * rad - dy * dy) + 0.5)
    body(cx - half, cy + dy, half * 2 + 1, 1, c)
  end
end

local function windows(r, x, top, w)
  for wy = top + 2, GROUND_Y - 2, 3 do
    for wx = x + 1, x + w - 2, 2 do
      dot(wx, wy, r.chance(0.4) and LIT or DARK_WIN)
    end
  end
end

S.helpers = { body = body, paint = paint, dot = dot, disc = disc, windows = windows }

-- An ordinary office block, w wide (including a 1 px gap), h tall.
-- Returns the roof's y.
local function block(r, x, w, h)
  local top = GROUND_Y - h
  body(x, top, w - 1, h, BODIES[r.int(1, #BODIES)])
  windows(r, x, top, w - 1)
  if snowing then paint(x, top, w - 1, 1, S.SNOW) end
  return top
end

---------------------------------------------------------------------------
-- Landmarks
---------------------------------------------------------------------------
local L = {}

-- The Shard: a tall glass pyramid with a split, open tip.
L[#L + 1] = { name = "THE SHARD", w = 20, value = 3, draw = function(r, x, w)
  local h = 84 + r.int(-3, 2)
  local cx = x + w // 2
  for i = 0, h - 1 do
    local y = GROUND_Y - 1 - i
    local half = math.max(1, math.floor((w / 2) * (1 - i / h) + 0.5))
    if i > h - 7 then
      body(cx - 1, y, 1, 1, 0xB9CCDD)
      if i % 2 == 0 then body(cx + 1, y, 1, 1, 0x8EA4BA) end
    else
      body(cx - half, y, half, 1, 0xA9BFD4)        -- the lit face
      body(cx, y, half, 1, 0x7D93AA)               -- the face in shadow
      if i % 5 == 0 then paint(cx - half, y, half * 2, 1, 0x6A7F96) end
    end
  end
end }

-- The Gherkin: a rounded bullet with spiralling dark glass.
L[#L + 1] = { name = "THE GHERKIN", w = 18, value = 3, draw = function(r, x, w)
  local h = 56 + r.int(-3, 3)
  local cx = x + w // 2
  for i = 0, h - 1 do
    local u = i / h                                -- 0 at the top
    local k = (u - 0.6) / 0.6
    local half = (w / 2) * math.sqrt(math.max(0, 1 - k * k))
    if u > 0.6 then half = (w / 2) * math.max(0.72, math.sqrt(math.max(0, 1 - k * k))) end
    local hw = math.max(1, math.floor(half + 0.5))
    local y = GROUND_Y - h + i
    body(cx - hw, y, hw * 2, 1, 0x2F6E78)
    for px = cx - hw, cx + hw - 1 do
      if (px + i * 2) % 7 < 2 then dot(px, y, 0x1C4650) end
    end
  end
end }

-- The Cheesegrater: a steel wedge, upright at the back, sloping at the front.
L[#L + 1] = { name = "CHEESEGRATER", w = 22, value = 2, draw = function(r, x, w)
  local h = 66 + r.int(-3, 3)
  for i = 0, h - 1 do
    local rw = math.max(2, math.floor(w * (0.25 + 0.75 * i / h) + 0.5))
    local y = GROUND_Y - h + i
    body(x + w - rw, y, rw, 1, 0xC6C9CF)
    dot(x + w - rw, y, 0x8E939C)                   -- the sloping edge
    if i % 5 == 0 then paint(x + w - rw, y, rw, 1, 0x8E939C) end
    dot(x + w - 2, y, 0xE3B341)                    -- yellow bracing at the back
  end
end }

-- The Walkie-Talkie: wider at the top than the bottom, with a roof garden.
L[#L + 1] = { name = "WALKIE-TALKIE", w = 20, value = 2, draw = function(r, x, w)
  local h = 52 + r.int(-3, 3)
  local base_w = w - 8
  local cx = x + w // 2
  for i = 0, h - 1 do
    local rw = math.floor(base_w + (w - base_w) * (1 - i / h) + 0.5)
    if i < 3 then rw = rw - (3 - i) * 2 end        -- the curved roof
    local y = GROUND_Y - h + i
    body(cx - rw // 2, y, rw, 1, i < 5 and 0x9FE3C4 or 0x3E6B66)
    if i >= 5 and i % 3 == 0 then paint(cx - rw // 2, y, rw, 1, 0x2C504C) end
  end
end }

---------------------------------------------------------------------------
-- More landmarks. Each is drawn inside its own box: x counts columns from
-- the box's left edge, r counts rows from its top, both inclusive, and the
-- last row sits on the ground. Anything not drawn is sky, so bombs fly
-- through it (the inside of the London Eye, under Tower Bridge, ...).
---------------------------------------------------------------------------
local function box(x0, h)
  local top = GROUND_Y - h
  local B = function(a, b, r0, r1, c) body(x0 + a, top + r0, b - a + 1, r1 - r0 + 1, c) end
  local P = function(a, b, r0, r1, c) paint(x0 + a, top + r0, b - a + 1, r1 - r0 + 1, c) end
  local D = function(a, r0, c) dot(x0 + a, top + r0, c) end
  -- a solid line of body pixels, in box coordinates
  local Ln = function(a, r0, b, r1, c)
    local n = math.max(math.abs(b - a), math.abs(r1 - r0), 1)
    for i = 0, n do
      local px = math.floor(a + (b - a) * i / n + 0.5)
      local py = math.floor(r0 + (r1 - r0) * i / n + 0.5)
      body(x0 + px, top + py, 1, 1, c)
    end
  end
  return B, P, D, Ln
end

local WARM = 0xFFE08A

-- Big Ben (the Elizabeth Tower): a lit clock face under a steep spire.
L[#L + 1] = { name = "BIG BEN", w = 10, value = 3, draw = function(r, x, w)
  local B, P, D = box(x, 38)
  local BODY, SHADE, CLOCK, ROOF = 0xC9A86A, 0x8A6E3E, 0xFFF2B0, 0x3E4A52
  B(4, 5, 0, 2, BODY)
  B(3, 6, 3, 4, ROOF)
  B(2, 7, 5, 6, ROOF)
  B(2, 7, 7, 9, BODY)
  D(3, 8, WARM) D(6, 8, WARM)
  B(1, 8, 10, 11, SHADE)
  B(1, 8, 12, 19, BODY)
  P(2, 7, 13, 18, CLOCK)
  D(2, 13, BODY) D(7, 13, BODY) D(2, 18, BODY) D(7, 18, BODY)
  D(4, 15, ROOF) D(5, 14, ROOF)
  B(0, 9, 20, 20, SHADE)
  B(1, 8, 21, 37, BODY)
  for row = 21, 37, 2 do D(3, row, WARM) D(6, row, WARM) end
end }

-- The London Eye: a thin wheel with capsules, on an upside-down V of legs.
-- Only the rim, spokes, capsules and legs are solid.
L[#L + 1] = { name = "LONDON EYE", w = 40, value = 3, draw = function(r, x, w)
  local B, P, D, Ln = box(x, 46)
  local RIM, SPOKE, CAPSULE, LEG = 0x6FD3FF, 0x2F6E94, 0xFFF6C8, 0xC8D0DA
  local cx, cy = 20, 20
  for k = 0, 7 do
    local a = k * math.pi / 4
    Ln(cx, cy, cx + math.floor(17 * math.cos(a) + 0.5), cy + math.floor(17 * math.sin(a) + 0.5), SPOKE)
  end
  for deg = 0, 358, 3 do
    local a = math.rad(deg)
    B(cx + math.floor(17 * math.cos(a) + 0.5), cx + math.floor(17 * math.cos(a) + 0.5),
      cy + math.floor(17 * math.sin(a) + 0.5), cy + math.floor(17 * math.sin(a) + 0.5), RIM)
  end
  for k = 0, 15 do
    local a = k * math.pi / 8
    local px = cx + math.floor(19 * math.cos(a) + 0.5)
    local py = cy + math.floor(19 * math.sin(a) + 0.5)
    B(px - 1, px, py - 1, py, CAPSULE)
  end
  B(18, 22, 18, 22, RIM)
  Ln(cx, cy, 12, 44, LEG) Ln(cx - 1, cy, 11, 44, LEG)
  Ln(cx, cy, 28, 44, LEG) Ln(cx + 1, cy, 29, 44, LEG)
  B(9, 31, 44, 45, LEG)
end }

-- Buckingham Palace: a long, flat, symmetrical front with the flag in the middle.
L[#L + 1] = { name = "BUCKINGHAM PALACE", w = 46, value = 3, wide = true, draw = function(r, x, w)
  local B, P, D = box(x, 18)
  local STONE, SHADE, WIN, BALCONY = 0xD8CDB0, 0xB5A887, WARM, 0x8B1E2E
  B(23, 23, 0, 6, 0xC0C0C0)
  B(24, 27, 0, 2, 0xC8102E)
  D(25, 1, 0xFFD400) D(26, 0, 0xFFD400)
  B(21, 25, 6, 6, STONE)
  B(19, 27, 7, 7, STONE)
  for px = 0, 45, 2 do if px < 19 or px > 27 then B(px, px, 7, 7, STONE) end end
  B(0, 45, 8, 8, STONE)
  B(0, 45, 9, 17, SHADE)
  P(0, 5, 9, 17, STONE) P(40, 45, 9, 17, STONE) P(17, 29, 9, 17, STONE)
  for px = 1, 45, 3 do
    D(px, 10, WIN) D(px, 12, WIN) D(px, 13, WIN) D(px, 15, WIN)
  end
  P(20, 26, 14, 14, BALCONY)
end }

-- Westminster Abbey: two square west towers and a pointed gable with a great window.
L[#L + 1] = { name = "WESTMINSTER ABBEY", w = 28, value = 2, draw = function(r, x, w)
  local B, P, D = box(x, 34)
  local STONE, SHADE, AMBER = 0xC7B79A, 0x8F7F63, 0xF2B04A
  B(0, 7, 4, 33, STONE) B(20, 27, 4, 33, STONE)
  B(0, 1, 0, 3, STONE) B(6, 7, 0, 3, STONE) B(20, 21, 0, 3, STONE) B(26, 27, 0, 3, STONE)
  for px = 2, 5, 2 do B(px, px, 3, 3, STONE) B(px + 20, px + 20, 3, 3, STONE) end
  for _, px in ipairs({ 2, 5, 22, 25 }) do P(px, px, 7, 12, AMBER) end
  P(0, 7, 14, 14, 0xE0D3B8) P(20, 27, 14, 14, 0xE0D3B8)
  P(2, 5, 17, 22, SHADE) P(22, 25, 17, 22, SHADE)
  for row = 10, 15 do B(13 - (row - 10), 14 + (row - 10), row, row, STONE) end
  B(8, 19, 16, 33, STONE)
  B(8, 8, 12, 15, STONE) B(19, 19, 12, 15, STONE)
  P(13, 14, 17, 17, AMBER) P(12, 15, 18, 18, AMBER) P(10, 17, 19, 26, AMBER)
  P(12, 12, 19, 26, SHADE) P(15, 15, 19, 26, SHADE)
  P(13, 14, 29, 29, 0x3A3226) P(12, 15, 30, 33, 0x3A3226)
end }

-- Tower Bridge: two gothic towers, high walkways and blue suspension chains.
L[#L + 1] = { name = "TOWER BRIDGE", w = 54, value = 3, wide = true, draw = function(r, x, w)
  local B, P, D, Ln = box(x, 32)
  local STONE, BLUE, WHITE, WIN = 0xBFAE90, 0x4FA3E0, 0xE8F1F8, 0xFFD27A
  for _, t in ipairs({ 10, 36 }) do
    B(t, t + 7, 6, 23, STONE)
    B(t, t + 1, 1, 5, STONE) B(t + 6, t + 7, 1, 5, STONE)
    B(t, t, 0, 0, WHITE) B(t + 7, t + 7, 0, 0, WHITE)
    B(t + 3, t + 4, 2, 3, STONE) B(t + 2, t + 5, 4, 5, STONE)
    P(t + 3, t + 4, 9, 11, WIN) P(t + 3, t + 4, 15, 17, WIN) P(t + 3, t + 4, 19, 21, WIN)
  end
  B(18, 35, 8, 8, BLUE) B(18, 35, 11, 11, BLUE)
  for px = 18, 35, 2 do B(px, px, 9, 10, BLUE) end
  B(0, 53, 22, 23, STONE)
  -- the chains sag from the tower tops down to the banks, with hangers
  local last
  for px = 0, 9 do
    local row = math.floor(8 + 13 * ((9 - px) / 9) ^ 1.6 + 0.5)
    if last then Ln(px - 1, last, px, row, BLUE) Ln(53 - (px - 1), last, 53 - px, row, BLUE) end
    if px % 3 == 0 then Ln(px, row, px, 21, BLUE) Ln(53 - px, row, 53 - px, 21, BLUE) end
    last = row
  end
  B(9, 18, 24, 31, STONE) B(35, 44, 24, 31, STONE)
end }

-- St Paul's Cathedral: a great dome with lantern and cross, and two front towers.
L[#L + 1] = { name = "ST PAUL'S", w = 32, value = 3, draw = function(r, x, w)
  local B, P = box(x, 42)
  local STONE, SHADE, DOME, GOLD = 0xE3DCC8, 0xA69C86, 0x9AB0B5, 0xFFC94A
  B(15, 16, 0, 2, GOLD) B(14, 17, 1, 1, GOLD)
  B(15, 16, 3, 3, GOLD)
  B(14, 17, 4, 8, STONE)
  local dome = { { 9, 13, 18 }, { 10, 11, 20 }, { 11, 10, 21 }, { 12, 9, 22 }, { 13, 8, 23 },
    { 14, 8, 23 }, { 15, 7, 24 }, { 16, 7, 24 }, { 17, 7, 24 } }
  for _, d in ipairs(dome) do B(d[2], d[3], d[1], d[1], DOME) end
  P(11, 11, 10, 17, 0x6F8589) P(15, 15, 9, 17, 0x6F8589) P(20, 20, 10, 17, 0x6F8589)
  B(7, 24, 18, 18, STONE)
  B(8, 23, 19, 23, STONE)
  for px = 8, 23, 2 do P(px, px, 19, 23, SHADE) end
  B(2, 29, 24, 41, STONE)
  for _, m in ipairs({ 0, 1 }) do
    local f = function(a) return m == 0 and a or 31 - a end
    local lo = function(a, b) if m == 0 then return a, b end return 31 - b, 31 - a end
    B(f(3), f(3), 10, 11, STONE)
    local a1, b1 = lo(2, 4) B(a1, b1, 12, 15, STONE)
    local a2, b2 = lo(1, 5) B(a2, b2, 16, 21, STONE)
    local a3, b3 = lo(0, 6) B(a3, b3, 22, 41, STONE)
  end
  P(15, 16, 26, 26, 0xF5F0E2) P(13, 18, 27, 27, 0xF5F0E2) P(12, 19, 28, 28, 0xF5F0E2) P(10, 21, 29, 29, 0xF5F0E2)
  for px = 10, 21, 2 do P(px, px, 30, 40, SHADE) end
end }

-- The BT Tower: a thin cylinder, ribbed at the top, with a glowing band.
L[#L + 1] = { name = "BT TOWER", w = 10, value = 2, draw = function(r, x, w)
  local B, P = box(x, 58)
  local GLASS, LIT_GLASS, LED, MAST = 0x3B6E8F, 0x9AD8FF, 0xFF4FA0, 0xC0C0C0
  B(4, 5, 0, 3, MAST)
  B(3, 6, 4, 6, GLASS)
  B(1, 8, 7, 10, LED)
  for px = 2, 8, 2 do P(px, px, 7, 10, 0x5AD0FF) end
  for row = 11, 24 do
    if (row - 11) % 3 == 0 then B(0, 9, row, row, GLASS) else B(2, 7, row, row, GLASS) end
  end
  B(2, 7, 25, 51, GLASS)
  for row = 25, 51, 2 do P(2, 7, row, row, LIT_GLASS) end
  B(1, 8, 52, 57, 0x2A4F66)
end }

-- The Tower of London (the White Tower): a square keep with domed corner turrets.
L[#L + 1] = { name = "TOWER OF LONDON", w = 24, value = 2, draw = function(r, x, w)
  local B, P = box(x, 22)
  local STONE, CAP, WIN = 0xD9D2C0, 0x4E5866, 0xFFD27A
  B(0, 3, 5, 21, STONE) B(20, 23, 5, 21, STONE)
  B(1, 2, 0, 2, CAP) B(0, 3, 3, 4, CAP)
  B(21, 22, 0, 2, CAP) B(20, 23, 3, 4, CAP)
  B(7, 9, 2, 7, STONE) B(14, 16, 2, 7, STONE)
  B(8, 8, 1, 1, CAP) B(15, 15, 1, 1, CAP)
  for px = 4, 19, 2 do B(px, px, 7, 7, STONE) end
  B(2, 21, 8, 21, STONE)
  for _, px in ipairs({ 6, 9, 14, 17 }) do P(px, px, 11, 12, WIN) P(px, px, 15, 16, WIN) end
end }

-- One Canada Square (Canary Wharf): a plain square shaft with a pyramid top
-- and a red light.
L[#L + 1] = { name = "CANARY WHARF", w = 16, value = 2, draw = function(r, x, w)
  local B, P, D = box(x, 68)
  local LITC, SHADE, TOP = 0x8FA2B8, 0x5E6E82, 0xB8C4D0
  B(7, 8, 0, 0, 0xFF2A2A)
  for row = 1, 7 do B(8 - row, 7 + row, row, row, TOP) end
  B(1, 7, 8, 67, LITC)
  B(8, 14, 8, 67, SHADE)
  for row = 9, 66, 3 do
    for px = 2, 13, 2 do
      if r.chance(0.25) then D(px, row, WARM) end
    end
  end
end }

-- Battersea Power Station: four white chimneys on a big brick block.
L[#L + 1] = { name = "BATTERSEA", w = 40, value = 2, draw = function(r, x, w)
  local B, P = box(x, 40)
  local BRICK, BRICK_SHADE, CHIMNEY, CHIMNEY_SHADE = 0x9A4A32, 0x6E2F20, 0xEDE8DC, 0xB9B2A2
  B(0, 14, 16, 39, BRICK) B(25, 39, 16, 39, BRICK)
  B(15, 24, 22, 39, BRICK_SHADE)
  for _, c in ipairs({ 2, 9, 27, 34 }) do
    B(c, c + 3, 0, 15, CHIMNEY)
    P(c + 3, c + 3, 1, 15, CHIMNEY_SHADE)
    P(c, c + 3, 0, 0, 0xFFFFFF)
    B(c - 1, c + 4, 16, 19, BRICK_SHADE)
  end
  for px = 1, 38, 3 do P(px, px, 24, 36, 0xFFB86A) end
end }

-- Nelson's Column: a thin column with a tiny statue, on a wide plinth.
L[#L + 1] = { name = "NELSON'S COLUMN", w = 8, value = 2, draw = function(r, x, w)
  local B, P = box(x, 30)
  local GRANITE, SHADE, STATUE = 0xB8B0A0, 0x807868, 0x6E5A3A
  B(3, 5, 0, 0, STATUE) B(3, 4, 1, 2, STATUE)
  B(2, 5, 3, 3, GRANITE) B(1, 6, 4, 5, GRANITE)
  B(3, 4, 6, 22, SHADE) P(3, 3, 6, 22, GRANITE)
  B(2, 5, 23, 24, GRANITE) B(1, 6, 25, 27, GRANITE) B(0, 7, 28, 29, SHADE)
end }

-- The O2: a low white dome with yellow masts poking through it.
L[#L + 1] = { name = "THE O2", w = 50, value = 1, wide = true, draw = function(r, x, w)
  local B, P = box(x, 18)
  local DOME, MAST, UP = 0xE9E6F0, 0xFFD21F, 0x9B7BFF
  for _, m in ipairs({ 6, 14, 22, 27, 35, 43 }) do
    local lean = m < 25 and -1 or 1
    B(m, m, 1, 13, MAST)
    B(m + lean, m + lean, 0, 0, MAST)
  end
  local rows = { { 8, 14, 35 }, { 9, 9, 40 }, { 10, 6, 43 }, { 11, 4, 45 }, { 12, 3, 46 }, { 13, 2, 47 },
    { 14, 1, 48 }, { 15, 1, 48 }, { 16, 1, 48 }, { 17, 0, 49 } }
  for _, d in ipairs(rows) do B(d[2], d[3], d[1], d[1], d[1] >= 14 and UP or DOME) end
end }

-- Wembley Stadium: a huge white arch over a low bowl. Only the arch line is
-- solid above the bowl.
L[#L + 1] = { name = "WEMBLEY", w = 46, value = 2, wide = true, draw = function(r, x, w)
  local B, P, D, Ln = box(x, 34)
  local ARCH, BOWL, BAND = 0xF2F2F2, 0x8A93A6, WARM
  local last
  for px = 2, 43 do
    local k = (px - 22.5) / 20.5
    local row = math.floor(33 * k * k + 0.5)
    if last then Ln(px - 1, last, px, row, (px % 3 == 0) and 0xB8B8B8 or ARCH) end
    B(px, px, row + 1, math.min(33, row + 1), ARCH)
    last = row
  end
  B(4, 41, 24, 33, BOWL)
  P(4, 41, 24, 24, 0xC7CEDB)
  P(4, 41, 27, 28, BAND)
end }

-- The Lloyd's Building: "inside-out", with steel service towers and blue cranes.
L[#L + 1] = { name = "LLOYD'S", w = 22, value = 1, draw = function(r, x, w)
  local B, P = box(x, 38)
  local GLASS, STEEL, SHADE, CRANE = 0x7FB3D5, 0xC9D1D9, 0x7B8794, 0x3D7BFF
  B(4, 17, 6, 37, GLASS)
  for row = 6, 37, 3 do P(4, 17, row, row, STEEL) end
  B(9, 12, 3, 3, GLASS) B(8, 13, 4, 4, GLASS) B(7, 14, 5, 5, GLASS)
  B(0, 3, 2, 37, STEEL) B(18, 21, 8, 37, STEEL)
  for row = 3, 37, 2 do P(0, 3, row, row, SHADE) end
  for row = 9, 37, 2 do P(18, 21, row, row, SHADE) end
  B(0, 5, 0, 0, CRANE) B(1, 1, 1, 1, CRANE)
  B(16, 21, 6, 6, CRANE) B(20, 20, 7, 7, CRANE)
end }

-- Olympia (Kensington): an exhibition hall under a great arched glass
-- roof, with small domed corner towers and a lit entrance band.
L[#L + 1] = { name = "OLYMPIA", w = 36, value = 2, draw = function(r, x, w)
  local B, P, D = box(x, 26)
  local GLASS, RIB, STONE, SHADE, CAP = 0x8FC1D9, 0x4E7F99, 0xE2D6BC, 0xA8987A, 0x4E5866
  -- the barrel roof: a half circle of glass, ribbed
  for row = 2, 15 do
    local dy = 16 - row
    local half = math.floor(math.sqrt(14 * 14 - dy * dy) + 0.5)
    B(18 - half, 17 + half, row, row, GLASS)
  end
  for px = 6, 30, 3 do P(px, px, 4, 15, RIB) end
  P(4, 31, 15, 15, RIB)
  -- the front and its towers
  B(1, 34, 16, 25, STONE)
  B(0, 4, 10, 25, STONE) B(31, 35, 10, 25, STONE)
  B(1, 3, 8, 9, CAP) B(2, 2, 7, 7, CAP)
  B(32, 34, 8, 9, CAP) B(33, 33, 7, 7, CAP)
  P(5, 30, 18, 18, WARM)                         -- the lit sign band
  P(14, 21, 20, 25, SHADE) P(15, 20, 19, 19, SHADE)   -- the arched entrance
  for px = 7, 12, 2 do P(px, px, 21, 23, WARM) P(px + 16, px + 16, 21, 23, WARM) end
end }

-- Somerset House: a long neoclassical front with arches along the bottom,
-- a central pediment and a small dome with a flag.
L[#L + 1] = { name = "SOMERSET HOUSE", w = 44, value = 2, wide = true, draw = function(r, x, w)
  local B, P, D = box(x, 22)
  local STONE, SHADE, DOME, WIN = 0xD9CFB8, 0xA89C82, 0x7E9AA0, WARM
  B(21, 21, 0, 3, 0xC0C0C0)
  B(22, 24, 0, 1, 0xC8102E)
  B(19, 24, 3, 3, DOME) B(18, 25, 4, 5, DOME)
  B(16, 27, 6, 6, STONE) B(14, 29, 7, 7, STONE)
  B(0, 43, 8, 8, SHADE)                          -- the cornice
  B(0, 43, 9, 21, STONE)
  for px = 2, 42, 3 do D(px, 11, WIN) D(px, 14, WIN) end
  P(0, 43, 16, 16, SHADE)
  for px = 1, 41, 4 do P(px, px + 1, 18, 21, 0x3A3226) P(px, px + 1, 17, 17, SHADE) end
  for px = 17, 26, 2 do P(px, px, 9, 15, SHADE) end    -- the portico's columns
end }

S.LANDMARKS = L

---------------------------------------------------------------------------
-- The whole city
---------------------------------------------------------------------------
local function new_building(name, value, x0, x1)
  return { name = name, value = value, x0 = x0, x1 = x1, total = 0, removed = 0, destroyed = false }
end

-- The Thames with a bridge over it, w wide from column x. The water isn't
-- solid; the bridge (deck, railing and piers) is, and can be blown up.
local function river(r, x, w)
  local surface = GROUND_Y - 3
  paint(x, surface, w, CH - surface, S.WATER)
  for px = x + r.int(0, 2), x + w - 1, 3 do dot(px, surface, S.WATER_LIGHT) end
  for _ = 1, 6 do dot(r.int(x, x + w - 1), r.int(surface + 1, CH - 1), S.WATER_LIGHT) end
  local deck = GROUND_Y - r.int(9, 14)
  local DECK, PIER = 0x7A6A55, 0x5E5246
  body(x, deck, w, 2, DECK)
  for px = x, x + w - 1, 3 do body(px, deck - 1, 1, 1, 0xA89878) end
  body(x + 6, deck + 2, 3, CH - deck - 2, PIER)
  body(x + w - 9, deck + 2, 3, CH - deck - 2, PIER)
  return { x0 = x, x1 = x + w - 1, surface = surface }
end

S.WEATHERS = { "clear", "rain", "snow", "fog" }

-- Returns { wind, weather, river (or nil), monkeys = {{x, y}, {x, y}},
-- buildings = {...}, owner = {[column] = building index} }.
function S.build(canvas, seed)
  city = canvas
  cur = nil
  local r = S.new_rng(seed)
  local buildings, owner = {}, {}

  local function start(name, value, x0, w)
    cur = new_building(name, value, x0, x0 + w - 1)
    buildings[#buildings + 1] = cur
    for cx = x0, x0 + w - 1 do owner[cx] = #buildings end
  end

  -- Sky, stars and the moon.
  city:rect(0, 0, CW, CH, S.SKY)
  for _ = 1, 28 do dot(r.int(0, CW - 1), r.int(0, 55), S.STAR) end
  local mx, my = r.int(14, 40), r.int(10, 18)
  for dy = -5, 5 do
    local half = math.floor(math.sqrt(25 - dy * dy) + 0.5)
    paint(mx - half, my + dy, half * 2 + 1, 1, S.MOON)
  end
  paint(mx + 1, my - 2, 2, 2, S.MOON_SHADE)
  dot(mx - 2, my + 2, S.MOON_SHADE)

  -- This round's weather: clear 40%, rain 25%, snow 15%, fog 20%.
  local roll = r.int(1, 100)
  local weather = roll <= 40 and "clear" or (roll <= 65 and "rain" or (roll <= 80 and "snow" or "fog"))
  snowing = weather == "snow"
  local has_river = r.chance(0.5)

  -- Left filler, the left monkey's block, the middle, the right monkey's block, right filler.
  local x = 0
  local fill_l, fill_r = r.int(8, 13), r.int(8, 13)
  start("", 0, x, fill_l)
  block(r, x, fill_l, r.int(18, 34))
  x = x + fill_l
  local lw = r.int(15, 18)
  start("", 0, x, lw)
  local roof_l = block(r, x, lw, r.int(28, 44))
  local monkey_l = x + lw // 2 - 4
  x = x + lw

  local rw = r.int(15, 18)
  local right_start = CW - fill_r - rw
  local mid_w = right_start - x
  if has_river then mid_w = mid_w - S.RIVER_W end

  -- Shuffle the landmarks and take as many as fit, leaving room for a
  -- block or a gap between them.
  local order = {}
  for i = 1, #L do order[i] = i end
  for i = #order, 2, -1 do
    local j = r.int(1, i)
    order[i], order[j] = order[j], order[i]
  end
  local picks, used, wide = {}, 0, false
  local want = r.int(3, 5)
  for _, k in ipairs(order) do
    local lm = L[k]
    if #picks < want and not (lm.wide and wide) and used + lm.w + 4 * (#picks + 2) <= mid_w then
      picks[#picks + 1] = lm
      used = used + lm.w
      if lm.wide then wide = true end
    end
  end

  local gap = mid_w - used
  local slots = #picks + 1
  local river_slot = has_river and r.int(1, slots) or 0
  local thames
  for i = 1, slots do
    if i == river_slot then
      start(BRIDGES[r.int(1, #BRIDGES)], 1, x, S.RIVER_W)
      thames = river(r, x, S.RIVER_W)
      x = x + S.RIVER_W
    end
    local gw
    if i == slots then gw = gap
    else gw = math.min(gap, math.max(3, math.floor(gap / (slots - i + 1)) + r.int(-2, 2))) end
    if gw >= 4 then
      start("", 0, x, gw)
      block(r, x, gw, r.int(14, 46))
    end
    x = x + gw
    gap = gap - gw
    local p = picks[i]
    if p then
      start(p.name, p.value, x, p.w)
      p.draw(r, x, p.w)
      x = x + p.w
    end
  end

  start("", 0, right_start, rw)
  local roof_r = block(r, right_start, rw, r.int(28, 44))
  local monkey_r = right_start + rw // 2 - 4
  start("", 0, right_start + rw, fill_r)
  block(r, right_start + rw, fill_r, r.int(18, 34))
  cur = nil
  city:rect(0, GROUND_Y, CW, 2, S.GROUND)
  if thames then paint(thames.x0, GROUND_Y, S.RIVER_W, 2, S.WATER) end
  snowing = false

  return {
    wind = r.int(-12, 12),
    weather = weather,
    river = thames,
    monkeys = { { x = monkey_l, y = roof_l - 10 }, { x = monkey_r, y = roof_r - 10 } },
    buildings = buildings,
    owner = owner,
  }
end

return S
