--!strict

local WASM = require(script:WaitForChild("wasm"))

local Engine = {}

function Engine.getLegalMoves(fen)
	-- Use perft to get legal moves
	-- https://chessprogrammingwiki.netlify.app/perft/

	local legalMoves: { string } = {}
	WASM.setListener(function(output)
		local prefix = string.match(output, "(.+):")
		if prefix == "Nodes searched" then
			WASM.setListener(print)
		elseif prefix then
			table.insert(legalMoves, prefix)
		end
	end)
	WASM.sendInput("position fen " .. fen)
	WASM.sendInput("go perft 1")

	return legalMoves
end

function Engine.getBestMove(initialFen: string, moves, updateEval, aiMoveTime)
	local result: string?
	WASM.setListener(function(output)
		print(output)

		local move = string.match(output, "bestmove (.+)")
		if move then
			result = if move == "a1a1" then nil else move
			WASM.setListener(print)
		else
			local eval = tonumber(string.match(output, "cp ([^ ]+)"))
			if not eval then
				return
			end
			updateEval(eval)
		end
	end)
	WASM.sendInput("position fen " .. initialFen .. " moves " .. moves)
	WASM.sendInput("go movetime " .. tostring(aiMoveTime))

	return result
end

return Engine