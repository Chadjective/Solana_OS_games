#!/usr/bin/env python3
"""Plays Solana Monkey Bomb headlessly and checks it behaves.

    python3 tools/test_monkey_bomb.py

1. Full matches against the CPU (Easy and Hard), and one pass-the-badge match.
   Checks no Lua errors and every callback stays well under the badge's
   200 000-instruction limit (the CPU's planning is the heavy part).
2. A two-badge match with 20% of radio messages dropped, with every
   weapon in play and the players walking, climbing and jumping. Checks
   both badges build the same skyline, every throw leaves both cities
   pixel-for-pixel identical with the monkeys in the same places, and both
   agree on the rounds and on every player's points.
"""
import json
import os
import random
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim import Sim  # noqa: E402
import test_pong_duo as net  # noqa: E402  (radio helpers)

BUDGET = 200_000


def counting(sim):
    sim.lua.execute('_COUNT = 0 debug.sethook(function() _COUNT = _COUNT + 100 end, "", 100)')


def take_count(sim):
    g = sim.lua.globals()
    n = g._COUNT
    g._COUNT = 0
    return n


def texts(sim):
    return [str(o.txt) for o in sim.M.objects.values() if o.kind == "label" and o.visible and not o.removed]


def hud_aim(sim):
    return next((t for t in texts(sim) if "angle" in t or "aiming" in t or "power" in t), "")


def canvas_pixels(sim):
    c = next(o for o in sim.M.objects.values() if o.kind == "canvas")
    return dict(c.buf.px)


def human_turn(sim, rnd):
    """Walk/climb/jump a bit, then aim with UP/DOWN, maybe switch weapon, then
    hold SELECT to charge and let go."""
    if rnd.random() < 0.7:
        sim.hold([rnd.choice(["left", "right"])])
        sim.tick(30, rnd.randint(5, 40))
        sim.hold([])
        if rnd.random() < 0.4:
            sim.hold(["up"])                # climb the wall in front (or jump)
            sim.press("up")
            sim.tick(30, rnd.randint(5, 50))
            sim.hold([])
        sim.tick(30, 40)                    # land / finish falling
        if not str(sim.M.hint).startswith("L/R walk"):
            return                          # walked into the Thames: the turn is over
    sim.press("select")                     # walking -> aiming
    sim.tick(30, 1)
    angle_steps = rnd.randint(-10, 25)
    for _ in range(abs(angle_steps)):
        sim.press("up" if angle_steps > 0 else "down")
    for _ in range(rnd.choice([0, 0, 1, 2, 3])):
        sim.press("right")
    sim.press("select")
    sim.hold(["select"])
    sim.tick(30, rnd.randint(18, 45))      # 0.5 - 1.35 s of charging
    sim.hold([])


def my_turn(sim, who="YOU:"):
    return str(sim.M.hint).startswith("L/R walk") and any(t.startswith(who + " walk") for t in texts(sim))


def monkey_spots(sim):
    return sorted((int(o.x), int(o.y)) for o in sim.M.objects.values()
                  if o.kind == "image" and o.visible and not o.removed and len(o.rows) == 10)


def play_vs_cpu(level_row, rnd, max_ticks=60000):
    sim = Sim("monkey-bomb")
    counting(sim)
    for _ in range(level_row - 1):
        sim.press("down")
    sim.press("select")
    throws = 0
    # Measure every callback on its own: each tick, and each key press.
    peaks = [take_count(sim)]
    raw_tick, raw_press = sim.tick, sim.press

    def tick(ms=30, n=1):
        for _ in range(n):
            take_count(sim)
            raw_tick(ms)
            peaks[0] = max(peaks[0], take_count(sim))

    def press(key, rep=False):
        take_count(sim)
        raw_press(key, rep)
        peaks[0] = max(peaks[0], take_count(sim))
    sim.tick, sim.press = tick, press
    for _ in range(max_ticks):
        if my_turn(sim):
            human_turn(sim, rnd)
            throws += 1
        sim.tick(30)
        peak = peaks[0]
        t = texts(sim)
        if "YOU WIN!" in t or "CPU WINS" in t:
            result = "YOU WIN!" if "YOU WIN!" in t else "CPU WINS"
            score = next(x for x in t if x.startswith("Rounds"))
            return result, score, throws, peak
    raise AssertionError("match never finished")


