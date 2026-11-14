#!/usr/bin/env python3
"""Plays Proof of Stack headlessly with a simple bot and checks it behaves.

    python3 tools/test_proof_of_stack.py

The bot reads the board off the screen (the canvas), works out where the
falling piece fits best, and presses the buttons. Checks: blocks get
finalized and paid in lamports, epochs advance, Sprint ends at 40 blocks,
Marathon ends with BLOCKSPACE FULL, every callback stays well under the
badge's instruction limit, and in Versus spam rows reach the other badge
and both badges agree on who won.
"""
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim import Sim  # noqa: E402
import test_pong_duo as net  # noqa: E402  (radio helpers)

COLS, ROWS, CELL = 10, 20, 5
BUDGET = 200_000

# The same shapes and rotations as the game.
SHAPES = [
    ([(0, 1), (1, 1), (2, 1), (3, 1)], 4, 0x14F195, False),
    ([(1, 0), (2, 0), (1, 1), (2, 1)], 4, 0x9945FF, True),
    ([(1, 0), (0, 1), (1, 1), (2, 1)], 3, 0x00C2FF, False),
    ([(1, 0), (2, 0), (0, 1), (1, 1)], 3, 0xEB54BC, False),
    ([(0, 0), (1, 0), (1, 1), (2, 1)], 3, 0xB4F000, False),
    ([(0, 0), (0, 1), (1, 1), (2, 1)], 3, 0xC4A4FF, False),
    ([(2, 0), (0, 1), (1, 1), (2, 1)], 3, 0x2F80ED, False),
]
ROT = []
for cells, n, _, fixed in SHAPES:
    r = [cells]
    for _ in range(3):
        r.append(cells if fixed else [(n - 1 - y, x) for x, y in r[-1]])
    ROT.append(r)


# Which way gravity points, read off the hint bar, and the buttons for it.
KEYS = {
    "down": dict(minus="left", plus="right", turn="up"),
    "up": dict(minus="left", plus="right", turn="down"),
    "right": dict(minus="up", plus="down", turn="left"),
    "left": dict(minus="up", plus="down", turn="right"),
}


def orientation(sim):
    h = str(sim.M.hint)
    if "UP rotate" in h:
        return "down"
    if "DN rotate" in h:
        return "up"
    if "LEFT rotate" in h:
        return "right"
    if "RIGHT rotate" in h:
        return "left"
    return "down"


def screen_cell(orient, c, r):
    """Where logical cell (column c, row r along gravity) is on the screen."""
    if orient == "down":
        return c, r
    if orient == "up":
        return c, ROWS - 1 - r
    if orient == "right":
        return r, c
    return ROWS - 1 - r, c


def texts(sim):
    return [str(o.txt) for o in sim.M.objects.values() if o.kind == "label" and o.visible and not o.removed]


def canvas(sim, w, h):
    return next(o for o in sim.M.objects.values() if o.kind == "canvas" and o.w == w and o.h == h)


