-- Solana Pong: Pong for the Solana OS badge.
-- The ball is the Solana mark (spinning like a coin); the paddles are the
-- top and bottom bars of the "S", and the net is made of its middle bar.
--
-- Two ways to play:
--   * against the CPU (Easy / Normal / Hard)
--   * against a friend on another badge nearby, over the badge mesh radio
--
-- Controls: UP/DOWN move your paddle (always the left one). SELECT pauses
-- (CPU games only). CANCEL goes back to the menu, and exits from the menu.
-- First to 7 points wins.
--
-- How the two-badge game stays in sync with only 4 messages a second:
--   * Each badge shows its own player on the left, so the other badge's view
--     is a mirror image (x flipped).
--   * Each badge alone decides hits and misses on its own paddle, using the
--     exact paddle position, so lag never costs anyone a point.
--   * Between hits the ball moves in straight lines and bounces off the walls
--     the same way on both badges, so a badge only has to say "the ball left
--     here, at this speed, this long ago" (a ball "event"). Every message
--     repeats the latest event and the score, so a lost message is repaired
--     by the next one.

local art = require("art")

local W, H = ui.W, ui.H             -- 320 x 218
local PAL = { palette = art.palette }
local WIN_SCORE = 7

local BALL_W, BALL_H = art.BALL_W, art.BALL_H
local PW, PH = art.PADDLE_W, art.PADDLE_H
local HINT_H = 16                   -- the key-hint strip pinned to the bottom
local TOP_Y, BOT_Y = 2, H - HINT_H - 2   -- the playing field, between the two walls
local MID_Y = (TOP_Y + BOT_Y) / 2
local LEFT_X = 8                    -- left paddle's x (its left edge)
local RIGHT_X = W - 8 - PW          -- right paddle's x
local CENTRE_X = W / 2 - BALL_W / 2 -- ball's x when it is served

local LEVELS = {
  -- cpu: paddle speed (px/s); err: aiming error (px, grows with ball speed);
  -- think: ms between decisions; sees: how far across (0..1) the ball must be
  -- before the CPU starts tracking it; start/max: ball speed (px/s).
  { name = "Easy",   cpu = 90,  err = 30, think = 260, sees = 0.60, start = 115, max = 230 },
  { name = "Normal", cpu = 125, err = 22, think = 180, sees = 0.45, start = 130, max = 280 },
  { name = "Hard",   cpu = 170, err = 14, think = 110, sees = 0.30, start = 150, max = 330 },
}
local DUO = { name = "2 badges", start = 130, max = 300 }   -- ball speeds, two-badge games
local PLAYER_SPEED = 210            -- px per second
local SPEEDUP = 1.06                -- ball speed multiplier per paddle hit
local MAX_BOUNCE = 1.0              -- radians (~57 degrees) at the paddle's tip
local SERVE_WAIT = 900              -- ms the ball waits before a serve
local FIRST_SERVE_WAIT = 1800

-- Mesh radio (two-badge games). The badge allows 4 messages a second.
local SEND_GAP = 260                -- ms at least between two messages (< 4 a second)
local SEND_EVERY = 400              -- ms between routine updates
local LOST_AFTER = 5000             -- ms of silence before the other badge counts as gone
local HOLD_MAX = 220                -- ms the ball waits at the other paddle for its verdict

local has_led = led ~= nil
local has_mesh = mesh ~= nil

---------------------------------------------------------------------------
-- Game objects (built once, drawn in the order they are made)
---------------------------------------------------------------------------
ui.bg(0x0B0B14)

