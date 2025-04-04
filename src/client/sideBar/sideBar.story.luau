--!strict

local Fusion = require(script.Parent.Parent:WaitForChild("Fusion"))
local makeSideBar = require(script.Parent)
local makeUndoButton = require(script.Parent:WaitForChild("undoButton"))
local makeRotateButton = require(script.Parent:WaitForChild("rotateButton"))
local makeAIMoveTimeBox = require(script.Parent:WaitForChild("aiMoveTimeBox"))
local makeAISelfPlayButton = require(script.Parent:WaitForChild("aiSelfPlayButton"))
local makeOpeningLabel = require(script.Parent:WaitForChild("openingLabel"))
local makeFenBox = require(script.Parent:WaitForChild("fenBox"))

return function(parent)
	local scope = Fusion.scoped({
		New = Fusion.New,
		Hydrate = Fusion.Hydrate,
	})

	local sideBar = makeSideBar(scope, parent)
	makeUndoButton(scope, sideBar)
	makeRotateButton(scope, sideBar)
	makeAISelfPlayButton(scope, sideBar)
	makeAIMoveTimeBox(scope, sideBar)
	makeOpeningLabel(scope, sideBar)
	makeFenBox(scope, sideBar)

	return function()
		Fusion.doCleanup(scope)
	end
end
