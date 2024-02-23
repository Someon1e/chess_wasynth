--!strict

local DEFAULT_AI_MOVE_TIME_IN_MILLISECONDS = 3000

local LIGHT_SQUARE_COLOUR, DARK_SQUARE_COLOUR = Color3.fromRGB(234, 233, 210), Color3.fromRGB(75, 115, 153)

local CAN_MOVE_TO_SQUARE_COLOUR = Color3.fromRGB(255, 85, 0)
local CAN_CAPTURE_SQUARE_COLOUR = Color3.fromRGB(255, 0, 0)

local WHITE_PAWN = 7
local BLACK_PAWN = 1
local WHITE_KING = 12
local BLACK_KING = 6
local PIECE_TEXTURES = {
	[BLACK_PAWN] = "rbxassetid://7079123026",
	[2] = "rbxassetid://7079118362",
	[3] = "rbxassetid://7079123704",
	[4] = "rbxassetid://7079124677",
	[5] = "rbxassetid://7079118808",
	[BLACK_KING] = "rbxassetid://7079124193",

	[WHITE_PAWN] = "rbxassetid://7079118994",
	[8] = "rbxassetid://7079116513",
	[9] = "rbxassetid://7079123407",
	[10] = "rbxassetid://7079124389",
	[11] = "rbxassetid://7079118641",
	[WHITE_KING] = "rbxassetid://7079123896",
}

local PIECE_ENUM_TO_NAME = {
	[BLACK_PAWN] = "p",
	[2] = "r",
	[3] = "n",
	[4] = "b",
	[5] = "q",
	[BLACK_KING] = "k",

	[WHITE_PAWN] = "P",
	[8] = "R",
	[9] = "N",
	[10] = "B",
	[11] = "Q",
	[WHITE_KING] = "K",
}
local PIECE_NAME_TO_ENUM = {
	p = BLACK_PAWN,
	r = 2,
	n = 3,
	b = 4,
	q = 5,
	k = BLACK_KING,

	P = WHITE_PAWN,
	R = 8,
	N = 9,
	B = 10,
	Q = 11,
	K = WHITE_KING,
}

local FILE_NUMBER_TO_NAME = buffer.fromstring("abcdefgh")

local SQUARE_NUMBER_TO_NAME = table.create(63)
local SQUARE_NAME_TO_NUMBER = {}
for x = 0, 7 do
	for y = 0, 7 do
		local name = buffer.readstring(FILE_NUMBER_TO_NAME, x, 1) .. y + 1
		SQUARE_NUMBER_TO_NAME[x + y * 8] = name
		SQUARE_NAME_TO_NUMBER[name] = x + y * 8
	end
end

-- UCI (Universal Chess Interface) is a protocol for communciation between the engine and gui
-- https://chessprogrammingwiki.netlify.app/uci/
local function uciFrom(uciNotation)
	return SQUARE_NAME_TO_NUMBER[string.sub(uciNotation, 1, 2)]
end
local function uciTo(uciNotation)
	return SQUARE_NAME_TO_NUMBER[string.sub(uciNotation, 3, 4)]
end

local line = {}

local messageListener: (string) -> ...any? = print

local rust = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("engine"))({
	env = {
		func_list = {
			time = os.clock,
			print_char = function(byte)
				local character = string.char(byte)
				if character == "\n" then
					messageListener(table.concat(line))
					table.clear(line)
					return
				end
				table.insert(line, character)
			end,
		},
	},
})

local function sendInput(input)
	for i = 1, #input do
		local character = string.byte(input, i, i)
		rust.func_list.send_input(character)
	end
	rust.func_list.send_input(string.byte("\n"))
end

-- Only used because the type checker is wrong
local unneeded_assert = assert

local UserInputService = game:GetService("UserInputService")
local playerGui = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")

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
local function fromFEN(fen): boardState
	local sections = string.split(fen, " ")
	local position = sections[1]

	local board = buffer.create(64)

	local file = 0
	local rank = 7
	local index = 0

	while true do
		index += 1
		local character = string.sub(position, index, index)
		local pieceEnum = PIECE_NAME_TO_ENUM[character]
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
		enPassantSquare = SQUARE_NAME_TO_NUMBER[enPassant]
	end

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

