--!strict

local WASM = require(script:WaitForChild("wasm"))

local Engine = {}

local Signal = require(script:WaitForChild("LemonSignal"))
local inputSignal = Signal.new()
local outputSignal = Signal.new()

local function setListener(listener)
	if listener then
		WASM.setListener(function(output)
			outputSignal:Fire(output)
			listener(output)
		end)
	else
		WASM.setListener(function(output)
			outputSignal:Fire(output)
		end)
	end
end

function Engine.send(input)
	inputSignal:Fire(input)
	WASM.sendInput(input)
end

function Engine.perft(out, fen: string, moves, depth)
	-- https://www.chessprogramming.org/Perft
	local moveCount

	setListener(function(output)
		local prefix, suffix = string.match(output, "(.+): (%d+)")
		if prefix == "Nodes searched" then
			moveCount = tonumber(suffix)
			setListener(nil)
		elseif prefix then
			out(prefix, suffix)
		end
	end)
	Engine.send("position fen " .. fen .. " moves " .. moves)
	Engine.send("go perft " .. tostring(depth))

	return assert(moveCount)
end

function Engine.setOptionValue(option, value)
	Engine.send("setoption name " .. option .. " value " .. value)
end

function Engine.uci(listener)
	-- TODO: parsing UCI output
	setListener(listener)
	Engine.send("uci")
end

function Engine.getLegalMoves(out, fen: string, moves: string)
	setListener(function(output)
		local prefix = string.match(output, "(.+):")
		if prefix == "Nodes searched" then
			setListener(nil)
		elseif prefix then
			out(prefix)
		end
	end)
	Engine.send("position fen " .. fen .. " moves " .. moves)
	Engine.send("go perft 1")
end

function Engine.getBestMove(initialFen: string, moves, updateEval: (mate: boolean, number) -> (), aiMoveTime)
	local result: string?
	setListener(function(output)
		local move = string.match(output, "bestmove ([^ ]+)")
		if move then
			result = if move == "0000" then nil else move
			setListener(nil)
		else
			local eval = tonumber(string.match(output, "cp ([^ ]+)"))
			if eval then
				updateEval(false, eval)
			else
				local mate = tonumber(string.match(output, "mate ([^ ]+)"))
				if mate then
					updateEval(true, mate)
				end
			end
		end
	end)
	Engine.send("position fen " .. initialFen .. " moves " .. moves)
	Engine.send("go movetime " .. tostring(aiMoveTime))

	return result
end

function Engine.watchOutput(callback)
	return outputSignal:Connect(callback)
end
function Engine.watchInput(callback)
	return inputSignal:Connect(callback)
end

return table.freeze(Engine)
