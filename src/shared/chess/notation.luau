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

-- UCI (Universal Chess Interface) is a protocol for communication between the engine and gui
-- https://www.chessprogramming.org/UCI
function Notation.uciFrom(uciNotation)
	return Notation.SQUARE_NAME_TO_NUMBER[string.sub(uciNotation, 1, 2)]
end
function Notation.uciTo(uciNotation)
	return Notation.SQUARE_NAME_TO_NUMBER[string.sub(uciNotation, 3, 4)]
end

function Notation.squareRank(square: number)
	return bit32.rshift(square, 3)
end
function Notation.squareFile(square: number)
	return bit32.band(square, 0b111)
end

Notation.BLACK_PAWN = 1
Notation.BLACK_ROOK = 2
Notation.BLACK_KNIGHT = 3
Notation.BLACK_BISHOP = 4
Notation.BLACK_QUEEN = 5
Notation.BLACK_KING = 6

Notation.WHITE_PAWN = 7
Notation.WHITE_ROOK = 8
Notation.WHITE_KNIGHT = 9
Notation.WHITE_BISHOP = 10
Notation.WHITE_QUEEN = 11
Notation.WHITE_KING = 12

Notation.PIECE_ENUM_TO_NAME = {
	[Notation.BLACK_PAWN] = "p",
	[Notation.BLACK_ROOK] = "r",
	[Notation.BLACK_KNIGHT] = "n",
	[Notation.BLACK_BISHOP] = "b",
	[Notation.BLACK_QUEEN] = "q",
	[Notation.BLACK_KING] = "k",

	[Notation.WHITE_PAWN] = "P",
	[Notation.WHITE_ROOK] = "R",
	[Notation.WHITE_KNIGHT] = "N",
	[Notation.WHITE_BISHOP] = "B",
	[Notation.WHITE_QUEEN] = "Q",
	[Notation.WHITE_KING] = "K",
}

Notation.PIECE_NAME_TO_ENUM = {
	p = Notation.BLACK_PAWN,
	r = Notation.BLACK_ROOK,
	n = Notation.BLACK_KNIGHT,
	b = Notation.BLACK_BISHOP,
	q = Notation.BLACK_QUEEN,
	k = Notation.BLACK_KING,

	P = Notation.WHITE_PAWN,
	R = Notation.WHITE_ROOK,
	N = Notation.WHITE_KNIGHT,
	B = Notation.WHITE_BISHOP,
	Q = Notation.WHITE_QUEEN,
	K = Notation.WHITE_KING,
}

return table.freeze(Notation)
