-- PROOF OF STACK: a Solana block-stacking puzzle for the Solana OS badge.
--
-- Transactions fall into the blockspace. Fill a whole row to finalize a
-- block: it clears, and you earn lamports (5,000 per block, Solana's base
-- fee per signature, times the epoch). Four blocks at once is a
-- SUPERMAJORITY. Every 10 blocks a new epoch starts and transactions fall
-- faster. When the blockspace is full, it's over.
--
-- Modes: Marathon (as long as you last), Sprint (finalize 40 blocks as fast
-- as you can) and Versus on two badges over the mesh radio, where clearing
-- rows sends spam transactions (garbage rows) to the other player.
--
-- Cluster switch: as the epochs go by the game moves between Solana's
-- clusters, and gravity turns with it. Mainnet (epochs 1-3): transactions
-- fall down. Devnet (4-6): they slide in sideways. Testnet (7-9): they rise.
-- Localnet (10+): gravity turns every epoch. The rules stay the same: the
-- board is simply drawn turned, and the buttons turn with it.
--
-- Controls (Mainnet): LEFT/RIGHT move, UP rotate, DOWN soft drop, SELECT
-- hard drop (a "priority fee": extra lamports), CANCEL quit. On other
-- clusters the arrows follow gravity (the hint bar shows which is which).

local W, H = ui.W, ui.H                  -- 320 x 218
local COLS, ROWS = 10, 20
local CELL = 5                           -- canvas pixels per cell (10 px on screen)
local BX, BY = 110, 1                    -- the board's top-left on screen
local SPRINT_LINES = 40
local LOCK_MS, LOCK_RESETS = 450, 12
local DAS, ARR = 170, 50                 -- held LEFT/RIGHT: delay, then repeat (ms)
local SOFT_MS = 35                       -- ms per row while DOWN is held
local SLOT_MS = 400                      -- Solana's slot time, for the slot counter

local NET = { HELLO_EVERY = 1200, STATE_EVERY = 400, LOST_AFTER = 6000 }
local ATTACK = { 0, 1, 2, 4 }            -- garbage rows sent for 1..4 blocks at once

local has_led = led ~= nil
local has_mesh = mesh ~= nil
local has_keys = sys.keys ~= nil

---------------------------------------------------------------------------
-- Pieces: the seven four-cell shapes, coloured along the Solana gradient:
-- seven even steps from Solana Purple (#9945FF) to Solana Green (#14F195),
-- the brand's two colours, as in the logo. Spam rows are a neutral grey.
---------------------------------------------------------------------------
local PURPLE, GREEN = 0x9945FF, 0x14F195
local GRADIENT = { PURPLE, 0x8263EE, 0x6B82DD, 0x549BCA, 0x3DB6B9, 0x26D4A8, GREEN }
local BG, GRID_DOT, GARBAGE = 0x0E0B1E, 0x221B3E, 0x4A4A5E
local SHAPES = {
  { cells = { { 0, 1 }, { 1, 1 }, { 2, 1 }, { 3, 1 } }, n = 4, color = GRADIENT[7] },  -- long
  { cells = { { 1, 0 }, { 2, 0 }, { 1, 1 }, { 2, 1 } }, n = 4, color = GRADIENT[1], fixed = true },  -- square
  { cells = { { 1, 0 }, { 0, 1 }, { 1, 1 }, { 2, 1 } }, n = 3, color = GRADIENT[4] },
  { cells = { { 1, 0 }, { 2, 0 }, { 0, 1 }, { 1, 1 } }, n = 3, color = GRADIENT[2] },
  { cells = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 2, 1 } }, n = 3, color = GRADIENT[6] },
  { cells = { { 0, 0 }, { 0, 1 }, { 1, 1 }, { 2, 1 } }, n = 3, color = GRADIENT[3] },
  { cells = { { 2, 0 }, { 0, 1 }, { 1, 1 }, { 2, 1 } }, n = 3, color = GRADIENT[5] },
}
-- Each shape's four rotations: turning a cell (x, y) in an n x n box gives (n-1-y, x).
for _, s in ipairs(SHAPES) do
  s.rot = { s.cells }
  for k = 2, 4 do
    local prev, nxt = s.rot[k - 1], {}
    for i, c in ipairs(prev) do nxt[i] = { s.n - 1 - c[2], c[1] } end
    s.rot[k] = s.fixed and s.cells or nxt
  end
end

-- Lighter and darker versions of a colour, for the bevel on each cell.
local function shade(c, f)
  local r, g, b = (c >> 16) & 255, (c >> 8) & 255, c & 255
  if f > 1 then
    r, g, b = r + (255 - r) * (f - 1), g + (255 - g) * (f - 1), b + (255 - b) * (f - 1)
  else
    r, g, b = r * f, g * f, b * f
  end
  return (math.floor(r) << 16) | (math.floor(g) << 8) | math.floor(b)
end
local COLORS = {}                         -- [colour index] = { base, light, dark }
for i, s in ipairs(SHAPES) do COLORS[i] = { s.color, shade(s.color, 1.45), shade(s.color, 0.55) } end
COLORS[8] = { GARBAGE, shade(GARBAGE, 1.4), shade(GARBAGE, 0.6) }
COLORS[9] = { 0xFFFFFF, 0xFFFFFF, 0xDDDDDD }   -- a finalized row, flashing

