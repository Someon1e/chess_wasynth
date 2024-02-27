--!strict

local Config = {}

local Notation =
	require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("chess"):WaitForChild("notation"))

Config.DEFAULT_AI_MOVE_TIME_IN_MILLISECONDS = 2000

Config.LIGHT_SQUARE_COLOUR, Config.DARK_SQUARE_COLOUR = Color3.fromRGB(234, 233, 210), Color3.fromRGB(75, 115, 153)

Config.CAN_MOVE_TO_SQUARE_COLOUR = Color3.fromRGB(100, 100, 100)
Config.CAN_CAPTURE_SQUARE_COLOUR = Color3.fromRGB(255, 0, 0)

Config.PIECE_TEXTURES = {
	[Notation.BLACK_PAWN] = "rbxassetid://7079123026",
	[Notation.BLACK_ROOK] = "rbxassetid://7079118362",
	[Notation.BLACK_KNIGHT] = "rbxassetid://7079123704",
	[Notation.BLACK_BISHOP] = "rbxassetid://7079124677",
	[Notation.BLACK_QUEEN] = "rbxassetid://7079118808",
	[Notation.BLACK_KING] = "rbxassetid://7079124193",

	[Notation.WHITE_PAWN] = "rbxassetid://7079118994",
	[Notation.WHITE_ROOK] = "rbxassetid://7079116513",
	[Notation.WHITE_KNIGHT] = "rbxassetid://7079123407",
	[Notation.WHITE_BISHOP] = "rbxassetid://7079124389",
	[Notation.WHITE_QUEEN] = "rbxassetid://7079118641",
	[Notation.WHITE_KING] = "rbxassetid://7079123896",
}

Config.PIECE_MOVE_SOUND = "rbxassetid://6308606116"

return table.freeze(Config)