local function toFEN(state: boardState)
	local result: { string | number }, index = {}, 0

	for y = 7, 0, -1 do
		local empty = 0
		for x = 0, 7 do
			local piece = buffer.readu8(state.board, x + y * 8)
			if piece ~= 0 then
				if empty ~= 0 then
					index += 1
					result[index] = empty
					empty = 0
				end
				index += 1
				result[index] = PIECE_ENUM_TO_NAME[piece]
			else
				empty += 1
			end
		end
		if empty ~= 0 then
			index += 1
			result[index] = empty
		end
		if y ~= 0 then
			index += 1
			result[index] = "/"
		end
	end

	index += 1
	if state.whiteToPlay then
		result[index] = " w "
	else
		result[index] = " b "
	end

	if
		state.whiteCanCastleKingSide
		or state.whiteCanCastleQueenSide
		or state.blackCanCastleKingSide
		or state.blackCanCastleQueenSide
	then
		if state.whiteCanCastleKingSide then
			index += 1
			result[index] = "K"
		end
		if state.whiteCanCastleQueenSide then
			index += 1
			result[index] = "Q"
		end
		if state.blackCanCastleKingSide then
			index += 1
			result[index] = "k"
		end
		if state.blackCanCastleQueenSide then
			index += 1
			result[index] = "q"
		end
	else
		index += 1
		result[index] = "-"
	end

	index += 1
	if state.enPassantSquare then
		result[index] = " " .. SQUARE_NUMBER_TO_NAME[state.enPassantSquare] .. " "
	else
		result[index] = " - "
	end

	index += 1
	result[index] = state.halfMoveClock

	index += 1
	result[index] = " "

	index += 1
	result[index] = state.fullMoveCounter

	return table.concat(result)
end

local function getLegalMoves(state)
	-- Use perft to get legal moves
	-- https://chessprogrammingwiki.netlify.app/perft/

	local legalMoves: { string } = {}
	messageListener = function(output)
		local prefix = string.match(output, "(.+):")
		if prefix == "Nodes searched" then
			messageListener = print
		else
			if prefix then
				table.insert(legalMoves, prefix)
			end
		end
	end
	sendInput("position fen " .. toFEN(state))
	sendInput("go perft 1")

	return legalMoves
end

local function getBestMove(initialFen: string, moves, updateEval, aiMoveTime)
	local result: string?
	messageListener = function(output)
		print(output)

		local move = string.match(output, "bestmove (.+)")
		if move then
			result = if move == "a1a1" then nil else move
			messageListener = print
		else
			local eval = tonumber(string.match(output, "cp ([^ ]+)"))
			if not eval then
				return
			end
			updateEval(eval)
		end
	end
	sendInput("position fen " .. initialFen .. " moves " .. moves)
	sendInput("go movetime " .. tostring(aiMoveTime))

	return result
end

local function constrain(object, aspectRatio)
	local constraint = Instance.new("UIAspectRatioConstraint")
	constraint.AspectRatio = aspectRatio
	constraint.Parent = object
end

local function makeBoardFrame()
	local boardFrame = Instance.new("Frame")
	boardFrame.Name = "Board"

	constrain(boardFrame, 1)

	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.CellSize = UDim2.fromScale(1 / 8, 1 / 8)
	gridLayout.CellPadding = UDim2.fromScale(0, 0)
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.StartCorner = Enum.StartCorner.BottomLeft
	gridLayout.Parent = boardFrame

	boardFrame.Size = UDim2.fromScale(0.8, 0.8)
	boardFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	boardFrame.Position = UDim2.fromScale(0.5, 0.5)

	return boardFrame, gridLayout
end
local function makeSquareGui(boardFrame, state)
	local labels = table.create(63)
	for y = 7, 0, -1 do
		for x = 0, 7 do
			local label = Instance.new("ImageLabel")

			label.LayoutOrder = y * 8 + x
			label.Name = SQUARE_NUMBER_TO_NAME[x + y * 8]
			label.BackgroundColor3 = if (y + x) % 2 == 0 then LIGHT_SQUARE_COLOUR else DARK_SQUARE_COLOUR

			local piece = buffer.readu8(state.board, x + y * 8)
			label.Active = piece ~= 0
			label.Image = PIECE_TEXTURES[piece] or ""

			label.BorderSizePixel = 0

			local corner = Instance.new("TextLabel")
			corner.ZIndex = 2
			corner.Text = SQUARE_NUMBER_TO_NAME[x + y * 8]
			corner.TextScaled = true
			corner.Size = UDim2.fromScale(0.2, 0.2)
			corner.Position = UDim2.fromScale(0.7, 0.8)
			corner.BackgroundTransparency = 1
			corner.Parent = label

			labels[x + y * 8] = label
			label.Parent = boardFrame
		end
	end
	return labels
