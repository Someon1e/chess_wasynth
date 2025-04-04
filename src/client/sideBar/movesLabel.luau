local Fusion = require(script.Parent.Parent:WaitForChild("Fusion"))
local baseLabel = require(script.Parent:WaitForChild("baseLabel"))

return function(scope, parent)
	-- TODO: make each move a separate button

	return scope:Hydrate(baseLabel(scope, parent))({
		Name = "Moves",
		Size = UDim2.fromScale(0.9, 0.2),
		ZIndex = 2,
		Position = UDim2.fromScale(0.5, 0.25),

		[Fusion.Children] = scope:New("UIAspectRatioConstraint")({
			AspectRatio = 9,
		}),
	})
end