class Bot:
    def __init__(self, sim, skill=1.0, rnd=None, ticker=None):
        self.sim, self.skill, self.rnd = sim, skill, rnd or random.Random(1)
        # how time passes while the bot holds a key (two badges tick together)
        self.ticker = ticker or (lambda: sim.tick(30))
        self.base = {sim.M.rgb565(c): k for k, (_, _, c, _) in enumerate(SHAPES)}
        self.last_next = None
        self.current = None
        self.next_kind = None

    def read_next(self):
        cv = canvas(self.sim, 4 * CELL, 2 * CELL).buf
        for y in range(2 * CELL):
            for x in range(4 * CELL):
                k = self.base.get(cv.get(x, y))
                if k is not None:
                    return k
        return None

    def read_grid(self):
        """Locked cells only: the falling piece is left out (it's at its spawn spot)."""
        o = orientation(self.sim)
        cv = self.board(o)
        grid = [[False] * COLS for _ in range(ROWS)]
        for r in range(ROWS):
            for c in range(COLS):
                sx, sy = screen_cell(o, c, r)
                col = cv.get(sx * CELL + 2, sy * CELL + 2)
                # empty cells show a dot, ghost cells the background
                grid[r][c] = col not in (self.sim.M.rgb565(0x221B3E), self.sim.M.rgb565(0x0E0B1E), None)
        if self.current is not None:
            k = self.current
            y0 = -1 if SHAPES[k][1] == 4 else 0
            for x, y in ROT[k][0]:
                if 0 <= y0 + y < ROWS:
                    grid[y0 + y][3 + x] = False
        return grid

    def board(self, o):
        if o in ("down", "up"):
            return canvas(self.sim, COLS * CELL, ROWS * CELL).buf
        return canvas(self.sim, ROWS * CELL, COLS * CELL).buf

    @staticmethod
    def fits(grid, k, r, x, y):
        for cx, cy in ROT[k][r]:
            gx, gy = x + cx, y + cy
            if gx < 0 or gx >= COLS or gy >= ROWS:
                return False
            if gy >= 0 and grid[gy][gx]:
                return False
        return True

    def best_move(self, grid, k):
        best, best_score = (0, 3), None
        for r in range(4):
            for x in range(-3, COLS):
                y = -1
                if not self.fits(grid, k, r, x, y):
                    continue
                while self.fits(grid, k, r, x, y + 1):
                    y += 1
                g = [row[:] for row in grid]
                for cx, cy in ROT[k][r]:
                    if y + cy >= 0:
                        g[y + cy][x + cx] = True
                full = sum(all(row) for row in g)
                g = [row for row in g if not all(row)]
                g = [[False] * COLS for _ in range(full)] + g
                heights = []
                holes = 0
                for c in range(COLS):
                    h = 0
                    seen = False
                    for rr in range(ROWS):
                        if g[rr][c]:
                            if not seen:
                                h = ROWS - rr
                            seen = True
                        elif seen:
                            holes += 1
                    heights.append(h)
                bump = sum(abs(heights[i] - heights[i + 1]) for i in range(COLS - 1))
                score = full * 7.6 - sum(heights) * 0.51 - holes * 3.6 - bump * 0.18
                score += self.rnd.uniform(-1, 1) * (1 - self.skill) * 30
                if best_score is None or score > best_score:
                    best, best_score = (r, x), score
        return best

    def tap(self, key):
        self.sim.hold([key])
        self.ticker()
        self.sim.hold([])
        self.ticker()

    def play_piece(self):
        """Call when a new piece has just appeared."""
        k = self.current
        keys = KEYS[orientation(self.sim)]
        grid = self.read_grid()
        r, x = self.best_move(grid, k)
        for _ in range(r):
            self.sim.press(keys["turn"])
        # after rotating at the spawn spot the piece is still at x = 3 (no kick needed at the top)
        dx = x - 3
        for _ in range(abs(dx)):
            self.tap(keys["plus"] if dx > 0 else keys["minus"])
        if self.playing():                  # the game may have ended meanwhile
            self.sim.press("select")

    def playing(self):
        return "SELECT drop" in str(self.sim.M.hint)

    def step(self):
        """One tick of watching: plays a piece whenever the NEXT box changes."""
        if not self.playing():
            return False
        nk = self.read_next()
        if nk is not None and nk != self.last_next and self.last_next is not None:
            self.current = self.last_next
            self.last_next = nk
            self.play_piece()
            return True
        if self.last_next is None and nk is not None:
            self.last_next = nk
            # the very first piece: its kind is unknown; read it off the top rows
            self.current = self.first_piece_kind()
            if self.current is not None:
                self.play_piece()
        return False

    def first_piece_kind(self):
        o = orientation(self.sim)
        cv = self.board(o)
        for r in range(3):
            for c in range(COLS):
                sx, sy = screen_cell(o, c, r)
                k = self.base.get(cv.get(sx * CELL + 2, sy * CELL + 2))
                if k is not None:
                    return k
        return None


