--!strict
local Notation = {}

Notation.FILE_NUMBER_TO_NAME = buffer.fromstring("abcdefgh")

Notation.SQUARE_NUMBER_TO_NAME = table.create(63)
Notation.SQUARE_NAME_TO_NUMBER = {}
for x = 0, 7 do
	for y = 0, 7 do
		local name = buffer.readstring(Notation.FILE_NUMBER_TO_NAME, x, 1) .. y + 1
		Notation.SQUARE_NUMBER_TO_NAME[x + y * 8] = name
		Notation.SQUARE_NAME_TO_NUMBER[name] = x + y * 8
	end
end

-- UCI (Universal Chess Interface) is a protocol for communciation between the engine and gui
-- https://chessprogrammingwiki.netlify.app/uci/
function Notation.UciFrom(uciNotation)
	return Notation.SQUARE_NAME_TO_NUMBER[string.sub(uciNotation, 1, 2)]
end
function Notation.UciTo(uciNotation)
	return Notation.SQUARE_NAME_TO_NUMBER[string.sub(uciNotation, 3, 4)]
end

return table.freeze(Notation)