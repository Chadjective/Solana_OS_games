-- Solana Pong: Pong for the Solana OS badge.
-- The ball is the Solana mark (spinning like a coin); the paddles are the
-- top and bottom bars of the "S", and the net is made of its middle bar.
--
-- Controls: UP/DOWN move your paddle (left). SELECT pauses. CANCEL quits to
-- the menu (and exits from the menu). First to 7 points wins.

local art = require("art")

local W, H = ui.W, ui.H             -- 320 x 218
local PAL = {palette = art.palette}
local WIN_SCORE = 7

local BALL_W, BALL_H = art.BALL_W, art.BALL_H
local PW, PH = art.PADDLE_W, art.PADDLE_H
local HINT_H = 16                   -- the key-hint strip pinned to the bottom
local TOP_Y, BOT_Y = 2, H - HINT_H - 2   -- the playing field, between the two walls
local MID_Y = (TOP_Y + BOT_Y) / 2
local LEFT_X = 8                    -- left paddle's x (its left edge)
local RIGHT_X = W - 8 - PW          -- right paddle's x

local LEVELS = {
  -- cpu: paddle speed (px/s); err: aiming error (px, grows with ball speed);
  -- think: ms between decisions; sees: how far across (0..1) the ball must be
  -- before the CPU starts tracking it; start/max: ball speed (px/s).
  { name = "Easy",   cpu = 90,  err = 30, think = 260, sees = 0.60, start = 115, max = 230 },
  { name = "Normal", cpu = 125, err = 22, think = 180, sees = 0.45, start = 130, max = 280 },
  { name = "Hard",   cpu = 170, err = 14, think = 110, sees = 0.30, start = 150, max = 330 },
}
local PLAYER_SPEED = 210            -- px per second
local SPEEDUP = 1.06                -- ball speed multiplier per paddle hit
local MAX_BOUNCE = 1.0              -- radians (~57 degrees) at the paddle's tip

local has_led = led ~= nil

---------------------------------------------------------------------------
-- Game objects (built once, drawn in the order they are made)
---------------------------------------------------------------------------
ui.bg(0x0B0B14)

