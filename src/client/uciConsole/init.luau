local TextService = game:GetService("TextService")
local RunService = game:GetService("RunService")

local makeUCIConsole = require(script:WaitForChild("frame"))
local baseBox = require(script.Parent:WaitForChild("baseBox"))
local Config = require(script.Parent:WaitForChild("config"))
local Fusion = require(script.Parent:WaitForChild("Fusion"))

local function label(scope, filter, colour, text, logFrame, frameWidth, canvasSizeY)
	local fontSize = 14
	local font = Config.MONOSPACE

	return scope:New("Frame")({
		ZIndex = 4,

		Visible = scope:Computed(function(use)
			local success, result = pcall(function()
				return string.find(text, use(filter)) ~= nil
			end)
			if success then
				return result
			end

			warn(result)
			return false
		end),

		Size = scope:Computed(function(use)
			local params = Instance.new("GetTextBoundsParams")
			params.Text = text
			params.Font = font
			params.Size = fontSize
			params.Width = use(frameWidth)

			local _, size = xpcall(function()
				return TextService:GetTextBoundsAsync(params).Y
			end, function()
				return 32
			end)

			return UDim2.new(1, 0, 0, size + 3)
		end),
		BackgroundColor3 = colour,

		Parent = logFrame,

		[Fusion.Children] = {
			scope:Hydrate(baseBox(scope, logFrame))({
				Text = text,
				TextSize = fontSize,
				TextEditable = false,
				TextWrapped = true,
				TextScaled = false,
				TextXAlignment = Enum.TextXAlignment.Left,
				FontFace = font,
				AnchorPoint = Vector2.new(1, 0.5),
				Size = UDim2.new(1, -5, 1, 0),
				Position = UDim2.fromScale(1, 0.5),
			}),
		},
	})
end

return function(scope, parent)
	local padding = 2
	local canvasSizeY = scope:Value(0)
	local logFrame, autoScrollButton, searchBox, sendBox = makeUCIConsole(scope, parent, canvasSizeY, padding)
	local labels = {}

	local frameWidth = scope:Value(logFrame.AbsoluteSize.X)
	RunService.PostSimulation:Connect(function()
		frameWidth:set(logFrame.AbsoluteSize.X)
	end)

	local autoScroll = true
	if autoScroll then
		autoScrollButton.TextColor3 = Config.BUTTON_ENABLED_COLOUR
	else
		autoScrollButton.TextColor3 = Config.BUTTON_DISABLED_COLOUR
	end
	scope:Hydrate(autoScrollButton)({
		[Fusion.OnEvent("Activated")] = function()
			autoScroll = not autoScroll
			if autoScroll then
				autoScrollButton.TextColor3 = Config.BUTTON_ENABLED_COLOUR
			else
				autoScrollButton.TextColor3 = Config.BUTTON_DISABLED_COLOUR
			end
		end,
	})

	local function recomputeCanvasSize()
		local newSize = 0
		for _, label in labels do
			newSize += label.AbsoluteSize.Y + padding
		end
		canvasSizeY:set(newSize)

		if autoScroll then
			logFrame.CanvasPosition = Vector2.new(logFrame.CanvasPosition.X, newSize + logFrame.AbsoluteSize.Y)
		end
	end

	scope:Observer(frameWidth):onChange(recomputeCanvasSize)

	local filter = scope:Value(searchBox.Text)
	scope:Hydrate(searchBox)({
		[Fusion.OnChange("Text")] = function(text)
			filter:set(text)
		end,
	})

	return sendBox,
		table.freeze({
			input = function(text)
				table.insert(
					labels,
					label(scope, filter, Color3.fromRGB(10, 10, 230), text, logFrame, frameWidth, canvasSizeY)
				)

				recomputeCanvasSize()
			end,
			output = function(text)
				table.insert(
					labels,
					label(scope, filter, Color3.fromRGB(10, 230, 10), text, logFrame, frameWidth, canvasSizeY)
				)

				recomputeCanvasSize()
			end,
		})
end