end

local function makeEvalBar()
	local evalBar = Instance.new("Frame")
	evalBar.Name = "Evaluation"
	evalBar.ClipsDescendants = true
	evalBar.Size = UDim2.fromScale(0.02, 0.8)
	evalBar.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	evalBar.Position = UDim2.fromScale(0.2, 0.1)
	evalBar.ZIndex = 2
	local blackEvalFill = Instance.new("Frame")
	blackEvalFill.Size = UDim2.fromScale(1, 0.5)
	blackEvalFill.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	blackEvalFill.Position = UDim2.fromScale(0, 0)
	blackEvalFill.ZIndex = 2
	blackEvalFill.Parent = evalBar
	evalBar.Visible = false
	return evalBar, blackEvalFill
end

local function makeButton(name)
	local button = Instance.new("TextButton")
	button.TextScaled = true
	button.Size = UDim2.fromScale(0.07, 0.07)
	button.BackgroundColor3 = Color3.fromRGB(0, 0, 30)
	button.TextColor3 = Color3.fromRGB(232, 232, 232)
	button.Name = name
	constrain(button, 2)

	return button
end

local function squareRank(square: number)
	return bit32.rshift(square, 3)
end
local function squareFile(square: number)
	return bit32.band(square, 0b111)
end

local function waitForRender()
	return task.wait() + task.wait() + task.wait()
end

