local Fusion = require(script.Parent:WaitForChild("Fusion"))
local Config = require(script.Parent:WaitForChild("config"))

return function(scope, parent)
	return scope:New("TextButton")({
		TextScaled = true,
		Size = UDim2.fromScale(0.38, 0.12),
		BackgroundColor3 = Config.SECONDARY_BACKGROUND_COLOUR,
		TextColor3 = Color3.fromRGB(232, 232, 232),
		AnchorPoint = Vector2.new(0.5, 0.5),

		[Fusion.Children] = scope:New("UIAspectRatioConstraint")({
			AspectRatio = 2.2,
		}),

		FontFace = Config.FONT,

		Parent = parent,
	})
end
