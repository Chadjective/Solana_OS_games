# Solana OS games

Games for the **Solana OS** badge (the Breakpoint 2026 conference badge: a
320 × 240 screen, a d-pad with SELECT and CANCEL, and 8 LEDs). Badge apps are
small **Lua** programs. Each game is a folder you upload at the badge site's
`/apps/submit` page. The format is documented in
[LUA_API.md](https://github.com/solana-foundation/solana-os/blob/main/docs/LUA_API.md).

| Game | Folder | Status |
|---|---|---|
| Solana Pong | [`pong/`](pong/) | Playable (tested in the local simulator) |
| Game 2 | — | Not started |

## Solana Pong

![Solana Pong: menu, two-player lobby, a two-badge match, and the win screen](docs/pong-preview.png)

- **The ball** is the Solana mark, spinning like a coin (it spins faster as the ball speeds up).
- **The paddles** are bars of the "S": you play the **bottom bar** (left), and the CPU plays the **top bar** (right).
- **The net** is a column of small copies of the S's **middle bar**.
- **1 player:** play the CPU on Easy, Normal or Hard.
- **2 players:** play a friend on **another badge nearby**, over the badges'
  built-in radio (the "mesh"). Both pick *2 players: 2 badges*, one invites the
  other from the list, and the other accepts. Each player sees themselves on
  the left.
- First to 7 wins. Wins are saved on the badge.
- The badge's LEDs flash purple or green on each hit and sweep across when someone scores.

**Controls:** UP/DOWN moves your paddle. SELECT pauses (vs. CPU only). CANCEL
returns to the menu, and CANCEL on the menu exits.

### How the two-badge mode stays in sync

The radio allows only 4 short messages a second, which is too few to stream
the ball's position. So:

- **Each badge decides hits and misses on its own paddle**, using its exact
  paddle position. Lag can never cost a player a point.
- **The ball's flight is predictable.** It moves in straight lines and bounces
  off the walls the same way on both badges. So when someone hits the ball,
  their badge sends one message: where the ball left from, at what speed, and
  how long ago. The other badge works out the rest.
- **Every message repeats the latest ball state and the score.** A lost
  message is repaired by the next one.
- Badges far apart can also connect through a server "bridge", but that adds
  1–3 seconds of delay, which is too slow for Pong. The lobby marks those
  players as "far: laggy".

To test it without two badges, open the badge site's `/emulator` and
`/emulator?badge=2` in two tabs of the same browser, side by side, and run the
game in both.

### Files

| File | What it is |
|---|---|
| `pong/main.lua` | The game. |
| `pong/art.lua` | The pixel art (ball, paddles, net, title logo). It is generated: don't edit it by hand. |
| `pong/app.json` | The manifest: name, icon, colour, and permissions (`led` for the lights, `mesh` for two-badge games). |

Everything in `pong/` ships to the badge, so keep only game files there.

### Try it on a real badge or the emulator

1. Open the badge site's `/apps/submit` page and drop in the `pong/` folder.
2. Click **Try in emulator** to play it in the browser, or **Run on badge** to
   copy it to a badge over USB (desktop Chrome or Edge).
3. **Publish** when you're happy. Publishing needs an account with X linked.

### Developer tools (`tools/`)

These run on a computer, not on the badge.

- `python3 tools/gen_art.py` rebuilds `pong/art.lua` from the official Solana logo shape.
- `python3 tools/test_pong.py` plays three full matches automatically. It checks
  for errors, pause, menu and exit, and that the game stays far below the
  badge's per-step CPU limit.
- `python3 tools/test_pong_duo.py` plays a two-badge match between two
  simulated badges, with 15% of messages dropped on purpose. It checks that
  both agree on the score, the screens stay in sync, and no badge goes over 4
  messages a second.
- `python3 tools/sim.py pong <folder>` saves screenshots from a rough stand-in for the badge.

The tools need `pip install lupa pillow`. The stand-in badge only approximates
the real one, so always check in the official emulator too.
