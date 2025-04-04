--!strict

local baseButton = require(script.Parent:WaitForChild("baseButton"))

return function(scope, parent)
	return scope:Hydrate(baseButton(scope, parent))({
		Position = UDim2.fromScale(0.25, 0.9),
		Name = "Undo",
		Text = "Undo",
	})
end
