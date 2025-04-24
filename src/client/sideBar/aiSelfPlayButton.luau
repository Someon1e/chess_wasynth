--!strict

local baseButton = require(script.Parent.Parent:WaitForChild("baseButton"))

return function(scope, parent)
	return scope:Hydrate(baseButton(scope, parent))({
		Name = "AISelfPlayButton",
		Position = UDim2.fromScale(0.25, 0.71),
		Text = "AI vs AI",
	})
end
