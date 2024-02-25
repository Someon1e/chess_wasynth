--!strict

local Board = {}

local Notation = require(script.Parent:WaitForChild("notation"))

-- Only used because the type checker is wrong
local unneeded_assert = assert

type boardState = {
	board: buffer,
	whiteToPlay: boolean,

	whiteCanCastleKingSide: boolean,
	whiteCanCastleQueenSide: boolean,

	blackCanCastleKingSide: boolean,
	blackCanCastleQueenSide: boolean,

	enPassantSquare: number?,

	halfMoveClock: number,
	fullMoveCounter: number,
}

--[[
	FEN (Forsynth Edward's Notation) is a string that describes a chess position
	https://chessprogrammingwiki.netlify.app/forsythedwards_notation/
]]
function Board.fromFEN(fen): boardState
	local sections = string.split(fen, " ")
	local position = sections[1]

	local board = buffer.create(64)

	local file = 0
	local rank = 7
	local index = 0

	while true do
		index += 1
		local character = string.sub(position, index, index)
		local pieceEnum = Notation.PIECE_NAME_TO_ENUM[character]
		if pieceEnum then
			buffer.writeu8(board, file + rank * 8, pieceEnum)
			file += 1
		elseif character == "8" then
			file += 8
		elseif character == "4" then
			file += 4
		elseif character == "3" then
			file += 3
		elseif character == "1" then
			file += 1
		elseif character == "2" then
			file += 2
		elseif character == "7" then
			file += 7
		elseif character == "5" then
			file += 5
		elseif character == "6" then
			file += 6
		elseif character ~= "/" then
			error("Invalid position")
		end
		if file == 8 then
			if rank == 0 then
				break
			end
			rank -= 1
			file = 0
		end
	end

	local whiteCanCastleKingSide, whiteCanCastleQueenSide = false, false
	local blackCanCastleKingSide, blackCanCastleQueenSide = false, false

	local whiteToPlay = sections[2] == "w"

	local castling = sections[3]
	if string.find(castling, "K") then
		whiteCanCastleKingSide = true
	end
	if string.find(castling, "k") then
		blackCanCastleKingSide = true
	end
	if string.find(castling, "Q") then
		whiteCanCastleQueenSide = true
	end
	if string.find(castling, "q") then
		blackCanCastleQueenSide = true
	end

	local enPassantSquare
	local enPassant = sections[4]
	if enPassant ~= "-" then
		enPassantSquare = Notation.SQUARE_NAME_TO_NUMBER[enPassant]
	end

	print(sections)

	local halfMoveClock = tonumber(sections[5])
	local fullMoveCounter = tonumber(sections[6])

	return {
		board = board,
		whiteToPlay = whiteToPlay,

		whiteCanCastleKingSide = whiteCanCastleKingSide,
		whiteCanCastleQueenSide = whiteCanCastleQueenSide,

		blackCanCastleKingSide = blackCanCastleKingSide,
		blackCanCastleQueenSide = blackCanCastleQueenSide,

		enPassantSquare = enPassantSquare,

		halfMoveClock = halfMoveClock or 0,
		fullMoveCounter = fullMoveCounter or 1,
	}
end

function Board.toFEN(state: boardState)
	local result: { string | number } = table.create(87)

	for y = 7, 0, -1 do
		local empty = 0
		for x = 0, 7 do
			local piece = buffer.readu8(state.board, x + y * 8)
			if piece ~= 0 then
				if empty ~= 0 then
					table.insert(result, empty)
					empty = 0
				end
				table.insert(result, Notation.PIECE_ENUM_TO_NAME[piece])
			else
				empty += 1
			end
		end
		if empty ~= 0 then
			table.insert(result, empty)
		end
		if y ~= 0 then
			table.insert(result, "/")
		end
	end

	if state.whiteToPlay then
		table.insert(result, " w ")
	else
		table.insert(result, " b ")
	end

	if
		state.whiteCanCastleKingSide
		or state.whiteCanCastleQueenSide
		or state.blackCanCastleKingSide
		or state.blackCanCastleQueenSide
	then
		if state.whiteCanCastleKingSide then
			table.insert(result, "K")
		end
		if state.whiteCanCastleQueenSide then
			table.insert(result, "Q")
		end
		if state.blackCanCastleKingSide then
			table.insert(result, "k")
		end
		if state.blackCanCastleQueenSide then
			table.insert(result, "q")
		end
	else
		table.insert(result, "-")
	end

	if state.enPassantSquare then
		table.insert(result, " " .. Notation.SQUARE_NUMBER_TO_NAME[state.enPassantSquare] .. " ")
	else
		table.insert(result, " - ")
	end

	table.insert(result, state.halfMoveClock)

	table.insert(result, " ")

	table.insert(result, math.floor(state.fullMoveCounter))

	return table.concat(result)
end

function Board.makeMove(state: boardState, moveNotation, onMove, onPromotion, onEnPassant)
	state.fullMoveCounter += 0.5

	local function teleportPiece(squareMoveFrom, squareMoveTo)
		buffer.writeu8(state.board, squareMoveTo, buffer.readu8(state.board, squareMoveFrom))
		buffer.writeu8(state.board, squareMoveFrom, 0)

		onMove(squareMoveFrom, squareMoveTo)
	end

	local oldEnPassantSquare = state.enPassantSquare
	state.enPassantSquare = nil

	local squareMoveFrom = Notation.uciFrom(moveNotation)
	local squareMoveTo = Notation.uciTo(moveNotation)

	local movingPiece = buffer.readu8(state.board, squareMoveFrom)
	assert(movingPiece ~= 0, "Missing moving piece")

	if buffer.readu8(state.board, squareMoveTo) ~= 0 then
		state.halfMoveClock = 0
	else
		state.halfMoveClock += 1
	end

	if movingPiece == Notation.WHITE_KING or squareMoveFrom == 0 or squareMoveTo == 0 then
		state.whiteCanCastleQueenSide = false
	end
	if movingPiece == Notation.WHITE_KING or squareMoveFrom == 7 or squareMoveTo == 7 then
		state.whiteCanCastleKingSide = false
	end
	if movingPiece == Notation.BLACK_KING or squareMoveFrom == 56 or squareMoveTo == 56 then
		state.blackCanCastleQueenSide = false
	end
	if movingPiece == Notation.BLACK_KING or squareMoveFrom == 63 or squareMoveTo == 63 then
		state.blackCanCastleKingSide = false
	end

	state.whiteToPlay = not state.whiteToPlay

	teleportPiece(squareMoveFrom, squareMoveTo)

	if movingPiece == Notation.WHITE_KING or movingPiece == Notation.BLACK_KING then
		local fileDistance = math.abs(Notation.squareFile(squareMoveFrom) - Notation.squareFile(squareMoveTo))
		local isCastle = fileDistance == 2
		if isCastle then
			local isKingSide = Notation.squareFile(squareMoveTo) == 6
			local rookToOffset = if isKingSide then -1 else 1
			local rookFromOffset = if isKingSide then 1 else -2
			local rookFrom = squareMoveTo + rookFromOffset
			local rookTo = squareMoveTo + rookToOffset
			teleportPiece(rookFrom, rookTo)
		end
	elseif movingPiece == Notation.WHITE_PAWN or movingPiece == Notation.BLACK_PAWN then
		state.halfMoveClock = 0

		local promotion = string.sub(moveNotation, 5, 5)
		if promotion ~= "" then
			local promotionIncrease = assert(({
				r = 1,
				n = 2,
				b = 3,
				q = 4,
			})[promotion], "Invalid promotion")
			buffer.writeu8(state.board, squareMoveTo, movingPiece + promotionIncrease)
			onPromotion(squareMoveTo, movingPiece + promotionIncrease)
		else
			local rankDistance = math.abs(Notation.squareRank(squareMoveFrom) - Notation.squareRank(squareMoveTo))
			if rankDistance == 2 then
				state.enPassantSquare = squareMoveFrom + (if movingPiece == Notation.WHITE_PAWN then 8 else -8)
			elseif squareMoveTo == oldEnPassantSquare then
				local captureSquare = unneeded_assert(oldEnPassantSquare)
					- (if movingPiece == Notation.WHITE_PAWN then 8 else -8)
				buffer.writeu8(state.board, captureSquare, 0)
				state.halfMoveClock = 0
				onEnPassant(captureSquare)
			end
		end
	end
end

return table.freeze(Board)
