local data = require(script:WaitForChild("data"))

local openings = {}

function openings.getFromMoves(moves)
	return data[moves]
end

return table.freeze(openings)
