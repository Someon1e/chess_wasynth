game:GetService("StarterGui"):SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)

local UserInputService = game:GetService("UserInputService")

local Config = require(script:WaitForChild("config"))

local chess = game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("chess")
local Engine = require(chess:WaitForChild("engine"))
local Notation = require(chess:WaitForChild("notation"))
local Board = require(chess:WaitForChild("board"))

local Fusion = require(script:WaitForChild("Fusion"))
local scope = Fusion.scoped({
	New = Fusion.New,
	Value = Fusion.Value,
	Hydrate = Fusion.Hydrate,
	Computed = Fusion.Computed,
})

local playerGui = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")

local pieceMoveSound = scope:New("Sound")({
	SoundId = Config.PIECE_MOVE_SOUND,
	Parent = workspace,
})

-- Only used because the type checker is wrong
local unneeded_assert = assert

local function makeBoardFrame(startCorner)
	return scope:New("Frame")({
		Name = "Board",
		Size = UDim2.fromScale(0.85, 0.85),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),

		[Fusion.Children] = {
			scope:New("UIAspectRatioConstraint")({
				AspectRatio = 1,
			}),
			scope:New("UIGridLayout")({
				CellSize = UDim2.fromScale(1 / 8, 1 / 8),
				CellPadding = UDim2.fromScale(0, 0),
				SortOrder = Enum.SortOrder.LayoutOrder,
				StartCorner = startCorner,
			}),
		},
	})
end
local function makeSquareGui(parent, state)
	local labels = table.create(63)
	for y = 7, 0, -1 do
		for x = 0, 7 do
			local number = x + y * 8

			local piece = buffer.readu8(state.board, number)

			local active = scope:Value(piece ~= 0)

			local image = scope:Value(Config.PIECE_TEXTURES[piece] or "")
			labels[number] = table.freeze({
				label = scope:New("ImageLabel")({
					LayoutOrder = number,
					Name = Notation.SQUARE_NUMBER_TO_NAME[number],
					BackgroundColor3 = if (y + x) % 2 == 0
						then Config.DARK_SQUARE_COLOUR
						else Config.LIGHT_SQUARE_COLOUR,
					Image = image,
					BorderSizePixel = 0,
					Active = active,

					[Fusion.Children] = scope:New("TextLabel")({
						ZIndex = 2,
						Text = Notation.SQUARE_NUMBER_TO_NAME[number],
						FontFace = Config.FONT,
						TextScaled = true,
						Size = UDim2.fromScale(0.2, 0.2),
						Position = UDim2.fromScale(0.7, 0.8),
						BackgroundTransparency = 1,
					}),

					Parent = parent,
				}),
				active = active,
				image = image,
			})
		end
	end
	return labels
end

local function makeEvalBar(evalScale, visible)
	return scope:New("Frame")({
		Name = "Evaluation",
		ClipsDescendants = true,
		Size = UDim2.fromScale(0.02, 0.8),
		BackgroundColor3 = Color3.fromRGB(255, 255, 255),
		Position = UDim2.fromScale(0.2, 0.1),
		ZIndex = 2,
		Visible = visible,

		[Fusion.Children] = scope:New("Frame")({
			Size = scope:Computed(function(use)
				return UDim2.fromScale(1, use(evalScale))
			end),
			BackgroundColor3 = Color3.fromRGB(0, 0, 0),
			Position = UDim2.fromScale(0, 0),
			ZIndex = 2,
		}),
	})
end

