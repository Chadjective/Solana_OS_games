-- Solana Pong: the "How to play" pages, shown from the menu by help.lua.
-- Up to 11 lines a page, at most 40 characters a line (the badge's small
-- text is a fixed-width font).

return {
  { title = "HOW TO PLAY", lines = {
    "The ball is the Solana mark. Your",
    "paddle is the bottom bar of the S,",
    "on the left. Get the ball past the",
    "other paddle, and don't let it past",
    "yours. First to 7 wins.",
    "",
    "UP/DOWN: move your paddle",
    "SELECT: pause (against the CPU)",
    "CANCEL: back to the menu",
    "",
    "The ball speeds up with every hit.",
  } },
  { title = "TIPS", lines = {
    "Hit the ball with the edge of your",
    "paddle to send it off at an angle.",
    "",
    "Easy, Normal and Hard: the CPU gets",
    "faster and sharper each level.",
    "",
    "Nearby leaderboard: your wins next to",
    "those of the badges around you with",
    "Pong open.",
  } },
  { title = "2 BADGES", lines = {
    "Both players open Solana Pong and",
    "pick 2 players: 2 badges.",
    "Pick the other player and press",
    "SELECT to invite them. They press",
    "SELECT to accept.",
    "You each see yourself on the left.",
    "",
    "Play in the same room: players",
    "marked \"far: laggy\" are too far",
    "away for real-time Pong.",
  } },
}
