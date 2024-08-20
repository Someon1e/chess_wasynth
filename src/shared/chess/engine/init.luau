--!strict

local WASM = require(script:WaitForChild("wasm"))

local Engine = {}

function Engine.perft(out, fen: string, moves, depth)
	-- https://www.chessprogramming.org/Perft
	local moveCount

	WASM.setListener(function(output)
		local prefix, suffix = string.match(output, "(.+): (%d+)")
		if prefix == "Nodes searched" then
			moveCount = tonumber(suffix)
			WASM.setListener(print)
		elseif prefix then
			out(prefix, suffix)
		end
	end)
	WASM.sendInput("position fen " .. fen .. " moves " .. moves)
	WASM.sendInput("go perft " .. tostring(depth))

	return assert(moveCount)
end

function Engine.setOptionValue(option, value)
	WASM.sendInput("setoption name " .. option .. " value " .. value)
end

function Engine.uci(listener)
	-- TODO: parsing UCI output
	WASM.setListener(listener)
	WASM.sendInput("uci")
end

function Engine.getLegalMoves(out, fen: string, moves: string)
	WASM.setListener(function(output)
		local prefix = string.match(output, "(.+):")
		if prefix == "Nodes searched" then
			WASM.setListener(print)
		elseif prefix then
			out(prefix)
		end
	end)
	WASM.sendInput("position fen " .. fen .. " moves " .. moves)
	WASM.sendInput("go perft 1")
end

function Engine.getBestMove(initialFen: string, moves, updateEval: (mate: boolean, number) -> (), aiMoveTime)
	local result: string?
	WASM.setListener(function(output)
		print(output)

		local move = string.match(output, "bestmove (.+)")
		if move then
			result = if move == "0000" then nil else move
			WASM.setListener(print)
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
	WASM.sendInput("position fen " .. initialFen .. " moves " .. moves)
	WASM.sendInput("go movetime " .. tostring(aiMoveTime))

	return result
end

return table.freeze(Engine)
