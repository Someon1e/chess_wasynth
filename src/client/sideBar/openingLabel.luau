local Fusion = require(script.Parent.Parent:WaitForChild("Fusion"))
local baseLabel = require(script.Parent:WaitForChild("baseLabel"))

return function(scope, parent)
	return scope:Hydrate(baseLabel(scope, parent))({
		Name = "Opening",
		Size = UDim2.fromScale(0.9, 0.08),
		ZIndex = 2,
		Position = UDim2.fromScale(0.5, 0.2),

		[Fusion.Children] = scope:New("UIAspectRatioConstraint")({
			AspectRatio = 9,
		}),
	})
end
