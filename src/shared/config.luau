--!strict

local Config = {}

Config.DEFAULT_AI_MOVE_TIME_IN_MILLISECONDS = 3000

Config.LIGHT_SQUARE_COLOUR, Config.DARK_SQUARE_COLOUR = Color3.fromRGB(234, 233, 210), Color3.fromRGB(75, 115, 153)

Config.CAN_MOVE_TO_SQUARE_COLOUR = Color3.fromRGB(255, 85, 0)
Config.CAN_CAPTURE_SQUARE_COLOUR = Color3.fromRGB(255, 0, 0)

Config.WHITE_PAWN = 7
Config.BLACK_PAWN = 1
Config.WHITE_KING = 12
Config.BLACK_KING = 6
Config.PIECE_TEXTURES = {
	[Config.BLACK_PAWN] = "rbxassetid://7079123026",
	[2] = "rbxassetid://7079118362",
	[3] = "rbxassetid://7079123704",
	[4] = "rbxassetid://7079124677",
	[5] = "rbxassetid://7079118808",
	[Config.BLACK_KING] = "rbxassetid://7079124193",

	[Config.WHITE_PAWN] = "rbxassetid://7079118994",
	[8] = "rbxassetid://7079116513",
	[9] = "rbxassetid://7079123407",
	[10] = "rbxassetid://7079124389",
	[11] = "rbxassetid://7079118641",
	[Config.WHITE_KING] = "rbxassetid://7079123896",
}

Config.PIECE_ENUM_TO_NAME = {
	[Config.BLACK_PAWN] = "p",
	[2] = "r",
	[3] = "n",
	[4] = "b",
	[5] = "q",
	[Config.BLACK_KING] = "k",

	[Config.WHITE_PAWN] = "P",
	[8] = "R",
	[9] = "N",
	[10] = "B",
	[11] = "Q",
	[Config.WHITE_KING] = "K",
}
Config.PIECE_NAME_TO_ENUM = {
	p = Config.BLACK_PAWN,
	r = 2,
	n = 3,
	b = 4,
	q = 5,
	k = Config.BLACK_KING,

	P = Config.WHITE_PAWN,
	R = 8,
	N = 9,
	B = 10,
	Q = 11,
	K = Config.WHITE_KING,
}

return table.freeze(Config)