def play_hotseat(rnd, max_ticks=80000):
    sim = Sim("monkey-bomb")
    for _ in range(1):
        sim.press("down")                  # menu opens on row 1: go to row 3
    sim.press("down")
    sim.press("select")
    throws = 0
    for _ in range(max_ticks):
        if my_turn(sim, "P1:") or my_turn(sim, "P2:"):
            human_turn(sim, rnd)
            throws += 1
        sim.tick(30)
        t = texts(sim)
        if "P1 WINS!" in t or "P2 WINS!" in t:
            return next(x for x in t if "WINS" in x), throws
    raise AssertionError("hot-seat match never finished")


def play_duo(rnd, loss=0.2, max_ticks=120000):
    net.LOSS = loss
    stats = {"max_size": 0, "lost": 0}
    a = Sim("monkey-bomb"); a.M.badge_id = "AAAAAA"; a.name = "@alice"; a.sent = []
    b = Sim("monkey-bomb"); b.M.badge_id = "BBBBBB"; b.name = "@bob"; b.sent = []
    net.link(a, b)

    def tick(n=1):
        for _ in range(n):
            a.tick(30)
            b.tick(30)
            net.pump(a, b, stats)
            net.pump(b, a, stats)

    for s in (a, b):
        for _ in range(3):
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
    for _ in range(300):                    # until both badges have started (a "go" can be lost)
        tick()
        if all(any("WIND" in t for t in texts(s)) for s in (a, b)):
            break
    assert canvas_pixels(a) == canvas_pixels(b), "both badges must build the same skyline"

    throws, checks = 0, 0
    last, last_change = None, 0
    for tick_no in range(max_ticks):
        now_view = (throws, tuple(texts(a)), tuple(texts(b)))
        if now_view != last:
            last, last_change = now_view, tick_no
        if tick_no - last_change > 3000:      # 90 s with nothing happening
            raise AssertionError(f"stuck: A {texts(a)} {a.M.hint} {monkey_spots(a)} / "
                                 f"B {texts(b)} {b.M.hint} {monkey_spots(b)}")
        for s in (a, b):
            if my_turn(s):
                human_turn(s, rnd)
                throws += 1
        tick()
        # Between throws (both waiting for someone to aim) the cities must match.
        def numbers(sim):                    # rounds and points on the score line
            return [re.findall(r"\d+", t) for t in texts(sim)[:2]]
        if my_turn(a) != my_turn(b) and numbers(a) == numbers(b):
            if any("is aiming" in t for t in texts(a) + texts(b)):
                pa, pb = canvas_pixels(a), canvas_pixels(b)
                assert pa == pb, (f"skylines differ after throw {throws}: A {texts(a)} {a.M.hint} {monkey_spots(a)}"
                                  f" / B {texts(b)} {b.M.hint} {monkey_spots(b)}")
                assert monkey_spots(a) == monkey_spots(b), f"monkeys differ: {monkey_spots(a)} / {monkey_spots(b)}"
                checks += 1
        ta, tb = texts(a), texts(b)
        def won(t):
            return any(x == "YOU WIN!" or x.endswith(" WINS") for x in t)
        done_a, done_b = won(ta), won(tb)
        if done_a and done_b:
            sa = next(x for x in ta if x.startswith("Rounds"))
            sb = next(x for x in tb if x.startswith("Rounds"))
            assert sa == sb, f"rounds or points differ: {sa} / {sb}"
            title = lambda t: next(x for x in t if x == "YOU WIN!" or x.endswith(" WINS"))
            return title(ta), title(tb), sa, throws, checks, stats, a, b
    raise AssertionError("two-badge match never finished")