local function makeGui(initialFen)
	local state = fromFEN(initialFen)
	local moveHistory = {}
	local stateHistory = {}
	local legalMoves = getLegalMoves(state)

	local gui = Instance.new("ScreenGui")
	gui.Name = "Chess"

	local boardFrame, boardGridLayout = makeBoardFrame()
	local labels = makeSquareGui(boardFrame, state)

	local function resetLabels()
		for y = 7, 0, -1 do
			for x = 0, 7 do
				local label = labels[x + y * 8]
				label.BackgroundColor3 = if (y + x) % 2 == 0 then LIGHT_SQUARE_COLOUR else DARK_SQUARE_COLOUR
				label.Active = buffer.readu8(state.board, x + y * 8) ~= 0
			end
		end
	end

	local evalBar, blackEvalFill = makeEvalBar()
	evalBar.Parent = gui

	local rotateButton = makeButton("Rotate")
	rotateButton.Text = "Rotate"
	rotateButton.Position = UDim2.fromScale(0.85, 0.9)
	rotateButton.Activated:Connect(function()
		if boardGridLayout.StartCorner == Enum.StartCorner.BottomLeft then
			boardGridLayout.StartCorner = Enum.StartCorner.TopRight
		else
			boardGridLayout.StartCorner = Enum.StartCorner.BottomLeft
		end
	end)
	rotateButton.Parent = gui

	local fenBox = Instance.new("TextBox")
	fenBox.Name = "FEN"
	fenBox.Text = initialFen
	fenBox.TextScaled = true
	fenBox.Size = UDim2.fromScale(0.2, 0.08)
	fenBox.ClearTextOnFocus = false
	fenBox.ZIndex = 2
	fenBox.BackgroundColor3 = Color3.fromRGB(0, 0, 30)
	fenBox.TextColor3 = Color3.fromRGB(232, 232, 232)
	fenBox.Position = UDim2.fromScale(0.75, 0.5)
	constrain(fenBox, 4)

	fenBox.FocusLost:Connect(function()
		local isValid, newState = pcall(fromFEN, fenBox.Text)
		if not isValid then
			warn("Invalid FEN")
			fenBox.Text = initialFen
			return
		end
		evalBar.Visible = false
		state = newState
		initialFen = toFEN(state)
		fenBox.Text = initialFen
		table.clear(moveHistory)
		table.clear(stateHistory)
		legalMoves = getLegalMoves(state)
		for square, label in labels do
			local piece = buffer.readu8(state.board, square)
			label.Image = PIECE_TEXTURES[piece] or ""
		end
		resetLabels()
	end)
	fenBox.Parent = gui

	local aiMoveTimeInMilliseconds = DEFAULT_AI_MOVE_TIME_IN_MILLISECONDS

	local aiMoveTimeBox = Instance.new("TextBox")
	aiMoveTimeBox.Name = "AIMoveTime"
	aiMoveTimeBox.Text = tostring(aiMoveTimeInMilliseconds)
	aiMoveTimeBox.TextScaled = true
	aiMoveTimeBox.Size = UDim2.fromScale(0.07, 0.07)
	aiMoveTimeBox.ClearTextOnFocus = false
	aiMoveTimeBox.ZIndex = 2
	aiMoveTimeBox.BackgroundColor3 = Color3.fromRGB(0, 0, 30)
	aiMoveTimeBox.TextColor3 = Color3.fromRGB(232, 232, 232)
	aiMoveTimeBox.Position = UDim2.fromScale(0.85, 0.797)
	aiMoveTimeBox.FocusLost:Connect(function()
		local number = tonumber(aiMoveTimeBox.Text)
		if not number then
			aiMoveTimeBox.Text = tostring(aiMoveTimeInMilliseconds)
			return
		end
		local clamped = math.clamp(number, 100, 10000)
		aiMoveTimeInMilliseconds = clamped
		aiMoveTimeBox.Text = tostring(clamped)
	end)
	constrain(aiMoveTimeBox, 3)

	local aiMoveTimeLabel = Instance.new("TextLabel")
	aiMoveTimeLabel.Text = "AI Move Time"
	aiMoveTimeLabel.TextScaled = true
	aiMoveTimeLabel.Size = UDim2.fromScale(0.6, 0.5)
	aiMoveTimeLabel.Position = UDim2.fromScale(0, 1.1)
	aiMoveTimeLabel.BackgroundColor3 = Color3.fromRGB(0, 0, 30)
	aiMoveTimeLabel.TextColor3 = Color3.fromRGB(232, 232, 232)
	aiMoveTimeLabel.Parent = aiMoveTimeBox
	aiMoveTimeBox.Parent = gui

	boardFrame.Parent = gui
	gui.Parent = playerGui

	local function highlightLegalMoves(from)
		for _, legalMove in legalMoves do
			local legalMoveFrom = uciFrom(legalMove)
			if legalMoveFrom ~= from then
				continue
			end

			local legalMoveTo = uciTo(legalMove)
			labels[legalMoveTo].BackgroundColor3 = if buffer.readu8(state.board, legalMoveTo) ~= 0
				then CAN_CAPTURE_SQUARE_COLOUR
				else CAN_MOVE_TO_SQUARE_COLOUR
			labels[legalMoveTo].Active = true
		end
	end

	local squareMoveFrom: number?

	local function teleportPiece(squareMoveFrom, squareMoveTo)
		buffer.writeu8(state.board, squareMoveTo, buffer.readu8(state.board, squareMoveFrom))
		labels[squareMoveTo].Image = labels[squareMoveFrom].Image

		buffer.writeu8(state.board, squareMoveFrom, 0)
		labels[squareMoveFrom].Image = ""
	end
	local function playMove(moveNotation)
		state.enPassantSquare = nil

		local squareMoveFrom = uciFrom(moveNotation)
		local squareMoveTo = uciTo(moveNotation)

		local movingPiece = buffer.readu8(state.board, squareMoveFrom)
		assert(movingPiece ~= 0)

		if movingPiece == WHITE_KING or squareMoveFrom == 0 or squareMoveTo == 0 then
			state.whiteCanCastleQueenSide = false
		end
		if movingPiece == WHITE_KING or squareMoveFrom == 7 or squareMoveTo == 7 then
			state.whiteCanCastleKingSide = false
		end
		if movingPiece == BLACK_KING or squareMoveFrom == 56 or squareMoveTo == 56 then
			state.blackCanCastleQueenSide = false
		end
		if movingPiece == BLACK_KING or squareMoveFrom == 63 or squareMoveTo == 63 then
			state.blackCanCastleKingSide = false
		end

		table.insert(moveHistory, moveNotation)

		state.whiteToPlay = not state.whiteToPlay

		teleportPiece(squareMoveFrom, squareMoveTo)

		if movingPiece == WHITE_KING or movingPiece == BLACK_KING then
			local fileDistance = math.abs(squareFile(squareMoveFrom) - squareFile(squareMoveTo))
			local isCastle = fileDistance == 2
			if isCastle then
				local isKingSide = squareFile(squareMoveTo) == 6
				local rookToOffset = if isKingSide then -1 else 1
				local rookFromOffset = if isKingSide then 1 else -2
				local rookFrom = squareMoveTo + rookFromOffset
				local rookTo = squareMoveTo + rookToOffset
				teleportPiece(rookFrom, rookTo)
			end
		elseif movingPiece == WHITE_PAWN or movingPiece == BLACK_PAWN then
			local promotion = string.sub(moveNotation, 5, 5)
			if promotion ~= "" then
				local promotionIncrease = assert(({
					r = 1,
					n = 2,
					b = 3,
					q = 4,
				})[promotion])
				buffer.writeu8(state.board, squareMoveTo, movingPiece + promotionIncrease)
				labels[squareMoveTo].Image = PIECE_TEXTURES[movingPiece + promotionIncrease]
			else
				local rankDistance = math.abs(squareRank(squareMoveFrom) - squareRank(squareMoveTo))
				if rankDistance == 2 then
					state.enPassantSquare = squareMoveFrom + (if movingPiece == WHITE_PAWN then 8 else -8)
				elseif squareMoveTo == state.enPassantSquare then
					buffer.writeu8(
						state.board,
						unneeded_assert(state.enPassantSquare) - (if movingPiece == WHITE_PAWN then 8 else -8),
						0
					)
				end
			end
		end

		legalMoves = getLegalMoves(state)
		resetLabels()

		fenBox.Text = toFEN(state)
	end

	local undoButton = makeButton("Undo")
	undoButton.Position = UDim2.fromScale(0.75, 0.9)
	undoButton.Text = "Undo"
	undoButton.Activated:Connect(function()
		assert(#moveHistory % 2 == 0)
		local prevState = table.remove(stateHistory)
		if not prevState then
			return
		end

		state = prevState
		evalBar.Visible = false
		table.remove(moveHistory)
		table.remove(moveHistory)
		for square, label in labels do
			local piece = buffer.readu8(state.board, square)
			label.Image = PIECE_TEXTURES[piece] or ""
		end
		legalMoves = getLegalMoves(state)
		resetLabels()
	end)
	undoButton.Parent = gui

	local function getAIResponse()
		return getBestMove(initialFen, table.concat(moveHistory, " "), function(evaluation)
			evalBar.Visible = true
			local blackEvaluation = if state.whiteToPlay then -evaluation else evaluation
			blackEvalFill.Size = UDim2.fromScale(1, 0.5 + blackEvaluation / 2000)
			waitForRender()
		end, aiMoveTimeInMilliseconds)
	end

	local aiSelfPlayButton = makeButton("AISelfPlay")
	aiSelfPlayButton.Position = UDim2.fromScale(0.75, 0.8)
	aiSelfPlayButton.Text = "AI vs AI"
	local aiSelfPlaying = false
	aiSelfPlayButton.Activated:Connect(function()
		aiSelfPlaying = not aiSelfPlaying
		while aiSelfPlaying do
			local move = getAIResponse()
			if not move then
				break
			end
			playMove(move)
		end
	end)
	aiSelfPlayButton.Parent = gui

	local function getHoveringSquare(input): (number?, ImageLabel?)
		for _, label in playerGui:GetGuiObjectsAtPosition(input.Position.X, input.Position.Y) do
			local squareMoveTo = table.find(labels, label)
			if squareMoveTo then
				return squareMoveTo, label
			end
			if labels[0] == label then
				return 0, label
			end
		end
		return nil, nil
	end

	local promotionFrame = Instance.new("Frame")
	promotionFrame.Name = "Promotion"
	local promotionButtons = {}
	local pieceColourOffset = if state.whiteToPlay then 6 else 0
	for piece = 2 + pieceColourOffset, 5 + pieceColourOffset do
		local button = Instance.new("ImageButton")
		button.Name = PIECE_ENUM_TO_NAME[piece - pieceColourOffset]
		button.Image = PIECE_TEXTURES[piece]
		button.Size = UDim2.fromScale(1 / 4, 1)
		button.Position = UDim2.fromScale((piece - 2 - pieceColourOffset) / 4, 0)
		button.Parent = promotionFrame

		promotionButtons[button] = PIECE_ENUM_TO_NAME[piece - pieceColourOffset]
	end
	constrain(promotionFrame, 4)
	promotionFrame.Position = UDim2.fromScale(0.03, 0.3)
	promotionFrame.Size = UDim2.fromScale(0.2, 0.2)
	promotionFrame.Visible = false
	promotionFrame.Parent = gui

	local function tryAskPromotion(squareMoveTo)
		for _, legalMove in legalMoves do
			local legalMoveFrom = uciFrom(legalMove)
			if legalMoveFrom ~= squareMoveFrom then
				continue
			end

			local legalMoveTo = uciTo(legalMove)
			if legalMoveTo ~= squareMoveTo then
				continue
			end

			local thread = coroutine.running()
			promotionFrame.Visible = true
			local connections: { RBXScriptConnection }? = {}
			for button, promotion in promotionButtons do
				table.insert(
					unneeded_assert(connections),
					button.Activated:Connect(function()
						for _, connection in unneeded_assert(connections) do
							connection:Disconnect()
						end
						connections = nil
						promotionFrame.Visible = false
						task.spawn(thread, promotion)
					end)
				)
			end
			return coroutine.yield()
		end
		return nil
	end

	local function humanMadeMove(input)
		local squareMoveTo = getHoveringSquare(input)
		if not squareMoveTo then
			return
		end
		if squareMoveFrom == squareMoveTo then
			return
		end

		local notation = SQUARE_NUMBER_TO_NAME[unneeded_assert(squareMoveFrom)] .. SQUARE_NUMBER_TO_NAME[squareMoveTo]
		local isPromotionRank = buffer.readu8(state.board, unneeded_assert(squareMoveFrom)) == 1 + pieceColourOffset
			and (squareRank(squareMoveTo) == 0 or squareRank(squareMoveTo) == 7)
		if isPromotionRank then
			local promotion = tryAskPromotion(squareMoveTo)
			if promotion then
				notation ..= promotion
			else
				return
			end
		elseif not table.find(legalMoves, notation) then
			return
		end

		table.insert(stateHistory, table.clone(state))
		stateHistory[#stateHistory].board = buffer.fromstring(buffer.tostring(state.board))
		playMove(notation)
		waitForRender()

		local response = getAIResponse()
		if response then
			playMove(response)
		end
		squareMoveFrom = nil
	end

	local draggedFrom: ImageLabel?
	local pieceDragImage = Instance.new("ImageLabel")
	pieceDragImage.Name = "Drag"
	pieceDragImage.BackgroundTransparency = 1
	pieceDragImage.AnchorPoint = Vector2.new(0.5, 0.5)
	boardFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		pieceDragImage.Size = UDim2.fromOffset(boardFrame.AbsoluteSize.X / 8, boardFrame.AbsoluteSize.Y / 8)
	end)
	pieceDragImage.Size = UDim2.fromOffset(boardFrame.AbsoluteSize.X / 8, boardFrame.AbsoluteSize.Y / 8)
	pieceDragImage.ZIndex = 3
	pieceDragImage.Parent = gui

	local function dragEnd()
		if not draggedFrom then
			return
		end
		pieceDragImage.Visible = false
		draggedFrom.Image = pieceDragImage.Image
		draggedFrom = nil
	end
	local function dragStart(position, from)
		resetLabels()
		pieceDragImage.Image = from.Image
		from.Image = ""

		pieceDragImage.Position = UDim2.fromOffset(position.X, position.Y)
		pieceDragImage.Visible = true
		draggedFrom = from
	end
	UserInputService.InputChanged:Connect(function(input)
		if aiSelfPlaying then
			return
		end
		if
			pieceDragImage.Visible
			and (
				input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch
			)
		then
			pieceDragImage.Position = UDim2.fromOffset(input.Position.X, input.Position.Y)
		end
	end)
	UserInputService.InputBegan:Connect(function(input)
		if aiSelfPlaying then
			return
		end
		if
			input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end
		local hoveringSquare, label = getHoveringSquare(input)
		if not hoveringSquare then
			return
		end
		local piece = buffer.readu8(state.board, hoveringSquare)
		if piece ~= 0 and if state.whiteToPlay then piece > 6 else 7 > piece then
			squareMoveFrom = hoveringSquare

			dragStart(input.Position, unneeded_assert(label))

			highlightLegalMoves(squareMoveFrom)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if aiSelfPlaying then
			return
		end
		if
			input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end
		if not squareMoveFrom then
			return
		end

		dragEnd()
		humanMadeMove(input)
	end)
end

makeGui("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
