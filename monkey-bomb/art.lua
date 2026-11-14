-- Solana Monkey Bomb's pixel art: one character per pixel, "." is
-- see-through. Letters are the badge's colours (k black, w white, y yellow,
-- o orange, m pink, p purple, g green, ...) plus the game's own palette
-- letters (h cap, n fur, f face, q grey, c and d coconut brown, r red).

local A = {}

A.MONKEY_STAND = {
  "..hhhh..",
  ".hhhhhhh",
  ".nnnnnn.",
  "nnffffnn",
  ".nfkfkn.",
  ".nffffn.",
  "..nffn..",
  ".nnnnnn.",
  "n.nnnn.n",
  "..n..n..",
}
A.MONKEY_THROW = {
  "..hhhh.n",
  ".hhhhhhn",
  ".nnnnnnn",
  "nnffffnn",
  ".nfkfkn.",
  ".nffffn.",
  "..nffn..",
  ".nnnnnn.",
  "n.nnnn..",
  "..n..n..",
}

A.ART = {
  bomb = { "...y.", "..o..", ".kkk.", "kkwkk", "kkkkk", ".kkk." },
  bunch = { "....g.", "..yyg.", ".yyyy.", "yyyyy.", "yyyy..", ".yy..." },
  banana = { "y...y", ".yyy." },
  rocket = { "y.....", "oqqqqm", "y....." },
  coconut = { "..y..", ".ccc.", "cdcdc", "ccccc", "ccdcc", ".ccc." },
  health = { "wwwwww", "wwrrww", "wrrrrw", "wrrrrw", "wwrrww", "wwwwww" },
  umbrella = { "..mm..", ".mmmm.", "mmmmmm", "...k..", "...k..", "..kk.." },
  crate = { "oooooo", "oyyyyo", "opgpgo", "ogpgpo", "oyyyyo", "oooooo" },
}

function A.mirror(rows, width)
  local out = {}
  for i, r in ipairs(rows) do
    out[i] = (r .. string.rep(".", width - #r)):reverse()
  end
  return out
end

function A.explosion_rows()
  local rows = {}
  for y = -6, 6 do
    local row = {}
    for x = -6, 6 do
      local d = math.sqrt(x * x + y * y)
      local ch = "."
      if d < 2.5 then ch = "w"
      elseif d < 4.2 then ch = "y"
      elseif d < 5.6 then ch = "o"
      elseif d < 6.6 and (x + y) % 2 == 0 then ch = "m" end
      row[#row + 1] = ch
    end
    rows[#rows + 1] = table.concat(row)
  end
  return rows
end

return A
