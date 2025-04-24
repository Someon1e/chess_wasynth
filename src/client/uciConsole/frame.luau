--!strict

local Fusion = require(script.Parent.Parent:WaitForChild("Fusion"))
local Config = require(script.Parent.Parent:WaitForChild("config"))
local baseBox = require(script.Parent.Parent:WaitForChild("baseBox"))
local baseLabel = require(script.Parent.Parent:WaitForChild("baseLabel"))
local baseButton = require(script.Parent.Parent:WaitForChild("baseButton"))

return function(scope, parent, canvasSizeY, padding)
	local scroll = scope:New("ScrollingFrame")({
		CanvasSize = scope:Computed(function(use)
			return UDim2.fromOffset(0, use(canvasSizeY))
		end),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.52),
		Size = UDim2.fromScale(0.96, 0.72),
		BackgroundColor3 = Config.PRIMARY_BACKGROUND_COLOUR,

		Parent = parent,

		[Fusion.Children] = {
			scope:New("UIListLayout")({
				Padding = UDim.new(0, padding),
			}),
		},
	})

	local title = scope:Hydrate(baseLabel(scope, nil))({
		Text = "UCI Console",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.25, 0.074),
		Size = UDim2.fromScale(0.3, 0.09),
		BackgroundColor3 = Config.SECONDARY_BACKGROUND_COLOUR,
	})
	local searchLabel = scope:Hydrate(baseLabel(scope, nil))({
		Text = "Search:",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.7, 0.074),
		Size = UDim2.fromScale(0.09, 0.09),
		BackgroundColor3 = Config.SECONDARY_BACKGROUND_COLOUR,
	})
	local searchBox = scope:Hydrate(baseBox(scope, nil))({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.85, 0.074),
		Size = UDim2.fromScale(0.2, 0.09),
		BackgroundColor3 = Config.SECONDARY_BACKGROUND_COLOUR,
	})
	local autoScrollButton = scope:Hydrate(baseButton(scope, nil))({
		Text = "Autoscroll",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.6, 0.074),
		Size = UDim2.fromScale(0.09, 0.09),
		BackgroundColor3 = Config.SECONDARY_BACKGROUND_COLOUR,
	})
	local sendBox = scope:Hydrate(baseBox(scope, nil))({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.925),
		Size = UDim2.fromScale(0.9, 0.06),
		BackgroundColor3 = Config.SECONDARY_BACKGROUND_COLOUR,
		TextXAlignment = Enum.TextXAlignment.Left,
		PlaceholderText = "Input command",
	})

	scope:New("Frame")({
		Name = "UCILog",

		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.7, 0.7),
		BackgroundColor3 = Config.PRIMARY_BACKGROUND_COLOUR,

		Parent = parent,

		[Fusion.Children] = {
			title,
			searchLabel,
			searchBox,
			autoScrollButton,
			scroll,
			sendBox,
			scope:New("UIDragDetector")({}),
		},
	})

	return scroll, autoScrollButton, searchBox, sendBox
end
