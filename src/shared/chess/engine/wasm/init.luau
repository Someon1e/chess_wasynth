--!strict

local WASM = {}

local line = {}

local messageListener: (string) -> ...any? = print

local rust rust = require(script:WaitForChild("compiled"))({
	env = {
		func_list = {
			time = os.clock,
			print_string = function(pointer, length)
				messageListener(rust.rt.load.string(rust.memory_list.memory, pointer, length))
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

return table.freeze(WASM)