-- The clusters, and which way transactions fall on each: "down", "right"
-- (they come in from the left), "up" (they rise) or "left".
local CLUSTERS = {
  { name = "MAINNET", dir = "down", color = GREEN },
  { name = "DEVNET", dir = "right", color = PURPLE },
  { name = "TESTNET", dir = "up", color = GRADIENT[4] },
  { name = "LOCALNET", dir = nil, color = 0xFFFFFF },   -- turns every epoch
}
local LOCAL_TURN = { "down", "right", "up", "left" }
local function cluster_of(ep)
  local c = CLUSTERS[math.min(4, (ep - 1) // 3 + 1)]
  return c, c.dir or LOCAL_TURN[(ep - 10) % 4 + 1]
end

-- For each direction: which button moves the piece across (-1 / +1), which
-- one is the soft drop and which one rotates, and the hint bar text.
local KEYS = {
  down = { minus = "left", plus = "right", soft = "down", turn = "up",
    hint = "L/R move  UP rotate  DN soft  SELECT drop" },
  up = { minus = "left", plus = "right", soft = "up", turn = "down",
    hint = "L/R move  DN rotate  UP soft  SELECT drop" },
  right = { minus = "up", plus = "down", soft = "right", turn = "left",
    hint = "U/D move  LEFT rotate  RIGHT soft  SELECT drop" },
  left = { minus = "up", plus = "down", soft = "left", turn = "right",
    hint = "U/D move  RIGHT rotate  LEFT soft  SELECT drop" },
}

-- The eight ideas Solana was built on, shown as blocks are finalized.
local INNOVATIONS = { "PROOF OF HISTORY", "TOWER BFT", "TURBINE", "GULF STREAM",
  "SEALEVEL", "PIPELINING", "CLOUDBREAK", "ARCHIVERS" }

---------------------------------------------------------------------------
-- Random numbers that are the same on every badge for the same seed, so
-- both players in a versus game get the same pieces (Park-Miller).
---------------------------------------------------------------------------
local function new_rng(seed)
  local s = seed % 2147483646 + 1
  return function(a, b)
    local hi, lo = s // 127773, s % 127773
    s = 16807 * lo - 2836 * hi
    if s <= 0 then s = s + 2147483647 end
    return a + s % (b - a + 1)
  end
end

---------------------------------------------------------------------------
-- Screen objects (drawn in the order they are made)
---------------------------------------------------------------------------
ui.bg(0x0B0B14)
local frame = ui.rect(BX - 2, BY - 1, COLS * CELL * 2 + 4, ROWS * CELL * 2 + 2, { color = 0x2A2350, radius = 2 })
-- Two boards: upright (gravity down or up) and sideways (right or left).
local board_v = ui.canvas(BX, BY, COLS * CELL, ROWS * CELL, { scale = 2, color = "bg" })
local board_h = ui.canvas(112, 52, ROWS * CELL, COLS * CELL, { scale = 2, color = "bg" })
local next_cv = ui.canvas(246, 22, 4 * CELL, 2 * CELL, { scale = 2, color = "bg" })
local peer_cv = ui.canvas(251, 118, COLS, ROWS, { scale = 3, color = "bg" })

local function lab(x, y, text, size, color, w, align)
  return ui.label(x, y, text, { size = size, color = color, w = w, align = align })
end
local L = {
  title = lab(4, 2, "PROOF OF STACK", 12, 0xFFFFFF, 102, "left"),
  cluster = lab(4, 16, "MAINNET", 12, GREEN, 102, "left"),
  k1 = lab(4, 34, "LAMPORTS", 12, "dim"), v1 = lab(4, 46, "0", 14, 0xFFFFFF),
  k2 = lab(4, 66, "BLOCKS", 12, "dim"), v2 = lab(4, 78, "0", 14, 0xFFFFFF),
  k3 = lab(4, 98, "EPOCH", 12, "dim"), v3 = lab(4, 110, "1", 14, 0xFFFFFF),
  k4 = lab(4, 130, "SLOT", 12, "dim"), v4 = lab(4, 142, "0", 14, 0xFFFFFF),
  k5 = lab(4, 162, "TPS", 12, "dim"), v5 = lab(4, 174, "0", 14, 0xFFFFFF),
  nxt = lab(216, 4, "NEXT TX", 12, "dim", 100, "center"),
  msg1 = lab(214, 50, "", 12, GREEN, 104, "center"),
  msg2 = lab(214, 66, "", 14, 0xFFFFFF, 104, "center"),
  msg3 = lab(214, 84, "", 12, "dim", 104, "center"),
  peer = lab(216, 102, "", 12, "dim", 100, "center"),
  spam = lab(216, 182, "", 12, PURPLE, 100, "center"),
}
local GAME_OBJS = { frame, next_cv }
for _, l in pairs(L) do GAME_OBJS[#GAME_OBJS + 1] = l end

-- Confetti for a SUPERMAJORITY: a few small squares in the Solana colours,
-- made once and hidden until a burst.
local CONFETTI_N = 24
local confetti = {}
for i = 1, CONFETTI_N do
  -- Alternate squares and strips, so the burst reads as paper confetti.
  local w, h = 6, 6
  if i % 2 == 0 then w, h = 9, 4 end
  local r = ui.rect(0, 0, w, h, { color = GRADIENT[(i - 1) % #GRADIENT + 1], radius = 0 })
  r:show(false)
  confetti[i] = { obj = r }
end

local panel = ui.rect(70, 66, W - 140, 76, { color = "panel", radius = 8, border = "border" })
local msg = ui.label(70, 78, "", { size = 20, color = 0xFFFFFF, w = W - 140, align = "center" })
local sub = ui.label(70, 110, "", { size = 12, color = "dim", w = W - 140, align = "center" })

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local state = "menu"      -- menu | lobby | play | clear | over
local mode = "marathon"   -- marathon | sprint | versus
local grid = {}           -- grid[row][col]: 0 empty, 1..8 a colour index
local shown = {}          -- what each screen cell shows now (to redraw only changes)
local orient = "down"     -- which way transactions fall on screen right now
local cur = nil           -- the falling piece: { k, r, x, y }
local next_k = 1
local bag = {}
local rng = nil
local fall_t, lock_t, lock_resets = 0, 0, 0
local das_dir, das_t = 0, 0
local score, lines, epoch, slot = 0, 0, 1, 0
local slot_t, play_ms = 0, 0
local locks = {}          -- when recent pieces locked (for the TPS meter)
local clearing = nil      -- rows being finalized, and when the flash ends
local now = 0
local msg_timer = nil
local best = storage.get("best") or { lamports = 0, sprint = 0, wins = 0 }

-- Versus
local VS = { peer = nil, name = "", game = 0, sent = 0, got = 0, pending = 0,
  last_send = -100000, last_heard = 0, over_at = nil, result = nil }
local sent_at = { -100000, -100000, -100000, -100000 }

-- Menus
local menu, menu_title, menu_sub, menu_back = nil, nil, nil, nil
local LB = { list = nil, title = nil, info = nil, ids = {}, seen = {}, invited = nil, asking = nil, timer = nil }
local menu_i = 1

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function commas(n)
  local s = tostring(math.floor(n))
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  if out:sub(1, 1) == "," then out = out:sub(2) end
  return out
end

local function clock(ms)
  local t = ms // 100
  return string.format("%d:%02d.%d", t // 600, (t // 10) % 60, t % 10)
end

local function show_message(a, b)
  local on = a ~= nil
  panel:show(on) msg:show(on) sub:show(on)
  if on then msg:text(a) sub:text(b or "") end
end

local function side_message(a, b, c)
  L.msg1:text(a or "") L.msg2:text(b or "") L.msg3:text(c or "")
  if msg_timer then timer.cancel(msg_timer) end
  msg_timer = timer.after(1800, function()
    L.msg1:text("") L.msg2:text("") L.msg3:text("")
    msg_timer = nil
  end)
end

-- Lights and confetti are moved along by on_tick, not by timers: the badge
-- allows only 8 timers at a time (and the LED sweep alone would need 9).
local FX = { led_off_at = nil, sweep_t = nil, sweep_n = 0, confetti_t = nil }
local SWEEP_STEP = 45

local function flash(r, g, b, ms)
  if not has_led then return end
  FX.sweep_t = nil
  led.fill(r, g, b)
  FX.led_off_at = now + (ms or 100)
end

-- A light runs across the LEDs from Solana Purple to Solana Green.
local function sweep()
  if not has_led then return end
  FX.led_off_at, FX.sweep_t, FX.sweep_n = nil, 0, 0
end

-- Confetti bursts from the middle of the board and falls the way
-- transactions fall on this cluster.
local function confetti_burst()
  local cx, cy = BX + COLS * CELL, BY + ROWS * CELL
  if orient == "right" or orient == "left" then cx, cy = 112 + ROWS * CELL, 52 + COLS * CELL end
  for i, p in ipairs(confetti) do
    local a = (i / CONFETTI_N) * 2 * math.pi + math.random() * 0.4
    local v = 120 + math.random() * 150           -- pixels a second
    p.x, p.y = cx, cy
    p.vx, p.vy = math.cos(a) * v, math.sin(a) * v
    p.obj:pos(cx, cy)
    p.obj:show(true)
  end
  FX.confetti_t = 0
end

local function confetti_stop()
  FX.confetti_t = nil
  for _, p in ipairs(confetti) do p.obj:show(false) end
end

local CONFETTI_MS, CONFETTI_G = 1600, 300   -- how long a burst lasts; its gravity (px/s/s)
local GRAVITY = { down = { 0, 1 }, up = { 0, -1 }, right = { 1, 0 }, left = { -1, 0 } }

local function fx_tick(ms)
  if has_led then
    if FX.led_off_at and now >= FX.led_off_at then FX.led_off_at = nil led.off() end
    if FX.sweep_t then
      FX.sweep_t = FX.sweep_t + ms
      local n = math.min(led.count, FX.sweep_t // SWEEP_STEP)
      if n > FX.sweep_n then
        FX.sweep_n = n
        led.off()
        local t = (n - 1) / (led.count - 1)
        led.set(n, math.floor(0x99 + (0x14 - 0x99) * t), math.floor(0x45 + (0xF1 - 0x45) * t),
          math.floor(0xFF + (0x95 - 0xFF) * t))
      end
      if FX.sweep_t >= led.count * SWEEP_STEP + 200 then FX.sweep_t = nil led.off() end
    end
  end
  if FX.confetti_t then
    FX.confetti_t = FX.confetti_t + ms
    if FX.confetti_t >= CONFETTI_MS then confetti_stop() return end
    local g = GRAVITY[orient] or GRAVITY.down
    local dt = ms / 1000
    for _, p in ipairs(confetti) do
      p.vx = p.vx * 0.97 + g[1] * CONFETTI_G * dt
      p.vy = p.vy * 0.97 + g[2] * CONFETTI_G * dt
      p.x, p.y = p.x + p.vx * dt, p.y + p.vy * dt
      p.obj:pos(math.floor(p.x), math.floor(p.y))
    end
  end
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

local function radio_send(to, m)
  local t = sys.millis()
  if t - sent_at[1] < 1000 then return false end   -- at most 4 a second
  table.remove(sent_at, 1)
  sent_at[4] = t
  mesh.send(to, m)
  return true
end

---------------------------------------------------------------------------
-- Drawing the board
---------------------------------------------------------------------------
local function paint_cell(cv, c, r, v)
  local x, y = c * CELL, r * CELL
  if v == 0 then
    cv:rect(x, y, CELL, CELL, BG)
    cv:pixel(x + 2, y + 2, GRID_DOT)
  elseif v < 0 then                       -- the ghost: where the piece would land
    local col = COLORS[-v][3]
    cv:rect(x, y, CELL, CELL, BG)
    cv:rect(x, y, CELL, 1, col) cv:rect(x, y + CELL - 1, CELL, 1, col)
    cv:rect(x, y, 1, CELL, col) cv:rect(x + CELL - 1, y, 1, CELL, col)
  else
    local col = COLORS[v]
    cv:rect(x, y, CELL, CELL, col[1])
    cv:rect(x, y, CELL, 1, col[2])
    cv:rect(x, y + 1, 1, CELL - 1, col[2])
    cv:rect(x + 1, y + CELL - 1, CELL - 1, 1, col[3])
    cv:rect(x + CELL - 1, y + 1, 1, CELL - 2, col[3])
  end
end

local function cells_of(p)
  local out = {}
  for i, c in ipairs(SHAPES[p.k].rot[p.r]) do out[i] = { p.x + c[1], p.y + c[2] } end
  return out
end

local function fits(k, r, x, y)
  for _, c in ipairs(SHAPES[k].rot[r]) do
    local cx, cy = x + c[1], y + c[2]
    if cx < 0 or cx >= COLS or cy >= ROWS then return false end
    if cy >= 0 and grid[cy][cx] ~= 0 then return false end
  end
  return true
end

local function ghost_y()
  local y = cur.y
  while fits(cur.k, cur.r, cur.x, y + 1) do y = y + 1 end
  return y
end

-- Redraws only the cells that changed since last time.
local function render()
  local view = {}
  for r = 0, ROWS - 1 do
    local row = {}
    for c = 0, COLS - 1 do row[c] = grid[r][c] end
    view[r] = row
  end
  if clearing then
    for _, r in ipairs(clearing.rows) do
      for c = 0, COLS - 1 do view[r][c] = 9 end
    end
  end
  if cur and state == "play" then
    local gy = ghost_y()
    for _, c in ipairs(SHAPES[cur.k].rot[cur.r]) do
      local cx, cy = cur.x + c[1], gy + c[2]
      if cy >= 0 and view[cy][cx] == 0 then view[cy][cx] = -cur.k end
    end
    for _, c in ipairs(cells_of(cur)) do
      if c[2] >= 0 then view[c[2]][c[1]] = cur.k end
    end
  end
  -- Logical row r runs along gravity; it lands on the screen turned to suit
  -- the cluster.
  local cv = (orient == "down" or orient == "up") and board_v or board_h
  for r = 0, ROWS - 1 do
    for c = 0, COLS - 1 do
      local v = view[r][c]
      local sx, sy
      if orient == "down" then sx, sy = c, r
      elseif orient == "up" then sx, sy = c, ROWS - 1 - r
      elseif orient == "right" then sx, sy = r, c
      else sx, sy = ROWS - 1 - r, c end
      local key = sy * 32 + sx
      if shown[key] ~= v then
        paint_cell(cv, sx, sy, v)
        shown[key] = v
      end
    end
  end
end

local function render_next()
  next_cv:clear(BG)
  local s = SHAPES[next_k]
  for _, c in ipairs(s.rot[1]) do
    local off = s.n == 3 and 0.5 or 0
    local x = math.floor((c[1] + off) * CELL)
    local y = (c[2] - (s.n == 4 and 1 or 0) + (s.n == 4 and 0.5 or 0)) * CELL
    local col = COLORS[next_k]
    next_cv:rect(x, math.floor(y), CELL, CELL, col[1])
    next_cv:rect(x, math.floor(y), CELL, 1, col[2])
  end
end

-- The other player's stack, from their column heights (versus).
-- Sideways there's no room for the picture, so it says how high their stack is.
local function render_peer(heights)
  peer_cv:clear(BG)
  local top = 0
  for c = 0, COLS - 1 do
    local h = heights[c + 1] or 0
    if h > 0 then peer_cv:rect(c, ROWS - h, 1, h, 0x6B3FB3) end   -- a deep Solana purple
    top = math.max(top, h)
  end
  if orient == "down" or orient == "up" then
    L.peer:text(VS.name)
  else
    L.peer:text(VS.name .. ": " .. top .. " rows")
  end
end

local function update_panel()
  L.v1:text(commas(score))
  if mode == "sprint" then
    L.k2:text("BLOCKS LEFT")
    L.v2:text(tostring(math.max(0, SPRINT_LINES - lines)))
    L.k5:text("TIME")
    L.v5:text(clock(play_ms))
  else
    L.k2:text("BLOCKS")
    L.v2:text(tostring(lines))
    L.k5:text("TPS")
    -- Pieces locked in the last 10 s, scaled so ~1 a second reads as
    -- Solana's famous 65,000.
    local n = 0
    for _, t in ipairs(locks) do if now - t < 10000 then n = n + 1 end end
    L.v5:text(commas(n * 6500))
  end
  L.v3:text(tostring(epoch))
  L.v4:text(commas(slot))
  L.spam:text(VS.pending > 0 and ("INCOMING SPAM " .. VS.pending) or "")
end

local function set_game_visible(on)
  for _, o in ipairs(GAME_OBJS) do o:show(on) end
  if not on then confetti_stop() end
  local upright = orient == "down" or orient == "up"
  board_v:show(on and upright)
  board_h:show(on and not upright)
  peer_cv:show(on and mode == "versus" and upright)
  L.peer:show(on and mode == "versus")
  L.spam:show(on and mode == "versus")
end

-- Turns the board for a new direction: the stack is redrawn turned, the
-- side panel makes room, and the buttons follow.
local function set_orientation(dir)
  orient = dir
  shown = {}
  local upright = dir == "down" or dir == "up"
  local cv = upright and board_v or board_h
  cv:clear(BG)
  if upright then
    frame:pos(BX - 2, BY - 1)
    frame:size(COLS * CELL * 2 + 4, ROWS * CELL * 2 + 2)
    L.nxt:pos(216, 4) next_cv:pos(246, 22)
    L.msg1:pos(214, 50) L.msg2:pos(214, 66) L.msg3:pos(214, 84)
    L.peer:pos(216, 102) peer_cv:pos(251, 118) L.spam:pos(216, 182)
  else
    -- Sideways: the board sits low on the right, the next piece and the
    -- messages go above it, and the other player's view below the panel.
    frame:pos(110, 51)
    frame:size(ROWS * CELL * 2 + 4, COLS * CELL * 2 + 2)
    L.nxt:pos(106, 4) next_cv:pos(130, 22)
    L.msg1:pos(206, 2) L.msg2:pos(206, 18) L.msg3:pos(206, 34)
    L.peer:pos(112, 158) L.spam:pos(112, 176)
  end
  if state ~= "menu" and state ~= "lobby" then
    board_v:show(upright)
    board_h:show(not upright)
    peer_cv:show(mode == "versus" and upright)
  end
  ui.hint(KEYS[dir].hint)
end

---------------------------------------------------------------------------
-- The game
---------------------------------------------------------------------------
local function fall_ms()
  return math.max(50, math.floor(800 * 0.85 ^ (epoch - 1)))
end

-- The next shape: each run of seven has every shape once, in a shuffled order.
local function draw_bag()
  if #bag == 0 then
    for i = 1, 7 do bag[i] = i end
    for i = 7, 2, -1 do
      local j = rng(1, i)
      bag[i], bag[j] = bag[j], bag[i]
    end
  end
  return table.remove(bag, 1)
end

local finish   -- defined below

local function spawn()
  local k = next_k
  next_k = draw_bag()
  render_next()
  cur = { k = k, r = 1, x = 3, y = SHAPES[k].n == 4 and -1 or 0 }
  fall_t, lock_t, lock_resets = 0, 0, 0
  if not fits(cur.k, cur.r, cur.x, cur.y) then
    finish(false)
  end
end

-- Versus: spam rows from the other player rise from the bottom, each with
-- one gap. Returns false if they push the stack over the top.
local function add_garbage(n)
  local hole = rng(0, COLS - 1)
  for _ = 1, n do
    for c = 0, COLS - 1 do
      if grid[0][c] ~= 0 then return false end
    end
    for r = 0, ROWS - 2 do
      for c = 0, COLS - 1 do grid[r][c] = grid[r + 1][c] end
    end
    for c = 0, COLS - 1 do grid[ROWS - 1][c] = (c == hole) and 0 or 8 end
  end
  return true
end

local function full_rows()
  local rows = {}
  for r = 0, ROWS - 1 do
    local full = true
    for c = 0, COLS - 1 do
      if grid[r][c] == 0 then full = false break end
    end
    if full then rows[#rows + 1] = r end
  end
  return rows
end

local function remove_rows(rows)
  local keep = {}
  local gone = {}
  for _, r in ipairs(rows) do gone[r] = true end
  for r = ROWS - 1, 0, -1 do
    if not gone[r] then keep[#keep + 1] = grid[r] end
  end
  for r = ROWS - 1, 0, -1 do
    local src = keep[ROWS - r]
    if src then grid[r] = src
    else
      grid[r] = {}
      for c = 0, COLS - 1 do grid[r][c] = 0 end
    end
  end
end

local function lock_piece()
  for _, c in ipairs(cells_of(cur)) do
    if c[2] < 0 then finish(false) return end
    grid[c[2]][c[1]] = cur.k
  end
  cur = nil
  locks[#locks + 1] = now
  if #locks > 30 then table.remove(locks, 1) end
  local rows = full_rows()
  if #rows > 0 then
    clearing = { rows = rows, until_t = now + 180 }
    state = "clear"
    return
  end
  -- Spam waiting from the other player lands now.
  if VS.pending > 0 then
    local n = math.min(VS.pending, 8)
    VS.pending = VS.pending - n
    if not add_garbage(n) then finish(false) return end
  end
  spawn()
end

-- After the flash: remove the finalized rows and pay out.
local function finish_clear()
  local rows = clearing.rows
  clearing = nil
  remove_rows(rows)
  local n = #rows
  local old_epoch = epoch
  lines = lines + n
  local pay = ({ 5000, 15000, 30000, 60000 })[n] * epoch
  score = score + pay
  epoch = 1 + lines // 10
  local idea = INNOVATIONS[math.random(1, #INNOVATIONS)]
  if n == 4 then
    side_message("SUPERMAJORITY!", "+" .. commas(pay), idea)
    sweep()
    confetti_burst()
  else
    side_message(idea, "+" .. commas(pay), n .. " FINALIZED")
    flash(0x14, 0xF1, 0x95, 90)
  end
  if epoch > old_epoch then
    local cl, dir = cluster_of(epoch)
    if dir ~= orient then
      -- A new cluster (or Localnet's turn): gravity changes direction.
      set_orientation(dir)
      L.cluster:text(cl.name) L.cluster:color(cl.color)
      side_message("CLUSTER SWITCH", cl.name, "gravity: " .. dir)
      sweep()
    else
      timer.after(1900, function()
        if state == "play" then side_message("NEW EPOCH", tostring(epoch), "validators rewarded") end
      end)
    end
  end
  if mode == "versus" then
    -- Finalized blocks cancel incoming spam first, then the rest is sent.
    local attack = ATTACK[n]
    local cancel = math.min(attack, VS.pending)
    VS.pending = VS.pending - cancel
    VS.sent = VS.sent + (attack - cancel)
  end
  state = "play"
  if mode == "sprint" and lines >= SPRINT_LINES then
    finish(true)
    return
  end
  spawn()
end

local function try_move(dx, dy)
  if cur and fits(cur.k, cur.r, cur.x + dx, cur.y + dy) then
    cur.x, cur.y = cur.x + dx, cur.y + dy
    if lock_resets < LOCK_RESETS then lock_t = 0 lock_resets = lock_resets + 1 end
    return true
  end
  return false
end

local function rotate()
  if not cur then return end
  local r = cur.r % 4 + 1
  -- Try in place, then nudged sideways or up, for turning against walls.
  for _, k in ipairs({ { 0, 0 }, { -1, 0 }, { 1, 0 }, { -2, 0 }, { 2, 0 }, { 0, -1 } }) do
    if fits(cur.k, r, cur.x + k[1], cur.y + k[2]) then
      cur.r, cur.x, cur.y = r, cur.x + k[1], cur.y + k[2]
      if lock_resets < LOCK_RESETS then lock_t = 0 lock_resets = lock_resets + 1 end
      return
    end
  end
end

local function hard_drop()
  if not cur then return end
  local d = ghost_y() - cur.y
  cur.y = cur.y + d
  score = score + 2 * d                   -- the priority fee
  if d > 2 then side_message("PRIORITY FEE", "+" .. (2 * d), "") end
  lock_piece()
end

local function new_game(seed)
  rng = new_rng(seed)
  for r = 0, ROWS - 1 do
    grid[r] = {}
    for c = 0, COLS - 1 do grid[r][c] = 0 end
  end
  bag = {}
  score, lines, epoch, slot, slot_t, play_ms = 0, 0, 1, 0, 0, 0
  locks, clearing = {}, nil
  VS.sent, VS.got, VS.pending, VS.over_at, VS.result = 0, 0, 0, nil, nil
  das_dir, das_t = 0, 0
  next_k = draw_bag()
  set_orientation("down")
  L.cluster:text("MAINNET") L.cluster:color(CLUSTERS[1].color)
  set_game_visible(true)
  show_message(nil)
  L.title:text(mode == "sprint" and "SPRINT 40" or (mode == "versus" and "VERSUS" or "PROOF OF STACK"))
  if mode == "versus" then
    render_peer({})
  end
  state = "play"
  ui.hint(KEYS[orient].hint)
  spawn()
  render()
  update_panel()
end

-- The game ends: won (sprint done, or the other player topped out) or not.
function finish(won)
  if state == "over" then return end
  state = "over"
  render()
  local title, line
  if mode == "sprint" and won then
    title = "FINALIZED"
    line = "40 blocks in " .. clock(play_ms)
    if best.sprint == 0 or play_ms < best.sprint then
      best.sprint = play_ms
      line = line .. "  NEW BEST"
    end
    sweep()
  elseif mode == "versus" then
    title = won and "YOU WIN!" or "BLOCKSPACE FULL"
    line = won and (VS.name .. "'s blockspace is full") or (VS.name .. " wins")
    if won then best.wins = (best.wins or 0) + 1 sweep() end
    VS.result = won and "win" or "lose"
    VS.over_at = now
  else
    title = "BLOCKSPACE FULL"
    line = commas(score) .. " lamports"
    if score > (best.lamports or 0) then
      best.lamports = score
      line = line .. "  NEW BEST"
    end
    flash(0x99, 0x45, 0xFF, 500)
  end
  storage.set("best", best)
  show_message(title, line .. "   SELECT again")
  ui.hint(mode == "versus" and "SELECT lobby   CANCEL menu" or "SELECT play again   CANCEL menu")
end

---------------------------------------------------------------------------
-- Versus over the mesh radio
---------------------------------------------------------------------------
-- Column heights, as one letter each ("a" = empty, "u" = full).
local function heights()
  local out = {}
  for c = 0, COLS - 1 do
    local h = 0
    for r = 0, ROWS - 1 do
      if grid[r][c] ~= 0 then h = ROWS - r break end
    end
    out[#out + 1] = string.char(97 + h)
  end
  return table.concat(out)
end

-- Every message repeats the running total of spam sent, so a lost message
-- is made up for by the next one.
local function send_state()
  if not VS.peer then return end
  if radio_send(VS.peer, { t = "s", g = VS.game, a = VS.sent, h = heights(),
      o = (VS.result == "lose") and 1 or 0, b = lines }) then
    VS.last_send = now
  end
end

local function on_peer_state(m)
  VS.last_heard = now
  if (m.a or 0) > VS.got then
    VS.pending = VS.pending + (m.a - VS.got)
    VS.got = m.a
    flash(0x99, 0x45, 0xFF, 120)
  end
  local hs = {}
  for i = 1, #(m.h or "") do hs[i] = string.byte(m.h, i) - 97 end
  render_peer(hs)
  if m.o == 1 and (state == "play" or state == "clear") then finish(true) end
  update_panel()
end

---------------------------------------------------------------------------
-- Nearby leaderboard (scores.lua, shared by all the games)
---------------------------------------------------------------------------
local board = require("scores").new({
  game = "Proof of Stack", send = radio_send, name_of = name_of,
  categories = {
    { label = "MARATHON LAMPORTS" },
    { label = "SPRINT 40 TIME", low = true, fmt = clock },
    { label = "VERSUS WINS" },
  },
  mine = function() return { best.lamports or 0, best.sprint or 0, best.wins or 0 } end,
})

---------------------------------------------------------------------------
-- Menus
---------------------------------------------------------------------------
local close_menu, close_lobby, open_lobby

local function menu_items()
  return {
    { title = "1 player: Marathon", right = (best.lamports or 0) > 0 and commas(best.lamports) or nil },
    { title = "1 player: Sprint 40", right = (best.sprint or 0) > 0 and clock(best.sprint) or nil },
    { title = "2 players: 2 badges", right = (best.wins or 0) > 0 and ("wins " .. best.wins) or nil },
    { title = "Nearby leaderboard" },
  }
end

local function open_menu()
  state = "menu"
  VS.peer = nil
  set_game_visible(false)
  show_message(nil)
  if has_led then led.off() end
  FX.led_off_at, FX.sweep_t = nil, nil
  menu_title = ui.label(0, 22, "PROOF OF STACK", { size = 32, color = 0xFFFFFF, w = W, align = "center" })
  menu_sub = ui.label(0, 64, "Finalize blocks. Earn lamports. Don't fill the blockspace.",
    { size = 12, color = "dim", w = W, align = "center" })
  menu_back = ui.rect(34, 90, W - 68, 116, { color = 0x15102A, radius = 8, border = "border" })
  menu = ui.list(40, 94, W - 80, 108, menu_items(), {
    on_select = function(i)
      menu_i = i
      if i == 1 then close_menu() mode = "marathon" new_game(math.random(1, 2147483000))
      elseif i == 2 then close_menu() mode = "sprint" new_game(math.random(1, 2147483000))
      elseif i == 4 then close_menu() state = "board" board:open(function() open_menu() end)
      elseif not has_mesh then ui.toast("Versus needs the mesh radio")
      else close_menu() open_lobby() end
    end,
  })
  menu:select(menu_i)
  ui.hint("SELECT play   CANCEL exit")
end

function close_menu()
  for _, o in ipairs({ menu, menu_title, menu_sub, menu_back }) do o:remove() end
  menu, menu_title, menu_sub, menu_back = nil, nil, nil, nil
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
  LB.info:text(#items == 0 and "Looking for players... Open Proof of Stack on another badge."
    or "Pick a player and press SELECT to invite them.")
end

function open_lobby()
  state = "lobby"
  LB.invited, LB.asking, LB.seen = nil, nil, {}
  set_game_visible(false)
  show_message(nil)
  LB.title = ui.label(0, 8, "VERSUS", { size = 20, color = 0xFFFFFF, w = W, align = "center" })
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
  LB.timer = timer.every(NET.HELLO_EVERY, function()
    if state == "lobby" then
      radio_send("*", { t = "hi" })
      if LB.invited then radio_send(LB.invited, { t = "inv" }) end
      refresh_lobby()
    end
  end)
  refresh_lobby()
end

function close_lobby()
  if LB.timer then timer.cancel(LB.timer) LB.timer = nil end
  for _, k in ipairs({ "list", "title", "info" }) do
    if LB[k] then LB[k]:remove() LB[k] = nil end
  end
end

local function start_versus(id, g)
  close_lobby()
  mode = "versus"
  VS.peer, VS.name, VS.game = id, name_of(id), g
  VS.last_heard = now
  new_game(g)                             -- the same seed: the same pieces for both
end

local function accept_invite(id)
  local g = math.random(1, 2147483000)
  radio_send(id, { t = "go", g = g })
  timer.after(400, function() radio_send(id, { t = "go", g = g }) end)
  start_versus(id, g)
end

local function leave_versus()
  if VS.peer then
    local to, bye = VS.peer, { t = "bye", g = VS.game }
    radio_send(to, bye)
    timer.after(300, function() radio_send(to, bye) end)
    timer.after(700, function() radio_send(to, bye) end)
    VS.peer = nil
  end
end

---------------------------------------------------------------------------
-- Callbacks
---------------------------------------------------------------------------
function on_mesh(from, m)
  if type(m) ~= "table" then return end
  if board:handle(from, m) then return end
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
      ui.confirm(name_of(from) .. " wants to play Proof of Stack. Play?", function(yes)
        LB.asking = nil
        if yes and state == "lobby" then accept_invite(from) end
      end)
    end
  elseif m.t == "go" or m.t == "s" then
    if state == "lobby" and LB.invited == from and m.g then
      start_versus(from, m.g)              -- also covers a lost "go"
    end
    if mode == "versus" and from == VS.peer and m.g == VS.game and m.t == "s" then
      on_peer_state(m)
    end
  elseif m.t == "bye" then
    if mode == "versus" and from == VS.peer and m.g == VS.game and (state == "play" or state == "clear") then
      VS.peer = nil
      finish(true)
      msg:text("PLAYER LEFT")
    end
  end
end

local function input_tick(ms)
  if not has_keys then return end
  local k = sys.keys()
  local map = KEYS[orient]
  local minus, plus = k[map.minus], k[map.plus]
  local dir = (minus and not plus) and -1 or ((plus and not minus) and 1 or 0)
  if dir == 0 then
    das_dir = 0
  elseif dir ~= das_dir then
    das_dir, das_t = dir, -DAS
    try_move(dir, 0)
  else
    das_t = das_t + ms
    while das_t >= ARR do
      das_t = das_t - ARR
      if not try_move(dir, 0) then das_t = 0 break end
    end
  end
  return k[map.soft]
end

function on_tick(ms)
  now = now + ms
  fx_tick(ms)
  -- Announce our bests for nearby leaderboards, except during a versus game.
  board:tick(ms, mode == "versus" and VS.peer ~= nil and (state == "play" or state == "clear"))
  if mode == "versus" and VS.peer and state ~= "menu" and state ~= "lobby" then
    if now - VS.last_send >= NET.STATE_EVERY then send_state() end
    if (state == "play" or state == "clear") and now - VS.last_heard > NET.LOST_AFTER then
      VS.peer = nil
      finish(true)
      msg:text("CONNECTION LOST")
    end
    -- After the game ends, keep telling the other badge for a few seconds.
    if state == "over" and VS.over_at and now - VS.over_at > 4000 then VS.peer = nil end
  end

  if state == "clear" then
    if now >= clearing.until_t then finish_clear() end
    render()
    update_panel()
    return
  end
  if state ~= "play" then return end
  ms = math.min(ms, 100)
  play_ms = play_ms + ms
  slot_t = slot_t + ms
  while slot_t >= SLOT_MS do slot_t = slot_t - SLOT_MS slot = slot + 1 end

  local soft = input_tick(ms)
  if not cur then return end
  local step = soft and math.min(SOFT_MS, fall_ms()) or fall_ms()
  if fits(cur.k, cur.r, cur.x, cur.y + 1) then
    lock_t = 0
    fall_t = fall_t + ms
    while fall_t >= step and cur and fits(cur.k, cur.r, cur.x, cur.y + 1) do
      fall_t = fall_t - step
      cur.y = cur.y + 1
      if soft then score = score + 1 end
    end
  else
    fall_t = 0
    lock_t = lock_t + ms
    if lock_t >= LOCK_MS then lock_piece() end
  end
  if state == "play" or state == "clear" then render() end
  update_panel()
end

function on_key(key, rep)
  if state == "board" then return board:key(key, rep) end
  if state == "menu" then return key ~= "back" end
  if state == "lobby" then
    if key == "back" and not rep then close_lobby() open_menu() end
    return true
  end
  if key == "back" then
    if rep then return true end
    if mode == "versus" then leave_versus() end
    cur = nil
    open_menu()
    return true
  end
  if state == "over" then
    if key == "select" and not rep then
      if mode == "versus" then leave_versus() open_lobby()
      else new_game(math.random(1, 2147483000)) end
    end
    return true
  end
  if state ~= "play" or not cur then return true end
  local map = KEYS[orient]
  if key == map.turn and not rep then rotate()
  elseif key == "select" and not rep then hard_drop()
  elseif not has_keys and (key == map.minus or key == map.plus) then
    try_move(key == map.minus and -1 or 1, 0)    -- older badges: a step per press
  elseif not has_keys and key == map.soft then
    if try_move(0, 1) then score = score + 1 end
  end
  if state == "play" then render() end
  update_panel()
  return true
end

function on_exit()
  if mode == "versus" then leave_versus() end
  if has_led then led.off() end
end

---------------------------------------------------------------------------
show_message(nil)
set_game_visible(false)
open_menu()
