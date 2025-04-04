local Fusion = require(script.Parent.Parent:WaitForChild("Fusion"))
local baseBox = require(script.Parent:WaitForChild("baseBox"))

return function(scope, parent)
	return scope:Hydrate(baseBox(scope, parent))({
		Name = "FEN",
		Size = UDim2.fromScale(0.9, 0.07),
		ClearTextOnFocus = false,
		ZIndex = 2,
		Position = UDim2.fromScale(0.5, 0.37),

		[Fusion.Children] = scope:New("UIAspectRatioConstraint")({
			AspectRatio = 9,
		}),
	})
end
