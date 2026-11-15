-- Proof of Stack: the "How to play" pages, shown from the menu by help.lua.
-- Up to 11 lines a page, at most 40 characters a line (the badge's small
-- text is a fixed-width font).

return {
  { title = "HOW TO PLAY", lines = {
    "Transactions fall into the",
    "blockspace. Fill a whole row to",
    "finalize a block: it clears and pays",
    "lamports (5,000 times the epoch).",
    "4 blocks at once: SUPERMAJORITY!",
    "",
    "Every 10 blocks a new epoch starts",
    "and transactions fall faster.",
    "A hard drop is a priority fee: 2",
    "extra lamports a row. Don't let the",
    "blockspace fill up!",
  } },
  { title = "CONTROLS", lines = {
    "LEFT/RIGHT: move (hold to slide)",
    "UP: rotate",
    "DOWN: drop faster",
    "SELECT: drop instantly",
    "CANCEL: quit",
    "",
    "These are for Mainnet. On the other",
    "clusters gravity turns, and so do",
    "the buttons: the hint bar at the",
    "bottom always shows them.",
  } },
  { title = "CLUSTER SWITCH", lines = {
    "Gravity turns as the epochs go by:",
    "",
    "Mainnet (epochs 1-3): down",
    "Devnet (4-6): in from the left",
    "Testnet (7-9): up from the bottom",
    "Localnet (10+): turns every epoch",
    "",
    "Your stack turns with the board.",
  } },
  { title = "MODES", lines = {
    "Marathon: as long as you can last.",
    "Sprint 40: 40 blocks, fastest wins.",
    "Daily challenge: 2 minutes, the same",
    "pieces on every badge today.",
    "Versus (2 badges): finalize 2, 3 or",
    "4 blocks at once to send 1, 2 or 4",
    "spam rows to the other player.",
    "",
    "Nearby leaderboard: bests from the",
    "badges around you, and today's daily.",
  } },
}