local score_l = ui.label(W // 2 - 70, 8, "0", { size = 32, color = "border", w = 40, align = "center" })
local score_r = ui.label(W // 2 + 30, 8, "0", { size = 32, color = "border", w = 40, align = "center" })
local name_l = ui.label(W // 2 - 110, 46, "", { size = 12, color = "dim", w = 100, align = "right" })
local name_r = ui.label(W // 2 + 10, 46, "", { size = 12, color = "dim", w = 100, align = "left" })
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

local panel = ui.rect(50, 64, W - 100, 74, { color = "panel", radius = 8, border = "border" })
local msg = ui.label(50, 76, "", { size = 20, color = 0xFFFFFF, w = W - 100, align = "center" })
local sub = ui.label(50, 108, "", { size = 14, color = "dim", w = W - 100, align = "center" })

local game_objects = { score_l, score_r, name_l, name_r, net, wall_t, wall_b, pad_l, pad_r }

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local state = "menu"     -- menu | lobby | play | paused | over
local mode = "cpu"       -- cpu | duo (two badges)
local level = LEVELS[2]
local level_i = 2
local menu_i = 2         -- which menu row to highlight
local score = { 0, 0 }   -- { left (you), right (CPU or the other badge) }
local ly, ry = 0, 0      -- paddle tops
local bx, by, vx, vy = 0, 0, 0, 0
local speed = 0
local serve_t = 0        -- ms the ball still waits before it moves
local spin, spin_t = 1, 0
local shown_frame = nil
local held_until = { up = 0, down = 0 }   -- fallback for badges without sys.keys
local now = 0

-- CPU
local cpu_target = MID_Y
local cpu_think = 0
local cpu_err = 0        -- how far off the CPU aims this time (px)

-- Two badges
local peer = nil         -- the other badge's id
local peer_name = ""
local game_id = 0        -- both badges' messages carry it, so old games can't interfere
local ev = { seq = 0, x = 0, y = 0, u = 0, v = 0, w = 0, at = 0 }   -- latest ball event (my view)
local remote_target = MID_Y - PH / 2
local hold_t = 0         -- ms the ball has waited at the other paddle
local last_send, last_heard = -100000, 0
local dirty = false      -- something changed: tell the other badge soon
local over_reason = nil

-- Menus
local menu, menu_logo, menu_title = nil, nil, nil
local lobby                -- the two-badge lobby (lobby.lua), made with the menus

local wins = storage.get("wins") or { 0, 0, 0 }
local duo_wins = storage.get("duo_wins") or 0

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi end
  return v
end

local function round(v) return math.floor(v + 0.5) end

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
    frame:pos(round(bx), round(by))
    if shown_frame ~= frame then frame:show(true) end
    shown_frame = frame
  else
    frame:show(false)
    shown_frame = nil
  end
end

local function draw_paddles()
  pad_l:pos(LEFT_X, round(ly))
  pad_r:pos(RIGHT_X, round(ry))
end

local function set_game_visible(on)
  for _, o in ipairs(game_objects) do o:show(on) end
  if not on then draw_ball(false) end
end

local function update_scores()
  score_l:text(tostring(score[1]))
  score_r:text(tostring(score[2]))
end

-- The radio (at most 4 messages a second) and badge names: lobby.lua,
-- shared by all the games.
local Lobby = require("lobby")
local radio_send, name_of = Lobby.send, Lobby.name_of

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
-- Two badges: messages
---------------------------------------------------------------------------
-- The ball's state right now becomes the shared "event" the other badge
-- follows. Rounded, so both badges start from exactly the same numbers.
local function new_event()
  bx, by, vx, vy = round(bx), round(by), round(vx), round(vy)
  ev.seq = ev.seq + 1
  ev.x, ev.y, ev.u, ev.v, ev.w, ev.at = bx, by, vx, vy, round(serve_t), now
  dirty = true
end

local function send_state()
  -- t: kind, g: game, q: event number, x/y/u/v/w: ball (sender's view),
  -- a: event age (ms), p: sender's paddle, m/o: sender's / other's score.
  if not radio_send(peer, {
    t = "s", g = game_id, q = ev.seq,
    x = ev.x, y = ev.y, u = ev.u, v = ev.v, w = ev.w, a = now - ev.at,
    p = round(ly), m = score[1], o = score[2],
  }) then return end
  last_send = now
  dirty = false
end

-- Is the ball about to reach my paddle? Then keep the radio free, so the
-- news of my hit (or miss) can go out the moment it happens.
local function hit_soon()
  if state ~= "play" or vx >= 0 or serve_t > 0 then return false end
  local gap = bx - (LEFT_X + PW)
  return gap >= 0 and gap / -vx < 0.3
end

local function net_tick()
  if not peer then return end
  if now - last_send < SEND_GAP then return end
  if dirty or (now - last_send >= SEND_EVERY and not hit_soon()) then
    send_state()
  end
end

---------------------------------------------------------------------------
-- Rounds
---------------------------------------------------------------------------
local function serve(dir, wait)
  bx, by = CENTRE_X, MID_Y - BALL_H / 2
  local angle = (math.random() - 0.5) * 0.9   -- up to ~26 degrees
  vx = dir * speed * math.cos(angle)
  vy = speed * math.sin(angle)
  serve_t = wait
  hold_t = 0
end

local function new_cpu_err()
  cpu_err = (math.random() * 2 - 1) * level.err * (speed / level.start)
end

local function finish(text, detail)
  state = "over"
  draw_ball(false)
  show_message(text, detail)
  ui.hint("SELECT play again   CANCEL menu")
end

local function check_winner()
  if score[1] < WIN_SCORE and score[2] < WIN_SCORE then return false end
  local line = score[1] .. " - " .. score[2]
  if score[1] >= WIN_SCORE then
    sweep(0x14, 0xF1, 0x95)
    if mode == "duo" then
      duo_wins = duo_wins + 1
      storage.set("duo_wins", duo_wins)
    else
      wins[level_i] = (wins[level_i] or 0) + 1
      storage.set("wins", wins)
    end
    finish("YOU WIN!", line)
  else
    sweep(0x99, 0x45, 0xFF)
    finish(mode == "duo" and (peer_name .. " WINS") or "CPU WINS", line)
  end
  return true
end

-- side 1 = you scored, side 2 = the other side scored.
local function point(side)
  score[side] = score[side] + 1
  update_scores()
  if check_winner() then
    if mode == "duo" then dirty = true end
    return
  end
  if side == 1 then sweep(0x14, 0xF1, 0x95) else sweep(0x99, 0x45, 0xFF) end
  speed = level.start
  -- The player who lost the point receives the next serve.
  serve(side == 1 and 1 or -1, SERVE_WAIT)
  if mode == "duo" then
    new_event()
  else
    new_cpu_err()
  end
end

local close_menu, close_lobby   -- defined with the menus, below

local function start_match()
  score = { 0, 0 }
  update_scores()
  ly = MID_Y - PH / 2
  ry = MID_Y - PH / 2
  remote_target = ry
  draw_paddles()
  set_game_visible(true)
  show_message(nil)
  speed = level.start
  state = "play"
  if mode == "duo" then
    name_l:text("YOU")
    name_r:text(peer_name)
    ui.hint("UP/DOWN move   CANCEL quit")
  else
    name_l:text("")
    name_r:text("")
    ui.hint("UP/DOWN move   SELECT pause   CANCEL menu")
  end
end

local function start_cpu_game(i)
  close_menu()
  mode = "cpu"
  level_i, menu_i = i, i
  level = LEVELS[i]
  start_match()
  serve(math.random() < 0.5 and -1 or 1, SERVE_WAIT)
  new_cpu_err()
end

-- host: true for the badge that sent the invite. The first ball heads
-- towards the host, from the middle, at an angle both badges derive from g.
local function start_duo_game(id, g, host)
  close_lobby()
  mode = "duo"
  level = DUO
  peer, peer_name, game_id = id, name_of(id), g
  start_match()
  local angle = ((g % 41) - 20) / 50
  bx, by = CENTRE_X, MID_Y - BALL_H / 2
  vx = (host and -1 or 1) * speed * math.cos(angle)
  vy = speed * math.sin(angle)
  serve_t = FIRST_SERVE_WAIT
  hold_t = 0
  ev.seq = 0
  new_event()
  ev.seq = 0               -- the first serve is event 0 on both badges
  last_heard = now
  over_reason = nil
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
  if mode == "duo" then
    new_event()
  elseif dir > 0 then
    new_cpu_err()
    cpu_think = 0
  end
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

  -- My paddle (left): its right face is at LEFT_X + PW.
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

  -- The other paddle (right): its left face is at RIGHT_X.
  if vx > 0 and bx + BALL_W <= RIGHT_X and nx + BALL_W > RIGHT_X then
    if mode == "cpu" then
      local t = (RIGHT_X - (bx + BALL_W)) / (nx - bx)
      local hy = by + (ny - by) * t
      if hy + BALL_H > ry and hy < ry + PH then
        bx, by = RIGHT_X - BALL_W, hy
        bounce(ry, -1)
        return
      end
    elseif hold_t < HOLD_MAX then
      -- The other badge decides this one: wait a moment at its paddle for
      -- its message instead of flying past and jumping back.
      hold_t = hold_t + dt * 1000
      return
    end
  end

  bx, by = nx, ny

  if bx + BALL_W < 0 then
    point(2)                 -- I missed: decided here, on both kinds of game
  elseif bx > W and mode == "cpu" then
    point(1)                 -- in a two-badge game the other badge says so
  end
end

-- Move the ball for ms milliseconds (in small steps, so a fast ball can't
-- pass through a paddle). Also used to catch up with a message's age.
local function advance(ms)
  if serve_t > 0 then
    local d = math.min(serve_t, ms)
    serve_t = serve_t - d
    ms = ms - d
  end
  if ms <= 0 then return end
  local dt = ms / 1000
  local dist = math.max(math.abs(vx), math.abs(vy)) * dt
  local n = math.max(1, math.ceil(dist / 3))
  local sdt = dt / n
  local start_seq = ev.seq
  for _ = 1, math.min(n, 400) do
    if state ~= "play" or ev.seq ~= start_seq then break end
    step_ball(sdt)
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
  local d = cpu_target - (ry + PH / 2)
  local maxd = level.cpu * dt
  ry = clamp(ry + clamp(d, -maxd, maxd), TOP_Y, BOT_Y - PH)
end

-- The other badge's paddle glides towards where it last said it was.
local function move_remote(dt)
  local maxd = 500 * dt
  ry = ry + clamp(remote_target - ry, -maxd, maxd)
end

---------------------------------------------------------------------------
-- Nearby leaderboard (scores.lua, shared by all the games)
---------------------------------------------------------------------------
local board = require("scores").new({
  game = "Solana Pong", send = radio_send, name_of = name_of,
  categories = { { label = "WINS VS CPU" }, { label = "2-BADGE WINS" } },
  mine = function() return { (wins[1] or 0) + (wins[2] or 0) + (wins[3] or 0), duo_wins } end,
})

---------------------------------------------------------------------------
-- Menu
---------------------------------------------------------------------------
local function menu_items()
  local items = {}
  for i, l in ipairs(LEVELS) do
    local w = wins[i] or 0
    items[i] = { title = "1 player: " .. l.name, right = w > 0 and ("wins " .. w) or nil }
  end
  items[#items + 1] = { title = "2 players: 2 badges", right = duo_wins > 0 and ("wins " .. duo_wins) or nil }
  items[#items + 1] = { title = "Nearby leaderboard" }
  return items
end

local open_lobby

local function open_menu()
  state = "menu"
  peer = nil
  set_game_visible(false)
  show_message(nil)
  if has_led then led.off() end
  menu_logo = ui.image(54, 5, art.logo, PAL)
  menu_title = ui.label(118, 16, "SOLANA PONG", { size = 20, color = 0xFFFFFF })
  menu = ui.list(40, 56, W - 80, 144, menu_items(), {     -- 4 rows of 36 px
    on_select = function(i)
      menu_i = i
      if i <= #LEVELS then
        start_cpu_game(i)
      elseif i == #LEVELS + 2 then
        close_menu()
        state = "board"
        board:open(function() open_menu() end)
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
  if menu_logo then menu_logo:remove() menu_logo = nil end
  if menu_title then menu_title:remove() menu_title = nil end
end

---------------------------------------------------------------------------
-- Lobby: find another badge running Solana Pong and invite it (lobby.lua)
---------------------------------------------------------------------------
function open_lobby()
  state = "lobby"
  lobby:open()
end

function close_lobby()
  lobby:close()
end

-- Real-time Pong is too slow through a server bridge, so the lobby marks
-- those players.
lobby = Lobby.new({ title = "2 PLAYERS", game = "Solana Pong", far = "far: laggy", on_start = start_duo_game })

---------------------------------------------------------------------------
-- Two badges: receiving
---------------------------------------------------------------------------
local function on_state(from, m)
  last_heard = now
  remote_target = clamp(m.p or remote_target, TOP_Y, BOT_Y - PH)

  -- Scores only ever go up within a game: take the higher of each.
  local changed = false
  if (m.o or 0) > score[1] then score[1] = m.o changed = true end
  if (m.m or 0) > score[2] then score[2] = m.m changed = true end
  if changed then
    update_scores()
    if state == "play" and check_winner() then return end
  end

  -- A newer ball event: take it (mirrored, as they see it the other way
  -- round), then move it on by how long ago it happened.
  if state == "play" and m.q and m.q > ev.seq then
    if changed then sweep(0x14, 0xF1, 0x95) end
    if m.q > 0 and not changed then flash(0x14, 0xF1, 0x95) end
    bx, by = W - m.x - BALL_W, m.y
    vx, vy = -m.u, m.v
    serve_t = m.w or 0
    speed = math.sqrt(vx * vx + vy * vy)
    hold_t = 0
    ev.seq, ev.x, ev.y, ev.u, ev.v, ev.w = m.q, bx, by, vx, vy, serve_t
    ev.at = now - (m.a or 0)
    advance(m.a or 0)
  end
end

function on_mesh(from, m)
  if type(m) ~= "table" then return end
  if lobby:handle(from, m) then return end      -- hello, invites, and the game starting
  if board:handle(from, m) then return end      -- nearby leaderboard scores
  if m.t == "s" then
    if mode == "duo" and from == peer and m.g == game_id and (state == "play" or state == "over") then
      on_state(from, m)
    end
  elseif m.t == "bye" then
    if mode == "duo" and from == peer and m.g == game_id and state == "play" then
      peer = nil
      finish("PLAYER LEFT", peer_name .. " quit the game")
    end
  end
end

---------------------------------------------------------------------------
-- Callbacks
---------------------------------------------------------------------------
function on_tick(ms)
  now = now + ms
  -- Announce our bests for nearby leaderboards, except during a 2-badge game.
  board:tick(ms, mode == "duo" and peer ~= nil and state == "play")
  if mode == "duo" and (state == "play" or state == "over") then
    net_tick()
    if state == "play" and now - last_heard > LOST_AFTER then
      peer = nil
      finish("CONNECTION LOST", "Can't hear " .. peer_name)
    end
  end
  if state ~= "play" then return end
  ms = math.min(ms, 60)                -- don't jump after a hiccup
  local dt = ms / 1000

  move_player(dt)
  if mode == "cpu" then move_cpu(dt, ms) else move_remote(dt) end
  advance(ms)

  -- Spin the coin: faster ball, faster spin.
  spin_t = spin_t + ms * (speed / 150)
  while spin_t >= 70 do
    spin_t = spin_t - 70
    spin = spin % #ball_frames + 1
  end

  draw_paddles()
  if state == "play" then draw_ball(true) end
end

local function leave_duo()
  if peer then
    -- Say goodbye three times: a lost "bye" would leave the other player
    -- waiting for the connection to time out.
    local to, bye = peer, { t = "bye", g = game_id }
    radio_send(to, bye)
    timer.after(300, function() radio_send(to, bye) end)
    timer.after(700, function() radio_send(to, bye) end)
    peer = nil
  end
end

function on_key(key, rep)
  if state == "board" then return board:key(key, rep) end
  if state == "menu" then
    return key ~= "back"               -- the list handles up/down/select
  end

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
    open_menu()
    return true
  end

  if key == "up" or key == "down" then
    held_until[key] = now + 140        -- for badges without sys.keys()
    return true
  end

  if key == "select" then
    if state == "over" then
      if mode == "duo" then
        leave_duo()
        set_game_visible(false)
        show_message(nil)
        open_lobby()
      else
        start_cpu_game(level_i)
      end
    elseif mode == "cpu" and state == "play" then
      state = "paused"
      show_message("PAUSED", "SELECT to resume")
    elseif state == "paused" then
      state = "play"
      show_message(nil)
    end
  end
  return true
end

function on_exit()
  if mode == "duo" and peer then leave_duo() end
  if has_led then led.off() end
end

---------------------------------------------------------------------------
show_message(nil)
open_menu()
