--!strict

local baseButton = require(script.Parent.Parent:WaitForChild("baseButton"))

return function(scope, parent)
	return scope:Hydrate(baseButton(scope, parent))({
		Position = UDim2.fromScale(0.25, 0.87),
		Name = "Undo",
		Text = "Undo",
	})
end