local function makeButton(name)
	local button = scope:New("TextButton")({
		TextScaled = true,
		Size = UDim2.fromScale(0.07, 0.07),
		BackgroundColor3 = Color3.fromRGB(0, 0, 30),
		TextColor3 = Color3.fromRGB(232, 232, 232),
		Name = name,

		[Fusion.Children] = scope:New("UIAspectRatioConstraint")({
			AspectRatio = 2,
		}),
	})

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

	local startCorner = scope:Value(Enum.StartCorner.BottomLeft)

	local boardFrame = makeBoardFrame(startCorner)
	local labels = makeSquareGui(boardFrame, state)

	local usedCircles, unusedCircles = table.create(27), table.create(27)
	do
		for index = 1, 27 do
			local parent = scope:Value(nil)
			local color = scope:Value(Color3.fromRGB())
			scope:New("Frame")({
				Name = "Circle",
				Size = UDim2.fromScale(0.4, 0.4),
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				BackgroundTransparency = 0.5,
				BackgroundColor3 = color,

				Parent = parent,

				[Fusion.Children] = scope:New("UICorner")({
					CornerRadius = UDim.new(1),
				}),
			})
			unusedCircles[index] = table.freeze({ parent = parent, color = color })
		end
	end

	local function resetLabels()
		for y = 7, 0, -1 do
			for x = 0, 7 do
				local label = labels[x + y * 8]
				label.active:set(buffer.readu8(state.board, x + y * 8) ~= 0)
			end
		end
		for _, circle in usedCircles do
			circle.parent:set(nil)
			table.insert(unusedCircles, circle)
		end
		table.clear(usedCircles)
	end

	local evalBarVisible = scope:Value(false)

	local rotateButton = makeButton("Rotate")
	scope:Hydrate(rotateButton)({
		Text = "Rotate",
		FontFace = Config.FONT,
		Position = UDim2.fromScale(0.85, 0.9),

		[Fusion.OnEvent("Activated")] = function()
			if Fusion.peek(startCorner) == Enum.StartCorner.BottomLeft then
				startCorner:set(Enum.StartCorner.TopRight)
			else
				startCorner:set(Enum.StartCorner.BottomLeft)
			end
		end,
	})

	local fenBox = scope:New("TextBox")({
		Name = "FEN",
		Text = initialFen,
		FontFace = Config.FONT,
		TextScaled = true,
		Size = UDim2.fromScale(0.2, 0.06),
		ClearTextOnFocus = false,
		ZIndex = 2,
		BackgroundColor3 = Color3.fromRGB(0, 0, 30),
		TextColor3 = Color3.fromRGB(232, 232, 232),
		Position = UDim2.fromScale(0.75, 0.5),

		[Fusion.Children] = scope:New("UIAspectRatioConstraint")({
			AspectRatio = 6,
		}),
	})
	fenBox.FocusLost:Connect(function()
		local isValid, newState = pcall(Board.fromFEN, fenBox.Text)
		if not isValid then
			warn("Invalid FEN")
			fenBox.Text = initialFen
			return
		end
		evalBarVisible:set(false)
		state = newState
		initialFen = Board.toFEN(state)
		fenBox.Text = initialFen
		sideOfHuman = state.whiteToPlay
		table.clear(moveHistory)
		table.clear(stateHistory)
		for square, label in labels do
			local piece = buffer.readu8(state.board, square)
			label.image:set(Config.PIECE_TEXTURES[piece] or "")
		end
		resetLabels()
	end)

	local aiMoveTimeInMilliseconds = Config.DEFAULT_AI_MOVE_TIME_IN_MILLISECONDS

	local aiMoveTimeBox
	aiMoveTimeBox = scope:New("TextBox")({
		Name = "AIMoveTime",
		Text = tostring(aiMoveTimeInMilliseconds),
		FontFace = Config.FONT,
		TextScaled = true,
		Size = UDim2.fromScale(0.07, 0.07),
		ClearTextOnFocus = false,
		ZIndex = 2,
		BackgroundColor3 = Color3.fromRGB(0, 0, 30),
		TextColor3 = Color3.fromRGB(232, 232, 232),
		Position = UDim2.fromScale(0.85, 0.797),

		[Fusion.Children] = {
			scope:New("TextLabel")({
				Text = "AI Move Time",
				FontFace = Config.FONT,
				TextScaled = true,
				Size = UDim2.fromScale(0.6, 0.5),
				Position = UDim2.fromScale(0, 1.1),
				BackgroundColor3 = Color3.fromRGB(0, 0, 30),
				TextColor3 = Color3.fromRGB(232, 232, 232),
			}),
			scope:New("UIAspectRatioConstraint")({
				AspectRatio = 3,
			}),
		},

		[Fusion.OnEvent("FocusLost")] = function()
			local number = tonumber(aiMoveTimeBox.Text)
			if number then
				aiMoveTimeInMilliseconds = math.clamp(number, 100, 10000)
			end
			aiMoveTimeBox.Text = tostring(aiMoveTimeInMilliseconds)
		end,
	})

	local function highlightLegalMoves(from)
		Engine.getLegalMoves(function(legalMove)
			local legalMoveFrom = Notation.uciFrom(legalMove)
			if legalMoveFrom ~= from then
				return
			end

			local legalMoveTo = Notation.uciTo(legalMove)

			local circle = assert(table.remove(unusedCircles), "Exceeded piece max possible moves")
			if buffer.readu8(state.board, legalMoveTo) ~= 0 then
				circle.color:set(Config.CAN_CAPTURE_SQUARE_COLOUR)
			else
				circle.color:set(Config.CAN_MOVE_TO_SQUARE_COLOUR)
			end
			circle.parent:set(labels[legalMoveTo].label)
			table.insert(usedCircles, circle)

			labels[legalMoveTo].active:set(true)
		end, initialFen, table.concat(moveHistory, " "))
	end

	local squareMoveFrom: number?

	local function playMove(moveNotation)
		pieceMoveSound:Play()

		table.insert(moveHistory, moveNotation)

		Board.makeMove(state, moveNotation, function(squareMoveFrom, squareMoveTo)
			labels[squareMoveTo].image:set(Fusion.peek(labels[squareMoveFrom].image))
			labels[squareMoveFrom].image:set("")
		end, function(promotionSquare, promoteInto)
			labels[promotionSquare].image:set(Config.PIECE_TEXTURES[promoteInto])
		end, function(captureSquare)
			labels[captureSquare].image:set("")
		end)

		resetLabels()

		fenBox.Text = Board.toFEN(state)
	end

	local undoButton = makeButton("Undo")
	scope:Hydrate(undoButton)({
		Position = UDim2.fromScale(0.75, 0.9),
		Text = "Undo",
		FontFace = Config.FONT,

		[Fusion.OnEvent("Activated")] = function()
			assert(#moveHistory % 2 == 0, "Incomplete turn")
			local prevState = table.remove(stateHistory)
			if not prevState then
				return
			end

			state = prevState
			evalBarVisible:set(false)
			table.remove(moveHistory)
			table.remove(moveHistory)
			for square, label in labels do
				local piece = buffer.readu8(state.board, square)
				label.Image = Config.PIECE_TEXTURES[piece] or ""
			end
			resetLabels()
			fenBox.Text = Board.toFEN(state)
		end,
	})

	local evalScale = scope:Value(0.5)

	local function getAIResponse()
		local result = Engine.getBestMove(initialFen, table.concat(moveHistory, " "), function(mate, evaluation)
			evalBarVisible:set(true)
			if mate then
				if evaluation ~= 0 then
					local engineIsMating = if evaluation > 0 then 1 else 0
					evalScale:set(if state.whiteToPlay then -engineIsMating else engineIsMating)
				end
			else
				local blackEvaluation = if state.whiteToPlay then -evaluation else evaluation
				evalScale:set(0.5 + blackEvaluation / 1800)
			end
			waitForRender()
		end, aiMoveTimeInMilliseconds)
		return result
	end

	local aiSelfPlayButton = makeButton("AISelfPlay")
	local aiSelfPlaying = scope:Value(false)
	scope:Hydrate(aiSelfPlayButton)({
		Position = UDim2.fromScale(0.75, 0.8),
		Text = "AI vs AI",
		FontFace = Config.FONT,
		TextColor3 = scope:Computed(function(use)
			return if use(aiSelfPlaying) then Config.BUTTON_ENABLED_COLOUR else Config.BUTTON_DISABLED_COLOUR
		end),

		[Fusion.OnEvent("Activated")] = function()
			sideOfHuman = nil
			aiSelfPlaying:set(not Fusion.peek(aiSelfPlaying))

			while Fusion.peek(aiSelfPlaying) do
				local move = getAIResponse()
				if not move then
					break
				end
				playMove(move)
			end

			sideOfHuman = state.whiteToPlay
		end,
	})

	local function getHoveringSquare(input): (number?, ImageLabel?)
		for squareMoveTo, labelInfo in labels do
			local label = labelInfo.label
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

	local promotionFrame = scope:New("Frame")({
		Name = "Promotion",
		Position = UDim2.fromScale(0.03, 0.3),
		Size = UDim2.fromScale(0.2, 0.2),
		Visible = false,

		[Fusion.Children] = scope:New("UIAspectRatioConstraint")({
			AspectRatio = 4,
		}),
	})
	local promotionButtons = {}
	local pieceColourOffset = if state.whiteToPlay then 6 else 0
	for piece = 2 + pieceColourOffset, 5 + pieceColourOffset do
		local button = scope:New("ImageButton")({
			Name = Notation.PIECE_ENUM_TO_NAME[piece - pieceColourOffset],
			Image = Config.PIECE_TEXTURES[piece],
			Size = UDim2.fromScale(1 / 4, 1),
			Position = UDim2.fromScale((piece - 2 - pieceColourOffset) / 4, 0),
			Parent = promotionFrame,
		})
		promotionButtons[button] = Notation.PIECE_ENUM_TO_NAME[piece - pieceColourOffset]
	end

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
	local pieceDragImage = scope:New("ImageLabel")({
		Name = "Drag",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),

		Size = UDim2.fromOffset(boardFrame.AbsoluteSize.X / 8, boardFrame.AbsoluteSize.Y / 8),
		ZIndex = 3,
	})
	boardFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		pieceDragImage.Size = UDim2.fromOffset(boardFrame.AbsoluteSize.X / 8, boardFrame.AbsoluteSize.Y / 8)
	end)

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

	scope:New("ScreenGui")({
		Name = "Chess",

		Parent = playerGui,

		[Fusion.Children] = {
			boardFrame,
			makeEvalBar(evalScale, evalBarVisible),
			rotateButton,
			fenBox,
			pieceDragImage,
			aiMoveTimeBox,
			promotionFrame,
			undoButton,
			aiSelfPlayButton,
		},
	})
end

Engine.uci(print)
Engine.setOptionValue("Hash", "16")
makeGui("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
