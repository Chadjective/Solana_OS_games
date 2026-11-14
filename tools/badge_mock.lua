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
  local o = new("image", x, y, { rows = rows, palette = pal })
  function o:set(r) self.rows = r end
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

timer = {}
local tid = 0
function timer.after(ms, fn) tid = tid + 1; M.timers[tid] = { at = M.now + ms, fn = fn }; return tid end
function timer.every(ms, fn) tid = tid + 1; M.timers[tid] = { at = M.now + ms, fn = fn, every = ms }; return tid end
function timer.cancel(id) M.timers[id] = nil end

local store = {}
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
  for id, t in pairs(M.timers) do
    if t.at <= M.now then
      t.fn()
      if t.every then t.at = t.at + t.every else M.timers[id] = nil end
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
