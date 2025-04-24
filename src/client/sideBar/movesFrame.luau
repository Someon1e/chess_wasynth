local Fusion = require(script.Parent.Parent:WaitForChild("Fusion"))
local baseLabel = require(script.Parent.Parent:WaitForChild("baseLabel"))
local Config = require(script.Parent.Parent:WaitForChild("config"))

return function(scope, parent, moves)
	return scope:New("ScrollingFrame")({
		Name = "Moves",
		Size = UDim2.fromScale(0.85, 0.3),
		ZIndex = 2,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.27),
		AutomaticCanvasSize = Enum.AutomaticSize.XY,
		BackgroundColor3 = Config.SECONDARY_BACKGROUND_COLOUR,
		CanvasSize = UDim2.fromScale(0, 0),
		Parent = parent,

		[Fusion.Children] = {
			scope:New("UIGridLayout")({
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				FillDirectionMaxCells = 2,
				CellSize = UDim2.fromScale(0.45, 0.28),
			}),

			scope:ForValues(moves, function(_, _, value)
				return scope:Hydrate(baseLabel(scope, parent))({
					BorderSizePixel = 1,
					Name = "Move",
					Text = value,
					ZIndex = 2,

					[Fusion.Children] = scope:New("UIAspectRatioConstraint")({
						AspectRatio = 2.4,
					}),
				})
			end),
		},
	})
end