local score_l = ui.label(W // 2 - 70, 8, "0", { size = 32, color = "border", w = 40, align = "center" })
local score_r = ui.label(W // 2 + 30, 8, "0", { size = 32, color = "border", w = 40, align = "center" })
local net = ui.image(W // 2 - art.NET_W // 2, TOP_Y + 2, art.net, PAL)
local wall_t = ui.gradient(0, 0, W, 2)
local wall_b = ui.gradient(0, BOT_Y, W, 2)
local pad_l = ui.image(LEFT_X, 0, art.paddle_left, PAL)
local pad_r = ui.image(RIGHT_X, 0, art.paddle_right, PAL)

local ball_frames = {}
for i, rows in ipairs(art.ball) do
  local img = ui.image(0, 0, rows, PAL)
  img:show(false)
  ball_frames[i] = img
end

local panel = ui.rect(60, 64, W - 120, 74, { color = "panel", radius = 8, border = "border" })
local msg = ui.label(60, 76, "", { size = 20, color = 0xFFFFFF, w = W - 120, align = "center" })
local sub = ui.label(60, 108, "", { size = 14, color = "dim", w = W - 120, align = "center" })

local game_objects = { score_l, score_r, net, wall_t, wall_b, pad_l, pad_r }

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local state = "menu"     -- menu | serve | play | paused | over
local level = LEVELS[2]
local level_i = 2
local score = { 0, 0 }
local ly, ry = 0, 0      -- paddle tops
local bx, by, vx, vy = 0, 0, 0, 0
local speed = 0
local spin, spin_t = 1, 0
local shown_frame = nil
local serve_t = 0        -- ms left before the ball moves
local serve_dir = 1
local cpu_target = MID_Y
local cpu_think = 0
local cpu_err = 0        -- how far off the CPU aims this time (px)
local held_until = { up = 0, down = 0 }   -- fallback for badges without sys.keys
local now = 0
local menu = nil
local menu_logo, menu_title = nil, nil

local wins = storage.get("wins") or { 0, 0, 0 }

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
  timer.after(ms or 70, led.off)
end

local function sweep(r, g, b)
  if not has_led then return end
  for i = 1, 6 do
    local n = i
    timer.after(n * 40, function()
      led.off()
      led.set(n, r, g, b)
    end)
  end
  timer.after(300, led.off)
end

local function draw_ball(visible)
  local frame = ball_frames[spin]
  if shown_frame and shown_frame ~= frame then shown_frame:show(false) end
  if visible then
    frame:pos(math.floor(bx + 0.5), math.floor(by + 0.5))
    if shown_frame ~= frame then frame:show(true) end
    shown_frame = frame
  else
    frame:show(false)
    shown_frame = nil
  end
end

local function draw_paddles()
  pad_l:pos(LEFT_X, math.floor(ly + 0.5))
  pad_r:pos(RIGHT_X, math.floor(ry + 0.5))
end

local function set_game_visible(on)
  for _, o in ipairs(game_objects) do o:show(on) end
  if not on then draw_ball(false) end
end

-- Where will the ball's centre be (in y) when it reaches x = tx?
-- Follows bounces off the top and bottom walls.
local function predict_y(tx)
  if vx == 0 then return MID_Y end
  local cx = bx + BALL_W / 2
  local cy = by + BALL_H / 2
  local t = (tx - cx) / vx
  if t < 0 then return MID_Y end
  local lo, hi = TOP_Y + BALL_H / 2, BOT_Y - BALL_H / 2
  local span = hi - lo
  local y = cy + vy * t - lo
  local m = y % (2 * span)
  if m > span then m = 2 * span - m end
  return m + lo
end

---------------------------------------------------------------------------
-- Rounds
---------------------------------------------------------------------------
local function reset_ball(dir)
  bx = W / 2 - BALL_W / 2
  by = MID_Y - BALL_H / 2
  serve_dir = dir
  speed = level.start
  vx, vy = 0, 0
  serve_t = 900
  state = "serve"
  cpu_target = MID_Y
  draw_ball(true)
end

-- A fresh aiming mistake for each ball heading towards the CPU.
local function new_cpu_err()
  cpu_err = (math.random() * 2 - 1) * level.err * (speed / level.start)
end

local function launch()
  local angle = (math.random() - 0.5) * 0.9   -- up to ~26 degrees
  vx = serve_dir * speed * math.cos(angle)
  vy = speed * math.sin(angle)
  new_cpu_err()
  state = "play"
end

local function update_scores()
  score_l:text(tostring(score[1]))
  score_r:text(tostring(score[2]))
end

local close_menu   -- defined with the menu, below

local function start_game(i)
  close_menu()
  level_i = i
  level = LEVELS[i]
  score = { 0, 0 }
  update_scores()
  ly = MID_Y - PH / 2
  ry = MID_Y - PH / 2
  draw_paddles()
  set_game_visible(true)
  show_message(nil)
  ui.hint("UP/DOWN move   SELECT pause   CANCEL menu")
  reset_ball(math.random() < 0.5 and -1 or 1)
end

local function point(side)
  score[side] = score[side] + 1
  update_scores()
  if side == 1 then sweep(0x14, 0xF1, 0x95) else sweep(0x99, 0x45, 0xFF) end
  if score[side] >= WIN_SCORE then
    state = "over"
    draw_ball(false)
    if side == 1 then
      wins[level_i] = (wins[level_i] or 0) + 1
      storage.set("wins", wins)
      show_message("YOU WIN!", score[1] .. " - " .. score[2] .. "   SELECT again")
    else
      show_message("CPU WINS", score[1] .. " - " .. score[2] .. "   SELECT again")
    end
    ui.hint("SELECT play again   CANCEL menu")
    return
  end
  -- The player who lost the point receives the next serve.
  reset_ball(side == 1 and 1 or -1)
end

---------------------------------------------------------------------------
-- Menu
---------------------------------------------------------------------------
local function menu_items()
  local items = {}
  for i, l in ipairs(LEVELS) do
    local w = wins[i] or 0
    items[i] = { title = "Play: " .. l.name, right = w > 0 and ("wins " .. w) or nil }
  end
  return items
end

local function open_menu()
  state = "menu"
  set_game_visible(false)
  show_message(nil)
  if has_led then led.off() end
  menu_logo = ui.image(W // 2 - art.LOGO_W // 2, 6, art.logo, PAL)
  menu_title = ui.label(0, 52, "SOLANA PONG", { size = 20, color = 0xFFFFFF, w = W, align = "center" })
  menu = ui.list(40, 84, W - 80, 108, menu_items(), {
    on_select = function(i) start_game(i) end,
  })
  menu:select(level_i)
  ui.hint("SELECT play   CANCEL exit")
end

function close_menu()
  if menu then menu:remove() menu = nil end
  if menu_logo then menu_logo:remove() menu_logo = nil end
  if menu_title then menu_title:remove() menu_title = nil end
end

---------------------------------------------------------------------------
-- Physics
---------------------------------------------------------------------------
-- Bounce off a paddle: the further from the paddle's centre the ball hits,
-- the steeper it leaves. Speeds up a little every hit.
local function bounce(paddle_top, dir)
  local rel = ((by + BALL_H / 2) - (paddle_top + PH / 2)) / (PH / 2 + BALL_H / 2)
  rel = clamp(rel, -1, 1)
  local angle = rel * MAX_BOUNCE
  speed = math.min(speed * SPEEDUP, level.max)
  vx = dir * speed * math.cos(angle)
  vy = speed * math.sin(angle)
  if dir > 0 then flash(0x99, 0x45, 0xFF) else flash(0x14, 0xF1, 0x95) end
  if dir > 0 then new_cpu_err() end
  cpu_think = 0
end

local function step_ball(dt)
  local nx = bx + vx * dt
  local ny = by + vy * dt

  -- Walls.
  if ny < TOP_Y then
    ny = TOP_Y + (TOP_Y - ny)
    vy = -vy
  elseif ny + BALL_H > BOT_Y then
    ny = (BOT_Y - BALL_H) - (ny + BALL_H - BOT_Y)
    vy = -vy
  end

  -- Left paddle: its right face is at LEFT_X + PW.
  local face_l = LEFT_X + PW
  if vx < 0 and bx >= face_l and nx < face_l then
    local t = (bx - face_l) / (bx - nx)
    local hy = by + (ny - by) * t
    if hy + BALL_H > ly and hy < ly + PH then
      bx, by = face_l, hy
      bounce(ly, 1)
      return
    end
  end

  -- Right paddle: its left face is at RIGHT_X.
  if vx > 0 and bx + BALL_W <= RIGHT_X and nx + BALL_W > RIGHT_X then
    local t = (RIGHT_X - (bx + BALL_W)) / (nx - bx)
    local hy = by + (ny - by) * t
    if hy + BALL_H > ry and hy < ry + PH then
      bx, by = RIGHT_X - BALL_W, hy
      bounce(ry, -1)
      return
    end
  end

  bx, by = nx, ny

  if bx + BALL_W < 0 then
    point(2)
  elseif bx > W then
    point(1)
  end
end

local function move_player(dt)
  local k = sys.keys and sys.keys() or {}
  local up = k.up or held_until.up > now
  local down = k.down or held_until.down > now
  if up and not down then
    ly = ly - PLAYER_SPEED * dt
  elseif down and not up then
    ly = ly + PLAYER_SPEED * dt
  end
  ly = clamp(ly, TOP_Y, BOT_Y - PH)
end

local function move_cpu(dt, ms)
  cpu_think = cpu_think - ms
  if cpu_think <= 0 then
    cpu_think = level.think
    if vx <= 0 then
      cpu_target = MID_Y              -- drift back to the middle
    elseif bx > W * level.sees then   -- coming this way and close enough to see
      cpu_target = predict_y(RIGHT_X) + cpu_err
    end
  end
  local centre = ry + PH / 2
  local d = cpu_target - centre
  local maxd = level.cpu * dt
  if d > maxd then d = maxd elseif d < -maxd then d = -maxd end
  ry = clamp(ry + d, TOP_Y, BOT_Y - PH)
end

---------------------------------------------------------------------------
-- Callbacks
---------------------------------------------------------------------------
function on_tick(ms)
  now = now + ms
  if state ~= "serve" and state ~= "play" then return end
  ms = math.min(ms, 60)                -- don't jump after a hiccup
  local dt = ms / 1000

  move_player(dt)
  move_cpu(dt, ms)

  if state == "serve" then
    serve_t = serve_t - ms
    if serve_t <= 0 then launch() end
  else
    -- Small sub-steps so a fast ball can't pass through a paddle.
    local dist = math.max(math.abs(vx), math.abs(vy)) * dt
    local n = math.max(1, math.ceil(dist / 3))
    local sdt = dt / n
    for _ = 1, n do
      if state ~= "play" then break end
      step_ball(sdt)
    end
  end

  -- Spin the coin: faster ball, faster spin.
  spin_t = spin_t + ms * (speed / 150)
  while spin_t >= 70 do
    spin_t = spin_t - 70
    spin = spin % #ball_frames + 1
  end

  draw_paddles()
  if state == "serve" or state == "play" then draw_ball(true) end
end

function on_key(key, rep)
  if state == "menu" then
    return key ~= "back"               -- the list handles up/down/select
  end

  if key == "back" then
    if rep then return true end
    open_menu()
    return true
  end

  if key == "up" or key == "down" then
    held_until[key] = now + 140        -- for badges without sys.keys()
    return true
  end

  if key == "select" then
    if state == "play" or state == "serve" then
      state = (state == "play") and "paused" or "paused_serve"
      show_message("PAUSED", "SELECT to resume")
    elseif state == "paused" or state == "paused_serve" then
      state = (state == "paused") and "play" or "serve"
      show_message(nil)
    elseif state == "over" then
      start_game(level_i)
    end
    return true
  end
  return true
end

function on_exit()
  if has_led then led.off() end
end

---------------------------------------------------------------------------
show_message(nil)
open_menu()
