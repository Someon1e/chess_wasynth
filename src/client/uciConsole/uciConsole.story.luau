--!strict

local Fusion = require(script.Parent.Parent:WaitForChild("Fusion"))
local makeUCIConsole = require(script.Parent)

return function(parent)
	local scope = Fusion.scoped({
		New = Fusion.New,
		Hydrate = Fusion.Hydrate,
		Value = Fusion.Value,
		Computed = Fusion.Computed,
		Observer = Fusion.Observer,
	})

	local logger = makeUCIConsole(scope, parent)
	logger.input("isready")
	logger.output("readyok")

	return function()
		Fusion.doCleanup(scope)
	end
end
