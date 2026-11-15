# Changelog

What changed in each game, newest first. The version is the `version` in each
game's `app.json`: the badge App Store offers a new version as an update, and
downloads only the files that changed.

Versions: **1.1.0** = a new feature, **1.0.1** = a fix only.

---

## Solana Pong

### 1.1.0 (ready to upload)
- **Nearby leaderboard:** a new menu entry with the best scores of the
  badges around you (wins vs CPU, 2-badge wins). Scores are announced over
  the radio while the game is open, paused during 2-badge games.
- **Quitting a 2-badge game:** the "player left" message is now sent three
  times, so the other player finds out straight away even if one copy is
  lost (before, a lost message meant waiting for the 5-second timeout).
- **How to play:** a new menu entry with pages on the goal, the buttons
  and the 2-badge mode.
- Behind the scenes: the lobby now uses the shared `lobby.lua` (it still
  marks players connected through a server bridge as "far: laggy").
- New files: `scores.lua`, `lobby.lua`, `help.lua` (shared by all the
  games) and `howto.lua` (the How to play text).

### 1.0.0 (first upload)
- Pong with the Solana mark as the ball and the bars of the "S" as the
  paddles and the net.
- 1 player vs CPU (Easy / Normal / Hard), 2 players on two badges over the
  radio, first to 7, LED flashes, saved wins.

---

## Solana Monkey Bomb

### 1.1.0 (ready to upload)
- **Nearby leaderboard:** best match points and matches won, from the
  badges around you.
- **Climbing:** hold UP facing a wall to climb it, DOWN to climb back down.
  Climbing costs the same energy as walking, there's more energy per turn
  (100), and a monkey left hanging on a wall carries on next turn.
- **Readable menu:** a solid panel behind the menu (the skyline made the
  lower options hard to read on the badge).
- **Brighter crates**, and the **northern lights** weather removed.
- **New store tagline:** "Mind the gap. Mind the banana bombs. Mind your monkey."
- **Faster start of each round** (the London Eye and office windows draw
  more cheaply).
- **Quitting a 2-badge game:** the goodbye is sent three times.
- **Turn clock:** each turn lasts at most 30 seconds (counted down top
  right). When it runs out, a throw being charged goes at its current
  power; otherwise the turn passes. No more stalled games.
- **How to play:** a new menu entry with pages on walking, aiming, the
  weapons, pickups, weather and the 2-player modes.
- Behind the scenes: `main.lua` split into `cpu.lua`, `lobby.lua` and
  `art.lua` (it was close to the store's 64 KB per-file limit), plus the
  shared `scores.lua`, `lobby.lua` and `help.lua`, and `howto.lua`.

### 1.0.0 (first upload)
- Turn-based throwing game over a London skyline of 20 landmarks, with
  destructible buildings, wind, weather, the Thames, pickups, health,
  four weapons, walking and jumping, points for damage, a CPU monkey that
  moves, pass-the-badge and 2 badges over the radio.

> If the version you uploaded was from before the climbing change, this
> update also brings climbing; if it was from before the menu fix, it brings
> that too. The list above covers both.

---

## Proof of Stack

### 1.0.0 (first upload)
- Falling-block puzzle: transactions, blocks, lamports, epochs, slots, a TPS
  meter, Solana's eight innovations, priority-fee hard drops.
- **Cluster switch:** gravity turns from Mainnet (down) to Devnet (sideways),
  Testnet (up) and Localnet (turning every epoch).
- **Modes:** Marathon, Sprint 40, **Daily challenge** (2 minutes, the same
  pieces on every badge that day), Versus on two badges (spam rows).
- **Nearby leaderboard:** marathon lamports, sprint time, versus wins,
  today's daily.
- Colours: seven steps of the Solana purple-to-green gradient.
- **How to play** pages: the goal, the buttons, the cluster switch and the
  modes.
