local Config = require(script.Parent:WaitForChild("config"))

return function(scope, parent)
	return scope:New("TextBox")({
		TextScaled = true,
		BackgroundColor3 = Config.SECONDARY_BACKGROUND_COLOUR,
		TextColor3 = Color3.fromRGB(232, 232, 232),
		AnchorPoint = Vector2.new(0.5, 0.5),

		FontFace = Config.FONT,

		Parent = parent,
	})
end
