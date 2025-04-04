--!strict

local Fusion = require(script.Parent:WaitForChild("Fusion"))
local Config = require(script.Parent:WaitForChild("config"))

return function(scope, parent)
	local frame = scope:New("Frame")({
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromScale(0.2, 1),
		BackgroundColor3 = Config.PRIMARY_BACKGROUND_COLOUR,

		Parent = parent,

		[Fusion.Children] = {
			scope:New("Frame")({
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.new(1, 0, 0, 2),
				BackgroundColor3 = Config.SECONDARY_BACKGROUND_COLOUR,
			}),
		},
	})

	return frame
end