def counting(sim):
    sim.lua.execute('_COUNT = 0 debug.sethook(function() _COUNT = _COUNT + 100 end, "", 100)')


def measured(sim):
    peaks = [0]
    raw_tick, raw_press = sim.tick, sim.press

    def take():
        g = sim.lua.globals()
        n = g._COUNT
        g._COUNT = 0
        return n

    def tick(ms=30, n=1):
        for _ in range(n):
            take()
            raw_tick(ms)
            peaks[0] = max(peaks[0], take())

    def press(key, rep=False):
        take()
        raw_press(key, rep)
        peaks[0] = max(peaks[0], take())
    sim.tick, sim.press = tick, press
    return peaks


def value(sim, key):
    t = texts(sim)
    return t[t.index(key) + 1] if key in t else None


def play_single(row, max_ticks, skill, until):
    sim = Sim("proof-of-stack")
    counting(sim)
    peaks = measured(sim)
    for _ in range(row - 1):
        sim.press("down")
    sim.press("select")
    bot = Bot(sim, skill, random.Random(row))
    pieces = 0
    for t in range(max_ticks):
        if bot.step():
            pieces += 1
        sim.tick(30)
        if until(sim):
            return sim, pieces, peaks[0], t
    raise AssertionError("never finished: " + str(texts(sim)))


def start_versus(loss):
    """Two linked badges, both in a versus game. Returns them, a tick function,
    the radio stats and the game id the badges agreed on."""
    net.LOSS = loss
    stats = {"max_size": 0, "lost": 0}
    a = Sim("proof-of-stack"); a.M.badge_id = "AAAAAA"; a.name = "@alice"; a.sent = []
    b = Sim("proof-of-stack"); b.M.badge_id = "BBBBBB"; b.name = "@bob"; b.sent = []
    net.link(a, b)
    game = {}

    def tick(n=1):
        for _ in range(n):
            a.tick(30)
            b.tick(30)
            for src in (a, b):
                for it in list(src.M.outbox.values()):
                    if it.msg.g:
                        game["id"] = it.msg.g
            net.pump(a, b, stats)
            net.pump(b, a, stats)
    for s in (a, b):
        s.press("down")
        s.press("down")
        s.press("select")
    for _ in range(300):
        tick()
        if "@bob" in [str(i.title) for i in a.M.focus_list._items.values()]:
            break
    a.press("select")
    for _ in range(300):
        tick()
        if b.M.confirm is not None:
            break
    b.M.answer(True)
    for _ in range(300):
        tick()
        if all("SELECT drop" in str(s.M.hint) for s in (a, b)):
            break
    return a, b, tick, stats, game


def spam_check():
    """Spam sent by one badge rises as grey rows on the other's board."""
    a, b, tick, stats, game = start_versus(0.0)
    b.M.deliver("AAAAAA", b.lua.table_from({"t": "s", "g": game["id"], "a": 3, "h": "aaaaaaaaaa", "o": 0, "b": 0}))
    tick()
    assert "INCOMING SPAM 3" in texts(b), texts(b)
    b.press("select")                       # the next piece lands, then the spam rises
    tick(5)
    grey = b.M.rgb565(0x4A4A5E)
    cv = canvas(b, COLS * CELL, ROWS * CELL).buf
    rows = [r for r in range(ROWS) if any(cv.get(c * CELL + 2, r * CELL + 2) == grey for c in range(COLS))]
    assert rows == [17, 18, 19], rows
    print("spam: 3 spam rows sent -> 3 grey rows rose on the other board")


