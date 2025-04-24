local Fusion = require(script.Parent.Parent:WaitForChild("Fusion"))
local baseBox = require(script.Parent.Parent:WaitForChild("baseBox"))

return function(scope, parent)
	return scope:Hydrate(baseBox(scope, parent))({
		Name = "FEN",
		Size = UDim2.fromScale(0.9, 0.1),
		ClearTextOnFocus = false,
		ZIndex = 2,
		Position = UDim2.fromScale(0.5, 0.52),

		[Fusion.Children] = scope:New("UIAspectRatioConstraint")({
			AspectRatio = 6,
		}),
	})
end