def timer_check():
    """A player who does nothing for 30 s loses the turn: on one badge, and on
    two badges, where both must agree."""
    # Pass the badge: P1 idles.
    sim = Sim("monkey-bomb")
    sim.press("down")
    sim.press("down")
    sim.press("select")
    sim.tick(30, 5)
    first = "P1:" if any(t.startswith("P1: walk") for t in texts(sim)) else "P2:"
    other = "P2:" if first == "P1:" else "P1:"
    seen_up = False
    lit_seq = []                                    # the LEDs lit, as the clock runs down
    for _ in range(1100):                           # 33 s
        sim.tick(30)
        lit = tuple(i for i in range(1, 9) if sim.M.leds[i] and tuple(sim.M.leds[i].values()) != (0, 0, 0))
        if not lit_seq or lit_seq[-1] != lit:
            lit_seq.append(lit)
        if any("TIME'S UP" in t for t in texts(sim)):
            seen_up = True
        if any(t.startswith(other + " walk") for t in texts(sim)):
            break
    assert seen_up and any(t.startswith(other + " walk") for t in texts(sim)), texts(sim)
    # The last 8 seconds on the LEDs: 8 lit, then 8 and 7 (beside the screen)
    # go out, then the top row from right to left.
    want = [tuple(range(1, n + 1)) for n in range(8, -1, -1)]
    assert lit_seq[-9:] == want, lit_seq

    # Two badges: whoever's turn it is idles; both badges move on together.
    net.LOSS = 0.2
    stats = {"max_size": 0, "lost": 0}
    a = Sim("monkey-bomb", badge_id="AAAAAA", name="@alice"); a.sent = []
    b = Sim("monkey-bomb", badge_id="BBBBBB", name="@bob"); b.sent = []
    net.link(a, b)

    def tick(n=1):
        for _ in range(n):
            a.tick(30)
            b.tick(30)
            net.pump(a, b, stats)
            net.pump(b, a, stats)
    for s_ in (a, b):
        for _ in range(3):
            s_.press("down")
        s_.press("select")
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
        if my_turn(a) or my_turn(b):
            break
    idler, watcher = (a, b) if my_turn(a) else (b, a)
    up_seen = False
    for _ in range(1400):                           # up to 42 s
        tick()
        if any("TIME'S UP" in t for t in texts(watcher)):
            up_seen = True
        if my_turn(watcher):
            break
    assert my_turn(watcher) and not my_turn(idler), (texts(a), texts(b))
    assert up_seen, texts(watcher)
    assert canvas_pixels(a) == canvas_pixels(b) and monkey_spots(a) == monkey_spots(b)
    print("turn timer: the LEDs count down the last 8 s (8 and 7 beside the screen first, then the "
          "top row right to left); an idle player's turn passes after 30 s, on one badge and on two "
          "(both badges agree, with 20% of messages lost)")


def main():
    rnd = random.Random(4)
    random.seed(4)
    for row, name in ((1, "Easy"), (2, "Hard")):
        result, score, throws, peak = play_vs_cpu(row, rnd)
        print(f"vs CPU {name}: {result} ({score}) after {throws} of your throws, "
              f"peak {peak} instructions per callback")
        assert peak < BUDGET * 0.5, "too close to the badge's instruction limit"

    timer_check()
    winner, throws = play_hotseat(rnd)
    print(f"pass the badge: {winner} after {throws} throws")

    wa, wb, score, throws, checks, stats, a, b = play_duo(rnd)
    print(f"two badges: A sees '{wa}', B sees '{wb}', {score}, "
          f"{throws} throws, skylines identical at {checks} checks")
    print(f"messages: biggest {stats['max_size']} bytes, {stats['lost']} dropped on purpose, "
          f"most in one second: A {net.max_per_second(a.sent)}, B {net.max_per_second(b.sent)}")
    assert net.max_per_second(a.sent) <= 4 and net.max_per_second(b.sent) <= 4
    print("OK")


if __name__ == "__main__":
    main()
