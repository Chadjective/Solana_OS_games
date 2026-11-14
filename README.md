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

![Solana Pong: menu, a rally, and the win screen](docs/pong-preview.png)

- **The ball** is the Solana mark, spinning like a coin (it spins faster as the ball speeds up).
- **The paddles** are bars of the "S": you play the **bottom bar** (left), and the CPU plays the **top bar** (right).
- **The net** is a column of small copies of the S's **middle bar**.
- Three difficulty levels. First to 7 wins. Wins per level are saved on the badge.
- The badge's LEDs flash purple or green on each hit and sweep across when someone scores.

**Controls:** UP/DOWN moves your paddle. SELECT pauses. CANCEL returns to the
menu, and CANCEL on the menu exits.

### Files

| File | What it is |
|---|---|
| `pong/main.lua` | The game. |
| `pong/art.lua` | The pixel art (ball, paddles, net, title logo). It is generated: don't edit it by hand. |
| `pong/app.json` | The manifest: name, icon, colour, and the `led` permission. |

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
- `python3 tools/sim.py pong <folder>` saves screenshots from a rough stand-in for the badge.

The tools need `pip install lupa pillow`. The stand-in badge only approximates
the real one, so always check in the official emulator too.