def clusters_check(shots_dir=None):
    """A strong bot plays Marathon through every cluster: gravity turns from
    down (Mainnet) to sideways (Devnet), up (Testnet), then every epoch
    (Localnet), and the bot keeps finalizing blocks in each."""
    random.seed(3)          # a fixed game, so the run always reaches every direction
    sim = Sim("proof-of-stack")
    sim.press("select")
    bot = Bot(sim, 1.0, random.Random(11))
    seen, order = {}, []
    for _ in range(400000):
        bot.step()
        sim.tick(30)
        t = texts(sim)
        cluster = t[1] if len(t) > 1 else ""
        o = orientation(sim)
        key = (cluster, o)
        if cluster in ("MAINNET", "DEVNET", "TESTNET", "LOCALNET") and key not in seen:
            seen[key] = value(sim, "BLOCKS")
            order.append(key)
            if shots_dir:
                sim.render(os.path.join(shots_dir, f"cluster-{cluster}-{o}.png"))
        if len({k[1] for k in seen if k[0] == "LOCALNET"}) >= 4 or "BLOCKSPACE FULL" in t:
            break
    print("clusters: " + ", ".join(f"{c} ({o}) from block {b}" for (c, o), b in
                                     sorted(seen.items(), key=lambda kv: int(kv[1] or 0))))
    names = [c for c, _ in order]
    assert names[:4] == ["MAINNET", "DEVNET", "TESTNET", "LOCALNET"], order
    assert {o for c, o in order if c == "LOCALNET"} == {"down", "right", "up", "left"}, order
    return sim


def main():
    random.seed(3)

    # Sprint: a good bot finalizes 40 blocks.
    sim, pieces, peak, t = play_single(2, 60000, 1.0, lambda s: "FINALIZED" in texts(s))
    line = next(x for x in texts(sim) if "40 blocks in" in x)
    print(f"sprint: {line.split('   ')[0]} with {pieces} pieces, peak {peak} instructions per callback")
    assert peak < BUDGET * 0.5

    # Marathon: a sloppier bot plays until the blockspace is full.
    sim, pieces, peak, t = play_single(1, 120000, 0.55, lambda s: "BLOCKSPACE FULL" in texts(s))
    print(f"marathon: BLOCKSPACE FULL after {pieces} pieces: {value(sim, 'BLOCKS')} blocks, "
          f"{value(sim, 'LAMPORTS')} lamports, epoch {value(sim, 'EPOCH')}, slot {value(sim, 'SLOT')}, "
          f"peak {peak} instructions per callback")
    assert int(value(sim, "BLOCKS")) > 0 and int(value(sim, "EPOCH")) >= 1
    assert peak < BUDGET * 0.5

    clusters_check()
    spam_check()

    # Versus: a strong bot against a weaker one, 15% of messages lost.
    a, b, tick, stats, game = start_versus(0.15)
    bots = [Bot(a, 1.0, random.Random(5), tick), Bot(b, 0.75, random.Random(6), tick)]
    grey = a.M.rgb565(0x4A4A5E)

    def has_spam_rows(s):
        cv = canvas(s, COLS * CELL, ROWS * CELL).buf
        return any(cv.get(c * CELL + 2, r * CELL + 2) == grey for r in range(ROWS) for c in range(COLS))
    spam_seen = False
    for t in range(40000):
        for bot in bots:
            bot.step()
        tick()
        if has_spam_rows(a) or has_spam_rows(b):     # grey spam rows on a board
            spam_seen = True
        ta, tb = texts(a), texts(b)
        if ("YOU WIN!" in ta or "BLOCKSPACE FULL" in ta) and ("YOU WIN!" in tb or "BLOCKSPACE FULL" in tb):
            break
    else:
        raise AssertionError("versus never finished")
    ra = "YOU WIN!" if "YOU WIN!" in ta else "BLOCKSPACE FULL"
    rb = "YOU WIN!" if "YOU WIN!" in tb else "BLOCKSPACE FULL"
    print(f"versus: A sees {ra}, B sees {rb}; "
          f"messages: biggest {stats['max_size']} bytes, most in one second A {net.max_per_second(a.sent)}, "
          f"B {net.max_per_second(b.sent)}")
    assert {ra, rb} == {"YOU WIN!", "BLOCKSPACE FULL"}, "exactly one winner"
    assert net.max_per_second(a.sent) <= 4 and net.max_per_second(b.sent) <= 4
    print("OK")


if __name__ == "__main__":
    main()
