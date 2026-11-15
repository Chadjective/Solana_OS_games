-- A stand-in for the Solana OS badge API, just enough to run and screenshot
-- the games on a computer (tools/sim.py). Not the real emulator: use
-- "Try in emulator" on the badge site for the real thing.

local M = { objects = {}, hint = "", keys = {}, timers = {}, now = 0, leds = {}, toasts = {} }
local next_id = 0

local function new(kind, x, y, props)
  next_id = next_id + 1
  local o = props or {}
  o.kind, o.x, o.y, o.visible, o.id = kind, x, y, true, next_id
  function o:pos(nx, ny) self.x, self.y = nx, ny end
  function o:show(b) self.visible = b ~= false end
  function o:remove() self.removed = true end
  function o:color(c) self.col = c end
  M.objects[#M.objects + 1] = o
  return o
end

ui = { W = 320, H = 218 }
function ui.bg(c) M.bg = c end
function ui.label(x, y, text, opts)
  local o = new("label", x, y, { txt = text, opts = opts or {} })
  o.col = o.opts.color or "text"
  function o:text(t) self.txt = t end
  return o
end
function ui.rect(x, y, w, h, opts)
  local o = new("rect", x, y, { w = w, h = h, opts = opts or {} })
  o.col = o.opts.color or "panel"
  function o:size(nw, nh) self.w, self.h = nw, nh end
  return o
end
function ui.bar(x, y, w, h, value)
  local o = new("bar", x, y, { w = w, h = h, value = value or 0 })
  function o:set(v) self.value = v end
  return o
end
function ui.gradient(x, y, w, h) return new("gradient", x, y, { w = w, h = h }) end
function ui.image(x, y, rows, opts)
  assert(type(rows) == "table", "mock supports row images only")
  local pal = opts and opts.palette or {}
  for _, r in ipairs(rows) do
    for ch in r:gmatch(".") do
      if ch ~= "." and ch ~= " " and pal[ch] == nil and not ("#kwpgmvblyoa"):find(ch, 1, true) then
        error("ui.image: character '" .. ch .. "' not in palette")
      end
    end
  end
  local o = new("image", x, y, { rows = rows, palette = pal, _scale = opts and opts.scale or 1 })
  function o:scale(n) self._scale = n end
  function o:set(r) self.rows = r end
  return o
end
local THEME = { text = 0xFFFFFF, dim = 0x8A8AA0, bg = 0x0B0B14, panel = 0x1C1C2B, border = 0x3A3A55,
  purple = 0x9945FF, green = 0x14F195, pink = 0xEB54BC, lpurple = 0xC4A4FF, blue = 0x2F80ED,
  aqua = 0x00C2FF, lime = 0xB4F000, yellow = 0xFFD84D, orange = 0xFF754A }
local function rgb565(c)
  if type(c) == "string" then c = THEME[c] end
  local r, g, b = (c >> 19) & 31, (c >> 10) & 63, (c >> 3) & 31
  return ((r << 3 | r >> 2) << 16) | ((g << 2 | g >> 4) << 8) | (b << 3 | b >> 2)
end
M.rgb565 = rgb565

-- Canvas: the pixels live on the Python side (M.make_canvas), so drawing
-- doesn't count towards the instruction budget, as on the badge where it
-- costs about 1 instruction per 16 pixels.
function ui.canvas(x, y, w, h, opts)
  local o = new("canvas", x, y, { w = w, h = h, scale = opts and opts.scale or 1 })
  local buf = M.make_canvas(w, h)
  o.buf = buf
  local function col(c) if c == nil then return nil end return rgb565(c) end
  function o:clear(c) buf.clear(col(c)) end
  function o:pixel(px, py, c) buf.rect(px, py, 1, 1, col(c)) end
  function o:rect(rx, ry, rw, rh, c) buf.rect(rx, ry, rw, rh, col(c)) end
  function o:line(x1, y1, x2, y2, c) buf.line(x1, y1, x2, y2, col(c)) end
  function o:get(px, py) return buf.get(px, py) end
  return o
end

function ui.list(x, y, w, h, items, opts)
  local o = new("list", x, y, { w = w, h = h, _items = items, opts = opts or {}, sel = 1 })
  function o:items(i) self._items = i end
  function o:selected() return self.sel end
  function o:select(i) self.sel = i end
  M.focus_list = o
  return o
end
function ui.hint(t) M.hint = t end
function ui.confirm(text, cb) M.confirm = { text = text, cb = cb } end
function ui.toast(t) M.toasts[#M.toasts + 1] = t end
function ui.clear() M.objects = {} end

led = { count = 8 }
function led.set(i, r, g, b) M.leds[i] = { r, g, b } end
function led.hex(i, c) M.leds[i] = { c >> 16, (c >> 8) & 255, c & 255 } end
function led.fill(r, g, b) for i = 1, 8 do M.leds[i] = { r, g, b } end end
function led.off() M.leds = {} end

-- !LAMPs: the server pays up to the app's daily cap (M.lamps.cap) and
-- answers on a later tick, as the real one does over the network.
M.lamps = { cap = 69, paid = 0, calls = {}, needsX = false, waiting = {} }
lamps = {}
function lamps.award(amount, reason, cb)
  local L = M.lamps
  L.calls[#L.calls + 1] = { amount = amount, reason = reason }
  local give = 0
  if not L.needsX then give = math.max(0, math.min(amount, L.cap - L.paid)) end
  L.paid = L.paid + give
  L.waiting[#L.waiting + 1] = function()
    cb(true, { awarded = give, balance = 1000 + L.paid, needsX = L.needsX or nil })
  end
end

timer = {}
local tid = 0
-- The badge allows 8 timers at a time and stops the app on a 9th.
local function room()
  local n = 0
  for _ in pairs(M.timers) do n = n + 1 end
  if n >= 8 then error("too many timers (8)", 3) end
end
function timer.after(ms, fn) room(); tid = tid + 1; M.timers[tid] = { at = M.now + ms, fn = fn }; return tid end
function timer.every(ms, fn) room(); tid = tid + 1; M.timers[tid] = { at = M.now + ms, fn = fn, every = ms }; return tid end
function timer.cancel(id) M.timers[id] = nil end

M.store = {}                 -- the app's storage (a test can fill it before the app starts)
local store = M.store
storage = {}
function storage.get(k) return store[k] end
function storage.set(k, v) store[k] = v end
function storage.remove(k) store[k] = nil end

-- Mesh: messages go to M.outbox; the driver (tools/sim.py) delivers them.
M.outbox, M.peers, M.badge_id = {}, {}, "AAAAAA"
mesh = {}
function mesh.send(to, msg) M.outbox[#M.outbox + 1] = { to = to, msg = msg, at = M.now } end
function mesh.nearby() return M.peers end
badge = {}
function badge.id() return M.badge_id end
function badge.owner() return nil end

sys = {}
function sys.millis() return M.now end
function sys.keys() return M.keys end
function sys.exit() M.exited = true end

function require(name)
  local path = M.root .. "/" .. name:gsub("%.", "/") .. ".lua"
  M.loaded = M.loaded or {}
  if M.loaded[name] == nil then
    local f = assert(loadfile(path))
    M.loaded[name] = f() or true
  end
  return M.loaded[name]
end

-- Driver helpers ------------------------------------------------------------
function M.answer(yes)
  local c = M.confirm
  M.confirm = nil
  if c then c.cb(yes) end
end

function M.deliver(from, msg)
  if on_mesh then on_mesh(from, msg) end
end

function M.press(key, rep)
  local l = M.focus_list
  if l and not l.removed and l.visible then
    if key == "up" then l.sel = math.max(1, l.sel - 1) return end
    if key == "down" then l.sel = math.min(#l._items, l.sel + 1) return end
    if key == "select" then
      if l.opts.on_select then l.opts.on_select(l.sel, l._items[l.sel]) end
      return
    end
  end
  local handled = on_key and on_key(key, rep or false)
  if key == "back" and not handled then M.exited = true end
end

function M.tick(ms)
  M.now = M.now + ms
  local answers = M.lamps.waiting
  M.lamps.waiting = {}
  for _, f in ipairs(answers) do f() end
  for id, t in pairs(M.timers) do
    if t.at <= M.now then
      -- A one-shot timer is spent (and frees its place) as it fires.
      if t.every then t.at = t.at + t.every else M.timers[id] = nil end
      t.fn()
    end
  end
  if on_tick then on_tick(ms) end
end

function M.run(root)
  M.root = root
  local f = assert(loadfile(root .. "/main.lua"))
  f()
end

return M
