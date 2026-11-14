-- The CPU monkey's thinking, for Solana Monkey Bomb. Two coroutines that
-- main.lua runs a little each tick, so the thinking never runs into the
-- badge's per-callback instruction limit:
--
--   T.scout(): walks an imaginary monkey both ways as far as its energy goes
--              and returns the best spot { x, dir, score } (dir 0: stay put).
--   T.plan():  picks a weapon and finds an angle and power that reach the
--              player, then adds a monkey-sized mistake; returns a, p, w.
--
-- Everything it needs from the game comes in `env` (see main.lua).

local M = {}

function M.new(env)
  local T = {}
  local monkeys, ammo, CPU, WEAPONS = env.monkeys, env.ammo, env.CPU, env.WEAPONS
  local RAIN_GRAV, CW, GROUND_Y, ENERGY = env.RAIN_GRAV, env.CW, env.GROUND_Y, env.ENERGY
  local launch_point, launch_velocity = env.launch_point, env.launch_velocity
  local step_projectile, monkey_at, solid = env.step_projectile, env.monkey_at, env.solid
  local walk_step, supported, drowned = env.walk_step, env.supported, env.drowned
  local clamp, draw_monkey = env.clamp, env.draw_monkey
  local wind, weather, level, items = 0, "clear", 1, {}   -- refreshed when a coroutine starts

  -- Where would a throw land, ignoring buildings (x where it drops to the
  -- target's height)? Coarse steps: this is the CPU "thinking", not the real throw.
  local function landing_x(a, p, wp, target_y)
    local x, y = launch_point(2)
    local vx, vy = launch_velocity(2, a, p, wp)
    local dt = 1 / 40
    for _ = 1, 400 do
      vx = vx + wind * wp.wind * dt
      vy = vy + (wp.grav + (weather == "rain" and RAIN_GRAV or 0)) * dt
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
  function T.plan()
    local w0 = env.now()
    wind, weather, level, items = w0.wind, w0.weather, w0.level, w0.items
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
  function T.scout()
    local w0 = env.now()
    wind, weather, level, items = w0.wind, w0.weather, w0.level, w0.items
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

  return T
end

return M
