--!strict

local Config = require(script:WaitForChild("config"))
local chess = game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("chess")
local Engine = require(chess:WaitForChild("engine"))
local Notation = require(chess:WaitForChild("notation"))
local Board = require(chess:WaitForChild("board"))

local pieceMoveSound = Instance.new("Sound")
pieceMoveSound.SoundId = Config.PIECE_MOVE_SOUND
pieceMoveSound.Parent = workspace

-- Only used because the type checker is wrong
local unneeded_assert = assert

local UserInputService = game:GetService("UserInputService")
local playerGui = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")

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
			label.Name = Notation.SQUARE_NUMBER_TO_NAME[x + y * 8]
			label.BackgroundColor3 = if (y + x) % 2 == 0 then Config.LIGHT_SQUARE_COLOUR else Config.DARK_SQUARE_COLOUR

			local piece = buffer.readu8(state.board, x + y * 8)
			label.Active = piece ~= 0
			label.Image = Config.PIECE_TEXTURES[piece] or ""

			label.BorderSizePixel = 0

			local corner = Instance.new("TextLabel")
			corner.ZIndex = 2
			corner.Text = Notation.SQUARE_NUMBER_TO_NAME[x + y * 8]
			corner.FontFace = Config.FONT
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

local function waitForRender()
	return task.wait() + task.wait() + task.wait()
end

