--!strict

local WASM = {}

local line = {}

local messageListener: (string) -> ...any? = print

local rust = require(script:WaitForChild("compiled"))({
	env = {
		func_list = {
			time = os.clock,
			print_char = function(byte)
				local character = string.char(byte)
				if character == "\n" then
					messageListener(table.concat(line))
					table.clear(line)
					return
				end
				table.insert(line, character)
			end,
		},
	},
})

function WASM.sendInput(input)
	for i = 1, #input do
		local character = string.byte(input, i, i)
		rust.func_list.send_input(character)
	end
	rust.func_list.send_input(string.byte("\n"))
end

function WASM.setListener(newMessageListener)
	messageListener = newMessageListener
end

return WASM
