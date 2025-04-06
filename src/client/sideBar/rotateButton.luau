--!strict

local baseButton = require(script.Parent:WaitForChild("baseButton"))

return function(scope, parent)
	return scope:Hydrate(baseButton(scope, parent))({
		Text = "Rotate",
		Position = UDim2.fromScale(0.75, 0.87),
	})
end