local function makeGui(initialFen)
	local state = Board.fromFEN(initialFen)
	local sideOfHuman: boolean? = state.whiteToPlay

	local moveHistory = {}
	local stateHistory = {}

	local gui = Instance.new("ScreenGui")
	gui.Name = "Chess"

	local boardFrame, boardGridLayout = makeBoardFrame()
	local labels = makeSquareGui(boardFrame, state)

	local usedCircles: { Frame }, unusedCircles = table.create(27), table.create(27)
	do
		for index = 1, 27 do
			local circle = Instance.new("Frame")
			circle.Name = "Circle"
			circle.Size = UDim2.fromScale(0.4, 0.4)
			circle.AnchorPoint = Vector2.new(0.5, 0.5)
			circle.Position = UDim2.fromScale(0.5, 0.5)
			circle.BackgroundTransparency = 0.5

			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(1)
			corner.Parent = circle

			unusedCircles[index] = circle
		end
	end

	local function resetLabels()
		for y = 7, 0, -1 do
			for x = 0, 7 do
				local label = labels[x + y * 8]
				label.Active = buffer.readu8(state.board, x + y * 8) ~= 0
			end
		end
		for _, circle in usedCircles do
			circle.Parent = nil
			table.insert(unusedCircles, circle)
		end
		table.clear(usedCircles)
	end

	local evalBar, blackEvalFill = makeEvalBar()
	evalBar.Parent = gui

	local rotateButton = makeButton("Rotate")
	rotateButton.Text = "Rotate"
	rotateButton.FontFace = Config.FONT
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
	fenBox.FontFace = Config.FONT
	fenBox.TextScaled = true
	fenBox.Size = UDim2.fromScale(0.2, 0.06)
	fenBox.ClearTextOnFocus = false
	fenBox.ZIndex = 2
	fenBox.BackgroundColor3 = Color3.fromRGB(0, 0, 30)
	fenBox.TextColor3 = Color3.fromRGB(232, 232, 232)
	fenBox.Position = UDim2.fromScale(0.75, 0.5)
	constrain(fenBox, 6)

	fenBox.FocusLost:Connect(function()
		local isValid, newState = pcall(Board.fromFEN, fenBox.Text)
		if not isValid then
			warn("Invalid FEN")
			fenBox.Text = initialFen
			return
		end
		evalBar.Visible = false
		state = newState
		initialFen = Board.toFEN(state)
		fenBox.Text = initialFen
		table.clear(moveHistory)
		table.clear(stateHistory)
		for square, label in labels do
			local piece = buffer.readu8(state.board, square)
			label.Image = Config.PIECE_TEXTURES[piece] or ""
		end
		resetLabels()
	end)
	fenBox.Parent = gui

	local aiMoveTimeInMilliseconds = Config.DEFAULT_AI_MOVE_TIME_IN_MILLISECONDS

	local aiMoveTimeBox = Instance.new("TextBox")
	aiMoveTimeBox.Name = "AIMoveTime"
	aiMoveTimeBox.Text = tostring(aiMoveTimeInMilliseconds)
	aiMoveTimeBox.FontFace = Config.FONT
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
	aiMoveTimeLabel.FontFace = Config.FONT
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
		Engine.getLegalMoves(function(legalMove)
			local legalMoveFrom = Notation.uciFrom(legalMove)
			if legalMoveFrom ~= from then
				return
			end

			local legalMoveTo = Notation.uciTo(legalMove)

			local circle = assert(table.remove(unusedCircles), "Exceeded piece max possible moves")
			if buffer.readu8(state.board, legalMoveTo) ~= 0 then
				circle.BackgroundColor3 = Config.CAN_CAPTURE_SQUARE_COLOUR
			else
				circle.BackgroundColor3 = Config.CAN_MOVE_TO_SQUARE_COLOUR
			end
			circle.Parent = labels[legalMoveTo]
			table.insert(usedCircles, circle)

			labels[legalMoveTo].Active = true
		end, initialFen, table.concat(moveHistory, " "))
	end

	local squareMoveFrom: number?

	local function playMove(moveNotation)
		pieceMoveSound:Play()

		table.insert(moveHistory, moveNotation)

		Board.makeMove(state, moveNotation, function(squareMoveFrom, squareMoveTo)
			labels[squareMoveTo].Image = labels[squareMoveFrom].Image
			labels[squareMoveFrom].Image = ""
		end, function(promotionSquare, promoteInto)
			labels[promotionSquare].Image = Config.PIECE_TEXTURES[promoteInto]
		end, function(captureSquare)
			labels[captureSquare].Image = ""
		end)

		resetLabels()

		fenBox.Text = Board.toFEN(state)
	end

	local undoButton = makeButton("Undo")
	undoButton.Position = UDim2.fromScale(0.75, 0.9)
	undoButton.Text = "Undo"
	undoButton.FontFace = Config.FONT
	undoButton.Activated:Connect(function()
		assert(#moveHistory % 2 == 0, "Incomplete turn")
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
			label.Image = Config.PIECE_TEXTURES[piece] or ""
		end
		resetLabels()
	end)
	undoButton.Parent = gui

	local function getAIResponse()
		local result = Engine.getBestMove(initialFen, table.concat(moveHistory, " "), function(evaluation)
			evalBar.Visible = true
			local blackEvaluation = if state.whiteToPlay then -evaluation else evaluation
			blackEvalFill.Size = UDim2.fromScale(1, 0.5 + blackEvaluation / 1800)
			waitForRender()
		end, aiMoveTimeInMilliseconds)
		return result
	end

	local aiSelfPlayButton = makeButton("AISelfPlay")
	aiSelfPlayButton.Position = UDim2.fromScale(0.75, 0.8)
	aiSelfPlayButton.Text = "AI vs AI"
	aiSelfPlayButton.FontFace = Config.FONT
	local aiSelfPlaying = false
	aiSelfPlayButton.Activated:Connect(function()
		sideOfHuman = nil
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
		for squareMoveTo, label in labels do
			if
				label.AbsolutePosition.X <= input.Position.X
				and input.Position.X <= label.AbsolutePosition.X + label.AbsoluteSize.X
				and label.AbsolutePosition.Y <= input.Position.Y
				and input.Position.Y <= label.AbsolutePosition.Y + label.AbsoluteSize.Y
			then
				return squareMoveTo, label
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
		button.Name = Notation.PIECE_ENUM_TO_NAME[piece - pieceColourOffset]
		button.Image = Config.PIECE_TEXTURES[piece]
		button.Size = UDim2.fromScale(1 / 4, 1)
		button.Position = UDim2.fromScale((piece - 2 - pieceColourOffset) / 4, 0)
		button.Parent = promotionFrame

		promotionButtons[button] = Notation.PIECE_ENUM_TO_NAME[piece - pieceColourOffset]
	end
	constrain(promotionFrame, 4)
	promotionFrame.Position = UDim2.fromScale(0.03, 0.3)
	promotionFrame.Size = UDim2.fromScale(0.2, 0.2)
	promotionFrame.Visible = false
	promotionFrame.Parent = gui

	local function tryAskPromotion(squareMoveTo)
		local thread = coroutine.running()

		local found = false
		Engine.getLegalMoves(function(legalMove)
			if found then
				return
			end

			local legalMoveFrom = Notation.uciFrom(legalMove)
			if legalMoveFrom ~= squareMoveFrom then
				return
			end

			local legalMoveTo = Notation.uciTo(legalMove)
			if legalMoveTo ~= squareMoveTo then
				return
			end

			found = true

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
		end, initialFen, table.concat(moveHistory, " "))

		return coroutine.yield()
	end

	local function humanMadeMove(input)
		local squareMoveTo = getHoveringSquare(input)
		if not squareMoveTo then
			return
		end
		if squareMoveFrom == squareMoveTo then
			return
		end

		local notation = Notation.SQUARE_NUMBER_TO_NAME[unneeded_assert(squareMoveFrom)]
			.. Notation.SQUARE_NUMBER_TO_NAME[squareMoveTo]
		local isPromotionRank = buffer.readu8(state.board, unneeded_assert(squareMoveFrom)) == 1 + pieceColourOffset
			and (Notation.squareRank(squareMoveTo) == 0 or Notation.squareRank(squareMoveTo) == 7)
		if isPromotionRank then
			local promotion = tryAskPromotion(squareMoveTo)
			if promotion then
				notation ..= promotion
			else
				return
			end
		else
			local legal
			Engine.getLegalMoves(function(legalMove)
				if legalMove == notation then
					legal = true
				end
			end, initialFen, table.concat(moveHistory, " "))
			if not legal then
				return
			end
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
		dragEnd()

		pieceDragImage.Image = from.Image
		from.Image = ""

		pieceDragImage.Position = UDim2.fromOffset(position.X, position.Y)
		pieceDragImage.Visible = true
		draggedFrom = from
	end
	UserInputService.InputChanged:Connect(function(input)
		if state.whiteToPlay ~= sideOfHuman then
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
		if state.whiteToPlay ~= sideOfHuman then
			return
		end
		if
			input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end
		local hoveringSquare, label = getHoveringSquare(input)
		if not hoveringSquare or not label then
			return
		end
		local piece = buffer.readu8(state.board, hoveringSquare)
		if piece ~= 0 and if sideOfHuman then piece > 6 else 7 > piece then
			dragStart(input.Position, label)

			if hoveringSquare ~= squareMoveFrom then
				resetLabels()
				squareMoveFrom = hoveringSquare
				highlightLegalMoves(squareMoveFrom)
			end
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if state.whiteToPlay ~= sideOfHuman then
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
