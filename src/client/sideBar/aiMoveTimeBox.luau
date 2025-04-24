local Fusion = require(script.Parent.Parent:WaitForChild("Fusion"))
local baseLabel = require(script.Parent.Parent:WaitForChild("baseLabel"))
local baseBox = require(script.Parent.Parent:WaitForChild("baseBox"))

return function(scope, parent)
	local aiMoveTimeBox = scope:Hydrate(baseBox(scope, parent))({
		Name = "AIMoveTime",
		Size = UDim2.fromScale(0.4, 0.4),
		ClearTextOnFocus = false,
		ZIndex = 2,
		Position = UDim2.fromScale(0.75, 0.7),

		[Fusion.Children] = {
			scope:New("UIAspectRatioConstraint")({
				AspectRatio = 3,
			}),
		},
	})

	scope:Hydrate(baseLabel(scope, aiMoveTimeBox))({
		Text = "AI Move Time",
		Size = UDim2.fromScale(1, 0.5),
		Position = UDim2.fromScale(0.5, 1.2),
	})

	return aiMoveTimeBox
end
