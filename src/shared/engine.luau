local Integer = (function()
	local Numeric = {}

	local NUM_ZERO, NUM_ONE, NUM_SIX_FOUR
	local NUM_BIT_26, NUM_BIT_52

	local bit_lshift = bit32.lshift
	local bit_rshift = bit32.rshift
	local bit_arshift = bit32.arshift

	local bit_and = bit32.band
	local bit_or = bit32.bor
	local bit_xor = bit32.bxor
	local bit_not = bit32.bnot

	local bit_extract = bit32.extract
	local bit_replace = bit32.replace

	local from_u32, from_u64, into_u64
	local num_subtract, num_divide_unsigned, num_negate
	local num_or, num_shift_left, num_shift_right_unsigned
	local num_is_negative, num_is_zero, num_is_less_unsigned

	-- X: a[0 ..21]
	-- Y: a[22..31]
	--  | b[0 ..11]
	-- Z: b[12..31]
	local constructor = Vector3.new

	function Numeric.from_u32(data_1, data_2)
		local x = bit_and(data_1, 0x3FFFFF)
		local y = bit_and(data_2, 0x3FFFFF)
		local z = bit_replace(bit_rshift(data_1, 22), bit_rshift(data_2, 22), 10, 10)

		return constructor(x, y, z)
	end

	local function load_d1(value)
		return bit_replace(bit_and(value.X, 0x3FFFFF), value.Z, 22, 10)
	end

	local function load_d2(value)
		return bit_replace(bit_and(value.Y, 0x3FFFFF), bit_rshift(value.Z, 10), 22, 10)
	end

	function Numeric.into_u32(value)
		return load_d1(value), load_d2(value)
	end

	function Numeric.from_u64(value)
		return from_u32(bit_and(value % 0x100000000), bit_and(value / 0x100000000))
	end

	function Numeric.into_u64(value)
		return load_d1(value) + load_d2(value) * 0x100000000
	end

	function Numeric.add(lhs, rhs)
		local data_1 = load_d1(lhs) + load_d1(rhs)
		local data_2 = load_d2(lhs) + load_d2(rhs)

		if data_1 >= 0x100000000 then
			data_1 = data_1 - 0x100000000
			data_2 = data_2 + 1
		end

		if data_2 >= 0x100000000 then
			data_2 = data_2 - 0x100000000
		end

		return from_u32(data_1, data_2)
	end

	function Numeric.subtract(lhs, rhs)
		local data_1 = load_d1(lhs) - load_d1(rhs)
		local data_2 = load_d2(lhs) - load_d2(rhs)

		if data_1 < 0 then
			data_1 = data_1 + 0x100000000
			data_2 = data_2 - 1
		end

		if data_2 < 0 then
			data_2 = data_2 + 0x100000000
		end

		return from_u32(data_1, data_2)
	end

	function Numeric.multiply(lhs, rhs)
		if num_is_zero(lhs) or num_is_zero(rhs) then
			return NUM_ZERO
		elseif num_is_less_unsigned(lhs, NUM_BIT_26) and num_is_less_unsigned(rhs, NUM_BIT_26) then
			return from_u64(load_d1(lhs) * load_d1(rhs))
		end

		-- Divide each long into 4 chunks of 16 bits, and then add up 4x4 products.
		-- We can skip products that would overflow.
		local lhs_1, lhs_2 = load_d1(lhs), load_d2(lhs)
		local rhs_1, rhs_2 = load_d1(rhs), load_d2(rhs)

		local a48 = bit_rshift(lhs_2, 16)
		local a32 = bit_and(lhs_2, 0xFFFF)
		local a16 = bit_rshift(lhs_1, 16)
		local a00 = bit_and(lhs_1, 0xFFFF)

		local b48 = bit_rshift(rhs_2, 16)
		local b32 = bit_and(rhs_2, 0xFFFF)
		local b16 = bit_rshift(rhs_1, 16)
		local b00 = bit_and(rhs_1, 0xFFFF)

		local c00 = a00 * b00
		local c16 = bit_rshift(c00, 16)

		c00 = bit_and(c00, 0xFFFF)
		c16 = c16 + a16 * b00

		local c32 = bit_rshift(c16, 16)

		c16 = bit_and(c16, 0xFFFF)
		c16 = c16 + a00 * b16
		c32 = c32 + bit_rshift(c16, 16)
		c16 = bit_and(c16, 0xFFFF)
		c32 = c32 + a32 * b00

		local c48 = bit_rshift(c32, 16)

		c32 = bit_and(c32, 0xFFFF)
		c32 = c32 + a16 * b16
		c48 = c48 + bit_rshift(c32, 16)
		c32 = bit_and(c32, 0xFFFF)
		c32 = c32 + a00 * b32
		c48 = c48 + bit_rshift(c32, 16)
		c32 = bit_and(c32, 0xFFFF)
		c48 = c48 + a48 * b00 + a32 * b16 + a16 * b32 + a00 * b48
		c48 = bit_and(c48, 0xFFFF)

		local data_1 = bit_replace(c00, c16, 16, 16)
		local data_2 = bit_replace(c32, c48, 16, 16)

		return from_u32(data_1, data_2)
	end

	function Numeric.divide_unsigned(lhs, rhs)
		if num_is_zero(rhs) then
			error("division by zero")
		elseif num_is_zero(lhs) then
			return NUM_ZERO, NUM_ZERO
		elseif num_is_less_unsigned(lhs, NUM_BIT_52) and num_is_less_unsigned(rhs, NUM_BIT_52) then
			local lhs_u = into_u64(lhs)
			local rhs_u = into_u64(rhs)

			return from_u64(lhs_u / rhs_u), from_u64(lhs_u % rhs_u)
		end

		local quotient = NUM_ZERO
		local remainder = NUM_ZERO

		local num_1, num_2 = load_d1(lhs), load_d2(lhs)

		for i = 63, 0, -1 do
			local temp = num_shift_left(remainder, NUM_ONE)
			local rem_1, rem_2 = load_d1(temp), load_d2(temp)

			if i > 31 then
				rem_1 = bit_or(rem_1, bit_extract(num_2, i - 32, 1))
			else
				rem_1 = bit_or(rem_1, bit_extract(num_1, i, 1))
			end

			remainder = from_u32(rem_1, rem_2)

			if not num_is_less_unsigned(remainder, rhs) then
				remainder = num_subtract(remainder, rhs)
				quotient = num_or(quotient, num_shift_left(NUM_ONE, from_u32(i, 0)))
			end
		end

		return quotient, remainder
	end

	function Numeric.divide_signed(lhs, rhs)
		local left_negative = num_is_negative(lhs)
		local right_negative = num_is_negative(rhs)

		if left_negative then
			lhs = num_negate(lhs)
		end

		if right_negative then
			rhs = num_negate(rhs)
		end

		local quotient, remainder = num_divide_unsigned(lhs, rhs)

		if left_negative ~= right_negative then
			quotient = num_negate(quotient)
		end

		if left_negative then
			remainder = num_negate(remainder)
		end

		return quotient, remainder
	end

	function Numeric.negate(value)
		local data_1 = bit_not(load_d1(value)) + 1
		local data_2 = bit_not(load_d2(value))

		if data_1 >= 0x100000000 then
			data_1 = data_1 - 0x100000000
			data_2 = data_2 + 1
		end

		if data_2 >= 0x100000000 then
			data_2 = data_2 - 0x100000000
		end

		return from_u32(data_1, data_2)
	end

	function Numeric.bit_and(lhs, rhs)
		local x = bit_and(lhs.X, rhs.X)
		local y = bit_and(lhs.Y, rhs.Y)
		local z = bit_and(lhs.Z, rhs.Z)

		return constructor(x, y, z)
	end

	function Numeric.bit_not(value)
		local x = bit_and(bit_not(value.X), 0xFFFFFF)
		local y = bit_and(bit_not(value.Y), 0xFFFFFF)
		local z = bit_and(bit_not(value.Z), 0xFFFFFF)

		return constructor(x, y, z)
	end

	function Numeric.bit_or(lhs, rhs)
		local x = bit_or(lhs.X, rhs.X)
		local y = bit_or(lhs.Y, rhs.Y)
		local z = bit_or(lhs.Z, rhs.Z)

		return constructor(x, y, z)
	end

	function Numeric.bit_xor(lhs, rhs)
		local x = bit_xor(lhs.X, rhs.X)
		local y = bit_xor(lhs.Y, rhs.Y)
		local z = bit_xor(lhs.Z, rhs.Z)

		return constructor(x, y, z)
	end

	function Numeric.shift_left(lhs, rhs)
		local count = rhs.X % 64

		if count == 0 then
			return lhs
		elseif count < 32 then
			local pad = 32 - count
			local lhs_1, lhs_2 = load_d1(lhs), load_d2(lhs)

			local data_1 = bit_lshift(lhs_1, count)
			local data_2 = bit_replace(bit_rshift(lhs_1, pad), lhs_2, count, pad)

			return from_u32(data_1, data_2)
		else
			local lhs_1 = load_d1(lhs)

			return from_u32(0, bit_lshift(lhs_1, count - 32))
		end
	end

	function Numeric.shift_right_unsigned(lhs, rhs)
		local count = rhs.X % 64

		if count == 0 then
			return lhs
		elseif count < 32 then
			local lhs_1, lhs_2 = load_d1(lhs), load_d2(lhs)

			local data_1 = bit_replace(bit_rshift(lhs_1, count), lhs_2, 32 - count, count)
			local data_2 = bit_rshift(lhs_2, count)

			return from_u32(data_1, data_2)
		else
			local lhs_2 = load_d2(lhs)

			return from_u32(bit_rshift(lhs_2, count - 32), 0)
		end
	end

	function Numeric.shift_right_signed(lhs, rhs)
		local count = rhs.X % 64

		if count == 0 then
			return lhs
		elseif count < 32 then
			local lhs_1, lhs_2 = load_d1(lhs), load_d2(lhs)

			local data_1 = bit_replace(bit_rshift(lhs_1, count), lhs_2, 32 - count, count)
			local data_2 = bit_arshift(lhs_2, count)

			return from_u32(data_1, data_2)
		else
			local lhs_2 = load_d2(lhs)

			local data_1 = bit_arshift(lhs_2, count - 32)
			local data_2 = lhs_2 >= 0x80000000 and 0xFFFFFFFF or 0

			return from_u32(data_1, data_2)
		end
	end

	function Numeric.rotate_left(lhs, rhs)
		if num_is_zero(rhs) then
			return lhs
		else
			local data_1 = num_shift_left(lhs, rhs)
			local data_2 = num_shift_right_unsigned(lhs, num_subtract(NUM_SIX_FOUR, rhs))

			return num_or(data_1, data_2)
		end
	end

	function Numeric.rotate_right(lhs, rhs)
		if num_is_zero(rhs) then
			return lhs
		else
			local data_1 = num_shift_right_unsigned(lhs, rhs)
			local data_2 = num_shift_left(lhs, num_subtract(NUM_SIX_FOUR, rhs))

			return num_or(data_1, data_2)
		end
	end

	function Numeric.is_negative(value)
		return value.Z >= 0x80000
	end

	function Numeric.is_zero(value)
		return value.X == 0 and value.Y == 0 and value.Z == 0
	end

	function Numeric.is_equal(lhs, rhs)
		return lhs.X == rhs.X and lhs.Y == rhs.Y and lhs.Z == rhs.Z
	end

	function Numeric.is_less_unsigned(lhs, rhs)
		local data_l_2 = load_d2(lhs)
		local data_r_2 = load_d2(rhs)

		return data_l_2 < data_r_2 or (data_l_2 == data_r_2 and load_d1(lhs) < load_d1(rhs))
	end

	function Numeric.is_greater_unsigned(lhs, rhs)
		local data_l_2 = load_d2(lhs)
		local data_r_2 = load_d2(rhs)

		return data_l_2 > data_r_2 or (data_l_2 == data_r_2 and load_d1(lhs) > load_d1(rhs))
	end

	function Numeric.is_less_signed(lhs, rhs)
		local neg_a = num_is_negative(lhs)
		local neg_b = num_is_negative(rhs)

		if neg_a and not neg_b then
			return true
		elseif not neg_a and neg_b then
			return false
		else
			return num_is_negative(num_subtract(lhs, rhs))
		end
	end

	function Numeric.is_greater_signed(lhs, rhs)
		local neg_a = num_is_negative(lhs)
		local neg_b = num_is_negative(rhs)

		if neg_a and not neg_b then
			return false
		elseif not neg_a and neg_b then
			return true
		else
			return num_is_negative(num_subtract(rhs, lhs))
		end
	end

	from_u32 = Numeric.from_u32
	from_u64 = Numeric.from_u64
	into_u64 = Numeric.into_u64

	num_subtract = Numeric.subtract
	num_divide_unsigned = Numeric.divide_unsigned
	num_negate = Numeric.negate

	num_or = Numeric.bit_or
	num_shift_left = Numeric.shift_left
	num_shift_right_unsigned = Numeric.shift_right_unsigned

	num_is_negative = Numeric.is_negative
	num_is_zero = Numeric.is_zero
	num_is_less_unsigned = Numeric.is_less_unsigned

	NUM_ZERO = from_u64(0)
	NUM_ONE = from_u64(1)
	NUM_SIX_FOUR = from_u64(64)
	NUM_BIT_26 = from_u64(0x4000000)
	NUM_BIT_52 = from_u64(0x10000000000000)

	Numeric.ZERO = NUM_ZERO
	Numeric.ONE = NUM_ONE

	return table.freeze(Numeric)

end)()
local rt = (function()
	local module = {}

	local bit_and = bit32.band
	local bit_xor = bit32.bxor
	local bit_lshift = bit32.lshift
	local bit_rshift = bit32.rshift

	local num_from_u32 = Integer.from_u32
	local num_into_u32 = Integer.into_u32

	local function to_i32(num)
		return bit_xor(num, 0x80000000) - 0x80000000
	end

	local function no_op(num)
		return num
	end

	module.i64 = Integer

	do
		local add = {}
		local sub = {}
		local mul = {}
		local div = {}
		local rem = {}
		local neg = {}
		local min = {}
		local max = {}
		local copysign = {}
		local nearest = {}

		local assert = assert

		local math_abs = math.abs
		local math_fmod = math.fmod
		local math_modf = math.modf
		local math_round = math.round
		local math_sign = math.sign
		local math_min = math.min
		local math_max = math.max

		local num_divide_signed = Integer.divide_signed
		local num_divide_unsigned = Integer.divide_unsigned

		function add.i32(lhs, rhs)
			return bit_and(lhs + rhs, 0xFFFFFFFF)
		end

		function sub.i32(lhs, rhs)
			return bit_and(lhs - rhs, 0xFFFFFFFF)
		end

		function mul.i32(lhs, rhs)
			if (lhs + rhs) < 0x8000000 then
				return bit_and(lhs * rhs, 0xFFFFFFFF)
			else
				local a16 = bit_rshift(lhs, 16)
				local a00 = bit_and(lhs, 0xFFFF)
				local b16 = bit_rshift(rhs, 16)
				local b00 = bit_and(rhs, 0xFFFF)

				local c00 = a00 * b00
				local c16 = a16 * b00 + a00 * b16

				return bit_and(c00 + bit_lshift(c16, 16), 0xFFFFFFFF)
			end
		end

		function div.i32(lhs, rhs)
			assert(rhs ~= 0, "division by zero")

			lhs = to_i32(lhs)
			rhs = to_i32(rhs)

			return bit_and(math_modf(lhs / rhs), 0xFFFFFFFF)
		end

		function div.u32(lhs, rhs)
			assert(rhs ~= 0, "division by zero")

			return bit_and(math_modf(lhs / rhs), 0xFFFFFFFF)
		end

		function rem.i32(lhs, rhs)
			assert(rhs ~= 0, "division by zero")

			lhs = to_i32(lhs)
			rhs = to_i32(rhs)

			return bit_and(math_fmod(lhs, rhs), 0xFFFFFFFF)
		end

		add.i64 = Integer.add
		sub.i64 = Integer.subtract
		mul.i64 = Integer.multiply
		div.i64 = num_divide_signed

		function rem.i64(lhs, rhs)
			local _, remainder = num_divide_signed(lhs, rhs)

			return remainder
		end

		div.u64 = num_divide_unsigned

		function rem.u64(lhs, rhs)
			local _, remainder = num_divide_unsigned(lhs, rhs)

			return remainder
		end

		function neg.f32(num)
			return -num
		end

		function min.f32(lhs, rhs)
			if rhs == rhs then
				return math_min(lhs, rhs)
			else
				return rhs
			end
		end

		function max.f32(lhs, rhs)
			if rhs == rhs then
				return math_max(lhs, rhs)
			else
				return rhs
			end
		end

		local CP_INSTANCE = buffer.create(8)

		local buffer_write_f64 = buffer.writef64
		local buffer_read_i8 = buffer.readi8

		function copysign.f32(lhs, rhs)
			buffer_write_f64(CP_INSTANCE, 0, rhs)

			if buffer_read_i8(CP_INSTANCE, 7) >= 0 then
				return (math_abs(lhs))
			else
				return -math_abs(lhs)
			end
		end

		function nearest.f32(num)
			local result = math_round(num)

			if (math_abs(num) + 0.5) % 2 == 1 then
				return result - math_sign(result)
			else
				return result
			end
		end

		neg.f64 = neg.f32
		min.f64 = min.f32
		max.f64 = max.f32
		copysign.f64 = copysign.f32
		nearest.f64 = nearest.f32

		module.add = add
		module.sub = sub
		module.mul = mul
		module.div = div
		module.rem = rem
		module.neg = neg
		module.min = min
		module.max = max
		module.copysign = copysign
		module.nearest = nearest
	end

	do
		local clz = {}
		local ctz = {}
		local popcnt = {}

		local bit_countlz = bit32.countlz
		local bit_countrz = bit32.countrz

		local function popcnt_i32(num)
			local count = 0

			while num ~= 0 do
				num = bit_and(num, num - 1)
				count = count + 1
			end

			return count
		end

		popcnt.i32 = popcnt_i32

		function clz.i64(num)
			local data_1, data_2 = num_into_u32(num)
			local temp

			if data_2 == 0 then
				temp = bit_countlz(data_1) + 32
			else
				temp = bit_countlz(data_2)
			end

			return num_from_u32(temp, 0)
		end

		function ctz.i64(num)
			local data_1, data_2 = num_into_u32(num)
			local temp

			if data_1 == 0 then
				temp = bit_countrz(data_2) + 32
			else
				temp = bit_countrz(data_1)
			end

			return num_from_u32(temp, 0)
		end

		function popcnt.i64(num)
			local data_1, data_2 = num_into_u32(num)
			local temp = popcnt_i32(data_1) + popcnt_i32(data_2)

			return num_from_u32(temp, 0)
		end

		module.clz = clz
		module.ctz = ctz
		module.popcnt = popcnt
	end

	do
		local eq = {}
		local ne = {}
		local le = {}
		local lt = {}
		local ge = {}
		local gt = {}

		local num_is_equal = Integer.is_equal
		local num_is_less_signed = Integer.is_less_signed
		local num_is_less_unsigned = Integer.is_less_unsigned
		local num_is_greater_signed = Integer.is_greater_signed
		local num_is_greater_unsigned = Integer.is_greater_unsigned

		function le.i32(lhs, rhs)
			return to_i32(lhs) <= to_i32(rhs)
		end

		function lt.i32(lhs, rhs)
			return to_i32(lhs) < to_i32(rhs)
		end

		function ge.i32(lhs, rhs)
			return to_i32(lhs) >= to_i32(rhs)
		end

		function gt.i32(lhs, rhs)
			return to_i32(lhs) > to_i32(rhs)
		end

		eq.i64 = num_is_equal

		function ne.i64(lhs, rhs)
			return not num_is_equal(lhs, rhs)
		end

		function le.i64(lhs, rhs)
			return num_is_less_signed(lhs, rhs) or num_is_equal(lhs, rhs)
		end

		function le.u64(lhs, rhs)
			return num_is_less_unsigned(lhs, rhs) or num_is_equal(lhs, rhs)
		end

		lt.i64 = num_is_less_signed
		lt.u64 = num_is_less_unsigned

		function ge.i64(lhs, rhs)
			return num_is_greater_signed(lhs, rhs) or num_is_equal(lhs, rhs)
		end

		function ge.u64(lhs, rhs)
			return num_is_greater_unsigned(lhs, rhs) or num_is_equal(lhs, rhs)
		end

		gt.i64 = num_is_greater_signed
		gt.u64 = num_is_greater_unsigned

		module.eq = eq
		module.ne = ne
		module.le = le
		module.lt = lt
		module.ge = ge
		module.gt = gt
	end

	do
		local band = {}
		local bor = {}
		local bxor = {}
		local bnot = {}

		band.i64 = Integer.bit_and
		bor.i64 = Integer.bit_or
		bxor.i64 = Integer.bit_xor
		bnot.i64 = Integer.bit_not

		module.band = band
		module.bor = bor
		module.bxor = bxor
		module.bnot = bnot
	end

	do
		local shl = {}
		local shr = {}
		local rotl = {}
		local rotr = {}

		local bit_arshift = bit32.arshift
		local bit_lrotate = bit32.lrotate
		local bit_rrotate = bit32.rrotate

		function shl.i32(lhs, rhs)
			return bit_lshift(lhs, rhs % 32)
		end

		function shr.u32(lhs, rhs)
			return bit_rshift(lhs, rhs % 32)
		end

		function shr.i32(lhs, rhs)
			return bit_arshift(lhs, rhs % 32)
		end

		function rotl.i32(lhs, rhs)
			return bit_lrotate(lhs, rhs % 32)
		end

		function rotr.i32(lhs, rhs)
			return bit_rrotate(lhs, rhs % 32)
		end

		shl.i64 = Integer.shift_left
		shr.i64 = Integer.shift_right_signed
		shr.u64 = Integer.shift_right_unsigned
		rotl.i64 = Integer.rotate_left
		rotr.i64 = Integer.rotate_right

		module.shl = shl
		module.shr = shr
		module.rotl = rotl
		module.rotr = rotr
	end

	do
		local wrap = {}
		local truncate = {}
		local saturate = {}
		local extend = {}
		local convert = {}
		local demote = {}
		local promote = {}
		local reinterpret = {}

		local math_ceil = math.ceil
		local math_floor = math.floor
		local math_clamp = math.clamp

		local NUM_ZERO = Integer.ZERO
		local NUM_MIN_I64 = num_from_u32(0, 0x80000000)
		local NUM_MAX_I64 = num_from_u32(0xFFFFFFFF, 0x7FFFFFFF)
		local NUM_MAX_U64 = num_from_u32(0xFFFFFFFF, 0xFFFFFFFF)

		local num_from_u64 = Integer.from_u64
		local num_into_u64 = Integer.into_u64

		local num_negate = Integer.negate
		local num_is_negative = Integer.is_negative

		local function truncate_f64(num)
			if num >= 0 then
				return math_floor(num)
			else
				return math_ceil(num)
			end
		end

		function wrap.i32_i64(num)
			local data_1, _ = num_into_u32(num)

			return data_1
		end

		function truncate.i32_f32(num)
			return bit_and(truncate_f64(num), 0xFFFFFFFF)
		end

		truncate.i32_f64 = truncate.i32_f32

		truncate.u32_f32 = truncate_f64
		truncate.u32_f64 = truncate_f64

		function truncate.i64_f32(num)
			if num < 0 then
				local temp = num_from_u64(-num)

				return num_negate(temp)
			else
				return num_from_u64(num)
			end
		end

		truncate.i64_f64 = truncate.i64_f32

		function truncate.u64_f32(num)
			if num <= 0 then
				return NUM_ZERO
			else
				return num_from_u64(math_floor(num))
			end
		end

		truncate.u64_f64 = truncate.u64_f32

		truncate.f32 = truncate_f64
		truncate.f64 = truncate_f64

		function saturate.i32_f32(num)
			local temp = math_clamp(truncate_f64(num), -0x80000000, 0x7FFFFFFF)

			return bit_and(temp, 0xFFFFFFFF)
		end

		saturate.i32_f64 = saturate.i32_f32

		function saturate.u32_f32(num)
			local temp = math_clamp(truncate_f64(num), 0, 0xFFFFFFFF)

			return temp
		end

		saturate.u32_f64 = saturate.u32_f32

		local truncate_i64_f64 = truncate.i64_f64

		function saturate.i64_f32(num)
			if num >= 2 ^ 63 - 1 then
				return NUM_MAX_I64
			elseif num <= -2 ^ 63 then
				return NUM_MIN_I64
			else
				return truncate_i64_f64(num)
			end
		end

		saturate.i64_f64 = saturate.i64_f32

		function saturate.u64_f32(num)
			if num >= 2 ^ 64 then
				return NUM_MAX_U64
			elseif num <= 0 then
				return NUM_ZERO
			else
				return truncate_i64_f64(num)
			end
		end

		saturate.u64_f64 = saturate.u64_f32

		function extend.i32_n8(num)
			num = bit_and(num, 0xFF)

			if num >= 0x80 then
				return bit_and(num - 0x100, 0xFFFFFFFF)
			else
				return num
			end
		end

		function extend.i32_n16(num)
			num = bit_and(num, 0xFFFF)

			if num >= 0x8000 then
				return bit_and(num - 0x10000, 0xFFFFFFFF)
			else
				return num
			end
		end

		function extend.i64_n8(num)
			local data_1, _ = num_into_u32(num)

			data_1 = bit_and(data_1, 0xFF)

			if data_1 >= 0x80 then
				local temp = num_from_u32(-data_1 + 0x100, 0)

				return num_negate(temp)
			else
				return num_from_u32(data_1, 0)
			end
		end

		function extend.i64_n16(num)
			local data_1, _ = num_into_u32(num)

			data_1 = bit_and(data_1, 0xFFFF)

			if data_1 >= 0x8000 then
				local temp = num_from_u32(-data_1 + 0x10000, 0)

				return num_negate(temp)
			else
				return num_from_u32(data_1, 0)
			end
		end

		function extend.i64_n32(num)
			local data_1, _ = num_into_u32(num)

			if data_1 >= 0x80000000 then
				local temp = num_from_u32(-data_1 + 0x100000000, 0)

				return num_negate(temp)
			else
				return num_from_u32(data_1, 0)
			end
		end

		function extend.i64_i32(num)
			if num >= 0x80000000 then
				local temp = num_from_u32(-num + 0x100000000, 0)

				return num_negate(temp)
			else
				return num_from_u32(num, 0)
			end
		end

		function extend.i64_u32(num)
			return num_from_u32(num, 0)
		end

		convert.f32_i32 = to_i32
		convert.f32_u32 = no_op

		function convert.f32_i64(num)
			if num_is_negative(num) then
				local temp = num_negate(num)

				return -num_into_u64(temp)
			else
				return num_into_u64(num)
			end
		end

		convert.f32_u64 = num_into_u64
		convert.f64_i32 = to_i32
		convert.f64_u32 = no_op
		convert.f64_i64 = convert.f32_i64
		convert.f64_u64 = num_into_u64

		demote.f32_f64 = no_op

		promote.f64_f32 = no_op

		local RE_INSTANCE = buffer.create(8)

		local buffer_read_f32 = buffer.readf32
		local buffer_read_f64 = buffer.readf64
		local buffer_read_u32 = buffer.readu32

		local buffer_write_f32 = buffer.writef32
		local buffer_write_f64 = buffer.writef64
		local buffer_write_u32 = buffer.writeu32

		function reinterpret.i32_f32(num)
			buffer_write_f32(RE_INSTANCE, 0, num)

			return buffer_read_u32(RE_INSTANCE, 0)
		end

		function reinterpret.i64_f64(num)
			buffer_write_f64(RE_INSTANCE, 0, num)

			local data_1 = buffer_read_u32(RE_INSTANCE, 0)
			local data_2 = buffer_read_u32(RE_INSTANCE, 4)

			return num_from_u32(data_1, data_2)
		end

		function reinterpret.f32_i32(num)
			buffer_write_u32(RE_INSTANCE, 0, num)

			return buffer_read_f32(RE_INSTANCE, 0)
		end

		function reinterpret.f64_i64(num)
			local data_1, data_2 = num_into_u32(num)

			buffer_write_u32(RE_INSTANCE, 0, data_1)
			buffer_write_u32(RE_INSTANCE, 4, data_2)

			return buffer_read_f64(RE_INSTANCE, 0)
		end

		module.wrap = wrap
		module.truncate = truncate
		module.saturate = saturate
		module.extend = extend
		module.convert = convert
		module.demote = demote
		module.promote = promote
		module.reinterpret = reinterpret
	end

	do
		local load = {}
		local store = {}
		local allocator = {}

		local string_sub = string.sub

		local buffer_create = buffer.create
		local buffer_to_string = buffer.tostring
		local buffer_from_string = buffer.fromstring

		local buffer_len = buffer.len
		local buffer_copy = buffer.copy
		local buffer_fill = buffer.fill

		local buffer_read_i8 = buffer.readi8
		local buffer_read_u8 = buffer.readu8
		local buffer_read_i16 = buffer.readi16
		local buffer_read_u16 = buffer.readu16
		local buffer_read_i32 = buffer.readi32
		local buffer_read_u32 = buffer.readu32
		local buffer_read_f32 = buffer.readf32
		local buffer_read_f64 = buffer.readf64

		local buffer_write_u8 = buffer.writeu8
		local buffer_write_u16 = buffer.writeu16
		local buffer_write_u32 = buffer.writeu32
		local buffer_write_f32 = buffer.writef32
		local buffer_write_f64 = buffer.writef64

		function load.i32_i8(memory, addr)
			return bit_and(buffer_read_i8(memory.data, addr), 0xFFFFFFFF)
		end

		function load.i32_u8(memory, addr)
			return buffer_read_u8(memory.data, addr)
		end

		function load.i32_i16(memory, addr)
			return bit_and(buffer_read_i16(memory.data, addr), 0xFFFFFFFF)
		end

		function load.i32_u16(memory, addr)
			return buffer_read_u16(memory.data, addr)
		end

		function load.i32(memory, addr)
			return buffer_read_u32(memory.data, addr)
		end

		function load.i64_i8(memory, addr)
			local value = buffer_read_i8(memory.data, addr)

			if value >= 0 then
				return num_from_u32(value, 0)
			else
				return num_from_u32(value + 0x100000000, 0xFFFFFFFF)
			end
		end

		function load.i64_u8(memory, addr)
			return num_from_u32(buffer_read_u8(memory.data, addr), 0)
		end

		function load.i64_i16(memory, addr)
			local value = buffer_read_i16(memory.data, addr)

			if value >= 0 then
				return num_from_u32(value, 0)
			else
				return num_from_u32(value + 0x100000000, 0xFFFFFFFF)
			end
		end

		function load.i64_u16(memory, addr)
			return num_from_u32(buffer_read_u16(memory.data, addr), 0)
		end

		function load.i64_i32(memory, addr)
			local value = buffer_read_i32(memory.data, addr)

			if value >= 0 then
				return num_from_u32(value, 0)
			else
				return num_from_u32(value + 0x100000000, 0xFFFFFFFF)
			end
		end

		function load.i64_u32(memory, addr)
			return num_from_u32(buffer_read_u32(memory.data, addr), 0)
		end

		function load.i64(memory, addr)
			local data = memory.data
			local value_1 = buffer_read_u32(data, addr)
			local value_2 = buffer_read_u32(data, addr + 4)

			return num_from_u32(value_1, value_2)
		end

		function load.f32(memory, addr)
			return buffer_read_f32(memory.data, addr)
		end

		function load.f64(memory, addr)
			return buffer_read_f64(memory.data, addr)
		end

		function load.string(memory, addr, len)
			local temp = buffer_create(len)

			buffer_copy(temp, 0, memory.data, addr, len)

			return buffer_to_string(temp)
		end

		function store.i32_n8(memory, addr, value)
			buffer_write_u8(memory.data, addr, value)
		end

		function store.i32_n16(memory, addr, value)
			buffer_write_u16(memory.data, addr, value)
		end

		function store.i32(memory, addr, value)
			buffer_write_u32(memory.data, addr, value)
		end

		function store.i64_n8(memory, addr, value)
			local value_1, _ = num_into_u32(value)

			buffer_write_u8(memory.data, addr, value_1)
		end

		function store.i64_n16(memory, addr, value)
			local value_1, _ = num_into_u32(value)

			buffer_write_u16(memory.data, addr, value_1)
		end

		function store.i64_n32(memory, addr, value)
			local value_1, _ = num_into_u32(value)

			buffer_write_u32(memory.data, addr, value_1)
		end

		function store.i64(memory, addr, value)
			local data = memory.data
			local value_1, value_2 = num_into_u32(value)

			buffer_write_u32(data, addr, value_1)
			buffer_write_u32(data, addr + 4, value_2)
		end

		function store.f32(memory, addr, value)
			buffer_write_f32(memory.data, addr, value)
		end

		function store.f64(memory, addr, value)
			buffer_write_f64(memory.data, addr, value)
		end

		function store.string(memory, addr, data, len)
			local content = if not len or len == #data then data else string_sub(data, 1, len)
			local temp = buffer_from_string(content)

			buffer_copy(memory.data, addr, temp)
		end

		function store.copy(memory_1, addr_1, memory_2, addr_2, len)
			buffer_copy(memory_1.data, addr_1, memory_2.data, addr_2, len)
		end

		function store.fill(memory, addr, len, value)
			buffer_fill(memory.data, addr, value, len)
		end

		local WASM_PAGE_SIZE = 65536

		function allocator.new(min, max)
			return { max = max, data = buffer_create(min * WASM_PAGE_SIZE) }
		end

		function allocator.size(memory)
			return buffer_len(memory.data) / WASM_PAGE_SIZE
		end

		function allocator.grow(memory, num)
			local old = allocator.size(memory)
			local new = old + num

			if new <= memory.max then
				local reallocated = buffer_create(new * WASM_PAGE_SIZE)

				buffer_copy(reallocated, 0, memory.data)

				memory.data = reallocated

				return old
			else
				return 0xFFFFFFFF
			end
		end

		module.load = load
		module.store = store
		module.allocator = allocator
	end

	return module

end)()
local add_i32 = rt.add.i32
local add_i64 = rt.add.i64
local band_i32 = bit32.band
local band_i64 = rt.band.i64
local bor_i32 = bit32.bor
local bor_i64 = rt.bor.i64
local bxor_i32 = bit32.bxor
local bxor_i64 = rt.bxor.i64
local clz_i32 = bit32.countlz
local clz_i64 = rt.clz.i64
local ctz_i32 = bit32.countrz
local ctz_i64 = rt.ctz.i64
local div_i32 = rt.div.i32
local div_u32 = rt.div.u32
local div_u64 = rt.div.u64
local eq_i64 = rt.eq.i64
local extend_i32_n16 = rt.extend.i32_n16
local extend_i32_n8 = rt.extend.i32_n8
local extend_i64_i32 = rt.extend.i64_i32
local extend_i64_u32 = rt.extend.i64_u32
local ge_i32 = rt.ge.i32
local ge_u64 = rt.ge.u64
local gt_i32 = rt.gt.i32
local gt_u64 = rt.gt.u64
local i64_ONE = rt.i64.ONE
local i64_ZERO = rt.i64.ZERO
local i64_from_u32 = rt.i64.from_u32
local le_i32 = rt.le.i32
local le_u64 = rt.le.u64
local load_f64 = rt.load.f64
local load_i32 = rt.load.i32
local load_i32_i8 = rt.load.i32_i8
local load_i32_u16 = rt.load.i32_u16
local load_i32_u8 = rt.load.i32_u8
local load_i64 = rt.load.i64
local load_i64_u16 = rt.load.i64_u16
local load_i64_u32 = rt.load.i64_u32
local load_i64_u8 = rt.load.i64_u8
local lt_i32 = rt.lt.i32
local lt_i64 = rt.lt.i64
local lt_u64 = rt.lt.u64
local mul_i32 = rt.mul.i32
local mul_i64 = rt.mul.i64
local ne_i64 = rt.ne.i64
local popcnt_i64 = rt.popcnt.i64
local reinterpret_i64_f64 = rt.reinterpret.i64_f64
local rem_u64 = rt.rem.u64
local rotl_i32 = rt.rotl.i32
local rotl_i64 = rt.rotl.i64
local shl_i32 = rt.shl.i32
local shl_i64 = rt.shl.i64
local shr_i32 = rt.shr.i32
local shr_u32 = rt.shr.u32
local shr_u64 = rt.shr.u64
local store_f64 = rt.store.f64
local store_i32 = rt.store.i32
local store_i32_n16 = rt.store.i32_n16
local store_i32_n8 = rt.store.i32_n8
local store_i64 = rt.store.i64
local sub_i32 = rt.sub.i32
local sub_i64 = rt.sub.i64
local wrap_i32_i64 = rt.wrap.i32_i64
local memory_at_0
local FUNC_LIST = table.create(263)
local TABLE_LIST = table.create(0)
local MEMORY_LIST = table.create(0)
local GLOBAL_LIST = table.create(2)
FUNC_LIST[2] = --[[ _ZN3std10sys_common9backtrace28__rust_begin_short_backtrace17h10a51349a23702f8E ]] function(loc_0)
	while true do
		TABLE_LIST[0].data[loc_0]()
		break
	end
end
FUNC_LIST[3] = --[[ _ZN3std2rt10lang_start28_$u7b$$u7b$closure$u7d$$u7d$17h0e6812f1852bdfafE ]] function(loc_0)
	local reg_0
	while true do
		FUNC_LIST[2](load_i32(memory_at_0, loc_0))
		reg_0 = 0
		break
	end
	return reg_0
end
FUNC_LIST[4] = --[[ _ZN4core3ops8function6FnOnce40call_once$u7b$$u7b$vtable.shim$u7d$$u7d$17h21e56185e4a49b6aE ]] function(loc_0)
	local reg_0
	while true do
		FUNC_LIST[2](load_i32(memory_at_0, loc_0))
		reg_0 = 0
		break
	end
	return reg_0
end
FUNC_LIST[5] = --[[ _ZN4core3ops8function6FnOnce9call_once17hd3a75ec91bd96d15E ]] function(loc_0, loc_1)
	while true do
		while true do
			if loc_1 == 0 then
				break
			end
			while true do
				FUNC_LIST[0](load_i32_u8(memory_at_0, loc_0))
				loc_0 = add_i32(loc_0, 1)
				loc_1 = add_i32(loc_1, 4294967295)
				if loc_1 ~= 0 then
					continue
				end
				break
			end
			break
		end
		FUNC_LIST[0](10)
		break
	end
end
FUNC_LIST[6] = --[[ _ZN4core3ptr42drop_in_place$LT$std..io..error..Error$GT$17h7c024c3b0e788351E ]] function(loc_0)
	local loc_1 = 0
	local loc_2 = 0
	local loc_3 = 0
	while true do
		while true do
			if load_i32_u8(memory_at_0, loc_0) ~= 3 then
				break
			end
			loc_0 = load_i32(memory_at_0, loc_0 + 4)
			loc_1 = load_i32(memory_at_0, loc_0)
			loc_2 = load_i32(memory_at_0, add_i32(loc_0, 4))
			TABLE_LIST[0].data[load_i32(memory_at_0, loc_2)](loc_1)
			while true do
				loc_3 = load_i32(memory_at_0, loc_2 + 4)
				if loc_3 == 0 then
					break
				end
				FUNC_LIST[22](loc_1, loc_3, load_i32(memory_at_0, loc_2 + 8))
				break
			end
			FUNC_LIST[22](loc_0, 12, 4)
			break
		end
		break
	end
end
FUNC_LIST[7] = --[[ _ZN4core3ptr85drop_in_place$LT$std..rt..lang_start$LT$$LP$$RP$$GT$..$u7b$$u7b$closure$u7d$$u7d$$GT$17h07114e820b78df51E ]] function(loc_0)
	while true do
		break
	end
end
FUNC_LIST[8] = --[[ _ZN5alloc7raw_vec19RawVec$LT$T$C$A$GT$7reserve21do_reserve_and_handle17h52eba92ca1fc46b0E.llvm.9175310757752277836 ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	local loc_4 = 0
	local desired
	while true do
		loc_3 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_3
		while true do
			while true do
				loc_2 = add_i32(loc_1, loc_2)
				if loc_2 < loc_1 then
					break
				end
				loc_1 = load_i32(memory_at_0, loc_0)
				loc_4 = shl_i32(loc_1, 1)
				loc_2 = (if loc_4 > loc_2 then loc_4 else loc_2)
				loc_2 = (if loc_2 > 8 then loc_2 else 8)
				loc_4 = shr_u32(bxor_i32(loc_2, 4294967295), 31)
				while true do
					while true do
						if loc_1 ~= 0 then
							break
						end
						store_i32(memory_at_0, loc_3 + 24, 0)
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32(memory_at_0, loc_3 + 28, loc_1)
					store_i32(memory_at_0, loc_3 + 24, 1)
					store_i32(memory_at_0, loc_3 + 20, load_i32(memory_at_0, loc_0 + 4))
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[9](add_i32(loc_3, 8), loc_4, loc_2, add_i32(loc_3, 20))
				loc_1 = load_i32(memory_at_0, loc_3 + 12)
				while true do
					if load_i32(memory_at_0, loc_3 + 8) ~= 0 then
						break
					end
					store_i32(memory_at_0, loc_0, loc_2)
					store_i32(memory_at_0, loc_0 + 4, loc_1)
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				if loc_1 == 2147483649 then
					desired = 1
					break
				end
				if loc_1 == 0 then
					break
				end
				FUNC_LIST[173](loc_1, load_i32(memory_at_0, add_i32(loc_3, 16)))
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[174]()
			error("out of code bounds")
		end
		GLOBAL_LIST[0].value = add_i32(loc_3, 32)
		break
	end
end
FUNC_LIST[9] = --[[ _ZN5alloc7raw_vec11finish_grow17h0a9f2c0fd855c09bE.llvm.9175310757752277836 ]] function(loc_0, loc_1, loc_2, loc_3)
	local loc_4 = 0
	local reg_0
	local desired
	while true do
		while true do
			while true do
				while true do
					if loc_1 == 0 then
						break
					end
					if le_i32(loc_2, 4294967295) then
						desired = 2
						break
					end
					while true do
						while true do
							while true do
								if load_i32(memory_at_0, loc_3 + 4) == 0 then
									break
								end
								while true do
									loc_4 = load_i32(memory_at_0, add_i32(loc_3, 8))
									if loc_4 ~= 0 then
										break
									end
									while true do
										if loc_2 ~= 0 then
											break
										end
										loc_3 = loc_1
										desired = 4
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									desired = 5
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								reg_0 = FUNC_LIST[23](load_i32(memory_at_0, loc_3), loc_4, loc_1, loc_2)
								loc_3 = reg_0
								desired = 4
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							while true do
								if loc_2 ~= 0 then
									break
								end
								loc_3 = loc_1
								desired = 4
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						reg_0 = FUNC_LIST[21](loc_2, loc_1)
						loc_3 = reg_0
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					while true do
						if loc_3 == 0 then
							break
						end
						store_i32(memory_at_0, loc_0 + 4, loc_3)
						store_i32(memory_at_0, add_i32(loc_0, 8), loc_2)
						store_i32(memory_at_0, loc_0, 0)
						desired = 0
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32(memory_at_0, loc_0 + 4, loc_1)
					store_i32(memory_at_0, add_i32(loc_0, 8), loc_2)
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i32(memory_at_0, loc_0 + 4, 0)
				store_i32(memory_at_0, add_i32(loc_0, 8), loc_2)
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			store_i32(memory_at_0, loc_0 + 4, 0)
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		store_i32(memory_at_0, loc_0, 1)
		break
	end
end
FUNC_LIST[10] = --[[ _ZN5alloc7raw_vec19RawVec$LT$T$C$A$GT$16reserve_for_push17h8564c3899d1956b7E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local desired
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_2
		while true do
			while true do
				loc_1 = add_i32(loc_1, 1)
				if loc_1 == 0 then
					break
				end
				loc_3 = load_i32(memory_at_0, loc_0)
				loc_4 = shl_i32(loc_3, 1)
				loc_1 = (if loc_4 > loc_1 then loc_4 else loc_1)
				loc_1 = (if loc_1 > 8 then loc_1 else 8)
				loc_4 = shr_u32(bxor_i32(loc_1, 4294967295), 31)
				while true do
					while true do
						if loc_3 ~= 0 then
							break
						end
						store_i32(memory_at_0, loc_2 + 24, 0)
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32(memory_at_0, loc_2 + 28, loc_3)
					store_i32(memory_at_0, loc_2 + 24, 1)
					store_i32(memory_at_0, loc_2 + 20, load_i32(memory_at_0, loc_0 + 4))
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[9](add_i32(loc_2, 8), loc_4, loc_1, add_i32(loc_2, 20))
				loc_3 = load_i32(memory_at_0, loc_2 + 12)
				while true do
					if load_i32(memory_at_0, loc_2 + 8) ~= 0 then
						break
					end
					store_i32(memory_at_0, loc_0, loc_1)
					store_i32(memory_at_0, loc_0 + 4, loc_3)
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				if loc_3 == 2147483649 then
					desired = 1
					break
				end
				if loc_3 == 0 then
					break
				end
				FUNC_LIST[173](loc_3, load_i32(memory_at_0, add_i32(loc_2, 16)))
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[174]()
			error("out of code bounds")
		end
		GLOBAL_LIST[0].value = add_i32(loc_2, 32)
		break
	end
end
FUNC_LIST[11] = --[[ send_input ]] function(loc_0)
	local loc_1 = 0
	local desired
	while true do
		loc_1 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_1
		store_i32(memory_at_0, loc_1 + 12, loc_0)
		while true do
			while true do
				if loc_0 ~= 10 then
					break
				end
				FUNC_LIST[18](1048600)
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[17](1048600, add_i32(loc_1, 12))
			break
		end
		GLOBAL_LIST[0].value = add_i32(loc_1, 16)
		break
	end
end
FUNC_LIST[12] = --[[ _ZN6engine4main17h1f2d56657a0f44e1E ]] function()
	local loc_0 = 0
	local loc_1 = 0
	local loc_2 = 0
	local reg_0
	local reg_1
	while true do
		loc_0 = sub_i32(GLOBAL_LIST[0].value, 80)
		GLOBAL_LIST[0].value = loc_0
		reg_1 = FUNC_LIST[141]()
		store_i32(memory_at_0, loc_0 + 48, reg_1)
		FUNC_LIST[143](add_i32(loc_0, 8), add_i32(loc_0, 48))
		store_i32_n8(memory_at_0, loc_0 + 24, load_i32_u8(memory_at_0, loc_0 + 12))
		store_i32(memory_at_0, loc_0 + 20, load_i32(memory_at_0, loc_0 + 8))
		store_i32(memory_at_0, loc_0 + 36, 0)
		store_i64(memory_at_0, loc_0 + 28, i64_from_u32(0, 1))
		FUNC_LIST[145](add_i32(loc_0, 40), add_i32(loc_0, 20), add_i32(loc_0, 28))
		while true do
			if load_i32_u8(memory_at_0, loc_0 + 40) ~= 4 then
				break
			end
			while true do
				loc_1 = load_i32(memory_at_0, loc_0 + 32)
				loc_2 = load_i32(memory_at_0, loc_0 + 36)
				store_i32_n16(memory_at_0, loc_0 + 76, 1)
				store_i32(memory_at_0, loc_0 + 72, 0)
				store_i32(memory_at_0, loc_0 + 68, add_i32(loc_1, loc_2))
				store_i32(memory_at_0, loc_0 + 64, loc_1)
				store_i32(memory_at_0, loc_0 + 60, loc_2)
				store_i32(memory_at_0, loc_0 + 56, loc_1)
				store_i32(memory_at_0, loc_0 + 52, loc_2)
				store_i32(memory_at_0, loc_0 + 48, 0)
				FUNC_LIST[19](1048604, add_i32(loc_0, 48))
				while true do
					loc_1 = load_i32(memory_at_0, loc_0 + 28)
					if loc_1 == 0 then
						break
					end
					FUNC_LIST[22](load_i32(memory_at_0, loc_0 + 32), loc_1, 1)
					break
				end
				store_i32(memory_at_0, loc_0 + 36, 0)
				store_i64(memory_at_0, loc_0 + 28, i64_from_u32(0, 1))
				FUNC_LIST[145](add_i32(loc_0, 40), add_i32(loc_0, 20), add_i32(loc_0, 28))
				if load_i32_u8(memory_at_0, loc_0 + 40) == 4 then
					continue
				end
				break
			end
			break
		end
		store_i64(memory_at_0, loc_0 + 48, load_i64(memory_at_0, loc_0 + 40))
		FUNC_LIST[208](1048608, 43, add_i32(loc_0, 48), 1048652, 1048680)
		error("out of code bounds")
	end
end
FUNC_LIST[13] = --[[ _ZN6engine13UCI_PROCESSOR7__getit17he1246172c76fea42E.llvm.9175310757752277836 ]] function(loc_0)
	local loc_1 = 0
	local loc_2 = i64_ZERO
	local loc_3 = i64_ZERO
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = i64_ZERO
	local loc_8 = 0
	local loc_9 = 0
	local loc_10 = 0
	local loc_11 = 0
	local loc_12 = 0
	local reg_0
	local desired
	while true do
		loc_1 = 0
		loc_2 = i64_ZERO
		while true do
			if ne_i64(load_i64(memory_at_0, 0 + 1077288), i64_ZERO) then
				break
			end
			loc_3 = i64_from_u32(5000, 0)
			loc_4 = 1
			loc_5 = 2147483648
			loc_6 = 4
			while true do
				while true do
					if loc_0 == 0 then
						break
					end
					loc_7 = load_i64(memory_at_0, loc_0)
					loc_2 = i64_ZERO
					store_i64(memory_at_0, loc_0, i64_ZERO)
					if eq_i64(loc_7, i64_ZERO) then
						break
					end
					loc_8 = load_i32(memory_at_0, loc_0 + 60)
					loc_1 = load_i32(memory_at_0, loc_0 + 56)
					loc_6 = load_i32(memory_at_0, loc_0 + 52)
					loc_9 = load_i32(memory_at_0, loc_0 + 48)
					loc_10 = load_i32(memory_at_0, loc_0 + 44)
					loc_11 = load_i32(memory_at_0, loc_0 + 40)
					loc_5 = load_i32(memory_at_0, loc_0 + 36)
					loc_2 = load_i64(memory_at_0, add_i32(loc_0, 24))
					loc_3 = load_i64(memory_at_0, loc_0 + 16)
					loc_4 = load_i32(memory_at_0, loc_0 + 32)
					loc_12 = load_i32(memory_at_0, loc_0 + 12)
					loc_0 = load_i32(memory_at_0, loc_0 + 8)
					desired = 2
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_9 = 0
				loc_0 = 0
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			store_i64(memory_at_0, 0 + 1077304, loc_3)
			store_i32(memory_at_0, 0 + 1077348, loc_8)
			store_i32(memory_at_0, 0 + 1077344, loc_1)
			store_i32(memory_at_0, 0 + 1077340, loc_6)
			store_i32(memory_at_0, 0 + 1077336, loc_9)
			store_i32(memory_at_0, 0 + 1077332, loc_10)
			store_i32(memory_at_0, 0 + 1077328, loc_11)
			store_i32(memory_at_0, 0 + 1077324, loc_5)
			store_i32(memory_at_0, 0 + 1077320, loc_4)
			store_i32(memory_at_0, 0 + 1077300, loc_12)
			store_i32(memory_at_0, 0 + 1077296, loc_0)
			store_i64(memory_at_0, 0 + 1077288, i64_ONE)
			store_i64(memory_at_0, 0 + 1077312, loc_2)
			break
		end
		reg_0 = 1077296
		break
	end
	return reg_0
end
FUNC_LIST[14] = --[[ _ZN6engine5INPUT7__getit17h10e9e815944622dcE ]] function(loc_0)
	local loc_1 = 0
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local reg_0
	while true do
		loc_1 = 0
		while true do
			if load_i32(memory_at_0, 0 + 1077352) ~= 0 then
				break
			end
			loc_2 = 1
			loc_3 = 0
			loc_4 = 0
			while true do
				if loc_0 == 0 then
					break
				end
				loc_5 = load_i32(memory_at_0, loc_0)
				loc_1 = 0
				store_i32(memory_at_0, loc_0, 0)
				loc_2 = 1
				loc_3 = 0
				loc_4 = 0
				if loc_5 == 0 then
					break
				end
				loc_1 = load_i32(memory_at_0, loc_0 + 16)
				loc_2 = load_i32(memory_at_0, loc_0 + 12)
				loc_3 = load_i32(memory_at_0, loc_0 + 8)
				loc_4 = load_i32(memory_at_0, loc_0 + 4)
				break
			end
			store_i32(memory_at_0, 0 + 1077368, loc_1)
			store_i32(memory_at_0, 0 + 1077364, loc_2)
			store_i32(memory_at_0, 0 + 1077360, loc_3)
			store_i32(memory_at_0, 0 + 1077356, loc_4)
			store_i32(memory_at_0, 0 + 1077352, 1)
			break
		end
		reg_0 = 1077356
		break
	end
	return reg_0
end
FUNC_LIST[15] = --[[ _ZN6engine13process_input28_$u7b$$u7b$closure$u7d$$u7d$19panic_cold_explicit17hde01e855b5e0e7f1E ]] function(loc_0)
	while true do
		FUNC_LIST[212](loc_0)
		error("out of code bounds")
	end
end
FUNC_LIST[16] = --[[ main ]] function(loc_0, loc_1)
	local loc_2 = 0
	local reg_0
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_2
		store_i32(memory_at_0, loc_2 + 12, 2)
		reg_0 = FUNC_LIST[137](add_i32(loc_2, 12), 1048576, loc_0, loc_1, 0)
		loc_1 = reg_0
		GLOBAL_LIST[0].value = add_i32(loc_2, 16)
		reg_0 = loc_1
		break
	end
	return reg_0
end
FUNC_LIST[17] = --[[ _ZN3std6thread5local17LocalKey$LT$T$GT$4with17h4e4ea0b7912cbe07E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local reg_0
	local desired
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_2
		loc_3 = load_i32(memory_at_0, loc_1)
		while true do
			while true do
				while true do
					while true do
						while true do
							reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, loc_0)](0)
							loc_1 = reg_0
							if loc_1 == 0 then
								break
							end
							if load_i32(memory_at_0, loc_1) ~= 0 then
								desired = 3
								break
							end
							store_i32(memory_at_0, loc_1, 4294967295)
							while true do
								if loc_3 < 128 then
									break
								end
								store_i32(memory_at_0, loc_2 + 8, 0)
								if loc_3 < 2048 then
									desired = 4
									break
								end
								while true do
									if loc_3 >= 65536 then
										break
									end
									store_i32_n8(memory_at_0, loc_2 + 10, bor_i32(band_i32(loc_3, 63), 128))
									store_i32_n8(memory_at_0, loc_2 + 8, bor_i32(shr_u32(loc_3, 12), 224))
									store_i32_n8(memory_at_0, loc_2 + 9, bor_i32(band_i32(shr_u32(loc_3, 6), 63), 128))
									loc_3 = 3
									desired = 2
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								store_i32_n8(memory_at_0, loc_2 + 11, bor_i32(band_i32(loc_3, 63), 128))
								store_i32_n8(memory_at_0, loc_2 + 10, bor_i32(band_i32(shr_u32(loc_3, 6), 63), 128))
								store_i32_n8(memory_at_0, loc_2 + 9, bor_i32(band_i32(shr_u32(loc_3, 12), 63), 128))
								store_i32_n8(memory_at_0, loc_2 + 8, bor_i32(band_i32(shr_u32(loc_3, 18), 7), 240))
								loc_3 = 4
								desired = 2
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							while true do
								loc_0 = load_i32(memory_at_0, add_i32(loc_1, 12))
								if loc_0 ~= load_i32(memory_at_0, loc_1 + 4) then
									break
								end
								FUNC_LIST[10](add_i32(loc_1, 4), loc_0)
								loc_0 = load_i32(memory_at_0, loc_1 + 12)
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							store_i32_n8(memory_at_0, add_i32(load_i32(memory_at_0, add_i32(loc_1, 8)), loc_0), loc_3)
							store_i32(memory_at_0, loc_1 + 12, add_i32(load_i32(memory_at_0, loc_1 + 12), 1))
							desired = 1
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						FUNC_LIST[208](1048696, 70, add_i32(loc_2, 15), 1048768, 1048864)
						error("out of code bounds")
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32_n8(memory_at_0, loc_2 + 9, bor_i32(band_i32(loc_3, 63), 128))
					store_i32_n8(memory_at_0, loc_2 + 8, bor_i32(shr_u32(loc_3, 6), 192))
					loc_3 = 2
					desired = 2
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[201](1048924)
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				loc_0 = load_i32(memory_at_0, add_i32(loc_1, 12))
				if sub_i32(load_i32(memory_at_0, loc_1 + 4), loc_0) >= loc_3 then
					break
				end
				FUNC_LIST[8](add_i32(loc_1, 4), loc_0, loc_3)
				loc_0 = load_i32(memory_at_0, loc_1 + 12)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			reg_0 = FUNC_LIST[262](add_i32(load_i32(memory_at_0, add_i32(loc_1, 8)), loc_0), add_i32(loc_2, 8), loc_3)
			store_i32(memory_at_0, loc_1 + 12, add_i32(loc_0, loc_3))
			break
		end
		store_i32(memory_at_0, loc_1, add_i32(load_i32(memory_at_0, loc_1), 1))
		GLOBAL_LIST[0].value = add_i32(loc_2, 16)
		break
	end
end
FUNC_LIST[18] = --[[ _ZN3std6thread5local17LocalKey$LT$T$GT$4with17h57e20f90c5db9e80E ]] function(loc_0)
	local loc_1 = 0
	local loc_2 = 0
	local loc_3 = 0
	local reg_0
	local desired
	while true do
		loc_1 = sub_i32(GLOBAL_LIST[0].value, 48)
		GLOBAL_LIST[0].value = loc_1
		while true do
			while true do
				while true do
					reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, loc_0)](0)
					loc_0 = reg_0
					if loc_0 == 0 then
						break
					end
					loc_2 = load_i32(memory_at_0, loc_0)
					if loc_2 > 2147483646 then
						desired = 2
						break
					end
					store_i32(memory_at_0, loc_0, add_i32(loc_2, 1))
					loc_2 = load_i32(memory_at_0, add_i32(loc_0, 8))
					loc_3 = load_i32(memory_at_0, add_i32(loc_0, 12))
					store_i32_n16(memory_at_0, loc_1 + 40, 1)
					store_i32(memory_at_0, loc_1 + 36, 0)
					store_i32(memory_at_0, loc_1 + 32, add_i32(loc_2, loc_3))
					store_i32(memory_at_0, loc_1 + 28, loc_2)
					store_i32(memory_at_0, loc_1 + 24, loc_3)
					store_i32(memory_at_0, loc_1 + 20, loc_2)
					store_i32(memory_at_0, loc_1 + 16, loc_3)
					store_i32(memory_at_0, loc_1 + 12, 0)
					FUNC_LIST[19](1048604, add_i32(loc_1, 12))
					loc_2 = add_i32(load_i32(memory_at_0, loc_0), 4294967295)
					store_i32(memory_at_0, loc_0, loc_2)
					if loc_2 ~= 0 then
						desired = 1
						break
					end
					store_i32(memory_at_0, loc_0, 0)
					store_i32(memory_at_0, loc_0 + 12, 0)
					GLOBAL_LIST[0].value = add_i32(loc_1, 48)
					desired = 0
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[208](1048696, 70, add_i32(loc_1, 47), 1048768, 1048864)
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[202](1048908)
			error("out of code bounds")
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		FUNC_LIST[201](1048892)
		error("out of code bounds")
	end
end
FUNC_LIST[19] = --[[ _ZN3std6thread5local17LocalKey$LT$T$GT$4with17hadf3c2c47aaa993fE ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = 0
	local loc_8 = 0
	local loc_9 = 0
	local loc_10 = 0
	local loc_11 = 0
	local loc_12 = 0
	local loc_13 = 0
	local reg_0
	local desired
	local br_map = {}
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_2
		while true do
			while true do
				while true do
					while true do
						while true do
							reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, loc_0)](0)
							loc_3 = reg_0
							if loc_3 == 0 then
								break
							end
							loc_4 = load_i32(memory_at_0, add_i32(loc_1, 24))
							loc_0 = load_i32(memory_at_0, add_i32(loc_1, 16))
							loc_5 = load_i32(memory_at_0, add_i32(loc_1, 20))
							loc_6 = load_i32(memory_at_0, loc_1 + 4)
							loc_7 = load_i32(memory_at_0, loc_1 + 8)
							loc_8 = load_i32(memory_at_0, loc_1)
							loc_9 = load_i32_u8(memory_at_0, loc_1 + 29)
							loc_10 = band_i32(load_i32_u8(memory_at_0, loc_1 + 28), 255)
							while true do
								loc_11 = loc_8
								while true do
									while true do
										if band_i32(loc_9, 255) ~= 0 then
											break
										end
										while true do
											while true do
												if loc_0 == loc_5 then
													break
												end
												while true do
													loc_12 = loc_4
													loc_4 = loc_0
													loc_0 = add_i32(loc_4, 1)
													store_i32(memory_at_0, loc_1 + 16, loc_0)
													while true do
														loc_8 = load_i32_u8(memory_at_0, loc_4)
														if gt_i32(extend_i32_n8(loc_8), 4294967295) then
															break
														end
														loc_0 = add_i32(loc_4, 2)
														store_i32(memory_at_0, loc_1 + 16, loc_0)
														loc_9 = band_i32(load_i32_u8(memory_at_0, loc_4 + 1), 63)
														loc_13 = band_i32(loc_8, 31)
														while true do
															if loc_8 > 223 then
																break
															end
															loc_8 = bor_i32(shl_i32(loc_13, 6), loc_9)
															desired = 12
															break
														end
														if desired then
															if desired == 12 then
																desired = nil
															end
															break
														end
														loc_0 = add_i32(loc_4, 3)
														store_i32(memory_at_0, loc_1 + 16, loc_0)
														loc_9 = bor_i32(shl_i32(loc_9, 6), band_i32(load_i32_u8(memory_at_0, loc_4 + 2), 63))
														while true do
															if loc_8 >= 240 then
																break
															end
															loc_8 = bor_i32(loc_9, shl_i32(loc_13, 12))
															desired = 12
															break
														end
														if desired then
															if desired == 12 then
																desired = nil
															end
															break
														end
														loc_0 = add_i32(loc_4, 4)
														store_i32(memory_at_0, loc_1 + 16, loc_0)
														loc_8 = bor_i32(bor_i32(shl_i32(loc_9, 6), band_i32(load_i32_u8(memory_at_0, loc_4 + 3), 63)), band_i32(shl_i32(loc_13, 18), 1835008))
														if loc_8 ~= 1114112 then
															break
														end
														loc_4 = loc_12
														desired = 9
														break
													end
													if desired then
														if desired == 11 then
															desired = nil
															continue
														end
														break
													end
													loc_4 = add_i32(sub_i32(loc_0, loc_4), loc_12)
													store_i32(memory_at_0, loc_1 + 24, loc_4)
													while true do
														while true do
															while true do
																loc_9 = add_i32(loc_8, 4294967287)
																if loc_9 > 23 then
																	break
																end
																if band_i32(shl_i32(1, loc_9), 8388639) ~= 0 then
																	desired = 13
																	break
																end
																break
															end
															if desired then
																if desired == 13 then
																	desired = nil
																end
																break
															end
															if loc_8 < 128 then
																desired = 12
																break
															end
															while true do
																while true do
																	while true do
																		while true do
																			loc_9 = shr_u32(loc_8, 8)
																			if not br_map[1] then
																				br_map[1] = (function()
																					return { [0] = 3, 5, 5, 5, 5, 5, 5, 5, 5, 5, 1, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 0, }
																				end)()
																			end
																			temp = br_map[1][add_i32(loc_9, 4294967274)] or 2
																			if temp < 2 then
																				if temp < 1 then
																					break
																				else
																					desired = 16
																					break
																				end
																			elseif temp > 2 then
																				if temp < 5 then
																					desired = 14
																					break
																				else
																					desired = 12
																					break
																				end
																			else
																				desired = 15
																				break
																			end
																		end
																		if desired then
																			if desired == 16 then
																				desired = nil
																			end
																			break
																		end
																		if loc_8 ~= 12288 then
																			desired = 12
																			break
																		end
																		desired = 13
																		break
																	end
																	if desired then
																		if desired == 15 then
																			desired = nil
																		end
																		break
																	end
																	if band_i32(load_i32_u8(memory_at_0, add_i32(band_i32(loc_8, 255), 1077031)), 2) == 0 then
																		desired = 12
																		break
																	end
																	desired = 13
																	break
																end
																if desired then
																	if desired == 14 then
																		desired = nil
																	end
																	break
																end
																if loc_9 ~= 0 then
																	desired = 12
																	break
																end
																if band_i32(load_i32_u8(memory_at_0, add_i32(band_i32(loc_8, 255), 1077031)), 1) ~= 0 then
																	desired = 13
																	break
																end
																desired = 12
																break
															end
															if desired then
																if desired == 13 then
																	desired = nil
																end
																break
															end
															if loc_8 ~= 5760 then
																desired = 12
																break
															end
															break
														end
														if desired then
															if desired == 12 then
																desired = nil
															end
															break
														end
														store_i32(memory_at_0, loc_1, loc_4)
														loc_9 = 0
														loc_8 = loc_4
														desired = 7
														break
													end
													if desired then
														if desired == 11 then
															desired = nil
															continue
														end
														break
													end
													if loc_0 ~= loc_5 then
														continue
													end
													break
												end
												if desired then
													if desired == 10 then
														desired = nil
													end
													break
												end
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											loc_0 = loc_5
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										loc_9 = 1
										store_i32_n8(memory_at_0, loc_1 + 29, 1)
										while true do
											if loc_10 == 0 then
												break
											end
											loc_8 = loc_11
											loc_12 = loc_6
											desired = 7
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										loc_8 = loc_11
										loc_12 = loc_6
										if loc_6 ~= loc_11 then
											desired = 7
											break
										end
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									FUNC_LIST[192](1048940, 43, 1048984)
									error("out of code bounds")
								end
								if desired then
									if desired == 6 then
										desired = nil
										continue
									end
									break
								end
								if loc_12 == loc_11 then
									continue
								end
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_0 = add_i32(loc_7, loc_11)
							while true do
								while true do
									while true do
										while true do
											while true do
												while true do
													while true do
														while true do
															while true do
																while true do
																	while true do
																		while true do
																			if not br_map[2] then
																				br_map[2] = (function()
																					return { [0] = 4, 6, 3, 7, 7, 0, 1, 7, 2, }
																				end)()
																			end
																			temp = br_map[2][add_i32(sub_i32(loc_12, loc_11), 4294967294)] or 7
																			if temp < 3 then
																				if temp < 1 then
																					break
																				elseif temp > 1 then
																					desired = 15
																					break
																				else
																					desired = 16
																					break
																				end
																			elseif temp > 3 then
																				if temp < 6 then
																					desired = 13
																					break
																				elseif temp > 6 then
																					desired = 10
																					break
																				else
																					desired = 11
																					break
																				end
																			else
																				desired = 14
																				break
																			end
																		end
																		if desired then
																			if desired == 16 then
																				desired = nil
																			end
																			break
																		end
																		reg_0 = FUNC_LIST[260](loc_0, 1049003, 7)
																		if reg_0 ~= 0 then
																			desired = 10
																			break
																		end
																		loc_0 = load_i32(memory_at_0, loc_3)
																		if loc_0 >= 2147483647 then
																			desired = 7
																			break
																		end
																		store_i32(memory_at_0, loc_3, add_i32(loc_0, 1))
																		FUNC_LIST[35](add_i32(loc_3, 8))
																		loc_0 = 4294967295
																		desired = 3
																		break
																	end
																	if desired then
																		if desired == 15 then
																			desired = nil
																		end
																		break
																	end
																	if ne_i64(load_i64(memory_at_0, loc_0), i64_from_u32(1769172848, 1852795252)) then
																		desired = 10
																		break
																	end
																	if load_i32(memory_at_0, loc_3) ~= 0 then
																		desired = 8
																		break
																	end
																	store_i32(memory_at_0, loc_3, 4294967295)
																	FUNC_LIST[36](add_i32(loc_3, 8), loc_1)
																	desired = 12
																	break
																end
																if desired then
																	if desired == 14 then
																		desired = nil
																	end
																	break
																end
																reg_0 = FUNC_LIST[260](loc_0, 1049010, 10)
																if reg_0 ~= 0 then
																	desired = 10
																	break
																end
																if load_i32(memory_at_0, loc_3) < 2147483647 then
																	desired = 2
																	break
																end
																FUNC_LIST[202](1049084)
																error("out of code bounds")
															end
															if desired then
																if desired == 13 then
																	desired = nil
																end
																break
															end
															if load_i32(memory_at_0, loc_0) == 1953068401 then
																desired = 1
																break
															end
															if load_i32(memory_at_0, loc_0) ~= 1886352499 then
																desired = 10
																break
															end
															if load_i32(memory_at_0, loc_3) < 2147483647 then
																desired = 2
																break
															end
															FUNC_LIST[202](1049052)
															error("out of code bounds")
														end
														if desired then
															if desired == 12 then
																desired = nil
															end
															break
														end
														if load_i32_u16(memory_at_0, loc_0) ~= 28519 then
															desired = 10
															break
														end
														if load_i32(memory_at_0, loc_3) ~= 0 then
															desired = 9
															break
														end
														store_i32(memory_at_0, loc_3, 4294967295)
														FUNC_LIST[37](add_i32(loc_3, 8), loc_1)
														break
													end
													if desired then
														if desired == 11 then
															desired = nil
														end
														break
													end
													loc_0 = 1
													desired = 3
													break
												end
												if desired then
													if desired == 10 then
														desired = nil
													end
													break
												end
												reg_0 = FUNC_LIST[260](loc_0, 1049000, 3)
												if reg_0 == 0 then
													desired = 6
													break
												end
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											FUNC_LIST[192](1049020, 15, 1049036)
											error("out of code bounds")
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										FUNC_LIST[201](1049068)
										error("out of code bounds")
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									FUNC_LIST[201](1049100)
									error("out of code bounds")
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								FUNC_LIST[202](1049116)
								error("out of code bounds")
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_0 = load_i32(memory_at_0, loc_3)
							if loc_0 < 2147483647 then
								desired = 4
								break
							end
							FUNC_LIST[202](1049132)
							error("out of code bounds")
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						FUNC_LIST[208](1048696, 70, add_i32(loc_2, 15), 1048768, 1048864)
						error("out of code bounds")
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32(memory_at_0, loc_3, add_i32(loc_0, 1))
					FUNC_LIST[34](add_i32(loc_3, 8))
					loc_0 = 4294967295
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i32(memory_at_0, loc_3, add_i32(load_i32(memory_at_0, loc_3), loc_0))
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			GLOBAL_LIST[0].value = add_i32(loc_2, 16)
			desired = 0
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		FUNC_LIST[15](1049148)
		error("out of code bounds")
	end
end
FUNC_LIST[20] = --[[ _ZN4core3ptr52drop_in_place$LT$std..thread..local..AccessError$GT$17h4c03a003a025e2e7E.llvm.18281253945106784138 ]] function(loc_0)
	while true do
		break
	end
end
FUNC_LIST[21] = --[[ __rust_alloc ]] function(loc_0, loc_1)
	local loc_2 = 0
	local reg_0
	while true do
		reg_0 = FUNC_LIST[152](loc_0, loc_1)
		loc_2 = reg_0
		reg_0 = loc_2
		break
	end
	return reg_0
end
FUNC_LIST[22] = --[[ __rust_dealloc ]] function(loc_0, loc_1, loc_2)
	while true do
		FUNC_LIST[153](loc_0, loc_1, loc_2)
		break
	end
end
FUNC_LIST[23] = --[[ __rust_realloc ]] function(loc_0, loc_1, loc_2, loc_3)
	local loc_4 = 0
	local reg_0
	while true do
		reg_0 = FUNC_LIST[154](loc_0, loc_1, loc_2, loc_3)
		loc_4 = reg_0
		reg_0 = loc_4
		break
	end
	return reg_0
end
FUNC_LIST[24] = --[[ __rust_alloc_error_handler ]] function(loc_0, loc_1)
	while true do
		FUNC_LIST[163](loc_0, loc_1)
		break
	end
end
FUNC_LIST[25] = --[[ _ZN4core3ops8function6FnOnce40call_once$u7b$$u7b$vtable.shim$u7d$$u7d$17h48702a3f55163e23E ]] function(loc_0)
	local loc_1 = 0
	local loc_2 = 0
	local loc_3 = 0.0
	local loc_4 = i64_ZERO
	local loc_5 = i64_ZERO
	local loc_6 = i64_ZERO
	local loc_7 = i64_ZERO
	local reg_0
	local reg_1
	while true do
		loc_1 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_1
		loc_2 = load_i32(memory_at_0, loc_0 + 4)
		loc_0 = load_i32(memory_at_0, loc_0)
		reg_1 = FUNC_LIST[1]()
		loc_3 = ((reg_1 - load_f64(memory_at_0, loc_0)) * 1e3)
		FUNC_LIST[252](loc_1, loc_3)
		loc_4 = load_i64(memory_at_0, add_i32(loc_1, 8))
		loc_5 = load_i64(memory_at_0, add_i32(loc_2, 8))
		loc_6 = load_i64(memory_at_0, loc_1)
		loc_7 = load_i64(memory_at_0, loc_2)
		GLOBAL_LIST[0].value = add_i32(loc_1, 16)
		loc_1 = (if loc_3 >= 0e0 then 1 else 0)
		loc_0 = (if loc_3 > 3.4028236692093843e38 then 1 else 0)
		loc_4 = (if loc_0 ~= 0 then i64_from_u32(4294967295, 4294967295) else (if loc_1 ~= 0 then loc_4 else i64_ZERO))
		reg_0 = (if eq_i64(loc_4, loc_5) then (if gt_u64((if loc_0 ~= 0 then i64_from_u32(4294967295, 4294967295) else (if loc_1 ~= 0 then loc_6 else i64_ZERO)), loc_7) then 1 else 0) else (if gt_u64(loc_4, loc_5) then 1 else 0))
		break
	end
	return reg_0
end
FUNC_LIST[26] = --[[ _ZN4core3ptr52drop_in_place$LT$core..num..error..ParseIntError$GT$17h8aba332ab6766012E ]] function(loc_0)
	while true do
		break
	end
end
FUNC_LIST[27] = --[[ _ZN4core3ptr55drop_in_place$LT$$RF$core..num..error..IntErrorKind$GT$17h08ab09bdf48e77bcE ]] function(loc_0)
	while true do
		break
	end
end
FUNC_LIST[28] = --[[ _ZN4core4iter6traits8iterator8Iterator8try_fold17h93e4dd8763395b06E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = 0
	local loc_8 = 0
	local loc_9 = 0
	local loc_10 = 0
	local loc_11 = 0
	local loc_12 = 0
	local loc_13 = 0
	local desired
	local br_map = {}
	while true do
		loc_2 = load_i32(memory_at_0, add_i32(loc_1, 24))
		loc_3 = load_i32(memory_at_0, add_i32(loc_1, 16))
		loc_4 = load_i32(memory_at_0, add_i32(loc_1, 20))
		loc_5 = load_i32(memory_at_0, loc_1 + 4)
		loc_6 = load_i32(memory_at_0, loc_1 + 8)
		loc_7 = load_i32(memory_at_0, loc_1)
		loc_8 = load_i32_u8(memory_at_0, loc_1 + 29)
		loc_9 = band_i32(load_i32_u8(memory_at_0, loc_1 + 28), 255)
		while true do
			while true do
				loc_10 = loc_7
				loc_11 = 0
				while true do
					if band_i32(loc_8, 255) == 0 then
						break
					end
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
						continue
					end
					break
				end
				while true do
					while true do
						while true do
							if loc_3 == loc_4 then
								break
							end
							while true do
								loc_12 = loc_2
								loc_2 = loc_3
								loc_3 = add_i32(loc_2, 1)
								store_i32(memory_at_0, loc_1 + 16, loc_3)
								while true do
									loc_7 = load_i32_u8(memory_at_0, loc_2)
									if gt_i32(extend_i32_n8(loc_7), 4294967295) then
										break
									end
									loc_3 = add_i32(loc_2, 2)
									store_i32(memory_at_0, loc_1 + 16, loc_3)
									loc_8 = band_i32(load_i32_u8(memory_at_0, loc_2 + 1), 63)
									loc_13 = band_i32(loc_7, 31)
									while true do
										if loc_7 > 223 then
											break
										end
										loc_7 = bor_i32(shl_i32(loc_13, 6), loc_8)
										desired = 7
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									loc_3 = add_i32(loc_2, 3)
									store_i32(memory_at_0, loc_1 + 16, loc_3)
									loc_8 = bor_i32(shl_i32(loc_8, 6), band_i32(load_i32_u8(memory_at_0, loc_2 + 2), 63))
									while true do
										if loc_7 >= 240 then
											break
										end
										loc_7 = bor_i32(loc_8, shl_i32(loc_13, 12))
										desired = 7
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									loc_3 = add_i32(loc_2, 4)
									store_i32(memory_at_0, loc_1 + 16, loc_3)
									loc_7 = bor_i32(bor_i32(shl_i32(loc_8, 6), band_i32(load_i32_u8(memory_at_0, loc_2 + 3), 63)), band_i32(shl_i32(loc_13, 18), 1835008))
									if loc_7 ~= 1114112 then
										break
									end
									loc_2 = loc_12
									desired = 4
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
										continue
									end
									break
								end
								loc_2 = add_i32(sub_i32(loc_3, loc_2), loc_12)
								store_i32(memory_at_0, loc_1 + 24, loc_2)
								while true do
									while true do
										while true do
											loc_8 = add_i32(loc_7, 4294967287)
											if loc_8 > 23 then
												break
											end
											if band_i32(shl_i32(1, loc_8), 8388639) ~= 0 then
												desired = 8
												break
											end
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										if loc_7 < 128 then
											desired = 7
											break
										end
										while true do
											while true do
												while true do
													while true do
														loc_8 = shr_u32(loc_7, 8)
														if not br_map[1] then
															br_map[1] = (function()
																return { [0] = 3, 5, 5, 5, 5, 5, 5, 5, 5, 5, 1, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 0, }
															end)()
														end
														temp = br_map[1][add_i32(loc_8, 4294967274)] or 2
														if temp < 2 then
															if temp < 1 then
																break
															else
																desired = 11
																break
															end
														elseif temp > 2 then
															if temp < 5 then
																desired = 9
																break
															else
																desired = 7
																break
															end
														else
															desired = 10
															break
														end
													end
													if desired then
														if desired == 11 then
															desired = nil
														end
														break
													end
													if loc_7 ~= 12288 then
														desired = 7
														break
													end
													desired = 8
													break
												end
												if desired then
													if desired == 10 then
														desired = nil
													end
													break
												end
												if band_i32(load_i32_u8(memory_at_0, add_i32(band_i32(loc_7, 255), 1077031)), 2) == 0 then
													desired = 7
													break
												end
												desired = 8
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											if loc_8 ~= 0 then
												desired = 7
												break
											end
											if band_i32(load_i32_u8(memory_at_0, add_i32(band_i32(loc_7, 255), 1077031)), 1) ~= 0 then
												desired = 8
												break
											end
											desired = 7
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										if loc_7 ~= 5760 then
											desired = 7
											break
										end
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									store_i32(memory_at_0, loc_1, loc_2)
									loc_8 = 0
									loc_7 = loc_2
									desired = 3
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
										continue
									end
									break
								end
								if loc_3 ~= loc_4 then
									continue
								end
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_3 = loc_4
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_8 = 1
					store_i32_n8(memory_at_0, loc_1 + 29, 1)
					while true do
						if loc_9 == 0 then
							break
						end
						loc_7 = loc_10
						loc_12 = loc_5
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_7 = loc_10
					loc_12 = loc_5
					if loc_5 == loc_10 then
						desired = 1
						break
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
						continue
					end
					break
				end
				loc_13 = sub_i32(loc_12, loc_10)
				if loc_13 == 0 then
					continue
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_11 = add_i32(loc_6, loc_10)
			break
		end
		store_i32(memory_at_0, loc_0 + 4, loc_13)
		store_i32(memory_at_0, loc_0, loc_11)
		break
	end
end
FUNC_LIST[29] = --[[ _ZN60_$LT$alloc..string..String$u20$as$u20$core..fmt..Display$GT$3fmt17h716fe1dd8cfb591fE ]] function(loc_0, loc_1)
	local reg_0
	while true do
		reg_0 = FUNC_LIST[237](load_i32(memory_at_0, loc_0 + 4), load_i32(memory_at_0, loc_0 + 8), loc_1)
		break
	end
	return reg_0
end
FUNC_LIST[30] = --[[ _ZN68_$LT$core..num..error..ParseIntError$u20$as$u20$core..fmt..Debug$GT$3fmt17h7cef7ce39f0947e1E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local reg_0
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_2
		store_i32(memory_at_0, loc_2 + 12, loc_0)
		reg_0 = FUNC_LIST[231](loc_1, 1049164, 13, 1049177, 4, add_i32(loc_2, 12), 1049184)
		loc_0 = reg_0
		GLOBAL_LIST[0].value = add_i32(loc_2, 16)
		reg_0 = loc_0
		break
	end
	return reg_0
end
FUNC_LIST[31] = --[[ _ZN6engine3uci11encode_move17hae94d597cd852bb5E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = 0
	local reg_0
	local desired
	local br_map = {}
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 80)
		GLOBAL_LIST[0].value = loc_2
		loc_3 = 0
		while true do
			while true do
				while true do
					while true do
						reg_0 = FUNC_LIST[21](4, 1)
						loc_4 = reg_0
						if loc_4 == 0 then
							break
						end
						loc_5 = band_i32(loc_1, 16711680)
						store_i32(memory_at_0, loc_2 + 16, 0)
						store_i32(memory_at_0, loc_2 + 12, loc_4)
						store_i32(memory_at_0, loc_2 + 8, 4)
						loc_6 = shr_u32(loc_1, 8)
						store_i32(memory_at_0, loc_2 + 32, add_i32(band_i32(loc_6, 7), 97))
						store_i32_n8(memory_at_0, loc_2 + 39, add_i32(shr_u32(extend_i32_n8(loc_6), 3), 1))
						store_i64(memory_at_0, add_i32(add_i32(loc_2, 40), 12), i64_from_u32(2, 0))
						store_i32(memory_at_0, add_i32(add_i32(loc_2, 64), 12), 12)
						store_i32(memory_at_0, loc_2 + 44, 2)
						store_i32(memory_at_0, loc_2 + 40, 1063180)
						store_i32(memory_at_0, loc_2 + 68, 13)
						store_i32(memory_at_0, loc_2 + 48, add_i32(loc_2, 64))
						store_i32(memory_at_0, loc_2 + 72, add_i32(loc_2, 39))
						store_i32(memory_at_0, loc_2 + 64, add_i32(loc_2, 32))
						FUNC_LIST[178](add_i32(loc_2, 20), add_i32(loc_2, 40))
						loc_7 = load_i32(memory_at_0, loc_2 + 24)
						while true do
							loc_6 = load_i32(memory_at_0, loc_2 + 28)
							if loc_6 < 5 then
								break
							end
							FUNC_LIST[62](add_i32(loc_2, 8), 0, loc_6)
							loc_4 = load_i32(memory_at_0, loc_2 + 12)
							loc_3 = load_i32(memory_at_0, loc_2 + 16)
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_5 = shr_u32(loc_5, 16)
						reg_0 = FUNC_LIST[262](add_i32(loc_4, loc_3), loc_7, loc_6)
						loc_3 = add_i32(loc_3, loc_6)
						store_i32(memory_at_0, loc_2 + 16, loc_3)
						while true do
							loc_4 = load_i32(memory_at_0, loc_2 + 20)
							if loc_4 == 0 then
								break
							end
							FUNC_LIST[22](loc_7, loc_4, 1)
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						store_i32(memory_at_0, loc_2 + 32, add_i32(band_i32(loc_5, 7), 97))
						store_i32_n8(memory_at_0, loc_2 + 39, add_i32(shr_u32(extend_i32_n8(loc_5), 3), 1))
						store_i64(memory_at_0, add_i32(add_i32(loc_2, 40), 12), i64_from_u32(2, 0))
						store_i32(memory_at_0, add_i32(add_i32(loc_2, 64), 12), 12)
						store_i32(memory_at_0, loc_2 + 44, 2)
						store_i32(memory_at_0, loc_2 + 40, 1063180)
						store_i32(memory_at_0, loc_2 + 68, 13)
						store_i32(memory_at_0, loc_2 + 48, add_i32(loc_2, 64))
						store_i32(memory_at_0, loc_2 + 72, add_i32(loc_2, 39))
						store_i32(memory_at_0, loc_2 + 64, add_i32(loc_2, 32))
						FUNC_LIST[178](add_i32(loc_2, 20), add_i32(loc_2, 40))
						loc_6 = load_i32(memory_at_0, loc_2 + 24)
						while true do
							loc_4 = load_i32(memory_at_0, loc_2 + 28)
							if sub_i32(load_i32(memory_at_0, loc_2 + 8), loc_3) >= loc_4 then
								break
							end
							FUNC_LIST[62](add_i32(loc_2, 8), loc_3, loc_4)
							loc_3 = load_i32(memory_at_0, loc_2 + 16)
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						reg_0 = FUNC_LIST[262](add_i32(load_i32(memory_at_0, loc_2 + 12), loc_3), loc_6, loc_4)
						loc_3 = add_i32(loc_3, loc_4)
						store_i32(memory_at_0, loc_2 + 16, loc_3)
						while true do
							loc_4 = load_i32(memory_at_0, loc_2 + 20)
							if loc_4 == 0 then
								break
							end
							FUNC_LIST[22](loc_6, loc_4, 1)
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						while true do
							while true do
								while true do
									while true do
										if not br_map[1] then
											br_map[1] = (function()
												return { [0] = 0, 1, 2, 3, }
											end)()
										end
										temp = br_map[1][add_i32(band_i32(loc_1, 255), 4294967295)] or 7
										if temp < 2 then
											if temp < 1 then
												break
											else
												desired = 7
												break
											end
										elseif temp > 2 then
											if temp < 7 then
												desired = 5
												break
											else
												desired = 1
												break
											end
										else
											desired = 6
											break
										end
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									loc_1 = 113
									if loc_3 ~= load_i32(memory_at_0, loc_2 + 8) then
										desired = 2
										break
									end
									desired = 3
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								loc_1 = 114
								if loc_3 == load_i32(memory_at_0, loc_2 + 8) then
									desired = 3
									break
								end
								desired = 2
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_1 = 98
							if loc_3 == load_i32(memory_at_0, loc_2 + 8) then
								desired = 3
								break
							end
							desired = 2
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_1 = 110
						if loc_3 == load_i32(memory_at_0, loc_2 + 8) then
							desired = 3
							break
						end
						desired = 2
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					FUNC_LIST[173](1, 4)
					error("out of code bounds")
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[57](add_i32(loc_2, 8), loc_3)
				loc_3 = load_i32(memory_at_0, loc_2 + 16)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			store_i32_n8(memory_at_0, add_i32(load_i32(memory_at_0, loc_2 + 12), loc_3), loc_1)
			store_i32(memory_at_0, loc_2 + 16, add_i32(load_i32(memory_at_0, loc_2 + 16), 1))
			break
		end
		store_i64(memory_at_0, loc_0, load_i64(memory_at_0, loc_2 + 8))
		store_i32(memory_at_0, add_i32(loc_0, 8), load_i32(memory_at_0, add_i32(add_i32(loc_2, 8), 8)))
		GLOBAL_LIST[0].value = add_i32(loc_2, 80)
		break
	end
end
FUNC_LIST[32] = --[[ _ZN6engine3uci11decode_move17h81b5581df02851b7E ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = i64_ZERO
	local loc_7 = 0
	local loc_8 = 0
	local reg_0
	local desired
	local br_map = {}
	while true do
		loc_3 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_3
		while true do
			while true do
				while true do
					if loc_2 > 2 then
						break
					end
					if loc_2 == 2 then
						desired = 2
						break
					end
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				if le_i32(load_i32_i8(memory_at_0, loc_1 + 2), 4294967231) then
					desired = 1
					break
				end
				while true do
					while true do
						if loc_2 > 4 then
							break
						end
						if loc_2 == 4 then
							desired = 3
							break
						end
						desired = 2
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					if le_i32(load_i32_i8(memory_at_0, loc_1 + 4), 4294967231) then
						desired = 2
						break
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				reg_0 = FUNC_LIST[76](loc_1, 2)
				loc_4 = reg_0
				reg_0 = FUNC_LIST[76](add_i32(loc_1, 2), 2)
				loc_5 = reg_0
				while true do
					while true do
						while true do
							loc_6 = shl_i64(i64_ONE, extend_i64_u32(loc_4))
							if (if eq_i64(band_i64(load_i64(memory_at_0, loc_0 + 32), loc_6), i64_ZERO) then 1 else 0) == 0 then
								break
							end
							loc_7 = 0
							if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 40)), loc_6), i64_ZERO) then
								desired = 3
								break
							end
							if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 48)), loc_6), i64_ZERO) then
								desired = 3
								break
							end
							if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 56)), loc_6), i64_ZERO) then
								desired = 3
								break
							end
							if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 64)), loc_6), i64_ZERO) then
								desired = 3
								break
							end
							if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 72)), loc_6), i64_ZERO) then
								desired = 4
								break
							end
							if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 80)), loc_6), i64_ZERO) then
								break
							end
							if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 88)), loc_6), i64_ZERO) then
								desired = 3
								break
							end
							if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 96)), loc_6), i64_ZERO) then
								desired = 3
								break
							end
							if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 104)), loc_6), i64_ZERO) then
								desired = 3
								break
							end
							if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 112)), loc_6), i64_ZERO) then
								desired = 3
								break
							end
							if (if eq_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 120)), loc_6), i64_ZERO) then 1 else 0) == 0 then
								desired = 4
								break
							end
							FUNC_LIST[192](1049504, 43, 1049548)
							error("out of code bounds")
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_7 = 6
						loc_8 = sub_i32(shr_i32(extend_i32_n8(loc_4), 3), shr_i32(extend_i32_n8(loc_5), 3))
						reg_0 = loc_8
						loc_8 = shr_i32(extend_i32_n8(loc_8), 7)
						if band_i32(sub_i32(bxor_i32(reg_0, loc_8), loc_8), 255) == 2 then
							desired = 3
							break
						end
						while true do
							if load_i32_u8(memory_at_0, loc_0 + 26) == 0 then
								break
							end
							loc_7 = 5
							if band_i32(load_i32_u8(memory_at_0, add_i32(loc_0, 27)), 255) == band_i32(loc_5, 255) then
								desired = 3
								break
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_7 = 0
						loc_0 = load_i32_u8(memory_at_0, add_i32(load_i32_u8(memory_at_0, loc_1), 1049200))
						if loc_0 == loc_2 then
							desired = 3
							break
						end
						loc_2 = add_i32(loc_1, loc_2)
						loc_1 = add_i32(loc_1, loc_0)
						loc_1 = add_i32(loc_1, load_i32_u8(memory_at_0, add_i32(load_i32_u8(memory_at_0, loc_1), 1049200)))
						if loc_2 == loc_1 then
							desired = 3
							break
						end
						loc_1 = add_i32(loc_1, load_i32_u8(memory_at_0, add_i32(load_i32_u8(memory_at_0, loc_1), 1049200)))
						if loc_2 == loc_1 then
							desired = 3
							break
						end
						loc_1 = add_i32(loc_1, load_i32_u8(memory_at_0, add_i32(load_i32_u8(memory_at_0, loc_1), 1049200)))
						if loc_1 == loc_2 then
							desired = 3
							break
						end
						while true do
							while true do
								loc_2 = load_i32_i8(memory_at_0, loc_1)
								if le_i32(loc_2, 4294967295) then
									break
								end
								loc_1 = band_i32(loc_2, 255)
								desired = 5
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_0 = band_i32(load_i32_u8(memory_at_0, loc_1 + 1), 63)
							loc_7 = band_i32(loc_2, 31)
							while true do
								if loc_2 > 4294967263 then
									break
								end
								loc_1 = bor_i32(shl_i32(loc_7, 6), loc_0)
								desired = 5
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_0 = bor_i32(shl_i32(loc_0, 6), band_i32(load_i32_u8(memory_at_0, loc_1 + 2), 63))
							while true do
								if loc_2 >= 4294967280 then
									break
								end
								loc_1 = bor_i32(loc_0, shl_i32(loc_7, 12))
								desired = 5
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_1 = bor_i32(bor_i32(shl_i32(loc_0, 6), band_i32(load_i32_u8(memory_at_0, loc_1 + 3), 63)), band_i32(shl_i32(loc_7, 18), 1835008))
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_7 = 1
						while true do
							while true do
								while true do
									while true do
										while true do
											if not br_map[1] then
												br_map[1] = (function()
													return { [0] = 4, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 3, 1, 1, 6, 2, }
												end)()
											end
											temp = br_map[1][add_i32(loc_1, 4294967198)] or 0
											if temp < 3 then
												if temp < 1 then
													break
												elseif temp > 1 then
													desired = 7
													break
												else
													desired = 8
													break
												end
											elseif temp > 3 then
												if temp < 6 then
													desired = 5
													break
												else
													desired = 3
													break
												end
											else
												desired = 6
												break
											end
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										loc_7 = 0
										if loc_1 == 1114112 then
											desired = 3
											break
										end
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									store_i64(memory_at_0, add_i32(loc_3, 20), i64_ZERO)
									store_i32(memory_at_0, loc_3 + 12, 1)
									store_i32(memory_at_0, loc_3 + 8, 1049592)
									store_i32(memory_at_0, loc_3 + 16, 1049164)
									FUNC_LIST[187](add_i32(loc_3, 8), 1049600)
									error("out of code bounds")
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								loc_7 = 2
								desired = 3
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_7 = 4
							desired = 3
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_7 = 3
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_1 = band_i32(loc_5, 7)
					loc_2 = band_i32(loc_4, 7)
					loc_7 = (if (if loc_2 < loc_1 then sub_i32(loc_1, loc_2) else sub_i32(loc_2, loc_1)) > 1 then 7 else 0)
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				GLOBAL_LIST[0].value = add_i32(loc_3, 32)
				reg_0 = bor_i32(bor_i32(shl_i32(loc_5, 16), shl_i32(band_i32(loc_4, 255), 8)), loc_7)
				desired = 0
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[236](loc_1, loc_2, 2, 4, 1049488)
			error("out of code bounds")
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		FUNC_LIST[236](loc_1, loc_2, 0, 2, 1049472)
		error("out of code bounds")
	end
	return reg_0
end
FUNC_LIST[33] = --[[ _ZN6engine3uci12GoParameters5parse17hbe057a700c388083E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = 0
	local loc_8 = 0
	local loc_9 = 0
	local loc_10 = i64_ZERO
	local reg_0
	local desired
	local br_map = {}
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 128)
		GLOBAL_LIST[0].value = loc_2
		FUNC_LIST[28](add_i32(loc_2, 88), loc_1)
		while true do
			loc_3 = load_i32(memory_at_0, loc_2 + 88)
			if loc_3 == 0 then
				break
			end
			loc_4 = load_i32(memory_at_0, loc_2 + 92)
			loc_5 = add_i32(loc_0, 64)
			loc_6 = add_i32(add_i32(loc_2, 96), 16)
			loc_7 = add_i32(loc_0, 88)
			loc_8 = add_i32(loc_0, 40)
			loc_9 = add_i32(loc_0, 160)
			while true do
				while true do
					while true do
						while true do
							while true do
								while true do
									while true do
										while true do
											while true do
												while true do
													while true do
														while true do
															while true do
																while true do
																	while true do
																		while true do
																			while true do
																				while true do
																					while true do
																						while true do
																							while true do
																								while true do
																									while true do
																										while true do
																											while true do
																												if not br_map[1] then
																													br_map[1] = (function()
																														return { [0] = 2, 1, 0, 9, 5, 3, 9, 8, }
																													end)()
																												end
																												temp = br_map[1][add_i32(loc_4, 4294967292)] or 9
																												if temp < 3 then
																													if temp < 1 then
																														break
																													elseif temp > 1 then
																														desired = 24
																														break
																													else
																														desired = 25
																														break
																													end
																												elseif temp > 3 then
																													if temp < 8 then
																														desired = 21
																														break
																													elseif temp > 8 then
																														desired = 17
																														break
																													else
																														desired = 18
																														break
																													end
																												else
																													desired = 23
																													break
																												end
																											end
																											if desired then
																												if desired == 25 then
																													desired = nil
																												end
																												break
																											end
																											reg_0 = FUNC_LIST[260](loc_3, 1049627, 6)
																											if reg_0 ~= 0 then
																												desired = 17
																												break
																											end
																											desired = 3
																											break
																										end
																										if desired then
																											if desired == 24 then
																												desired = nil
																											end
																											break
																										end
																										reg_0 = FUNC_LIST[260](loc_3, 1049633, 5)
																										if reg_0 == 0 then
																											desired = 7
																											break
																										end
																										reg_0 = FUNC_LIST[260](loc_3, 1049638, 5)
																										if reg_0 ~= 0 then
																											desired = 22
																											break
																										end
																										FUNC_LIST[28](add_i32(loc_2, 16), loc_1)
																										loc_3 = load_i32(memory_at_0, loc_2 + 16)
																										if loc_3 ~= 0 then
																											desired = 8
																											break
																										end
																										FUNC_LIST[192](1049504, 43, 1050032)
																										error("out of code bounds")
																									end
																									if desired then
																										if desired == 23 then
																											desired = nil
																										end
																										break
																									end
																									if load_i32(memory_at_0, loc_3) == 1668180343 then
																										desired = 9
																										break
																									end
																									if load_i32(memory_at_0, loc_3) ~= 1668180322 then
																										desired = 20
																										break
																									end
																									FUNC_LIST[28](add_i32(loc_2, 56), loc_1)
																									loc_3 = load_i32(memory_at_0, loc_2 + 56)
																									if loc_3 ~= 0 then
																										desired = 10
																										break
																									end
																									FUNC_LIST[192](1049504, 43, 1049968)
																									error("out of code bounds")
																								end
																								if desired then
																									if desired == 22 then
																										desired = nil
																									end
																									break
																								end
																								reg_0 = FUNC_LIST[260](loc_3, 1049643, loc_4)
																								if reg_0 ~= 0 then
																									desired = 17
																									break
																								end
																								FUNC_LIST[28](add_i32(loc_2, 72), loc_1)
																								loc_3 = load_i32(memory_at_0, loc_2 + 72)
																								if loc_3 ~= 0 then
																									desired = 11
																									break
																								end
																								FUNC_LIST[192](1049504, 43, 1049936)
																								error("out of code bounds")
																							end
																							if desired then
																								if desired == 21 then
																									desired = nil
																								end
																								break
																							end
																							reg_0 = FUNC_LIST[260](loc_3, 1049652, 5)
																							if reg_0 == 0 then
																								desired = 12
																								break
																							end
																							reg_0 = FUNC_LIST[260](loc_3, 1049657, 5)
																							if reg_0 ~= 0 then
																								desired = 19
																								break
																							end
																							FUNC_LIST[28](add_i32(loc_2, 32), loc_1)
																							loc_3 = load_i32(memory_at_0, loc_2 + 32)
																							if loc_3 ~= 0 then
																								desired = 13
																								break
																							end
																							FUNC_LIST[192](1049504, 43, 1049872)
																							error("out of code bounds")
																						end
																						if desired then
																							if desired == 20 then
																								desired = nil
																							end
																							break
																						end
																						reg_0 = FUNC_LIST[260](loc_3, 1049662, loc_4)
																						if reg_0 == 0 then
																							desired = 15
																							break
																						end
																						reg_0 = FUNC_LIST[260](loc_3, 1049675, loc_4)
																						if reg_0 ~= 0 then
																							desired = 17
																							break
																						end
																						store_i32_n8(memory_at_0, loc_0 + 173, 1)
																						desired = 3
																						break
																					end
																					if desired then
																						if desired == 19 then
																							desired = nil
																						end
																						break
																					end
																					if load_i32(memory_at_0, loc_3) ~= 1702125933 then
																						desired = 17
																						break
																					end
																					FUNC_LIST[28](add_i32(loc_2, 64), loc_1)
																					loc_3 = load_i32(memory_at_0, loc_2 + 64)
																					if loc_3 ~= 0 then
																						desired = 14
																						break
																					end
																					FUNC_LIST[192](1049504, 43, 1049840)
																					error("out of code bounds")
																				end
																				if desired then
																					if desired == 18 then
																						desired = nil
																					end
																					break
																				end
																				reg_0 = FUNC_LIST[260](loc_3, 1049670, 5)
																				if reg_0 ~= 0 then
																					desired = 17
																					break
																				end
																				store_i32_n8(memory_at_0, loc_0 + 172, 1)
																				FUNC_LIST[28](add_i32(loc_2, 40), loc_1)
																				loc_3 = load_i32(memory_at_0, loc_2 + 40)
																				if loc_3 ~= 0 then
																					desired = 16
																					break
																				end
																				FUNC_LIST[192](1049504, 43, 1049716)
																				error("out of code bounds")
																			end
																			if desired then
																				if desired == 17 then
																					desired = nil
																				end
																				break
																			end
																			reg_0 = FUNC_LIST[260](loc_3, 1049616, 11)
																			if reg_0 == 0 then
																				desired = 3
																				break
																			end
																			break
																		end
																		if desired then
																			if desired == 16 then
																				desired = nil
																			end
																			break
																		end
																		FUNC_LIST[192](1049683, 15, 1049700)
																		error("out of code bounds")
																	end
																	if desired then
																		if desired == 15 then
																			desired = nil
																		end
																		break
																	end
																	while true do
																		reg_0 = FUNC_LIST[245](loc_3, load_i32(memory_at_0, loc_2 + 44))
																		loc_3 = reg_0
																		if band_i32(loc_3, 1) ~= 0 then
																			break
																		end
																		store_i32_n16(memory_at_0, loc_0 + 168, 1)
																		store_i32_n16(memory_at_0, loc_0 + 170, shr_u32(loc_3, 16))
																		desired = 3
																		break
																	end
																	if desired then
																		if desired == 15 then
																			desired = nil
																		end
																		break
																	end
																	store_i32_n8(memory_at_0, loc_2 + 96, shr_u32(loc_3, 8))
																	FUNC_LIST[208](1049732, 43, add_i32(loc_2, 96), 1049776, 1049792)
																	error("out of code bounds")
																end
																if desired then
																	if desired == 14 then
																		desired = nil
																	end
																	break
																end
																FUNC_LIST[28](add_i32(loc_2, 80), loc_1)
																loc_3 = load_i32(memory_at_0, loc_2 + 80)
																if loc_3 == 0 then
																	desired = 4
																	break
																end
																FUNC_LIST[247](add_i32(loc_2, 96), loc_3, load_i32(memory_at_0, loc_2 + 84))
																while true do
																	if load_i32_u8(memory_at_0, loc_2 + 96) ~= 0 then
																		break
																	end
																	loc_10 = load_i64(memory_at_0, loc_2 + 104)
																	store_i64(memory_at_0, loc_9, load_i64(memory_at_0, loc_6))
																	store_i64(memory_at_0, loc_0 + 152, loc_10)
																	store_i64(memory_at_0, loc_0 + 144, i64_ONE)
																	desired = 3
																	break
																end
																if desired then
																	if desired == 14 then
																		desired = nil
																	end
																	break
																end
																store_i32_n8(memory_at_0, loc_2 + 127, load_i32_u8(memory_at_0, loc_2 + 97))
																FUNC_LIST[208](1049732, 43, add_i32(loc_2, 127), 1049776, 1049824)
																error("out of code bounds")
															end
															if desired then
																if desired == 13 then
																	desired = nil
																end
																break
															end
															FUNC_LIST[246](add_i32(loc_2, 96), loc_3, load_i32(memory_at_0, loc_2 + 68))
															while true do
																if load_i32_u8(memory_at_0, loc_2 + 96) ~= 0 then
																	break
																end
																store_i64(memory_at_0, loc_0 + 136, load_i64(memory_at_0, loc_2 + 104))
																store_i64(memory_at_0, loc_0 + 128, i64_ONE)
																desired = 3
																break
															end
															if desired then
																if desired == 13 then
																	desired = nil
																end
																break
															end
															store_i32_n8(memory_at_0, loc_2 + 127, load_i32_u8(memory_at_0, loc_2 + 97))
															FUNC_LIST[208](1049732, 43, add_i32(loc_2, 127), 1049776, 1049856)
															error("out of code bounds")
														end
														if desired then
															if desired == 12 then
																desired = nil
															end
															break
														end
														FUNC_LIST[246](add_i32(loc_2, 96), loc_3, load_i32(memory_at_0, loc_2 + 36))
														while true do
															if load_i32_u8(memory_at_0, loc_2 + 96) ~= 0 then
																break
															end
															store_i64(memory_at_0, loc_0 + 120, load_i64(memory_at_0, loc_2 + 104))
															store_i64(memory_at_0, loc_0 + 112, i64_ONE)
															desired = 3
															break
														end
														if desired then
															if desired == 12 then
																desired = nil
															end
															break
														end
														store_i32_n8(memory_at_0, loc_2 + 127, load_i32_u8(memory_at_0, loc_2 + 97))
														FUNC_LIST[208](1049732, 43, add_i32(loc_2, 127), 1049776, 1049888)
														error("out of code bounds")
													end
													if desired then
														if desired == 11 then
															desired = nil
														end
														break
													end
													FUNC_LIST[28](add_i32(loc_2, 24), loc_1)
													loc_3 = load_i32(memory_at_0, loc_2 + 24)
													if loc_3 == 0 then
														desired = 5
														break
													end
													while true do
														reg_0 = FUNC_LIST[245](loc_3, load_i32(memory_at_0, loc_2 + 28))
														loc_3 = reg_0
														if band_i32(loc_3, 1) ~= 0 then
															break
														end
														store_i32_n16(memory_at_0, loc_0 + 168, 1)
														store_i32_n16(memory_at_0, loc_0 + 170, shr_u32(loc_3, 16))
														desired = 3
														break
													end
													if desired then
														if desired == 11 then
															desired = nil
														end
														break
													end
													store_i32_n8(memory_at_0, loc_2 + 96, shr_u32(loc_3, 8))
													FUNC_LIST[208](1049732, 43, add_i32(loc_2, 96), 1049776, 1049920)
													error("out of code bounds")
												end
												if desired then
													if desired == 10 then
														desired = nil
													end
													break
												end
												FUNC_LIST[246](add_i32(loc_2, 96), loc_3, load_i32(memory_at_0, loc_2 + 76))
												while true do
													if load_i32_u8(memory_at_0, loc_2 + 96) ~= 0 then
														break
													end
													store_i64(memory_at_0, loc_0 + 104, load_i64(memory_at_0, loc_2 + 104))
													store_i64(memory_at_0, loc_0 + 96, i64_ONE)
													desired = 3
													break
												end
												if desired then
													if desired == 10 then
														desired = nil
													end
													break
												end
												store_i32_n8(memory_at_0, loc_2 + 127, load_i32_u8(memory_at_0, loc_2 + 97))
												FUNC_LIST[208](1049732, 43, add_i32(loc_2, 127), 1049776, 1049952)
												error("out of code bounds")
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											FUNC_LIST[247](add_i32(loc_2, 96), loc_3, load_i32(memory_at_0, loc_2 + 60))
											while true do
												if load_i32_u8(memory_at_0, loc_2 + 96) ~= 0 then
													break
												end
												loc_10 = load_i64(memory_at_0, loc_2 + 104)
												store_i64(memory_at_0, loc_7, load_i64(memory_at_0, loc_6))
												store_i64(memory_at_0, loc_0 + 80, loc_10)
												store_i64(memory_at_0, loc_0 + 72, i64_ONE)
												desired = 3
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											store_i32_n8(memory_at_0, loc_2 + 127, load_i32_u8(memory_at_0, loc_2 + 97))
											FUNC_LIST[208](1049732, 43, add_i32(loc_2, 127), 1049776, 1049984)
											error("out of code bounds")
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										FUNC_LIST[28](add_i32(loc_2, 48), loc_1)
										loc_3 = load_i32(memory_at_0, loc_2 + 48)
										if loc_3 == 0 then
											desired = 6
											break
										end
										FUNC_LIST[247](add_i32(loc_2, 96), loc_3, load_i32(memory_at_0, loc_2 + 52))
										while true do
											if load_i32_u8(memory_at_0, loc_2 + 96) ~= 0 then
												break
											end
											loc_10 = load_i64(memory_at_0, loc_2 + 104)
											store_i64(memory_at_0, loc_5, load_i64(memory_at_0, loc_6))
											store_i64(memory_at_0, loc_0 + 56, loc_10)
											store_i64(memory_at_0, loc_0 + 48, i64_ONE)
											desired = 3
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										store_i32_n8(memory_at_0, loc_2 + 127, load_i32_u8(memory_at_0, loc_2 + 97))
										FUNC_LIST[208](1049732, 43, add_i32(loc_2, 127), 1049776, 1050016)
										error("out of code bounds")
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									FUNC_LIST[247](add_i32(loc_2, 96), loc_3, load_i32(memory_at_0, loc_2 + 20))
									while true do
										if load_i32_u8(memory_at_0, loc_2 + 96) ~= 0 then
											break
										end
										loc_10 = load_i64(memory_at_0, loc_2 + 104)
										store_i64(memory_at_0, loc_8, load_i64(memory_at_0, loc_6))
										store_i64(memory_at_0, loc_0 + 32, loc_10)
										store_i64(memory_at_0, loc_0 + 24, i64_ONE)
										desired = 3
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									store_i32_n8(memory_at_0, loc_2 + 127, load_i32_u8(memory_at_0, loc_2 + 97))
									FUNC_LIST[208](1049732, 43, add_i32(loc_2, 127), 1049776, 1050048)
									error("out of code bounds")
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								FUNC_LIST[28](add_i32(loc_2, 8), loc_1)
								while true do
									loc_3 = load_i32(memory_at_0, loc_2 + 8)
									if loc_3 == 0 then
										break
									end
									FUNC_LIST[247](add_i32(loc_2, 96), loc_3, load_i32(memory_at_0, loc_2 + 12))
									while true do
										if load_i32_u8(memory_at_0, loc_2 + 96) ~= 0 then
											break
										end
										loc_10 = load_i64(memory_at_0, loc_2 + 104)
										store_i64(memory_at_0, add_i32(loc_0, 16), load_i64(memory_at_0, loc_6))
										store_i64(memory_at_0, loc_0 + 8, loc_10)
										store_i64(memory_at_0, loc_0, i64_ONE)
										desired = 3
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									store_i32_n8(memory_at_0, loc_2 + 127, load_i32_u8(memory_at_0, loc_2 + 97))
									FUNC_LIST[208](1049732, 43, add_i32(loc_2, 127), 1049776, 1050080)
									error("out of code bounds")
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								FUNC_LIST[192](1049504, 43, 1050064)
								error("out of code bounds")
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							FUNC_LIST[192](1049504, 43, 1050000)
							error("out of code bounds")
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						FUNC_LIST[192](1049504, 43, 1049904)
						error("out of code bounds")
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					FUNC_LIST[192](1049504, 43, 1049808)
					error("out of code bounds")
				end
				if desired then
					if desired == 2 then
						desired = nil
						continue
					end
					break
				end
				FUNC_LIST[28](loc_2, loc_1)
				loc_4 = load_i32(memory_at_0, loc_2 + 4)
				loc_3 = load_i32(memory_at_0, loc_2)
				if loc_3 ~= 0 then
					continue
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			break
		end
		GLOBAL_LIST[0].value = add_i32(loc_2, 128)
		break
	end
end
FUNC_LIST[34] = --[[ _ZN6engine3uci12UCIProcessor3uci17h838a2ed387b42917E ]] function(loc_0)
	while true do
		TABLE_LIST[0].data[load_i32(memory_at_0, loc_0 + 16)](1050096, 37)
		break
	end
end
FUNC_LIST[35] = --[[ _ZN6engine3uci12UCIProcessor7isready17h5b3a55939e11ff62E ]] function(loc_0)
	while true do
		TABLE_LIST[0].data[load_i32(memory_at_0, loc_0 + 16)](1050133, 7)
		break
	end
end
FUNC_LIST[36] = --[[ _ZN6engine3uci12UCIProcessor8position17h67111b42bf6b28a4E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = 0
	local loc_8 = 0
	local loc_9 = 0
	local loc_10 = 0
	local loc_11 = 0
	local loc_12 = 0
	local loc_13 = 0
	local loc_14 = 0
	local loc_15 = 0
	local loc_16 = 0
	local loc_17 = 0
	local loc_18 = 0
	local loc_19 = 0
	local reg_0
	local desired
	local br_map = {}
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 48)
		GLOBAL_LIST[0].value = loc_2
		loc_3 = add_i32(loc_0, 40)
		loc_4 = load_i32(memory_at_0, loc_3)
		store_i32(memory_at_0, loc_3, 0)
		while true do
			if loc_4 == 0 then
				break
			end
			loc_3 = load_i32(memory_at_0, add_i32(loc_0, 36))
			while true do
				while true do
					loc_5 = load_i32(memory_at_0, loc_3)
					if loc_5 == 0 then
						break
					end
					FUNC_LIST[22](load_i32(memory_at_0, add_i32(loc_3, 4)), loc_5, 1)
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
						continue
					end
					break
				end
				loc_3 = add_i32(loc_3, 12)
				loc_4 = add_i32(loc_4, 4294967295)
				if loc_4 ~= 0 then
					continue
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			break
		end
		loc_6 = add_i32(loc_0, 20)
		while true do
			loc_3 = load_i32(memory_at_0, loc_0 + 20)
			if loc_3 == 2147483648 then
				break
			end
			if loc_3 == 0 then
				break
			end
			FUNC_LIST[22](load_i32(memory_at_0, add_i32(loc_0, 24)), loc_3, 1)
			break
		end
		store_i32(memory_at_0, loc_6, 2147483648)
		store_i32(memory_at_0, loc_2 + 28, 0)
		store_i64(memory_at_0, loc_2 + 20, i64_from_u32(0, 1))
		FUNC_LIST[28](add_i32(loc_2, 8), loc_1)
		while true do
			while true do
				while true do
					while true do
						loc_5 = load_i32(memory_at_0, loc_2 + 8)
						if loc_5 == 0 then
							break
						end
						loc_7 = add_i32(loc_0, 32)
						loc_4 = load_i32(memory_at_0, loc_2 + 12)
						loc_3 = 1
						while true do
							loc_8 = loc_3
							loc_3 = 0
							while true do
								while true do
									while true do
										while true do
											while true do
												if not br_map[1] then
													br_map[1] = (function()
														return { [0] = 2, 3, 0, 3, 3, 1, }
													end)()
												end
												temp = br_map[1][add_i32(loc_4, 4294967293)] or 3
												if temp < 2 then
													if temp < 1 then
														break
													else
														desired = 9
														break
													end
												elseif temp > 2 then
													desired = 7
													break
												else
													desired = 8
													break
												end
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											reg_0 = FUNC_LIST[260](loc_5, 1050140, 5)
											if reg_0 ~= 0 then
												desired = 7
												break
											end
											loc_9 = load_i32(memory_at_0, loc_1 + 24)
											loc_3 = load_i32(memory_at_0, loc_1 + 16)
											loc_10 = load_i32(memory_at_0, loc_1)
											loc_11 = load_i32_u8(memory_at_0, loc_1 + 29)
											loc_12 = load_i32(memory_at_0, loc_1 + 4)
											loc_13 = load_i32_u8(memory_at_0, loc_1 + 28)
											loc_14 = load_i32(memory_at_0, loc_1 + 20)
											loc_15 = load_i32(memory_at_0, loc_1 + 8)
											while true do
												while true do
													loc_16 = loc_9
													loc_4 = loc_3
													loc_5 = loc_10
													loc_17 = loc_11
													while true do
														loc_18 = loc_5
														while true do
															if band_i32(loc_17, 255) == 0 then
																break
															end
															loc_3 = loc_8
															desired = 6
															break
														end
														if desired then
															if desired == 12 then
																desired = nil
																continue
															end
															break
														end
														while true do
															while true do
																while true do
																	if loc_4 == loc_14 then
																		break
																	end
																	loc_19 = loc_16
																	loc_3 = loc_4
																	while true do
																		loc_5 = loc_3
																		loc_3 = add_i32(loc_5, 1)
																		store_i32(memory_at_0, loc_1 + 16, loc_3)
																		while true do
																			loc_4 = load_i32_u8(memory_at_0, loc_5)
																			if gt_i32(extend_i32_n8(loc_4), 4294967295) then
																				break
																			end
																			loc_3 = add_i32(loc_5, 2)
																			store_i32(memory_at_0, loc_1 + 16, loc_3)
																			loc_17 = band_i32(load_i32_u8(memory_at_0, loc_5 + 1), 63)
																			loc_16 = band_i32(loc_4, 31)
																			while true do
																				if loc_4 > 223 then
																					break
																				end
																				loc_4 = bor_i32(shl_i32(loc_16, 6), loc_17)
																				desired = 17
																				break
																			end
																			if desired then
																				if desired == 17 then
																					desired = nil
																				end
																				break
																			end
																			loc_3 = add_i32(loc_5, 3)
																			store_i32(memory_at_0, loc_1 + 16, loc_3)
																			loc_17 = bor_i32(shl_i32(loc_17, 6), band_i32(load_i32_u8(memory_at_0, loc_5 + 2), 63))
																			while true do
																				if loc_4 >= 240 then
																					break
																				end
																				loc_4 = bor_i32(loc_17, shl_i32(loc_16, 12))
																				desired = 17
																				break
																			end
																			if desired then
																				if desired == 17 then
																					desired = nil
																				end
																				break
																			end
																			loc_3 = add_i32(loc_5, 4)
																			store_i32(memory_at_0, loc_1 + 16, loc_3)
																			loc_4 = bor_i32(bor_i32(shl_i32(loc_17, 6), band_i32(load_i32_u8(memory_at_0, loc_5 + 3), 63)), band_i32(shl_i32(loc_16, 18), 1835008))
																			if loc_4 ~= 1114112 then
																				break
																			end
																			loc_16 = loc_19
																			loc_4 = loc_3
																			desired = 14
																			break
																		end
																		if desired then
																			if desired == 16 then
																				desired = nil
																				continue
																			end
																			break
																		end
																		loc_9 = add_i32(sub_i32(loc_3, loc_5), loc_19)
																		store_i32(memory_at_0, loc_1 + 24, loc_9)
																		while true do
																			while true do
																				while true do
																					loc_5 = add_i32(loc_4, 4294967287)
																					if loc_5 > 23 then
																						break
																					end
																					if band_i32(shl_i32(1, loc_5), 8388639) ~= 0 then
																						desired = 18
																						break
																					end
																					break
																				end
																				if desired then
																					if desired == 18 then
																						desired = nil
																					end
																					break
																				end
																				if loc_4 < 128 then
																					desired = 17
																					break
																				end
																				while true do
																					while true do
																						while true do
																							while true do
																								loc_5 = shr_u32(loc_4, 8)
																								if not br_map[2] then
																									br_map[2] = (function()
																										return { [0] = 3, 5, 5, 5, 5, 5, 5, 5, 5, 5, 1, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 0, }
																									end)()
																								end
																								temp = br_map[2][add_i32(loc_5, 4294967274)] or 2
																								if temp < 2 then
																									if temp < 1 then
																										break
																									else
																										desired = 21
																										break
																									end
																								elseif temp > 2 then
																									if temp < 5 then
																										desired = 19
																										break
																									else
																										desired = 17
																										break
																									end
																								else
																									desired = 20
																									break
																								end
																							end
																							if desired then
																								if desired == 21 then
																									desired = nil
																								end
																								break
																							end
																							if loc_4 ~= 12288 then
																								desired = 17
																								break
																							end
																							desired = 18
																							break
																						end
																						if desired then
																							if desired == 20 then
																								desired = nil
																							end
																							break
																						end
																						if band_i32(load_i32_u8(memory_at_0, add_i32(band_i32(loc_4, 255), 1077031)), 2) == 0 then
																							desired = 17
																							break
																						end
																						desired = 18
																						break
																					end
																					if desired then
																						if desired == 19 then
																							desired = nil
																						end
																						break
																					end
																					if loc_5 ~= 0 then
																						desired = 17
																						break
																					end
																					if band_i32(load_i32_u8(memory_at_0, add_i32(band_i32(loc_4, 255), 1077031)), 1) ~= 0 then
																						desired = 18
																						break
																					end
																					desired = 17
																					break
																				end
																				if desired then
																					if desired == 18 then
																						desired = nil
																					end
																					break
																				end
																				if loc_4 ~= 5760 then
																					desired = 17
																					break
																				end
																				break
																			end
																			if desired then
																				if desired == 17 then
																					desired = nil
																				end
																				break
																			end
																			store_i32(memory_at_0, loc_1, loc_9)
																			loc_17 = 0
																			loc_10 = loc_9
																			loc_16 = loc_9
																			loc_4 = loc_3
																			loc_5 = loc_9
																			desired = 13
																			break
																		end
																		if desired then
																			if desired == 16 then
																				desired = nil
																				continue
																			end
																			break
																		end
																		loc_19 = loc_9
																		if loc_3 ~= loc_14 then
																			continue
																		end
																		break
																	end
																	if desired then
																		if desired == 15 then
																			desired = nil
																		end
																		break
																	end
																	loc_3 = loc_14
																	loc_16 = loc_9
																	break
																end
																if desired then
																	if desired == 14 then
																		desired = nil
																	end
																	break
																end
																loc_4 = loc_14
																break
															end
															if desired then
																if desired == 13 then
																	desired = nil
																end
																break
															end
															loc_11 = 1
															store_i32_n8(memory_at_0, loc_1 + 29, 1)
															while true do
																if band_i32(loc_13, 255) == 0 then
																	break
																end
																loc_5 = loc_18
																loc_17 = 1
																loc_19 = loc_12
																desired = 13
																break
															end
															if desired then
																if desired == 13 then
																	desired = nil
																end
																break
															end
															loc_5 = loc_18
															loc_17 = 1
															loc_19 = loc_12
															if loc_12 ~= loc_18 then
																break
															end
															loc_3 = loc_8
															desired = 6
															break
														end
														if desired then
															if desired == 12 then
																desired = nil
																continue
															end
															break
														end
														if loc_19 == loc_18 then
															continue
														end
														break
													end
													if desired then
														if desired == 11 then
															desired = nil
															continue
														end
														break
													end
													while true do
														loc_4 = sub_i32(loc_19, loc_18)
														if le_i32(loc_4, 4294967295) then
															break
														end
														reg_0 = FUNC_LIST[21](loc_4, 1)
														loc_5 = reg_0
														if loc_5 == 0 then
															desired = 10
															break
														end
														reg_0 = FUNC_LIST[262](loc_5, add_i32(loc_15, loc_18), loc_4)
														loc_19 = reg_0
														while true do
															loc_5 = load_i32(memory_at_0, loc_0 + 40)
															if loc_5 ~= load_i32(memory_at_0, loc_0 + 32) then
																break
															end
															FUNC_LIST[58](loc_7, loc_5)
															loc_5 = load_i32(memory_at_0, loc_0 + 40)
															break
														end
														if desired then
															if desired == 12 then
																desired = nil
															end
															break
														end
														loc_5 = add_i32(load_i32(memory_at_0, loc_0 + 36), mul_i32(loc_5, 12))
														store_i32(memory_at_0, loc_5 + 8, loc_4)
														store_i32(memory_at_0, loc_5 + 4, loc_19)
														store_i32(memory_at_0, loc_5, loc_4)
														store_i32(memory_at_0, loc_0 + 40, add_i32(load_i32(memory_at_0, loc_0 + 40), 1))
														desired = 11
														break
													end
													if desired then
														if desired == 11 then
															desired = nil
															continue
														end
														break
													end
													break
												end
												if desired then
													if desired == 10 then
														desired = nil
													end
													break
												end
												FUNC_LIST[174]()
												error("out of code bounds")
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											FUNC_LIST[173](1, loc_4)
											error("out of code bounds")
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										loc_3 = (if eq_i64(load_i64(memory_at_0, loc_5), i64_from_u32(1918989427, 1936683124)) then 1 else 0)
										desired = 7
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									loc_3 = 0
									reg_0 = FUNC_LIST[260](loc_5, 1050145, 3)
									if reg_0 == 0 then
										desired = 6
										break
									end
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								loc_9 = bor_i32(loc_3, loc_8)
								loc_3 = 1
								if band_i32(loc_9, 1) ~= 0 then
									break
								end
								while true do
									loc_3 = load_i32(memory_at_0, loc_2 + 28)
									if sub_i32(load_i32(memory_at_0, loc_2 + 20), loc_3) >= loc_4 then
										break
									end
									FUNC_LIST[62](add_i32(loc_2, 20), loc_3, loc_4)
									loc_3 = load_i32(memory_at_0, loc_2 + 28)
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								reg_0 = FUNC_LIST[262](add_i32(load_i32(memory_at_0, loc_2 + 24), loc_3), loc_5, loc_4)
								loc_3 = add_i32(loc_3, loc_4)
								store_i32(memory_at_0, loc_2 + 28, loc_3)
								while true do
									if loc_3 ~= load_i32(memory_at_0, loc_2 + 20) then
										break
									end
									FUNC_LIST[57](add_i32(loc_2, 20), loc_3)
									loc_3 = load_i32(memory_at_0, loc_2 + 28)
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								store_i32_n8(memory_at_0, add_i32(load_i32(memory_at_0, loc_2 + 24), loc_3), 32)
								store_i32(memory_at_0, loc_2 + 28, add_i32(load_i32(memory_at_0, loc_2 + 28), 1))
								loc_3 = 0
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
									continue
								end
								break
							end
							FUNC_LIST[28](loc_2, loc_1)
							loc_4 = load_i32(memory_at_0, loc_2 + 4)
							loc_5 = load_i32(memory_at_0, loc_2)
							if loc_5 == 0 then
								desired = 3
								break
							end
							continue
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_4 = add_i32(loc_0, 24)
					desired = 2
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_4 = add_i32(loc_0, 24)
				if band_i32(loc_3, 1) ~= 0 then
					break
				end
				loc_3 = add_i32(add_i32(loc_2, 32), 8)
				store_i32(memory_at_0, loc_3, load_i32(memory_at_0, add_i32(add_i32(loc_2, 20), 8)))
				store_i64(memory_at_0, loc_2 + 32, load_i64(memory_at_0, loc_2 + 20))
				while true do
					loc_5 = load_i32(memory_at_0, loc_6)
					if loc_5 == 2147483648 then
						break
					end
					if loc_5 == 0 then
						break
					end
					FUNC_LIST[22](load_i32(memory_at_0, loc_4), loc_5, 1)
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i64(memory_at_0, loc_6, load_i64(memory_at_0, loc_2 + 32))
				store_i32(memory_at_0, add_i32(loc_6, 8), load_i32(memory_at_0, loc_3))
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				reg_0 = FUNC_LIST[21](56, 1)
				loc_3 = reg_0
				if loc_3 == 0 then
					break
				end
				store_i64(memory_at_0, add_i32(loc_3, 48), load_i64(memory_at_0, 0 + 1050196))
				store_i64(memory_at_0, add_i32(loc_3, 40), load_i64(memory_at_0, 0 + 1050188))
				store_i64(memory_at_0, add_i32(loc_3, 32), load_i64(memory_at_0, 0 + 1050180))
				store_i64(memory_at_0, add_i32(loc_3, 24), load_i64(memory_at_0, 0 + 1050172))
				store_i64(memory_at_0, add_i32(loc_3, 16), load_i64(memory_at_0, 0 + 1050164))
				store_i64(memory_at_0, add_i32(loc_3, 8), load_i64(memory_at_0, 0 + 1050156))
				store_i64(memory_at_0, loc_3, load_i64(memory_at_0, 0 + 1050148))
				while true do
					loc_5 = load_i32(memory_at_0, loc_6)
					if loc_5 == 2147483648 then
						break
					end
					if loc_5 == 0 then
						break
					end
					FUNC_LIST[22](load_i32(memory_at_0, loc_4), loc_5, 1)
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i32(memory_at_0, loc_0 + 24, loc_3)
				store_i32(memory_at_0, loc_0 + 20, 56)
				store_i32(memory_at_0, add_i32(loc_0, 28), 56)
				loc_3 = load_i32(memory_at_0, loc_2 + 20)
				if loc_3 == 0 then
					desired = 1
					break
				end
				FUNC_LIST[22](load_i32(memory_at_0, loc_2 + 24), loc_3, 1)
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[173](1, 56)
			error("out of code bounds")
		end
		GLOBAL_LIST[0].value = add_i32(loc_2, 48)
		break
	end
end
FUNC_LIST[37] = --[[ _ZN6engine3uci12UCIProcessor2go17h5e4981d88ffc0270E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = i64_ZERO
	local loc_7 = i64_ZERO
	local loc_8 = i64_ZERO
	local loc_9 = i64_ZERO
	local loc_10 = 0.0
	local reg_0
	local reg_1
	local desired
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 17120)
		GLOBAL_LIST[0].value = loc_2
		store_i64(memory_at_0, loc_2 + 184, i64_ZERO)
		store_i64(memory_at_0, loc_2 + 160, i64_ZERO)
		store_i64(memory_at_0, loc_2 + 136, i64_ZERO)
		store_i64(memory_at_0, loc_2 + 112, i64_ZERO)
		store_i64(memory_at_0, loc_2 + 88, i64_ZERO)
		store_i32_n16(memory_at_0, loc_2 + 260, 0)
		store_i32_n16(memory_at_0, loc_2 + 256, 0)
		store_i64(memory_at_0, loc_2 + 232, i64_ZERO)
		store_i64(memory_at_0, loc_2 + 216, i64_ZERO)
		store_i64(memory_at_0, loc_2 + 200, i64_ZERO)
		FUNC_LIST[33](add_i32(loc_2, 88), loc_1)
		while true do
			while true do
				while true do
					while true do
						while true do
							if load_i32(memory_at_0, loc_0 + 20) == 2147483648 then
								break
							end
							FUNC_LIST[49](add_i32(loc_2, 264), load_i32(memory_at_0, add_i32(loc_0, 24)), load_i32(memory_at_0, add_i32(loc_0, 28)))
							store_i32_n8(memory_at_0, loc_2 + 16992, 3)
							reg_0 = FUNC_LIST[21](31999992, 8)
							loc_1 = reg_0
							if loc_1 == 0 then
								desired = 4
								break
							end
							loc_3 = add_i32(add_i32(loc_2, 16940), 8)
							store_i32(memory_at_0, loc_3, 0)
							store_i32(memory_at_0, loc_2 + 16944, loc_1)
							store_i32(memory_at_0, loc_2 + 16940, 1333333)
							FUNC_LIST[93](add_i32(loc_2, 16940), 1333333, add_i32(loc_2, 16976))
							store_i32(memory_at_0, add_i32(add_i32(loc_2, 17104), 8), load_i32(memory_at_0, loc_3))
							store_i64(memory_at_0, loc_2 + 17104, load_i64(memory_at_0, loc_2 + 16940))
							reg_0 = FUNC_LIST[21](40, 8)
							loc_1 = reg_0
							if loc_1 == 0 then
								desired = 3
								break
							end
							store_i32(memory_at_0, add_i32(loc_2, 428), 0)
							store_i32(memory_at_0, add_i32(add_i32(loc_2, 408), 16), loc_1)
							store_i32(memory_at_0, add_i32(add_i32(loc_2, 408), 8), load_i32(memory_at_0, add_i32(add_i32(loc_2, 17104), 8)))
							store_i64(memory_at_0, loc_2 + 408, load_i64(memory_at_0, loc_2 + 17104))
							store_i32_n16(memory_at_0, loc_2 + 16888, 0)
							store_i32(memory_at_0, loc_2 + 420, 5)
							store_i32(memory_at_0, loc_2 + 432, add_i32(loc_2, 264))
							reg_0 = FUNC_LIST[259](add_i32(loc_2, 436), 0, 16448)
							store_i32(memory_at_0, loc_2 + 16884, 2147483649)
							while true do
								loc_1 = load_i32(memory_at_0, add_i32(loc_0, 40))
								if loc_1 ~= 0 then
									break
								end
								loc_3 = add_i32(loc_2, 264)
								desired = 1
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_4 = add_i32(add_i32(loc_2, 408), 12)
							loc_5 = mul_i32(loc_1, 12)
							loc_1 = add_i32(load_i32(memory_at_0, add_i32(loc_0, 36)), 8)
							while true do
								reg_1 = FUNC_LIST[32](load_i32(memory_at_0, loc_2 + 432), load_i32(memory_at_0, add_i32(loc_1, 4294967292)), load_i32(memory_at_0, loc_1))
								loc_3 = reg_1
								store_i32_n16(memory_at_0, loc_2 + 16976, loc_3)
								store_i32_n8(memory_at_0, loc_2 + 16978, shr_u32(loc_3, 16))
								loc_6 = load_i64(memory_at_0, load_i32(memory_at_0, loc_2 + 432) + 16)
								while true do
									loc_3 = load_i32(memory_at_0, loc_2 + 428)
									if loc_3 ~= load_i32(memory_at_0, loc_2 + 420) then
										break
									end
									FUNC_LIST[59](loc_4, loc_3)
									loc_3 = load_i32(memory_at_0, loc_2 + 428)
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
										continue
									end
									break
								end
								store_i64(memory_at_0, add_i32(load_i32(memory_at_0, loc_2 + 424), shl_i32(loc_3, 3)), loc_6)
								store_i32(memory_at_0, loc_2 + 428, add_i32(load_i32(memory_at_0, loc_2 + 428), 1))
								FUNC_LIST[51](load_i32(memory_at_0, loc_2 + 432), add_i32(loc_2, 16976))
								loc_1 = add_i32(loc_1, 12)
								loc_5 = add_i32(loc_5, 4294967284)
								if loc_5 == 0 then
									desired = 2
									break
								end
								continue
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						FUNC_LIST[192](1049504, 43, 1050204)
						error("out of code bounds")
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					FUNC_LIST[173](8, 31999992)
					error("out of code bounds")
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[173](8, 40)
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_3 = load_i32(memory_at_0, loc_2 + 432)
			break
		end
		loc_1 = load_i32(memory_at_0, loc_0 + 16)
		FUNC_LIST[50](add_i32(loc_2, 16976), loc_3)
		loc_3 = load_i32(memory_at_0, loc_2 + 16980)
		TABLE_LIST[0].data[loc_1](loc_3, load_i32(memory_at_0, loc_2 + 16984))
		while true do
			loc_5 = load_i32(memory_at_0, loc_2 + 16976)
			if loc_5 == 0 then
				break
			end
			FUNC_LIST[22](loc_3, loc_5, 1)
			break
		end
		while true do
			while true do
				while true do
					while true do
						while true do
							if load_i32_u8(memory_at_0, loc_2 + 260) ~= 0 then
								break
							end
							while true do
								while true do
									while true do
										if load_i32_u8(memory_at_0, loc_2 + 261) ~= 0 then
											break
										end
										if eq_i64(load_i64(memory_at_0, loc_2 + 232), i64_ZERO) then
											desired = 7
											break
										end
										loc_6 = load_i64(memory_at_0, add_i32(loc_2, 248))
										loc_7 = load_i64(memory_at_0, loc_2 + 240)
										desired = 6
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									loc_6 = load_i64(memory_at_0, add_i32(loc_0, 8))
									loc_7 = load_i64(memory_at_0, loc_0)
									desired = 6
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								loc_6 = i64_ZERO
								loc_1 = load_i32_u8(memory_at_0, load_i32(memory_at_0, loc_2 + 432) + 140)
								if eq_i64(load_i64(memory_at_0, (if loc_1 ~= 0 then add_i32(loc_2, 88) else add_i32(loc_2, 112))), i64_ZERO) then
									desired = 4
									break
								end
								loc_3 = (if loc_1 ~= 0 then add_i32(add_i32(loc_2, 88), 8) else add_i32(loc_2, 120))
								loc_7 = load_i64(memory_at_0, loc_3)
								loc_8 = load_i64(memory_at_0, add_i32(loc_3, 8))
								while true do
									while true do
										loc_1 = add_i32(add_i32(loc_2, 88), (if loc_1 ~= 0 then 48 else 72))
										if (if eq_i64(load_i64(memory_at_0, loc_1), i64_ZERO) then 1 else 0) == 0 then
											break
										end
										loc_9 = i64_ZERO
										desired = 7
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									loc_9 = load_i64(memory_at_0, add_i32(loc_1, 16))
									loc_6 = bor_i64(shr_u64(load_i64(memory_at_0, loc_1 + 8), i64_ONE), shl_i64(loc_9, i64_from_u32(63, 0)))
									loc_9 = shr_u64(loc_9, i64_ONE)
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								FUNC_LIST[261](add_i32(loc_2, 72), loc_7, loc_8, i64_from_u32(20, 0), i64_ZERO)
								loc_7 = add_i64(loc_6, load_i64(memory_at_0, loc_2 + 72))
								loc_6 = add_i64(add_i64(loc_9, load_i64(memory_at_0, add_i32(add_i32(loc_2, 72), 8))), extend_i64_u32((if lt_u64(loc_7, loc_6) then 1 else 0)))
								loc_8 = load_i64(memory_at_0, add_i32(loc_0, 8))
								loc_9 = load_i64(memory_at_0, loc_0)
								loc_1 = (if eq_i64(loc_6, loc_8) then (if lt_u64(loc_7, loc_9) then 1 else 0) else (if lt_u64(loc_6, loc_8) then 1 else 0))
								loc_6 = (if loc_1 ~= 0 then loc_6 else loc_8)
								loc_7 = (if loc_1 ~= 0 then loc_7 else loc_9)
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_3 = add_i32(add_i32(loc_2, 16896), 8)
							store_i64(memory_at_0, loc_3, loc_6)
							store_i64(memory_at_0, loc_2 + 16896, loc_7)
							reg_1 = FUNC_LIST[1]()
							loc_10 = reg_1
							store_f64(memory_at_0, loc_2 + 16912, loc_10)
							loc_0 = add_i32(loc_0, 16)
							store_i32(memory_at_0, loc_2 + 16940, loc_0)
							store_i32(memory_at_0, loc_2 + 16944, add_i32(loc_2, 16912))
							store_i32(memory_at_0, loc_2 + 16980, add_i32(loc_2, 16896))
							store_i32(memory_at_0, loc_2 + 16976, add_i32(loc_2, 16912))
							reg_1 = FUNC_LIST[1]()
							loc_10 = ((reg_1 - loc_10) * 1e3)
							FUNC_LIST[252](add_i32(loc_2, 56), loc_10)
							loc_1 = 0
							while true do
								while true do
									loc_5 = (if loc_10 >= 0e0 then 1 else 0)
									loc_4 = (if loc_10 > 3.4028236692093843e38 then 1 else 0)
									loc_6 = (if loc_4 ~= 0 then i64_from_u32(4294967295, 4294967295) else (if loc_5 ~= 0 then load_i64(memory_at_0, add_i32(add_i32(loc_2, 56), 8)) else i64_ZERO))
									loc_7 = load_i64(memory_at_0, loc_3)
									if (if eq_i64(loc_6, loc_7) then (if gt_u64((if loc_4 ~= 0 then i64_from_u32(4294967295, 4294967295) else (if loc_5 ~= 0 then load_i64(memory_at_0, loc_2 + 56) else i64_ZERO)), load_i64(memory_at_0, loc_2 + 16896)) then 1 else 0) else (if gt_u64(loc_6, loc_7) then 1 else 0)) ~= 0 then
										break
									end
									loc_1 = 0
									while true do
										loc_1 = add_i32(loc_1, 1)
										reg_0 = FUNC_LIST[65](add_i32(loc_2, 408), loc_1, 0, 0, add_i32(loc_2, 16976), 1050220, 2147483649, 2147483647)
										loc_3 = load_i32(memory_at_0, loc_2 + 16976)
										reg_1 = FUNC_LIST[1]()
										loc_10 = ((reg_1 - load_f64(memory_at_0, loc_3)) * 1e3)
										FUNC_LIST[252](add_i32(loc_2, 40), loc_10)
										loc_3 = (if loc_10 >= 0e0 then 1 else 0)
										loc_5 = (if loc_10 > 3.4028236692093843e38 then 1 else 0)
										loc_4 = load_i32(memory_at_0, loc_2 + 16980)
										loc_6 = (if loc_5 ~= 0 then i64_from_u32(4294967295, 4294967295) else (if loc_3 ~= 0 then load_i64(memory_at_0, add_i32(add_i32(loc_2, 40), 8)) else i64_ZERO))
										loc_7 = load_i64(memory_at_0, add_i32(loc_4, 8))
										if (if eq_i64(loc_6, loc_7) then (if gt_u64((if loc_5 ~= 0 then i64_from_u32(4294967295, 4294967295) else (if loc_3 ~= 0 then load_i64(memory_at_0, loc_2 + 40) else i64_ZERO)), load_i64(memory_at_0, loc_4)) then 1 else 0) else (if gt_u64(loc_6, loc_7) then 1 else 0)) ~= 0 then
											desired = 7
											break
										end
										while true do
											loc_5 = load_i32_u16(memory_at_0, loc_2 + 16888)
											if loc_5 ~= 0 then
												break
											end
											loc_3 = 0
											desired = 6
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
												continue
											end
											break
										end
										loc_3 = load_i32(memory_at_0, loc_2 + 16884)
										loc_4 = shr_i32(loc_3, 31)
										if sub_i32(bxor_i32(loc_3, loc_4), loc_4) == 2147483646 then
											desired = 7
											break
										end
										FUNC_LIST[38](add_i32(loc_2, 16940), loc_1, loc_5, loc_3)
										loc_3 = load_i32(memory_at_0, loc_2 + 16976)
										reg_1 = FUNC_LIST[1]()
										loc_10 = ((reg_1 - load_f64(memory_at_0, loc_3)) * 1e3)
										FUNC_LIST[252](add_i32(loc_2, 24), loc_10)
										loc_3 = (if loc_10 >= 0e0 then 1 else 0)
										loc_5 = (if loc_10 > 3.4028236692093843e38 then 1 else 0)
										loc_4 = load_i32(memory_at_0, loc_2 + 16980)
										loc_6 = (if loc_5 ~= 0 then i64_from_u32(4294967295, 4294967295) else (if loc_3 ~= 0 then load_i64(memory_at_0, add_i32(add_i32(loc_2, 24), 8)) else i64_ZERO))
										loc_7 = load_i64(memory_at_0, add_i32(loc_4, 8))
										if (if eq_i64(loc_6, loc_7) then (if le_u64((if loc_5 ~= 0 then i64_from_u32(4294967295, 4294967295) else (if loc_3 ~= 0 then load_i64(memory_at_0, loc_2 + 24) else i64_ZERO)), load_i64(memory_at_0, loc_4)) then 1 else 0) else (if le_u64(loc_6, loc_7) then 1 else 0)) ~= 0 then
											continue
										end
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								loc_3 = load_i32_u16(memory_at_0, loc_2 + 16888)
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_5 = load_i32(memory_at_0, loc_2 + 16884)
							store_i32_n16(memory_at_0, loc_2 + 16922, loc_1)
							store_i32(memory_at_0, loc_2 + 16924, loc_5)
							loc_4 = load_i32(memory_at_0, loc_0)
							reg_1 = FUNC_LIST[1]()
							loc_10 = ((reg_1 - load_f64(memory_at_0, loc_2 + 16912)) * 1e3)
							FUNC_LIST[252](add_i32(loc_2, 8), loc_10)
							loc_1 = (if loc_10 >= 0e0 then 1 else 0)
							loc_5 = (if loc_10 > 3.4028236692093843e38 then 1 else 0)
							store_i64(memory_at_0, loc_2 + 17112, (if loc_5 ~= 0 then i64_from_u32(4294967295, 4294967295) else (if loc_1 ~= 0 then load_i64(memory_at_0, add_i32(add_i32(loc_2, 8), 8)) else i64_ZERO)))
							store_i64(memory_at_0, loc_2 + 17104, (if loc_5 ~= 0 then i64_from_u32(4294967295, 4294967295) else (if loc_1 ~= 0 then load_i64(memory_at_0, loc_2 + 8) else i64_ZERO)))
							loc_1 = shr_u32(band_i32(loc_3, 61440), 12)
							if le_i32(extend_i32_n16(loc_3), 4294967295) then
								desired = 3
								break
							end
							loc_3 = bor_i32(bor_i32(band_i32(shl_i32(loc_3, 10), 4128768), shl_i32(band_i32(loc_3, 63), 8)), load_i32_u8(memory_at_0, add_i32(loc_1, 1069940)))
							FUNC_LIST[31](add_i32(loc_2, 16964), loc_3)
							store_i32(memory_at_0, add_i32(loc_2, 17004), 14)
							store_i32(memory_at_0, add_i32(loc_2, 16996), 15)
							store_i32(memory_at_0, add_i32(add_i32(loc_2, 16976), 12), 16)
							store_i64(memory_at_0, add_i32(add_i32(loc_2, 16940), 12), i64_from_u32(4, 0))
							store_i32(memory_at_0, loc_2 + 16980, 17)
							store_i32(memory_at_0, loc_2 + 16944, 4)
							store_i32(memory_at_0, loc_2 + 16940, 1050272)
							store_i32(memory_at_0, loc_2 + 17000, add_i32(loc_2, 16964))
							store_i32(memory_at_0, loc_2 + 16992, add_i32(loc_2, 17104))
							store_i32(memory_at_0, loc_2 + 16984, add_i32(loc_2, 16924))
							store_i32(memory_at_0, loc_2 + 16976, add_i32(loc_2, 16922))
							store_i32(memory_at_0, loc_2 + 16948, add_i32(loc_2, 16976))
							FUNC_LIST[178](add_i32(loc_2, 16928), add_i32(loc_2, 16940))
							while true do
								loc_1 = load_i32(memory_at_0, loc_2 + 16964)
								if loc_1 == 0 then
									break
								end
								FUNC_LIST[22](load_i32(memory_at_0, loc_2 + 16968), loc_1, 1)
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_1 = load_i32(memory_at_0, loc_2 + 16928)
							loc_5 = load_i32(memory_at_0, loc_2 + 16932)
							TABLE_LIST[0].data[loc_4](loc_5, load_i32(memory_at_0, loc_2 + 16936))
							while true do
								if loc_1 == 0 then
									break
								end
								FUNC_LIST[22](loc_5, loc_1, 1)
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_5 = load_i32(memory_at_0, loc_0)
							FUNC_LIST[31](add_i32(loc_2, 16940), loc_3)
							store_i64(memory_at_0, add_i32(loc_2, 16988), i64_ONE)
							store_i32(memory_at_0, loc_2 + 16968, 14)
							store_i32(memory_at_0, loc_2 + 16980, 1)
							store_i32(memory_at_0, loc_2 + 16976, 1050316)
							store_i32(memory_at_0, loc_2 + 16964, add_i32(loc_2, 16940))
							store_i32(memory_at_0, loc_2 + 16984, add_i32(loc_2, 16964))
							FUNC_LIST[178](add_i32(loc_2, 17104), add_i32(loc_2, 16976))
							while true do
								loc_1 = load_i32(memory_at_0, loc_2 + 16940)
								if loc_1 == 0 then
									break
								end
								FUNC_LIST[22](load_i32(memory_at_0, loc_2 + 16944), loc_1, 1)
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_1 = load_i32(memory_at_0, loc_2 + 17104)
							loc_3 = load_i32(memory_at_0, loc_2 + 17108)
							TABLE_LIST[0].data[loc_5](loc_3, load_i32(memory_at_0, loc_2 + 17112))
							while true do
								if loc_1 == 0 then
									break
								end
								FUNC_LIST[22](loc_3, loc_1, 1)
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							while true do
								loc_1 = load_i32(memory_at_0, loc_2 + 408)
								if loc_1 == 0 then
									break
								end
								FUNC_LIST[22](load_i32(memory_at_0, loc_2 + 412), mul_i32(loc_1, 24), 8)
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							while true do
								loc_1 = load_i32(memory_at_0, loc_2 + 420)
								if loc_1 == 0 then
									break
								end
								FUNC_LIST[22](load_i32(memory_at_0, loc_2 + 424), shl_i32(loc_1, 3), 8)
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_1 = load_i32(memory_at_0, loc_2 + 392)
							if loc_1 == 0 then
								desired = 1
								break
							end
							FUNC_LIST[22](load_i32(memory_at_0, add_i32(loc_2, 396)), shl_i32(loc_1, 5), 8)
							desired = 1
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						if load_i32_u16(memory_at_0, loc_2 + 256) == 0 then
							desired = 2
							break
						end
						loc_3 = load_i32_u16(memory_at_0, loc_2 + 258)
						store_i32(memory_at_0, loc_2 + 16928, loc_1)
						store_i32_n16(memory_at_0, loc_2 + 16924, loc_3)
						store_i32(memory_at_0, loc_2 + 16964, 0)
						FUNC_LIST[53](add_i32(loc_2, 16976), add_i32(loc_2, 264))
						store_i32(memory_at_0, loc_2 + 17116, add_i32(loc_2, 264))
						store_i32(memory_at_0, loc_2 + 17112, add_i32(loc_2, 16964))
						store_i32(memory_at_0, loc_2 + 17108, add_i32(loc_2, 16928))
						store_i32(memory_at_0, loc_2 + 17104, add_i32(loc_2, 16924))
						FUNC_LIST[54](add_i32(loc_2, 16976), add_i32(loc_2, 17104), 1069836, 0)
						store_i64(memory_at_0, add_i32(loc_2, 16952), i64_ONE)
						store_i32(memory_at_0, loc_2 + 16900, 18)
						store_i32(memory_at_0, loc_2 + 16944, 1)
						store_i32(memory_at_0, loc_2 + 16940, 1050340)
						store_i32(memory_at_0, loc_2 + 16912, load_i32(memory_at_0, loc_2 + 16964))
						store_i32(memory_at_0, loc_2 + 16896, add_i32(loc_2, 16912))
						store_i32(memory_at_0, loc_2 + 16948, add_i32(loc_2, 16896))
						FUNC_LIST[178](add_i32(loc_2, 16976), add_i32(loc_2, 16940))
						loc_3 = load_i32(memory_at_0, loc_2 + 16980)
						TABLE_LIST[0].data[loc_1](loc_3, load_i32(memory_at_0, loc_2 + 16984))
						while true do
							loc_1 = load_i32(memory_at_0, loc_2 + 16976)
							if loc_1 == 0 then
								break
							end
							FUNC_LIST[22](loc_3, loc_1, 1)
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						while true do
							loc_1 = load_i32(memory_at_0, loc_2 + 408)
							if loc_1 == 0 then
								break
							end
							FUNC_LIST[22](load_i32(memory_at_0, loc_2 + 412), mul_i32(loc_1, 24), 8)
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						while true do
							loc_1 = load_i32(memory_at_0, loc_2 + 420)
							if loc_1 == 0 then
								break
							end
							FUNC_LIST[22](load_i32(memory_at_0, loc_2 + 424), shl_i32(loc_1, 3), 8)
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_1 = load_i32(memory_at_0, loc_2 + 392)
						if loc_1 == 0 then
							desired = 1
							break
						end
						FUNC_LIST[22](load_i32(memory_at_0, add_i32(loc_2, 396)), shl_i32(loc_1, 5), 8)
						desired = 1
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					FUNC_LIST[192](1049504, 43, 1050364)
					error("out of code bounds")
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[189](loc_1, 8, 1069924)
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[192](1049504, 43, 1050348)
			error("out of code bounds")
		end
		GLOBAL_LIST[0].value = add_i32(loc_2, 17120)
		break
	end
end
FUNC_LIST[38] = --[[ _ZN6engine3uci12UCIProcessor2go28_$u7b$$u7b$closure$u7d$$u7d$17h4b92013878f4522bE ]] function(loc_0, loc_1, loc_2, loc_3)
	local loc_4 = 0
	local loc_5 = 0.0
	local reg_0
	local reg_1
	local desired
	while true do
		loc_4 = sub_i32(GLOBAL_LIST[0].value, 128)
		GLOBAL_LIST[0].value = loc_4
		store_i32_n16(memory_at_0, loc_4 + 22, loc_1)
		store_i32(memory_at_0, loc_4 + 24, loc_3)
		loc_3 = load_i32(memory_at_0, load_i32(memory_at_0, loc_0))
		loc_0 = load_i32(memory_at_0, loc_0 + 4)
		reg_1 = FUNC_LIST[1]()
		loc_5 = ((reg_1 - load_f64(memory_at_0, loc_0)) * 1e3)
		FUNC_LIST[252](loc_4, loc_5)
		loc_0 = (if loc_5 >= 0e0 then 1 else 0)
		loc_1 = (if loc_5 > 3.4028236692093843e38 then 1 else 0)
		store_i64(memory_at_0, loc_4 + 104, (if loc_1 ~= 0 then i64_from_u32(4294967295, 4294967295) else (if loc_0 ~= 0 then load_i64(memory_at_0, add_i32(loc_4, 8)) else i64_ZERO)))
		store_i64(memory_at_0, loc_4 + 96, (if loc_1 ~= 0 then i64_from_u32(4294967295, 4294967295) else (if loc_0 ~= 0 then load_i64(memory_at_0, loc_4) else i64_ZERO)))
		loc_0 = shr_u32(band_i32(loc_2, 61440), 12)
		while true do
			if le_i32(extend_i32_n16(loc_2), 4294967295) then
				break
			end
			FUNC_LIST[31](add_i32(loc_4, 116), bor_i32(bor_i32(band_i32(shl_i32(loc_2, 10), 4128768), shl_i32(band_i32(loc_2, 63), 8)), load_i32_u8(memory_at_0, add_i32(loc_0, 1069940))))
			store_i32(memory_at_0, add_i32(loc_4, 92), 14)
			store_i32(memory_at_0, add_i32(loc_4, 84), 15)
			store_i32(memory_at_0, add_i32(add_i32(loc_4, 64), 12), 16)
			store_i64(memory_at_0, add_i32(add_i32(loc_4, 40), 12), i64_from_u32(4, 0))
			store_i32(memory_at_0, loc_4 + 68, 17)
			store_i32(memory_at_0, loc_4 + 44, 4)
			store_i32(memory_at_0, loc_4 + 40, 1050272)
			store_i32(memory_at_0, loc_4 + 88, add_i32(loc_4, 116))
			store_i32(memory_at_0, loc_4 + 80, add_i32(loc_4, 96))
			store_i32(memory_at_0, loc_4 + 72, add_i32(loc_4, 24))
			store_i32(memory_at_0, loc_4 + 64, add_i32(loc_4, 22))
			store_i32(memory_at_0, loc_4 + 48, add_i32(loc_4, 64))
			FUNC_LIST[178](add_i32(loc_4, 28), add_i32(loc_4, 40))
			while true do
				loc_2 = load_i32(memory_at_0, loc_4 + 116)
				if loc_2 == 0 then
					break
				end
				FUNC_LIST[22](load_i32(memory_at_0, loc_4 + 120), loc_2, 1)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_2 = load_i32(memory_at_0, loc_4 + 28)
			loc_0 = load_i32(memory_at_0, loc_4 + 32)
			TABLE_LIST[0].data[loc_3](loc_0, load_i32(memory_at_0, loc_4 + 36))
			while true do
				if loc_2 == 0 then
					break
				end
				FUNC_LIST[22](loc_0, loc_2, 1)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			GLOBAL_LIST[0].value = add_i32(loc_4, 128)
			desired = 0
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		FUNC_LIST[189](loc_0, 8, 1069924)
		error("out of code bounds")
	end
end
FUNC_LIST[39] = --[[ _ZN6engine3uci12UCIProcessor2go28_$u7b$$u7b$closure$u7d$$u7d$17ha22767aa424bf57aE ]] function(loc_0)
	local loc_1 = 0
	local loc_2 = 0
	local loc_3 = 0.0
	local loc_4 = i64_ZERO
	local loc_5 = i64_ZERO
	local loc_6 = i64_ZERO
	local loc_7 = i64_ZERO
	local reg_0
	local reg_1
	while true do
		loc_1 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_1
		loc_2 = load_i32(memory_at_0, loc_0)
		reg_1 = FUNC_LIST[1]()
		loc_3 = ((reg_1 - load_f64(memory_at_0, loc_2)) * 1e3)
		FUNC_LIST[252](loc_1, loc_3)
		loc_4 = load_i64(memory_at_0, add_i32(loc_1, 8))
		loc_0 = load_i32(memory_at_0, loc_0 + 4)
		loc_5 = load_i64(memory_at_0, add_i32(loc_0, 8))
		loc_6 = load_i64(memory_at_0, loc_1)
		loc_7 = load_i64(memory_at_0, loc_0)
		GLOBAL_LIST[0].value = add_i32(loc_1, 16)
		loc_1 = (if loc_3 >= 0e0 then 1 else 0)
		loc_0 = (if loc_3 > 3.4028236692093843e38 then 1 else 0)
		loc_4 = (if loc_0 ~= 0 then i64_from_u32(4294967295, 4294967295) else (if loc_1 ~= 0 then loc_4 else i64_ZERO))
		reg_0 = (if eq_i64(loc_4, loc_5) then (if gt_u64((if loc_0 ~= 0 then i64_from_u32(4294967295, 4294967295) else (if loc_1 ~= 0 then loc_6 else i64_ZERO)), loc_7) then 1 else 0) else (if gt_u64(loc_4, loc_5) then 1 else 0))
		break
	end
	return reg_0
end
FUNC_LIST[40] = --[[ _ZN4core3ptr28drop_in_place$LT$$RF$str$GT$17h38d3c086a8d1fa95E ]] function(loc_0)
	while true do
		break
	end
end
FUNC_LIST[41] = --[[ _ZN4core3ptr37drop_in_place$LT$core..fmt..Error$GT$17hc552c807d2736f5eE ]] function(loc_0)
	while true do
		break
	end
end
FUNC_LIST[42] = --[[ _ZN4core3ptr42drop_in_place$LT$alloc..string..String$GT$17h0437b2dce3597bb5E ]] function(loc_0)
	local loc_1 = 0
	while true do
		while true do
			loc_1 = load_i32(memory_at_0, loc_0)
			if loc_1 == 0 then
				break
			end
			FUNC_LIST[22](load_i32(memory_at_0, loc_0 + 4), loc_1, 1)
			break
		end
		break
	end
end
FUNC_LIST[43] = --[[ _ZN4core3ptr52drop_in_place$LT$core..num..error..ParseIntError$GT$17h8aba332ab6766012E ]] function(loc_0)
	while true do
		break
	end
end
FUNC_LIST[44] = --[[ _ZN4core4iter6traits8iterator8Iterator8try_fold17h93e4dd8763395b06E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = 0
	local loc_8 = 0
	local loc_9 = 0
	local loc_10 = 0
	local loc_11 = 0
	local loc_12 = 0
	local loc_13 = 0
	local desired
	local br_map = {}
	while true do
		loc_2 = load_i32(memory_at_0, add_i32(loc_1, 24))
		loc_3 = load_i32(memory_at_0, add_i32(loc_1, 16))
		loc_4 = load_i32(memory_at_0, add_i32(loc_1, 20))
		loc_5 = load_i32(memory_at_0, loc_1 + 4)
		loc_6 = load_i32(memory_at_0, loc_1 + 8)
		loc_7 = load_i32(memory_at_0, loc_1)
		loc_8 = load_i32_u8(memory_at_0, loc_1 + 29)
		loc_9 = band_i32(load_i32_u8(memory_at_0, loc_1 + 28), 255)
		while true do
			while true do
				loc_10 = loc_7
				loc_11 = 0
				while true do
					if band_i32(loc_8, 255) == 0 then
						break
					end
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
						continue
					end
					break
				end
				while true do
					while true do
						while true do
							if loc_3 == loc_4 then
								break
							end
							while true do
								loc_12 = loc_2
								loc_2 = loc_3
								loc_3 = add_i32(loc_2, 1)
								store_i32(memory_at_0, loc_1 + 16, loc_3)
								while true do
									loc_7 = load_i32_u8(memory_at_0, loc_2)
									if gt_i32(extend_i32_n8(loc_7), 4294967295) then
										break
									end
									loc_3 = add_i32(loc_2, 2)
									store_i32(memory_at_0, loc_1 + 16, loc_3)
									loc_8 = band_i32(load_i32_u8(memory_at_0, loc_2 + 1), 63)
									loc_13 = band_i32(loc_7, 31)
									while true do
										if loc_7 > 223 then
											break
										end
										loc_7 = bor_i32(shl_i32(loc_13, 6), loc_8)
										desired = 7
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									loc_3 = add_i32(loc_2, 3)
									store_i32(memory_at_0, loc_1 + 16, loc_3)
									loc_8 = bor_i32(shl_i32(loc_8, 6), band_i32(load_i32_u8(memory_at_0, loc_2 + 2), 63))
									while true do
										if loc_7 >= 240 then
											break
										end
										loc_7 = bor_i32(loc_8, shl_i32(loc_13, 12))
										desired = 7
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									loc_3 = add_i32(loc_2, 4)
									store_i32(memory_at_0, loc_1 + 16, loc_3)
									loc_7 = bor_i32(bor_i32(shl_i32(loc_8, 6), band_i32(load_i32_u8(memory_at_0, loc_2 + 3), 63)), band_i32(shl_i32(loc_13, 18), 1835008))
									if loc_7 ~= 1114112 then
										break
									end
									loc_2 = loc_12
									desired = 4
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
										continue
									end
									break
								end
								loc_2 = add_i32(sub_i32(loc_3, loc_2), loc_12)
								store_i32(memory_at_0, loc_1 + 24, loc_2)
								while true do
									while true do
										while true do
											loc_8 = add_i32(loc_7, 4294967287)
											if loc_8 > 23 then
												break
											end
											if band_i32(shl_i32(1, loc_8), 8388639) ~= 0 then
												desired = 8
												break
											end
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										if loc_7 < 128 then
											desired = 7
											break
										end
										while true do
											while true do
												while true do
													while true do
														loc_8 = shr_u32(loc_7, 8)
														if not br_map[1] then
															br_map[1] = (function()
																return { [0] = 3, 5, 5, 5, 5, 5, 5, 5, 5, 5, 1, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 0, }
															end)()
														end
														temp = br_map[1][add_i32(loc_8, 4294967274)] or 2
														if temp < 2 then
															if temp < 1 then
																break
															else
																desired = 11
																break
															end
														elseif temp > 2 then
															if temp < 5 then
																desired = 9
																break
															else
																desired = 7
																break
															end
														else
															desired = 10
															break
														end
													end
													if desired then
														if desired == 11 then
															desired = nil
														end
														break
													end
													if loc_7 ~= 12288 then
														desired = 7
														break
													end
													desired = 8
													break
												end
												if desired then
													if desired == 10 then
														desired = nil
													end
													break
												end
												if band_i32(load_i32_u8(memory_at_0, add_i32(band_i32(loc_7, 255), 1077031)), 2) == 0 then
													desired = 7
													break
												end
												desired = 8
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											if loc_8 ~= 0 then
												desired = 7
												break
											end
											if band_i32(load_i32_u8(memory_at_0, add_i32(band_i32(loc_7, 255), 1077031)), 1) ~= 0 then
												desired = 8
												break
											end
											desired = 7
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										if loc_7 ~= 5760 then
											desired = 7
											break
										end
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									store_i32(memory_at_0, loc_1, loc_2)
									loc_8 = 0
									loc_7 = loc_2
									desired = 3
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
										continue
									end
									break
								end
								if loc_3 ~= loc_4 then
									continue
								end
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_3 = loc_4
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_8 = 1
					store_i32_n8(memory_at_0, loc_1 + 29, 1)
					while true do
						if loc_9 == 0 then
							break
						end
						loc_7 = loc_10
						loc_12 = loc_5
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_7 = loc_10
					loc_12 = loc_5
					if loc_5 == loc_10 then
						desired = 1
						break
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
						continue
					end
					break
				end
				loc_13 = sub_i32(loc_12, loc_10)
				if loc_13 == 0 then
					continue
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_11 = add_i32(loc_6, loc_10)
			break
		end
		store_i32(memory_at_0, loc_0 + 4, loc_13)
		store_i32(memory_at_0, loc_0, loc_11)
		break
	end
end
FUNC_LIST[45] = --[[ _ZN53_$LT$core..fmt..Error$u20$as$u20$core..fmt..Debug$GT$3fmt17h1738d1094ba0f72dE ]] function(loc_0, loc_1)
	local reg_0
	while true do
		reg_0 = FUNC_LIST[229](loc_1, 1050568, 5)
		break
	end
	return reg_0
end
FUNC_LIST[46] = --[[ _ZN58_$LT$alloc..string..String$u20$as$u20$core..fmt..Write$GT$10write_char17h062851a21fa82158E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local reg_0
	local desired
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_2
		while true do
			while true do
				while true do
					while true do
						if loc_1 < 128 then
							break
						end
						store_i32(memory_at_0, loc_2 + 12, 0)
						if loc_1 < 2048 then
							desired = 3
							break
						end
						while true do
							if loc_1 >= 65536 then
								break
							end
							store_i32_n8(memory_at_0, loc_2 + 14, bor_i32(band_i32(loc_1, 63), 128))
							store_i32_n8(memory_at_0, loc_2 + 12, bor_i32(shr_u32(loc_1, 12), 224))
							store_i32_n8(memory_at_0, loc_2 + 13, bor_i32(band_i32(shr_u32(loc_1, 6), 63), 128))
							loc_1 = 3
							desired = 2
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						store_i32_n8(memory_at_0, loc_2 + 15, bor_i32(band_i32(loc_1, 63), 128))
						store_i32_n8(memory_at_0, loc_2 + 14, bor_i32(band_i32(shr_u32(loc_1, 6), 63), 128))
						store_i32_n8(memory_at_0, loc_2 + 13, bor_i32(band_i32(shr_u32(loc_1, 12), 63), 128))
						store_i32_n8(memory_at_0, loc_2 + 12, bor_i32(band_i32(shr_u32(loc_1, 18), 7), 240))
						loc_1 = 4
						desired = 2
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					while true do
						loc_3 = load_i32(memory_at_0, loc_0 + 8)
						if loc_3 ~= load_i32(memory_at_0, loc_0) then
							break
						end
						FUNC_LIST[57](loc_0, loc_3)
						loc_3 = load_i32(memory_at_0, loc_0 + 8)
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32_n8(memory_at_0, add_i32(load_i32(memory_at_0, loc_0 + 4), loc_3), loc_1)
					store_i32(memory_at_0, loc_0 + 8, add_i32(load_i32(memory_at_0, loc_0 + 8), 1))
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i32_n8(memory_at_0, loc_2 + 13, bor_i32(band_i32(loc_1, 63), 128))
				store_i32_n8(memory_at_0, loc_2 + 12, bor_i32(shr_u32(loc_1, 6), 192))
				loc_1 = 2
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				loc_3 = load_i32(memory_at_0, loc_0 + 8)
				if sub_i32(load_i32(memory_at_0, loc_0), loc_3) >= loc_1 then
					break
				end
				FUNC_LIST[62](loc_0, loc_3, loc_1)
				loc_3 = load_i32(memory_at_0, loc_0 + 8)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			reg_0 = FUNC_LIST[262](add_i32(load_i32(memory_at_0, loc_0 + 4), loc_3), add_i32(loc_2, 12), loc_1)
			store_i32(memory_at_0, loc_0 + 8, add_i32(loc_3, loc_1))
			break
		end
		GLOBAL_LIST[0].value = add_i32(loc_2, 16)
		reg_0 = 0
		break
	end
	return reg_0
end
FUNC_LIST[47] = --[[ _ZN58_$LT$alloc..string..String$u20$as$u20$core..fmt..Write$GT$9write_str17hbef94c01d8f2ab7aE ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	local reg_0
	while true do
		while true do
			loc_3 = load_i32(memory_at_0, loc_0 + 8)
			if sub_i32(load_i32(memory_at_0, loc_0), loc_3) >= loc_2 then
				break
			end
			FUNC_LIST[62](loc_0, loc_3, loc_2)
			loc_3 = load_i32(memory_at_0, loc_0 + 8)
			break
		end
		reg_0 = FUNC_LIST[262](add_i32(load_i32(memory_at_0, loc_0 + 4), loc_3), loc_1, loc_2)
		store_i32(memory_at_0, loc_0 + 8, add_i32(loc_3, loc_2))
		reg_0 = 0
		break
	end
	return reg_0
end
FUNC_LIST[48] = --[[ _ZN68_$LT$core..num..error..ParseIntError$u20$as$u20$core..fmt..Debug$GT$3fmt17h7cef7ce39f0947e1E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local reg_0
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_2
		store_i32(memory_at_0, loc_2 + 12, loc_0)
		reg_0 = FUNC_LIST[231](loc_1, 1050573, 13, 1050586, 4, add_i32(loc_2, 12), 1050592)
		loc_0 = reg_0
		GLOBAL_LIST[0].value = add_i32(loc_2, 16)
		reg_0 = loc_0
		break
	end
	return reg_0
end
FUNC_LIST[49] = --[[ _ZN6engine5board3fen38_$LT$impl$u20$engine..board..Board$GT$8from_fen17h3926ab870a68f6afE ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = i64_ZERO
	local loc_7 = 0
	local loc_8 = 0
	local loc_9 = 0
	local loc_10 = 0
	local loc_11 = i64_ZERO
	local loc_12 = i64_ZERO
	local reg_0
	local reg_1
	local desired
	local br_map = {}
	while true do
		loc_3 = sub_i32(GLOBAL_LIST[0].value, 208)
		GLOBAL_LIST[0].value = loc_3
		reg_0 = FUNC_LIST[259](add_i32(loc_3, 48), 0, 96)
		loc_4 = add_i32(loc_1, loc_2)
		loc_5 = 7
		loc_6 = i64_ZERO
		while true do
			while true do
				while true do
					loc_7 = shl_i32(loc_5, 3)
					loc_8 = 0
					while true do
						while true do
							while true do
								if loc_1 ~= loc_4 then
									break
								end
								loc_1 = loc_4
								desired = 1
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
									continue
								end
								break
							end
							while true do
								while true do
									loc_2 = load_i32_i8(memory_at_0, loc_1)
									if le_i32(loc_2, 4294967295) then
										break
									end
									loc_1 = add_i32(loc_1, 1)
									loc_2 = band_i32(loc_2, 255)
									desired = 6
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								loc_9 = band_i32(load_i32_u8(memory_at_0, loc_1 + 1), 63)
								loc_10 = band_i32(loc_2, 31)
								while true do
									if loc_2 > 4294967263 then
										break
									end
									loc_2 = bor_i32(shl_i32(loc_10, 6), loc_9)
									loc_1 = add_i32(loc_1, 2)
									desired = 6
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								loc_9 = bor_i32(shl_i32(loc_9, 6), band_i32(load_i32_u8(memory_at_0, loc_1 + 2), 63))
								while true do
									if loc_2 >= 4294967280 then
										break
									end
									loc_2 = bor_i32(loc_9, shl_i32(loc_10, 12))
									loc_1 = add_i32(loc_1, 3)
									desired = 6
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								loc_2 = load_i32_u8(memory_at_0, loc_1 + 3)
								loc_1 = add_i32(loc_1, 4)
								loc_2 = bor_i32(bor_i32(shl_i32(loc_9, 6), band_i32(loc_2, 63)), band_i32(shl_i32(loc_10, 18), 1835008))
								if loc_2 == 1114112 then
									desired = 1
									break
								end
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
									continue
								end
								break
							end
							if loc_2 == 47 then
								continue
							end
							while true do
								loc_10 = add_i32(loc_2, 4294967248)
								if loc_10 <= 9 then
									break
								end
								loc_10 = 0
								while true do
									while true do
										while true do
											while true do
												while true do
													while true do
														while true do
															while true do
																while true do
																	while true do
																		while true do
																			while true do
																				if not br_map[1] then
																					br_map[1] = (function()
																						return { [0] = 0, 16, 16, 16, 16, 16, 16, 16, 16, 3, 16, 16, 10, 16, 11, 2, 1, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 6, 16, 16, 16, 16, 16, 16, 16, 16, 9, 16, 16, 5, 16, 4, 8, 7, }
																					end)()
																				end
																				temp = br_map[1][add_i32(loc_2, 4294967230)] or 16
																				if temp < 6 then
																					if temp < 3 then
																						if temp < 1 then
																							break
																						elseif temp > 1 then
																							desired = 16
																							break
																						else
																							desired = 17
																							break
																						end
																					elseif temp > 3 then
																						if temp < 5 then
																							desired = 14
																							break
																						else
																							desired = 13
																							break
																						end
																					else
																						desired = 15
																						break
																					end
																				elseif temp > 6 then
																					if temp < 10 then
																						if temp < 8 then
																							desired = 11
																							break
																						elseif temp > 8 then
																							desired = 9
																							break
																						else
																							desired = 10
																							break
																						end
																					elseif temp > 10 then
																						if temp < 16 then
																							desired = 7
																							break
																						else
																							desired = 2
																							break
																						end
																					else
																						desired = 8
																						break
																					end
																				else
																					desired = 12
																					break
																				end
																			end
																			if desired then
																				if desired == 17 then
																					desired = nil
																				end
																				break
																			end
																			loc_10 = 2
																			desired = 7
																			break
																		end
																		if desired then
																			if desired == 16 then
																				desired = nil
																			end
																			break
																		end
																		loc_10 = 3
																		desired = 7
																		break
																	end
																	if desired then
																		if desired == 15 then
																			desired = nil
																		end
																		break
																	end
																	loc_10 = 4
																	desired = 7
																	break
																end
																if desired then
																	if desired == 14 then
																		desired = nil
																	end
																	break
																end
																loc_10 = 5
																desired = 7
																break
															end
															if desired then
																if desired == 13 then
																	desired = nil
																end
																break
															end
															loc_10 = 6
															desired = 7
															break
														end
														if desired then
															if desired == 12 then
																desired = nil
															end
															break
														end
														loc_10 = 7
														desired = 7
														break
													end
													if desired then
														if desired == 11 then
															desired = nil
														end
														break
													end
													loc_10 = 8
													desired = 7
													break
												end
												if desired then
													if desired == 10 then
														desired = nil
													end
													break
												end
												loc_10 = 9
												desired = 7
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											loc_10 = 10
											desired = 7
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										loc_10 = 11
										desired = 7
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									loc_10 = 1
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								loc_2 = add_i32(add_i32(loc_3, 48), shl_i32(loc_10, 3))
								reg_0 = loc_2
								reg_1 = load_i64(memory_at_0, loc_2)
								loc_2 = add_i32(loc_7, loc_8)
								store_i64(memory_at_0, reg_0, bor_i64(reg_1, shl_i64(i64_ONE, extend_i64_u32(band_i32(loc_2, 63)))))
								loc_9 = extend_i32_n8(loc_2)
								if band_i32(loc_2, 255) >= 64 then
									desired = 4
									break
								end
								loc_6 = bxor_i64(load_i64(memory_at_0, add_i32(add_i32(shl_i32(loc_10, 9), shl_i32(loc_9, 3)), 1056448)), loc_6)
								loc_10 = 1
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
									continue
								end
								break
							end
							loc_8 = add_i32(loc_10, loc_8)
							if band_i32(loc_8, 255) ~= 8 then
								continue
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						if band_i32(loc_5, 255) == 0 then
							desired = 1
							break
						end
						loc_5 = add_i32(loc_5, 4294967295)
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
							continue
						end
						break
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[189](loc_9, 64, 1062828)
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			store_i32(memory_at_0, loc_3 + 148, 13)
			store_i32(memory_at_0, loc_3 + 144, 1051032)
			FUNC_LIST[208](1050608, 20, add_i32(loc_3, 144), 1050916, 1050932)
			error("out of code bounds")
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		store_i32(memory_at_0, loc_3 + 184, loc_4)
		store_i32(memory_at_0, loc_3 + 180, loc_1)
		store_i32(memory_at_0, loc_3 + 176, 1114113)
		store_i32(memory_at_0, loc_3 + 152, 0)
		store_i64(memory_at_0, loc_3 + 144, i64_from_u32(0, 1))
		FUNC_LIST[75](add_i32(loc_3, 144), add_i32(loc_3, 176))
		loc_4 = load_i32(memory_at_0, loc_3 + 144)
		loc_2 = load_i32(memory_at_0, loc_3 + 152)
		loc_1 = load_i32(memory_at_0, loc_3 + 148)
		store_i32_n16(memory_at_0, loc_3 + 172, 1)
		store_i32(memory_at_0, loc_3 + 168, 0)
		store_i32(memory_at_0, loc_3 + 164, add_i32(loc_1, loc_2))
		store_i32(memory_at_0, loc_3 + 160, loc_1)
		store_i32(memory_at_0, loc_3 + 156, loc_2)
		store_i32(memory_at_0, loc_3 + 152, loc_1)
		store_i32(memory_at_0, loc_3 + 148, loc_2)
		store_i32(memory_at_0, loc_3 + 144, 0)
		FUNC_LIST[44](add_i32(loc_3, 40), add_i32(loc_3, 144))
		while true do
			loc_2 = load_i32(memory_at_0, loc_3 + 40)
			if loc_2 ~= 0 then
				break
			end
			FUNC_LIST[210](1050644, 19, 1050664)
			error("out of code bounds")
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		while true do
			while true do
				while true do
					while true do
						while true do
							while true do
								while true do
									if load_i32(memory_at_0, loc_3 + 44) ~= 1 then
										break
									end
									while true do
										loc_9 = load_i32_u8(memory_at_0, loc_2)
										if loc_9 == 119 then
											break
										end
										if load_i32_u8(memory_at_0, loc_2) ~= 98 then
											desired = 7
											break
										end
										loc_6 = bxor_i64(loc_6, i64_from_u32(4095246069, 424779229))
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									FUNC_LIST[44](add_i32(loc_3, 32), add_i32(loc_3, 144))
									loc_2 = load_i32(memory_at_0, loc_3 + 32)
									if loc_2 == 0 then
										desired = 6
										break
									end
									reg_0 = FUNC_LIST[70](loc_2, load_i32(memory_at_0, loc_3 + 36))
									loc_8 = reg_0
									loc_2 = band_i32(loc_8, 255)
									if loc_2 >= 16 then
										desired = 5
										break
									end
									loc_11 = load_i64(memory_at_0, add_i32(shl_i32(loc_2, 3), 1062592))
									FUNC_LIST[44](add_i32(loc_3, 24), add_i32(loc_3, 144))
									loc_2 = load_i32(memory_at_0, loc_3 + 24)
									if loc_2 == 0 then
										desired = 4
										break
									end
									loc_6 = bxor_i64(loc_11, loc_6)
									loc_10 = 1
									while true do
										while true do
											loc_5 = load_i32(memory_at_0, loc_3 + 28)
											if loc_5 ~= 1 then
												break
											end
											if load_i32_u8(memory_at_0, loc_2) ~= 45 then
												break
											end
											loc_10 = 0
											desired = 8
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										reg_0 = FUNC_LIST[76](loc_2, loc_5)
										loc_5 = reg_0
										loc_6 = bxor_i64(load_i64(memory_at_0, add_i32(shl_i32(band_i32(loc_5, 7), 3), 1062720)), loc_6)
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									FUNC_LIST[44](add_i32(loc_3, 16), add_i32(loc_3, 144))
									loc_2 = load_i32(memory_at_0, loc_3 + 16)
									if loc_2 == 0 then
										desired = 3
										break
									end
									FUNC_LIST[246](add_i32(loc_3, 176), loc_2, load_i32(memory_at_0, loc_3 + 20))
									if load_i32_u8(memory_at_0, loc_3 + 176) ~= 0 then
										desired = 2
										break
									end
									loc_11 = load_i64(memory_at_0, loc_3 + 184)
									FUNC_LIST[44](add_i32(loc_3, 8), add_i32(loc_3, 144))
									loc_2 = load_i32(memory_at_0, loc_3 + 8)
									if loc_2 == 0 then
										desired = 1
										break
									end
									FUNC_LIST[246](add_i32(loc_3, 176), loc_2, load_i32(memory_at_0, loc_3 + 12))
									while true do
										if load_i32_u8(memory_at_0, loc_3 + 176) ~= 0 then
											break
										end
										loc_12 = load_i64(memory_at_0, loc_3 + 184)
										reg_0 = FUNC_LIST[262](add_i32(loc_0, 32), add_i32(loc_3, 48), 96)
										store_i32(memory_at_0, add_i32(loc_0, 136), 0)
										store_i64(memory_at_0, loc_0 + 128, i64_from_u32(0, 8))
										store_i32_n8(memory_at_0, loc_0 + 27, loc_5)
										store_i32_n8(memory_at_0, loc_0 + 26, loc_10)
										store_i32_n8(memory_at_0, loc_0 + 25, 12)
										store_i32_n8(memory_at_0, loc_0 + 24, loc_8)
										store_i64(memory_at_0, loc_0 + 16, loc_6)
										store_i64(memory_at_0, loc_0 + 8, loc_12)
										store_i64(memory_at_0, loc_0, loc_11)
										store_i32_n8(memory_at_0, loc_0 + 140, (if loc_9 == 119 then 1 else 0))
										while true do
											if loc_4 == 0 then
												break
											end
											FUNC_LIST[22](loc_1, loc_4, 1)
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										GLOBAL_LIST[0].value = add_i32(loc_3, 208)
										desired = 0
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									store_i32_n8(memory_at_0, loc_3 + 207, load_i32_u8(memory_at_0, loc_3 + 177))
									FUNC_LIST[208](1050832, 20, add_i32(loc_3, 207), 1050868, 1050884)
									error("out of code bounds")
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								store_i64(memory_at_0, add_i32(loc_3, 188), i64_ZERO)
								store_i32(memory_at_0, loc_3 + 180, 1)
								store_i32(memory_at_0, loc_3 + 176, 1050696)
								store_i32(memory_at_0, loc_3 + 184, 1050568)
								FUNC_LIST[187](add_i32(loc_3, 176), 1050704)
								error("out of code bounds")
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							FUNC_LIST[210](1050720, 23, 1050744)
							error("out of code bounds")
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						FUNC_LIST[189](loc_2, 16, 1062812)
						error("out of code bounds")
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					FUNC_LIST[210](1050760, 18, 1050780)
					error("out of code bounds")
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[210](1050796, 18, 1050816)
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			store_i32_n8(memory_at_0, loc_3 + 207, load_i32_u8(memory_at_0, loc_3 + 177))
			FUNC_LIST[208](1050796, 18, add_i32(loc_3, 207), 1050868, 1050900)
			error("out of code bounds")
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		FUNC_LIST[210](1050832, 20, 1050852)
		error("out of code bounds")
	end
end
FUNC_LIST[50] = --[[ _ZN6engine5board3fen38_$LT$impl$u20$engine..board..Board$GT$6to_fen17h31f402e8b5d81099E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = i64_ZERO
	local loc_6 = i64_ZERO
	local loc_7 = i64_ZERO
	local loc_8 = i64_ZERO
	local loc_9 = i64_ZERO
	local loc_10 = i64_ZERO
	local loc_11 = i64_ZERO
	local loc_12 = i64_ZERO
	local loc_13 = i64_ZERO
	local loc_14 = i64_ZERO
	local loc_15 = i64_ZERO
	local loc_16 = i64_ZERO
	local loc_17 = i64_ZERO
	local loc_18 = i64_ZERO
	local loc_19 = i64_ZERO
	local loc_20 = 0
	local loc_21 = i64_ZERO
	local loc_22 = 0
	local reg_0
	local desired
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 96)
		GLOBAL_LIST[0].value = loc_2
		loc_3 = 0
		while true do
			while true do
				reg_0 = FUNC_LIST[21](87, 1)
				loc_4 = reg_0
				if loc_4 == 0 then
					break
				end
				store_i32(memory_at_0, loc_2 + 16, loc_4)
				store_i32(memory_at_0, loc_2 + 12, 87)
				loc_5 = load_i64(memory_at_0, add_i32(loc_1, 120))
				loc_6 = load_i64(memory_at_0, add_i32(loc_1, 112))
				loc_7 = load_i64(memory_at_0, add_i32(loc_1, 104))
				loc_8 = load_i64(memory_at_0, add_i32(loc_1, 96))
				loc_9 = load_i64(memory_at_0, add_i32(loc_1, 88))
				loc_10 = load_i64(memory_at_0, add_i32(loc_1, 80))
				loc_11 = load_i64(memory_at_0, add_i32(loc_1, 72))
				loc_12 = load_i64(memory_at_0, add_i32(loc_1, 64))
				loc_13 = load_i64(memory_at_0, add_i32(loc_1, 56))
				loc_14 = load_i64(memory_at_0, add_i32(loc_1, 48))
				loc_15 = load_i64(memory_at_0, add_i32(loc_1, 40))
				loc_16 = load_i64(memory_at_0, loc_1 + 32)
				loc_17 = i64_from_u32(56, 0)
				loc_18 = i64_from_u32(8, 0)
				while true do
					store_i32(memory_at_0, loc_2 + 20, loc_3)
					loc_18 = add_i64(loc_18, i64_from_u32(4294967295, 4294967295))
					loc_19 = i64_ZERO
					while true do
						loc_20 = 0
						loc_21 = loc_19
						loc_4 = 0
						while true do
							while true do
								while true do
									loc_19 = shl_i64(i64_ONE, add_i64(loc_17, loc_21))
									if ne_i64(band_i64(loc_16, loc_19), i64_ZERO) then
										desired = 6
										break
									end
									while true do
										if eq_i64(band_i64(loc_15, loc_19), i64_ZERO) then
											break
										end
										loc_20 = 1
										desired = 6
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
											continue
										end
										break
									end
									while true do
										if eq_i64(band_i64(loc_14, loc_19), i64_ZERO) then
											break
										end
										loc_20 = 2
										desired = 6
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
											continue
										end
										break
									end
									while true do
										if eq_i64(band_i64(loc_13, loc_19), i64_ZERO) then
											break
										end
										loc_20 = 3
										desired = 6
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
											continue
										end
										break
									end
									while true do
										if eq_i64(band_i64(loc_12, loc_19), i64_ZERO) then
											break
										end
										loc_20 = 4
										desired = 6
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
											continue
										end
										break
									end
									while true do
										if eq_i64(band_i64(loc_11, loc_19), i64_ZERO) then
											break
										end
										loc_20 = 5
										desired = 6
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
											continue
										end
										break
									end
									while true do
										if eq_i64(band_i64(loc_10, loc_19), i64_ZERO) then
											break
										end
										loc_20 = 6
										desired = 6
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
											continue
										end
										break
									end
									while true do
										if eq_i64(band_i64(loc_9, loc_19), i64_ZERO) then
											break
										end
										loc_20 = 7
										desired = 6
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
											continue
										end
										break
									end
									while true do
										if eq_i64(band_i64(loc_8, loc_19), i64_ZERO) then
											break
										end
										loc_20 = 8
										desired = 6
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
											continue
										end
										break
									end
									while true do
										if eq_i64(band_i64(loc_7, loc_19), i64_ZERO) then
											break
										end
										loc_20 = 9
										desired = 6
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
											continue
										end
										break
									end
									while true do
										if eq_i64(band_i64(loc_6, loc_19), i64_ZERO) then
											break
										end
										loc_20 = 10
										desired = 6
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
											continue
										end
										break
									end
									while true do
										if eq_i64(band_i64(loc_5, loc_19), i64_ZERO) then
											break
										end
										loc_20 = 11
										desired = 6
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
											continue
										end
										break
									end
									loc_4 = add_i32(loc_4, 1)
									loc_21 = add_i64(loc_21, i64_ONE)
									if ne_i64(loc_21, i64_from_u32(8, 0)) then
										continue
									end
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								if loc_4 == 0 then
									desired = 5
									break
								end
								while true do
									if loc_4 <= 9 then
										break
									end
									FUNC_LIST[192](1050954, 43, 1051000)
									error("out of code bounds")
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								loc_4 = add_i32(add_i32(loc_4, 4294967295), 49)
								while true do
									if loc_3 ~= load_i32(memory_at_0, loc_2 + 12) then
										break
									end
									FUNC_LIST[57](add_i32(loc_2, 12), loc_3)
									loc_3 = load_i32(memory_at_0, loc_2 + 20)
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								store_i32_n8(memory_at_0, add_i32(load_i32(memory_at_0, loc_2 + 16), loc_3), loc_4)
								loc_3 = add_i32(load_i32(memory_at_0, loc_2 + 20), 1)
								store_i32(memory_at_0, loc_2 + 20, loc_3)
								desired = 5
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							while true do
								if loc_4 == 0 then
									break
								end
								while true do
									if loc_4 <= 9 then
										break
									end
									FUNC_LIST[192](1050954, 43, 1051016)
									error("out of code bounds")
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								while true do
									if loc_3 ~= load_i32(memory_at_0, loc_2 + 12) then
										break
									end
									FUNC_LIST[57](add_i32(loc_2, 12), loc_3)
									loc_3 = load_i32(memory_at_0, loc_2 + 20)
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								store_i32_n8(memory_at_0, add_i32(load_i32(memory_at_0, loc_2 + 16), loc_3), add_i32(loc_4, 48))
								loc_3 = add_i32(load_i32(memory_at_0, loc_2 + 20), 1)
								store_i32(memory_at_0, loc_2 + 20, loc_3)
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_4 = load_i32_u8(memory_at_0, add_i32(loc_20, 1051200))
							while true do
								if loc_3 ~= load_i32(memory_at_0, loc_2 + 12) then
									break
								end
								FUNC_LIST[57](add_i32(loc_2, 12), loc_3)
								loc_3 = load_i32(memory_at_0, loc_2 + 20)
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_19 = add_i64(loc_21, i64_ONE)
							store_i32_n8(memory_at_0, add_i32(load_i32(memory_at_0, loc_2 + 16), loc_3), loc_4)
							loc_3 = add_i32(load_i32(memory_at_0, loc_2 + 20), 1)
							store_i32(memory_at_0, loc_2 + 20, loc_3)
							if ne_i64(loc_21, i64_from_u32(7, 0)) then
								desired = 4
								break
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
								continue
							end
							break
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
							continue
						end
						break
					end
					if eq_i64(loc_18, i64_ZERO) then
						desired = 1
						break
					end
					while true do
						if loc_3 ~= load_i32(memory_at_0, loc_2 + 12) then
							break
						end
						FUNC_LIST[57](add_i32(loc_2, 12), loc_3)
						loc_3 = load_i32(memory_at_0, loc_2 + 20)
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
							continue
						end
						break
					end
					store_i32_n8(memory_at_0, add_i32(load_i32(memory_at_0, loc_2 + 16), loc_3), 47)
					loc_17 = add_i64(loc_17, i64_from_u32(4294967288, 4294967295))
					loc_3 = add_i32(load_i32(memory_at_0, loc_2 + 20), 1)
					continue
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[173](1, 87)
			error("out of code bounds")
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		loc_4 = (if load_i32_u8(memory_at_0, loc_1 + 140) ~= 0 then 1050951 else 1050948)
		while true do
			if sub_i32(load_i32(memory_at_0, loc_2 + 12), loc_3) > 2 then
				break
			end
			FUNC_LIST[62](add_i32(loc_2, 12), loc_3, 3)
			loc_3 = load_i32(memory_at_0, loc_2 + 20)
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		loc_20 = add_i32(load_i32(memory_at_0, loc_2 + 16), loc_3)
		store_i32_n16(memory_at_0, loc_20, load_i32_u16(memory_at_0, loc_4))
		store_i32_n8(memory_at_0, add_i32(loc_20, 2), load_i32_u8(memory_at_0, add_i32(loc_4, 2)))
		loc_4 = add_i32(loc_3, 3)
		store_i32(memory_at_0, loc_2 + 20, loc_4)
		while true do
			while true do
				while true do
					while true do
						loc_3 = load_i32_u8(memory_at_0, loc_1 + 24)
						if loc_3 ~= 0 then
							break
						end
						loc_3 = 45
						if loc_4 ~= load_i32(memory_at_0, loc_2 + 12) then
							desired = 2
							break
						end
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					while true do
						if band_i32(loc_3, 1) == 0 then
							break
						end
						while true do
							if loc_4 ~= load_i32(memory_at_0, loc_2 + 12) then
								break
							end
							FUNC_LIST[57](add_i32(loc_2, 12), loc_4)
							loc_4 = load_i32(memory_at_0, loc_2 + 20)
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						store_i32_n8(memory_at_0, add_i32(load_i32(memory_at_0, loc_2 + 16), loc_4), 75)
						loc_4 = add_i32(load_i32(memory_at_0, loc_2 + 20), 1)
						store_i32(memory_at_0, loc_2 + 20, loc_4)
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					while true do
						if band_i32(loc_3, 2) == 0 then
							break
						end
						while true do
							if loc_4 ~= load_i32(memory_at_0, loc_2 + 12) then
								break
							end
							FUNC_LIST[57](add_i32(loc_2, 12), loc_4)
							loc_4 = load_i32(memory_at_0, loc_2 + 20)
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						store_i32_n8(memory_at_0, add_i32(load_i32(memory_at_0, loc_2 + 16), loc_4), 81)
						loc_4 = add_i32(load_i32(memory_at_0, loc_2 + 20), 1)
						store_i32(memory_at_0, loc_2 + 20, loc_4)
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					while true do
						if band_i32(loc_3, 4) == 0 then
							break
						end
						while true do
							if loc_4 ~= load_i32(memory_at_0, loc_2 + 12) then
								break
							end
							FUNC_LIST[57](add_i32(loc_2, 12), loc_4)
							loc_4 = load_i32(memory_at_0, loc_2 + 20)
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						store_i32_n8(memory_at_0, add_i32(load_i32(memory_at_0, loc_2 + 16), loc_4), 107)
						loc_4 = add_i32(load_i32(memory_at_0, loc_2 + 20), 1)
						store_i32(memory_at_0, loc_2 + 20, loc_4)
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					if band_i32(loc_3, 8) == 0 then
						desired = 1
						break
					end
					loc_3 = 113
					if loc_4 ~= load_i32(memory_at_0, loc_2 + 12) then
						desired = 2
						break
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[57](add_i32(loc_2, 12), loc_4)
				loc_4 = load_i32(memory_at_0, loc_2 + 20)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			store_i32_n8(memory_at_0, add_i32(load_i32(memory_at_0, loc_2 + 16), loc_4), loc_3)
			loc_4 = add_i32(load_i32(memory_at_0, loc_2 + 20), 1)
			store_i32(memory_at_0, loc_2 + 20, loc_4)
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		while true do
			if loc_4 ~= load_i32(memory_at_0, loc_2 + 12) then
				break
			end
			FUNC_LIST[57](add_i32(loc_2, 12), loc_4)
			loc_4 = load_i32(memory_at_0, loc_2 + 20)
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		store_i32_n8(memory_at_0, add_i32(load_i32(memory_at_0, loc_2 + 16), loc_4), 32)
		loc_4 = add_i32(load_i32(memory_at_0, loc_2 + 20), 1)
		store_i32(memory_at_0, loc_2 + 20, loc_4)
		while true do
			while true do
				if load_i32_u8(memory_at_0, loc_1 + 26) == 0 then
					break
				end
				loc_4 = load_i32_i8(memory_at_0, add_i32(loc_1, 27))
				store_i32(memory_at_0, loc_2 + 72, add_i32(band_i32(loc_4, 7), 97))
				store_i32_n8(memory_at_0, loc_2 + 79, add_i32(shr_u32(loc_4, 3), 1))
				store_i64(memory_at_0, add_i32(add_i32(loc_2, 36), 12), i64_from_u32(2, 0))
				store_i32(memory_at_0, add_i32(add_i32(loc_2, 80), 12), 12)
				store_i32(memory_at_0, loc_2 + 40, 2)
				store_i32(memory_at_0, loc_2 + 36, 1063180)
				store_i32(memory_at_0, loc_2 + 84, 13)
				store_i32(memory_at_0, loc_2 + 44, add_i32(loc_2, 80))
				store_i32(memory_at_0, loc_2 + 88, add_i32(loc_2, 79))
				store_i32(memory_at_0, loc_2 + 80, add_i32(loc_2, 72))
				FUNC_LIST[178](add_i32(loc_2, 24), add_i32(loc_2, 36))
				loc_20 = load_i32(memory_at_0, loc_2 + 28)
				while true do
					loc_4 = load_i32(memory_at_0, loc_2 + 20)
					loc_3 = load_i32(memory_at_0, loc_2 + 32)
					if sub_i32(load_i32(memory_at_0, loc_2 + 12), loc_4) >= loc_3 then
						break
					end
					FUNC_LIST[62](add_i32(loc_2, 12), loc_4, loc_3)
					loc_4 = load_i32(memory_at_0, loc_2 + 20)
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				reg_0 = FUNC_LIST[262](add_i32(load_i32(memory_at_0, loc_2 + 16), loc_4), loc_20, loc_3)
				loc_4 = add_i32(loc_4, loc_3)
				store_i32(memory_at_0, loc_2 + 20, loc_4)
				loc_3 = load_i32(memory_at_0, loc_2 + 24)
				if loc_3 == 0 then
					desired = 1
					break
				end
				FUNC_LIST[22](loc_20, loc_3, 1)
				loc_4 = load_i32(memory_at_0, loc_2 + 20)
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				if loc_4 ~= load_i32(memory_at_0, loc_2 + 12) then
					break
				end
				FUNC_LIST[57](add_i32(loc_2, 12), loc_4)
				loc_4 = load_i32(memory_at_0, loc_2 + 20)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			store_i32_n8(memory_at_0, add_i32(load_i32(memory_at_0, loc_2 + 16), loc_4), 45)
			loc_4 = add_i32(load_i32(memory_at_0, loc_2 + 20), 1)
			store_i32(memory_at_0, loc_2 + 20, loc_4)
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		while true do
			if loc_4 ~= load_i32(memory_at_0, loc_2 + 12) then
				break
			end
			FUNC_LIST[57](add_i32(loc_2, 12), loc_4)
			loc_4 = load_i32(memory_at_0, loc_2 + 20)
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		store_i32_n8(memory_at_0, add_i32(load_i32(memory_at_0, loc_2 + 16), loc_4), 32)
		store_i32(memory_at_0, loc_2 + 20, add_i32(load_i32(memory_at_0, loc_2 + 20), 1))
		store_i32(memory_at_0, loc_2 + 88, 0)
		store_i64(memory_at_0, loc_2 + 80, i64_from_u32(0, 1))
		store_i32(memory_at_0, add_i32(loc_2, 60), 1050380)
		store_i32_n8(memory_at_0, loc_2 + 68, 3)
		store_i32(memory_at_0, loc_2 + 52, 32)
		store_i32(memory_at_0, loc_2 + 64, 0)
		store_i32(memory_at_0, loc_2 + 44, 0)
		store_i32(memory_at_0, loc_2 + 36, 0)
		store_i32(memory_at_0, loc_2 + 56, add_i32(loc_2, 80))
		while true do
			while true do
				reg_0 = FUNC_LIST[243](loc_1, add_i32(loc_2, 36))
				if reg_0 ~= 0 then
					break
				end
				loc_20 = load_i32(memory_at_0, loc_2 + 84)
				loc_22 = load_i32(memory_at_0, loc_2 + 80)
				while true do
					loc_4 = load_i32(memory_at_0, loc_2 + 20)
					loc_3 = load_i32(memory_at_0, loc_2 + 88)
					if sub_i32(load_i32(memory_at_0, loc_2 + 12), loc_4) >= loc_3 then
						break
					end
					FUNC_LIST[62](add_i32(loc_2, 12), loc_4, loc_3)
					loc_4 = load_i32(memory_at_0, loc_2 + 20)
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				reg_0 = FUNC_LIST[262](add_i32(load_i32(memory_at_0, loc_2 + 16), loc_4), loc_20, loc_3)
				loc_4 = add_i32(loc_4, loc_3)
				store_i32(memory_at_0, loc_2 + 20, loc_4)
				while true do
					if loc_22 == 0 then
						break
					end
					FUNC_LIST[22](loc_20, loc_22, 1)
					loc_4 = load_i32(memory_at_0, loc_2 + 20)
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				while true do
					if loc_4 ~= load_i32(memory_at_0, loc_2 + 12) then
						break
					end
					FUNC_LIST[57](add_i32(loc_2, 12), loc_4)
					loc_4 = load_i32(memory_at_0, loc_2 + 20)
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i32_n8(memory_at_0, add_i32(load_i32(memory_at_0, loc_2 + 16), loc_4), 32)
				store_i32(memory_at_0, loc_2 + 20, add_i32(load_i32(memory_at_0, loc_2 + 20), 1))
				store_i32(memory_at_0, loc_2 + 88, 0)
				store_i64(memory_at_0, loc_2 + 80, i64_from_u32(0, 1))
				store_i32(memory_at_0, add_i32(loc_2, 60), 1050380)
				store_i32_n8(memory_at_0, loc_2 + 68, 3)
				store_i32(memory_at_0, loc_2 + 52, 32)
				store_i32(memory_at_0, loc_2 + 64, 0)
				store_i32(memory_at_0, loc_2 + 44, 0)
				store_i32(memory_at_0, loc_2 + 36, 0)
				store_i32(memory_at_0, loc_2 + 56, add_i32(loc_2, 80))
				reg_0 = FUNC_LIST[243](add_i32(loc_1, 8), add_i32(loc_2, 36))
				if reg_0 ~= 0 then
					desired = 1
					break
				end
				loc_20 = load_i32(memory_at_0, loc_2 + 84)
				loc_1 = load_i32(memory_at_0, loc_2 + 80)
				while true do
					loc_4 = load_i32(memory_at_0, loc_2 + 20)
					loc_3 = load_i32(memory_at_0, loc_2 + 88)
					if sub_i32(load_i32(memory_at_0, loc_2 + 12), loc_4) >= loc_3 then
						break
					end
					FUNC_LIST[62](add_i32(loc_2, 12), loc_4, loc_3)
					loc_4 = load_i32(memory_at_0, loc_2 + 20)
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				reg_0 = FUNC_LIST[262](add_i32(load_i32(memory_at_0, loc_2 + 16), loc_4), loc_20, loc_3)
				store_i32(memory_at_0, loc_2 + 20, add_i32(loc_4, loc_3))
				while true do
					if loc_1 == 0 then
						break
					end
					FUNC_LIST[22](loc_20, loc_1, 1)
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i64(memory_at_0, loc_0, load_i64(memory_at_0, loc_2 + 12))
				store_i32(memory_at_0, add_i32(loc_0, 8), load_i32(memory_at_0, add_i32(add_i32(loc_2, 12), 8)))
				GLOBAL_LIST[0].value = add_i32(loc_2, 96)
				desired = 0
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[208](1050404, 55, add_i32(loc_2, 24), 1050460, 1050552)
			error("out of code bounds")
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		FUNC_LIST[208](1050404, 55, add_i32(loc_2, 24), 1050460, 1050552)
		error("out of code bounds")
	end
end
FUNC_LIST[51] = --[[ _ZN6engine14move_generator5maker38_$LT$impl$u20$engine..board..Board$GT$9make_move17hb6c3ee5aac65c340E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = i64_ZERO
	local loc_8 = i64_ZERO
	local loc_9 = 0
	local loc_10 = i64_ZERO
	local loc_11 = 0
	local loc_12 = 0
	local loc_13 = 0
	local loc_14 = 0
	local reg_0
	local reg_1
	local desired
	local br_map = {}
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_2
		loc_3 = add_i32(loc_2, 24)
		store_i64(memory_at_0, loc_3, load_i64(memory_at_0, add_i32(loc_0, 24)))
		loc_4 = add_i32(loc_2, 16)
		store_i64(memory_at_0, loc_4, load_i64(memory_at_0, add_i32(loc_0, 16)))
		loc_5 = add_i32(loc_2, 8)
		store_i64(memory_at_0, loc_5, load_i64(memory_at_0, add_i32(loc_0, 8)))
		store_i64(memory_at_0, loc_2, load_i64(memory_at_0, loc_0))
		while true do
			loc_6 = load_i32(memory_at_0, add_i32(loc_0, 136))
			if loc_6 ~= load_i32(memory_at_0, loc_0 + 128) then
				break
			end
			FUNC_LIST[60](add_i32(loc_0, 128), loc_6)
			loc_6 = load_i32(memory_at_0, loc_0 + 136)
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		loc_6 = add_i32(load_i32(memory_at_0, add_i32(loc_0, 132)), shl_i32(loc_6, 5))
		store_i64(memory_at_0, loc_6, load_i64(memory_at_0, loc_2))
		store_i64(memory_at_0, add_i32(loc_6, 24), load_i64(memory_at_0, loc_3))
		store_i64(memory_at_0, add_i32(loc_6, 16), load_i64(memory_at_0, loc_4))
		store_i64(memory_at_0, add_i32(loc_6, 8), load_i64(memory_at_0, loc_5))
		store_i32(memory_at_0, loc_0 + 136, add_i32(load_i32(memory_at_0, loc_0 + 136), 1))
		loc_7 = bxor_i64(load_i64(memory_at_0, loc_0 + 16), i64_from_u32(4095246069, 424779229))
		store_i64(memory_at_0, loc_0 + 16, loc_7)
		loc_4 = load_i32_i8(memory_at_0, loc_1 + 1)
		loc_8 = shl_i64(i64_ONE, extend_i64_u32(band_i32(loc_4, 63)))
		while true do
			while true do
				while true do
					loc_5 = load_i32_u8(memory_at_0, loc_0 + 140)
					if loc_5 ~= 0 then
						break
					end
					loc_3 = 6
					if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 80)), loc_8), i64_ZERO) then
						desired = 2
						break
					end
					loc_3 = 7
					if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 88)), loc_8), i64_ZERO) then
						desired = 2
						break
					end
					loc_3 = 8
					if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 96)), loc_8), i64_ZERO) then
						desired = 2
						break
					end
					loc_3 = 9
					if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 104)), loc_8), i64_ZERO) then
						desired = 2
						break
					end
					loc_3 = 10
					if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 112)), loc_8), i64_ZERO) then
						desired = 2
						break
					end
					loc_3 = 11
					if (if eq_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 120)), loc_8), i64_ZERO) then 1 else 0) == 0 then
						desired = 2
						break
					end
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_3 = 0
				if ne_i64(band_i64(load_i64(memory_at_0, loc_0 + 32), loc_8), i64_ZERO) then
					break
				end
				loc_3 = 1
				if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 40)), loc_8), i64_ZERO) then
					break
				end
				loc_3 = 2
				if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 48)), loc_8), i64_ZERO) then
					break
				end
				loc_3 = 3
				if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 56)), loc_8), i64_ZERO) then
					break
				end
				loc_3 = 4
				if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 64)), loc_8), i64_ZERO) then
					break
				end
				loc_3 = 5
				if eq_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 72)), loc_8), i64_ZERO) then
					desired = 1
					break
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				while true do
					while true do
						while true do
							if loc_4 >= 64 then
								break
							end
							loc_7 = bxor_i64(load_i64(memory_at_0, add_i32(add_i32(shl_i32(loc_3, 9), shl_i32(loc_4, 3)), 1056448)), loc_7)
							store_i64(memory_at_0, loc_0 + 16, loc_7)
							loc_6 = load_i32_u8(memory_at_0, loc_0 + 24)
							if loc_6 >= 16 then
								desired = 4
								break
							end
							loc_9 = load_i32_u8(memory_at_0, loc_1)
							loc_10 = load_i64(memory_at_0, add_i32(shl_i32(loc_6, 3), 1062592))
							loc_11 = 243
							while true do
								while true do
									if not br_map[1] then
										br_map[1] = (function()
											return { [0] = 0, 1, 1, 1, 1, 1, 4, }
										end)()
									end
									temp = br_map[1][add_i32(loc_3, 4294967291)] or 1
									if temp < 1 then
										break
									elseif temp > 1 then
										desired = 3
										break
									else
										desired = 6
										break
									end
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								loc_11 = 252
								desired = 3
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_12 = load_i32_u8(memory_at_0, loc_1 + 2)
							loc_11 = bor_i32((if loc_4 == 0 then 1 else 0), (if loc_12 == 0 then 1 else 0))
							loc_6 = (if loc_11 ~= 0 then band_i32(loc_6, 253) else loc_6)
							loc_13 = bor_i32((if loc_4 == 7 then 1 else 0), (if loc_12 == 7 then 1 else 0))
							loc_6 = (if loc_13 ~= 0 then band_i32(loc_6, 254) else loc_6)
							loc_14 = bor_i32((if loc_4 == 56 then 1 else 0), (if loc_12 == 56 then 1 else 0))
							loc_6 = (if loc_14 ~= 0 then band_i32(loc_6, 247) else loc_6)
							while true do
								while true do
									if loc_11 ~= 0 then
										break
									end
									if loc_13 ~= 0 then
										break
									end
									if loc_14 == 0 then
										desired = 6
										break
									end
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								store_i32_n8(memory_at_0, loc_0 + 24, loc_6)
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_11 = 251
							if loc_4 == 63 then
								desired = 3
								break
							end
							if loc_12 == 63 then
								desired = 3
								break
							end
							desired = 2
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						FUNC_LIST[189](loc_4, 64, 1062828)
						error("out of code bounds")
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					FUNC_LIST[189](loc_6, 16, 1062812)
					error("out of code bounds")
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_6 = band_i32(loc_6, loc_11)
				store_i32_n8(memory_at_0, loc_0 + 24, loc_6)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_7 = bxor_i64(bxor_i64(loc_10, load_i64(memory_at_0, add_i32(shl_i32(loc_6, 3), 1062592))), loc_7)
			store_i64(memory_at_0, loc_0 + 16, loc_7)
			while true do
				while true do
					while true do
						while true do
							while true do
								while true do
									while true do
										if not br_map[2] then
											br_map[2] = (function()
												return { [0] = 3, 0, 1, 2, }
											end)()
										end
										temp = br_map[2][add_i32(loc_9, 4294967295)] or 5
										if temp < 2 then
											if temp < 1 then
												break
											else
												desired = 7
												break
											end
										elseif temp > 2 then
											if temp < 5 then
												desired = 5
												break
											else
												desired = 3
												break
											end
										else
											desired = 6
											break
										end
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									loc_11 = (if loc_5 ~= 0 then 3 else 9)
									desired = 4
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								loc_11 = (if loc_5 ~= 0 then 2 else 8)
								desired = 4
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_11 = (if loc_5 ~= 0 then 1 else 7)
							desired = 4
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_11 = (if loc_5 ~= 0 then 4 else 10)
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_6 = add_i32(loc_0, 32)
					loc_3 = add_i32(loc_6, shl_i32(loc_3, 3))
					store_i64(memory_at_0, loc_3, band_i64(load_i64(memory_at_0, loc_3), bxor_i64(loc_8, i64_from_u32(4294967295, 4294967295))))
					loc_3 = add_i32(loc_6, shl_i32(loc_11, 3))
					loc_6 = load_i32_u8(memory_at_0, loc_1 + 2)
					store_i64(memory_at_0, loc_3, bor_i64(shl_i64(i64_ONE, extend_i64_u32(band_i32(loc_6, 63))), load_i64(memory_at_0, loc_3)))
					desired = 2
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_11 = add_i32(add_i32(loc_0, shl_i32(loc_3, 3)), 32)
				loc_6 = load_i32_u8(memory_at_0, loc_1 + 2)
				store_i64(memory_at_0, loc_11, bxor_i64(bor_i64(shl_i64(i64_ONE, extend_i64_u32(band_i32(loc_6, 63))), loc_8), load_i64(memory_at_0, loc_11)))
				loc_11 = loc_3
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_3 = extend_i32_n8(loc_6)
			while true do
				while true do
					while true do
						while true do
							while true do
								while true do
									while true do
										if loc_6 >= 64 then
											break
										end
										loc_8 = bxor_i64(load_i64(memory_at_0, add_i32(add_i32(shl_i32(loc_11, 9), shl_i32(loc_3, 3)), 1056448)), loc_7)
										store_i64(memory_at_0, loc_0 + 16, loc_8)
										loc_1 = load_i32_u8(memory_at_0, add_i32(loc_0, 27))
										while true do
											loc_11 = load_i32_u8(memory_at_0, loc_0 + 26)
											if loc_11 == 0 then
												break
											end
											loc_8 = bxor_i64(load_i64(memory_at_0, add_i32(shl_i32(band_i32(loc_1, 7), 3), 1062720)), loc_8)
											store_i64(memory_at_0, loc_0 + 16, loc_8)
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										store_i32_n8(memory_at_0, loc_0 + 26, 0)
										while true do
											while true do
												while true do
													while true do
														if not br_map[3] then
															br_map[3] = (function()
																return { [0] = 3, 1, 2, }
															end)()
														end
														temp = br_map[3][add_i32(loc_9, 4294967291)] or 0
														if temp < 2 then
															if temp < 1 then
																break
															else
																desired = 11
																break
															end
														elseif temp > 2 then
															desired = 9
															break
														else
															desired = 10
															break
														end
													end
													if desired then
														if desired == 11 then
															desired = nil
														end
														break
													end
													loc_7 = shl_i64(i64_ONE, extend_i64_u32(loc_6))
													while true do
														while true do
															if load_i32_u8(memory_at_0, loc_0 + 140) ~= 0 then
																break
															end
															loc_6 = 0
															if ne_i64(band_i64(load_i64(memory_at_0, loc_0 + 32), loc_7), i64_ZERO) then
																desired = 3
																break
															end
															loc_6 = 1
															if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 40)), loc_7), i64_ZERO) then
																desired = 3
																break
															end
															loc_6 = 2
															if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 48)), loc_7), i64_ZERO) then
																desired = 3
																break
															end
															loc_6 = 3
															if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 56)), loc_7), i64_ZERO) then
																desired = 3
																break
															end
															loc_6 = 4
															if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 64)), loc_7), i64_ZERO) then
																desired = 3
																break
															end
															loc_6 = 5
															if eq_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 72)), loc_7), i64_ZERO) then
																desired = 12
																break
															end
															desired = 3
															break
														end
														if desired then
															if desired == 12 then
																desired = nil
															end
															break
														end
														loc_6 = 6
														if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 80)), loc_7), i64_ZERO) then
															desired = 3
															break
														end
														loc_6 = 7
														if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 88)), loc_7), i64_ZERO) then
															desired = 3
															break
														end
														loc_6 = 8
														if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 96)), loc_7), i64_ZERO) then
															desired = 3
															break
														end
														loc_6 = 9
														if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 104)), loc_7), i64_ZERO) then
															desired = 3
															break
														end
														loc_6 = 10
														if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 112)), loc_7), i64_ZERO) then
															desired = 3
															break
														end
														loc_6 = 11
														if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 120)), loc_7), i64_ZERO) then
															desired = 3
															break
														end
														break
													end
													if desired then
														if desired == 11 then
															desired = nil
														end
														break
													end
													store_i32_n8(memory_at_0, loc_0 + 25, 12)
													desired = 2
													break
												end
												if desired then
													if desired == 10 then
														desired = nil
													end
													break
												end
												store_i32_n16(memory_at_0, loc_0 + 25, 268)
												store_i32_n8(memory_at_0, loc_0 + 27, add_i32((if load_i32_u8(memory_at_0, loc_0 + 140) ~= 0 then 8 else 4294967288), loc_4))
												store_i64(memory_at_0, loc_0 + 16, bxor_i64(loc_8, load_i64(memory_at_0, add_i32(shl_i32(band_i32(loc_4, 7), 3), 1062720))))
												desired = 2
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											loc_3 = add_i32(loc_0, (if loc_5 ~= 0 then 56 else 104))
											loc_4 = (if band_i32(loc_6, 7) == 6 then 1 else 0)
											reg_0 = loc_3
											reg_1 = load_i64(memory_at_0, loc_3)
											loc_3 = add_i32((if loc_4 ~= 0 then 1 else 4294967294), loc_6)
											loc_6 = add_i32((if loc_4 ~= 0 then 4294967295 else 1), loc_6)
											store_i64(memory_at_0, reg_0, bxor_i64(reg_1, bor_i64(shl_i64(i64_ONE, extend_i64_u32(band_i32(loc_3, 63))), shl_i64(i64_ONE, extend_i64_u32(band_i32(loc_6, 63))))))
											loc_4 = extend_i32_n8(loc_3)
											if band_i32(loc_3, 255) >= 64 then
												desired = 7
												break
											end
											loc_1 = (if loc_5 ~= 0 then 3 else 9)
											loc_8 = bxor_i64(loc_8, load_i64(memory_at_0, add_i32(add_i32(shl_i32(loc_1, 9), shl_i32(loc_4, 3)), 1056448)))
											store_i64(memory_at_0, loc_0 + 16, loc_8)
											loc_3 = extend_i32_n8(loc_6)
											if band_i32(loc_6, 255) >= 64 then
												desired = 6
												break
											end
											store_i64(memory_at_0, loc_0 + 16, bxor_i64(load_i64(memory_at_0, add_i32(add_i32(shl_i32(loc_1, 9), shl_i32(loc_3, 3)), 1056448)), loc_8))
											desired = 2
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										if loc_11 == 0 then
											desired = 4
											break
										end
										loc_3 = (if loc_5 ~= 0 then 6 else 0)
										store_i32_n8(memory_at_0, loc_0 + 25, loc_3)
										loc_6 = add_i32(add_i32(loc_0, shl_i32(loc_3, 3)), 32)
										reg_0 = loc_6
										reg_1 = load_i64(memory_at_0, loc_6)
										loc_6 = add_i32((if load_i32_u8(memory_at_0, loc_0 + 140) ~= 0 then 4294967288 else 8), loc_1)
										store_i64(memory_at_0, reg_0, band_i64(reg_1, rotl_i64(i64_from_u32(4294967294, 4294967295), extend_i64_u32(loc_6))))
										loc_4 = extend_i32_n8(loc_6)
										if band_i32(loc_6, 255) >= 64 then
											desired = 5
											break
										end
										store_i64(memory_at_0, loc_0 + 16, bxor_i64(loc_8, load_i64(memory_at_0, add_i32(add_i32(shl_i32(loc_3, 9), shl_i32(loc_4, 3)), 1056448))))
										desired = 2
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									FUNC_LIST[189](loc_3, 64, 1062828)
									error("out of code bounds")
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								FUNC_LIST[189](loc_4, 64, 1062828)
								error("out of code bounds")
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							FUNC_LIST[189](loc_3, 64, 1062828)
							error("out of code bounds")
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						FUNC_LIST[189](loc_4, 64, 1062828)
						error("out of code bounds")
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					FUNC_LIST[192](1050954, 43, 1051104)
					error("out of code bounds")
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i32_n8(memory_at_0, loc_0 + 25, loc_6)
				loc_4 = add_i32(add_i32(loc_0, shl_i32(loc_6, 3)), 32)
				store_i64(memory_at_0, loc_4, band_i64(load_i64(memory_at_0, loc_4), bxor_i64(loc_7, i64_from_u32(4294967295, 4294967295))))
				store_i64(memory_at_0, loc_0 + 16, bxor_i64(loc_8, load_i64(memory_at_0, add_i32(add_i32(shl_i32(loc_6, 9), shl_i32(loc_3, 3)), 1056448))))
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			store_i32_n8(memory_at_0, loc_0 + 140, bxor_i32(loc_5, 1))
			GLOBAL_LIST[0].value = add_i32(loc_2, 32)
			desired = 0
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		FUNC_LIST[192](1050954, 43, 1051088)
		error("out of code bounds")
	end
end
FUNC_LIST[52] = --[[ _ZN6engine14move_generator5maker38_$LT$impl$u20$engine..board..Board$GT$11unmake_move17h492f4c8388cd9d05E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = i64_ZERO
	local desired
	local br_map = {}
	while true do
		while true do
			while true do
				while true do
					while true do
						while true do
							loc_2 = load_i32(memory_at_0, add_i32(loc_0, 136))
							if loc_2 == 0 then
								break
							end
							loc_3 = load_i32_u8(memory_at_0, loc_0 + 25)
							loc_2 = add_i32(loc_2, 4294967295)
							store_i32(memory_at_0, loc_0 + 136, loc_2)
							loc_2 = add_i32(load_i32(memory_at_0, add_i32(loc_0, 132)), shl_i32(loc_2, 5))
							loc_4 = load_i32_u8(memory_at_0, loc_2 + 26)
							if loc_4 == 2 then
								break
							end
							store_i32_n8(memory_at_0, loc_0 + 26, loc_4)
							store_i64(memory_at_0, loc_0, load_i64(memory_at_0, loc_2))
							store_i32(memory_at_0, loc_0 + 27, load_i32(memory_at_0, loc_2 + 27))
							store_i32_n16(memory_at_0, add_i32(loc_0, 24), load_i32_u16(memory_at_0, add_i32(loc_2, 24)))
							store_i64(memory_at_0, add_i32(loc_0, 16), load_i64(memory_at_0, add_i32(loc_2, 16)))
							store_i64(memory_at_0, add_i32(loc_0, 8), load_i64(memory_at_0, add_i32(loc_2, 8)))
							store_i32_n8(memory_at_0, add_i32(loc_0, 31), load_i32_u8(memory_at_0, add_i32(loc_2, 31)))
							loc_2 = load_i32_u8(memory_at_0, loc_0 + 140)
							loc_5 = bxor_i32(loc_2, 1)
							store_i32_n8(memory_at_0, loc_0 + 140, loc_5)
							while true do
								while true do
									while true do
										while true do
											while true do
												while true do
													while true do
														while true do
															while true do
																while true do
																	while true do
																		loc_6 = load_i32_u8(memory_at_0, loc_1)
																		if not br_map[1] then
																			br_map[1] = (function()
																				return { [0] = 0, 1, 1, 1, 1, 10, 2, 3, }
																			end)()
																		end
																		temp = br_map[1][loc_6] or 0
																		if temp < 2 then
																			if temp < 1 then
																				break
																			else
																				desired = 15
																				break
																			end
																		elseif temp > 2 then
																			if temp < 10 then
																				desired = 13
																				break
																			else
																				desired = 6
																				break
																			end
																		else
																			desired = 14
																			break
																		end
																	end
																	if desired then
																		if desired == 15 then
																			desired = nil
																		end
																		break
																	end
																	loc_7 = shl_i64(i64_ONE, load_i64_u8(memory_at_0, loc_1 + 2))
																	while true do
																		while true do
																			if band_i32(loc_5, 255) ~= 0 then
																				break
																			end
																			loc_2 = 6
																			if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 80)), loc_7), i64_ZERO) then
																				desired = 2
																				break
																			end
																			loc_2 = 7
																			if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 88)), loc_7), i64_ZERO) then
																				desired = 2
																				break
																			end
																			loc_2 = 8
																			if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 96)), loc_7), i64_ZERO) then
																				desired = 2
																				break
																			end
																			loc_2 = 9
																			if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 104)), loc_7), i64_ZERO) then
																				desired = 2
																				break
																			end
																			loc_2 = 10
																			if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 112)), loc_7), i64_ZERO) then
																				desired = 2
																				break
																			end
																			loc_2 = 11
																			if eq_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 120)), loc_7), i64_ZERO) then
																				desired = 16
																				break
																			end
																			desired = 2
																			break
																		end
																		if desired then
																			if desired == 16 then
																				desired = nil
																			end
																			break
																		end
																		loc_2 = 0
																		if ne_i64(band_i64(load_i64(memory_at_0, loc_0 + 32), loc_7), i64_ZERO) then
																			desired = 2
																			break
																		end
																		loc_2 = 1
																		if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 40)), loc_7), i64_ZERO) then
																			desired = 2
																			break
																		end
																		loc_2 = 2
																		if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 48)), loc_7), i64_ZERO) then
																			desired = 2
																			break
																		end
																		loc_2 = 3
																		if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 56)), loc_7), i64_ZERO) then
																			desired = 2
																			break
																		end
																		loc_2 = 4
																		if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 64)), loc_7), i64_ZERO) then
																			desired = 2
																			break
																		end
																		loc_2 = 5
																		if (if eq_i64(band_i64(load_i64(memory_at_0, add_i32(loc_0, 72)), loc_7), i64_ZERO) then 1 else 0) == 0 then
																			desired = 2
																			break
																		end
																		break
																	end
																	if desired then
																		if desired == 15 then
																			desired = nil
																		end
																		break
																	end
																	FUNC_LIST[192](1050954, 43, 1051136)
																	error("out of code bounds")
																end
																if desired then
																	if desired == 14 then
																		desired = nil
																	end
																	break
																end
																loc_2 = band_i32(loc_2, 255)
																loc_4 = add_i32(loc_0, (if loc_2 ~= 0 then 80 else 32))
																store_i64(memory_at_0, loc_4, bor_i64(shl_i64(i64_ONE, load_i64_u8(memory_at_0, loc_1 + 1)), load_i64(memory_at_0, loc_4)))
																if not br_map[2] then
																	br_map[2] = (function()
																		return { [0] = 6, 2, 3, 4, }
																	end)()
																end
																temp = br_map[2][add_i32(loc_6, 4294967295)] or 5
																if temp < 4 then
																	if temp < 3 then
																		desired = 12
																		break
																	else
																		desired = 11
																		break
																	end
																elseif temp > 4 then
																	if temp < 6 then
																		desired = 9
																		break
																	else
																		desired = 8
																		break
																	end
																else
																	desired = 10
																	break
																end
															end
															if desired then
																if desired == 13 then
																	desired = nil
																end
																break
															end
															loc_0 = add_i32(loc_0, (if band_i32(loc_2, 255) ~= 0 then 80 else 32))
															store_i64(memory_at_0, loc_0, bxor_i64(bor_i64(shl_i64(i64_ONE, load_i64_u8(memory_at_0, loc_1 + 2)), shl_i64(i64_ONE, load_i64_u8(memory_at_0, loc_1 + 1))), load_i64(memory_at_0, loc_0)))
															desired = 0
															break
														end
														if desired then
															if desired == 12 then
																desired = nil
															end
															break
														end
														loc_3 = band_i32(loc_2, 255)
														loc_4 = add_i32(loc_0, (if loc_3 ~= 0 then 104 else 56))
														loc_2 = load_i32_u8(memory_at_0, loc_1 + 2)
														loc_6 = (if band_i32(loc_2, 7) == 6 then 1 else 0)
														store_i64(memory_at_0, loc_4, bxor_i64(bor_i64(shl_i64(i64_ONE, extend_i64_u32(band_i32(add_i32((if loc_6 ~= 0 then 1 else 62), loc_2), 63))), shl_i64(i64_ONE, extend_i64_u32(band_i32(add_i32((if loc_6 ~= 0 then 63 else 1), loc_2), 63)))), load_i64(memory_at_0, loc_4)))
														loc_0 = add_i32(loc_0, (if loc_3 ~= 0 then 120 else 72))
														store_i64(memory_at_0, loc_0, bxor_i64(bor_i64(shl_i64(i64_ONE, load_i64_u8(memory_at_0, loc_1 + 1)), shl_i64(i64_ONE, extend_i64_u32(band_i32(loc_2, 63)))), load_i64(memory_at_0, loc_0)))
														desired = 1
														break
													end
													if desired then
														if desired == 11 then
															desired = nil
														end
														break
													end
													loc_2 = (if loc_2 ~= 0 then 9 else 3)
													desired = 7
													break
												end
												if desired then
													if desired == 10 then
														desired = nil
													end
													break
												end
												loc_2 = (if loc_2 ~= 0 then 8 else 2)
												desired = 7
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											loc_2 = (if loc_2 ~= 0 then 7 else 1)
											desired = 7
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										FUNC_LIST[192](1050954, 43, 1051152)
										error("out of code bounds")
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									loc_2 = (if loc_2 ~= 0 then 10 else 4)
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								loc_2 = add_i32(add_i32(loc_0, shl_i32(loc_2, 3)), 32)
								loc_7 = load_i64_u8(memory_at_0, loc_1 + 2)
								store_i64(memory_at_0, loc_2, band_i64(load_i64(memory_at_0, loc_2), rotl_i64(i64_from_u32(4294967294, 4294967295), loc_7)))
								if loc_3 == 12 then
									desired = 1
									break
								end
								loc_0 = add_i32(add_i32(loc_0, shl_i32(loc_3, 3)), 32)
								store_i64(memory_at_0, loc_0, bor_i64(load_i64(memory_at_0, loc_0), shl_i64(i64_ONE, loc_7)))
								desired = 0
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							if loc_4 == 0 then
								desired = 3
								break
							end
							if loc_3 == 12 then
								desired = 4
								break
							end
							loc_3 = add_i32(add_i32(loc_0, shl_i32(loc_3, 3)), 32)
							loc_2 = band_i32(loc_2, 255)
							store_i64(memory_at_0, loc_3, bor_i64(load_i64(memory_at_0, loc_3), shl_i64(i64_ONE, extend_i64_u32(band_i32(add_i32(load_i32_u8(memory_at_0, add_i32(loc_0, 27)), (if loc_2 ~= 0 then 8 else 56)), 63)))))
							loc_0 = add_i32(loc_0, (if loc_2 ~= 0 then 80 else 32))
							store_i64(memory_at_0, loc_0, bxor_i64(bor_i64(shl_i64(i64_ONE, load_i64_u8(memory_at_0, loc_1 + 2)), shl_i64(i64_ONE, load_i64_u8(memory_at_0, loc_1 + 1))), load_i64(memory_at_0, loc_0)))
							desired = 0
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						FUNC_LIST[192](1050954, 43, 1051120)
						error("out of code bounds")
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					FUNC_LIST[192](1050954, 43, 1051184)
					error("out of code bounds")
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[192](1050954, 43, 1051168)
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_2 = add_i32(add_i32(loc_0, shl_i32(loc_2, 3)), 32)
			store_i64(memory_at_0, loc_2, bxor_i64(bor_i64(shl_i64(i64_ONE, load_i64_u8(memory_at_0, loc_1 + 1)), loc_7), load_i64(memory_at_0, loc_2)))
			if loc_3 == 12 then
				break
			end
			loc_0 = add_i32(add_i32(loc_0, shl_i32(loc_3, 3)), 32)
			store_i64(memory_at_0, loc_0, bor_i64(load_i64(memory_at_0, loc_0), loc_7))
			desired = 0
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		break
	end
end
FUNC_LIST[53] = --[[ _ZN6engine14move_generator13MoveGenerator3new17h20d223586279e544E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = i64_ZERO
	local loc_5 = i64_ZERO
	local loc_6 = i64_ZERO
	local loc_7 = i64_ZERO
	local loc_8 = i64_ZERO
	local loc_9 = i64_ZERO
	local loc_10 = i64_ZERO
	local loc_11 = i64_ZERO
	local loc_12 = i64_ZERO
	local loc_13 = i64_ZERO
	local loc_14 = i64_ZERO
	local loc_15 = i64_ZERO
	local loc_16 = 0
	local loc_17 = 0
	local loc_18 = 0
	local loc_19 = 0
	local loc_20 = 0
	local loc_21 = i64_ZERO
	local loc_22 = i64_ZERO
	local loc_23 = i64_ZERO
	local loc_24 = i64_ZERO
	local loc_25 = 0
	local loc_26 = i64_ZERO
	local loc_27 = i64_ZERO
	local loc_28 = i64_ZERO
	local loc_29 = 0
	local loc_30 = 0
	local loc_31 = i64_ZERO
	local loc_32 = i64_ZERO
	local loc_33 = i64_ZERO
	local loc_34 = i64_ZERO
	local loc_35 = i64_ZERO
	local loc_36 = i64_ZERO
	local loc_37 = i64_ZERO
	local loc_38 = i64_ZERO
	local loc_39 = i64_ZERO
	local loc_40 = i64_ZERO
	local loc_41 = i64_ZERO
	local loc_42 = 0
	local loc_43 = i64_ZERO
	local loc_44 = i64_ZERO
	local loc_45 = 0
	local loc_46 = i64_ZERO
	local loc_47 = 0
	local desired
	while true do
		loc_2 = add_i32(loc_1, 32)
		loc_3 = load_i32_u8(memory_at_0, loc_1 + 140)
		loc_4 = load_i64(memory_at_0, add_i32(loc_2, (if loc_3 ~= 0 then 16 else 64)))
		loc_5 = load_i64(memory_at_0, add_i32(loc_2, (if loc_3 ~= 0 then 32 else 80)))
		loc_6 = load_i64(memory_at_0, add_i32(loc_2, (if loc_3 ~= 0 then 0 else 48)))
		loc_7 = load_i64(memory_at_0, add_i32(loc_2, (if loc_3 ~= 0 then 8 else 56)))
		loc_8 = load_i64(memory_at_0, add_i32(loc_2, (if loc_3 ~= 0 then 24 else 72)))
		loc_9 = load_i64(memory_at_0, add_i32(loc_2, (if loc_3 ~= 0 then 64 else 16)))
		loc_10 = load_i64(memory_at_0, add_i32(loc_2, (if loc_3 ~= 0 then 80 else 32)))
		loc_11 = load_i64(memory_at_0, add_i32(loc_2, (if loc_3 ~= 0 then 48 else 0)))
		loc_12 = load_i64(memory_at_0, add_i32(loc_2, (if loc_3 ~= 0 then 56 else 8)))
		loc_13 = load_i64(memory_at_0, add_i32(loc_2, (if loc_3 ~= 0 then 72 else 24)))
		loc_14 = load_i64(memory_at_0, add_i32(loc_2, (if loc_3 ~= 0 then 88 else 40)))
		loc_15 = load_i64(memory_at_0, add_i32(loc_2, (if loc_3 ~= 0 then 40 else 88)))
		loc_16 = wrap_i32_i64(ctz_i64(loc_15))
		loc_17 = load_i32_u8(memory_at_0, add_i32(loc_1, 27))
		loc_18 = load_i32_u8(memory_at_0, loc_1 + 24)
		loc_19 = load_i32_u8(memory_at_0, loc_1 + 26)
		while true do
			if load_i32_u8(memory_at_0, 0 + 1084648) == 3 then
				break
			end
			FUNC_LIST[88](1084136)
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		while true do
			while true do
				while true do
					while true do
						if loc_16 >= 64 then
							break
						end
						loc_20 = add_i32(shl_i32(loc_16, 3), 1084136)
						loc_21 = bor_i64(loc_10, loc_9)
						loc_22 = bor_i64(bor_i64(bor_i64(bor_i64(loc_12, loc_11), loc_13), loc_21), loc_14)
						loc_23 = bor_i64(loc_5, loc_4)
						loc_9 = bor_i64(bor_i64(bor_i64(bor_i64(loc_7, loc_6), loc_8), loc_23), loc_15)
						loc_24 = bor_i64(loc_22, loc_9)
						loc_4 = band_i64(load_i64(memory_at_0, loc_20), loc_24)
						loc_2 = mul_i32(loc_16, 24)
						loc_25 = load_i32(memory_at_0, add_i32(loc_2, 1054888))
						loc_26 = load_i64(memory_at_0, add_i32(loc_2, 1054880))
						loc_27 = load_i64(memory_at_0, add_i32(loc_2, 1054872))
						while true do
							if load_i32_u8(memory_at_0, 0 + 1084684) == 3 then
								break
							end
							FUNC_LIST[86](1084672)
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						while true do
							loc_2 = add_i32(loc_25, wrap_i32_i64(shr_u64(mul_i64(loc_27, loc_4), loc_26)))
							loc_1 = load_i32(memory_at_0, 0 + 1084680)
							if loc_2 >= loc_1 then
								break
							end
							loc_28 = load_i64(memory_at_0, add_i32(load_i32(memory_at_0, 0 + 1084676), shl_i32(loc_2, 3)))
							while true do
								if load_i32_u8(memory_at_0, 0 + 1084128) == 3 then
									break
								end
								FUNC_LIST[87](1083616)
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_29 = add_i32(shl_i32(loc_16, 3), 1083616)
							loc_4 = band_i64(load_i64(memory_at_0, loc_29), loc_24)
							loc_2 = mul_i32(loc_16, 24)
							loc_30 = load_i32(memory_at_0, add_i32(loc_2, 1053336))
							loc_31 = load_i64(memory_at_0, add_i32(loc_2, 1053328))
							loc_32 = load_i64(memory_at_0, add_i32(loc_2, 1053320))
							while true do
								if load_i32_u8(memory_at_0, 0 + 1084668) == 3 then
									break
								end
								FUNC_LIST[89](1084656)
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							while true do
								loc_2 = add_i32(loc_30, wrap_i32_i64(shr_u64(mul_i64(loc_32, loc_4), loc_31)))
								loc_1 = load_i32(memory_at_0, 0 + 1084664)
								if loc_2 >= loc_1 then
									break
								end
								loc_33 = load_i64(memory_at_0, add_i32(load_i32(memory_at_0, 0 + 1084660), shl_i32(loc_2, 3)))
								while true do
									if load_i32_u8(memory_at_0, 0 + 1079440) == 3 then
										break
									end
									FUNC_LIST[91](1078416)
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								loc_34 = load_i64(memory_at_0, add_i32(shl_i32(loc_16, 3), (if loc_3 ~= 0 then 1078416 else 1078928)))
								while true do
									if load_i32_u8(memory_at_0, 0 + 1077888) == 3 then
										break
									end
									FUNC_LIST[85](1077376)
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								loc_35 = load_i64(memory_at_0, add_i32(shl_i32(loc_16, 3), 1077376))
								loc_4 = band_i64(loc_11, (if loc_3 ~= 0 then i64_from_u32(4278124286, 4278124286) else i64_from_u32(2139062143, 2139062143)))
								loc_36 = band_i64(loc_11, (if loc_3 ~= 0 then i64_from_u32(2139062143, 2139062143) else i64_from_u32(4278124286, 4278124286)))
								loc_37 = (if loc_3 ~= 0 then bor_i64(shr_u64(loc_4, i64_from_u32(9, 0)), shr_u64(loc_36, i64_from_u32(7, 0))) else bor_i64(shl_i64(loc_4, i64_from_u32(9, 0)), shl_i64(loc_36, i64_from_u32(7, 0))))
								loc_36 = loc_37
								if eq_i64(loc_12, i64_ZERO) then
									desired = 2
									break
								end
								loc_1 = load_i32_u8(memory_at_0, 0 + 1077888)
								if loc_1 == 3 then
									desired = 3
									break
								end
								loc_4 = loc_12
								loc_36 = loc_37
								while true do
									loc_2 = band_i32(loc_1, 255)
									loc_1 = 3
									while true do
										if loc_2 == 3 then
											break
										end
										FUNC_LIST[85](1077376)
										loc_1 = load_i32_u8(memory_at_0, 0 + 1077888)
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
											continue
										end
										break
									end
									loc_38 = ctz_i64(loc_4)
									loc_2 = wrap_i32_i64(loc_38)
									if ge_u64(loc_38, i64_from_u32(64, 0)) then
										desired = 1
										break
									end
									loc_36 = bor_i64(load_i64(memory_at_0, add_i32(shl_i32(loc_2, 3), 1077376)), loc_36)
									loc_4 = band_i64(add_i64(loc_4, i64_from_u32(4294967295, 4294967295)), loc_4)
									if (if eq_i64(loc_4, i64_ZERO) then 1 else 0) == 0 then
										continue
									end
									desired = 2
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							FUNC_LIST[189](loc_2, loc_1, 1054856)
							error("out of code bounds")
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						FUNC_LIST[189](loc_2, loc_1, 1056408)
						error("out of code bounds")
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					FUNC_LIST[189](loc_16, 64, 1051320)
					error("out of code bounds")
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_4 = loc_12
				loc_36 = loc_37
				while true do
					loc_38 = ctz_i64(loc_4)
					loc_2 = wrap_i32_i64(loc_38)
					if gt_u64(loc_38, i64_from_u32(63, 0)) then
						desired = 1
						break
					end
					loc_36 = bor_i64(load_i64(memory_at_0, add_i32(shl_i32(loc_2, 3), 1077376)), loc_36)
					loc_4 = band_i64(add_i64(loc_4, i64_from_u32(4294967295, 4294967295)), loc_4)
					if ne_i64(loc_4, i64_ZERO) then
						continue
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				while true do
					if (if eq_i64(loc_21, i64_ZERO) then 1 else 0) == 0 then
						break
					end
					loc_39 = i64_ZERO
					desired = 2
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_40 = band_i64(loc_26, i64_from_u32(63, 0))
				loc_41 = bxor_i64(loc_15, i64_from_u32(4294967295, 4294967295))
				loc_39 = i64_ZERO
				loc_4 = loc_21
				while true do
					while true do
						while true do
							while true do
								while true do
									if load_i32_u8(memory_at_0, 0 + 1084648) == 3 then
										break
									end
									FUNC_LIST[88](1084136)
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
										continue
									end
									break
								end
								loc_38 = ctz_i64(loc_4)
								loc_2 = wrap_i32_i64(loc_38)
								if gt_u64(loc_38, i64_from_u32(63, 0)) then
									desired = 5
									break
								end
								loc_42 = add_i32(shl_i32(loc_2, 3), 1084136)
								loc_43 = band_i64(band_i64(load_i64(memory_at_0, loc_42), loc_41), loc_24)
								loc_2 = mul_i32(loc_2, 24)
								loc_1 = load_i32(memory_at_0, add_i32(loc_2, 1054888))
								loc_26 = load_i64(memory_at_0, add_i32(loc_2, 1054880))
								loc_44 = load_i64(memory_at_0, add_i32(loc_2, 1054872))
								while true do
									if load_i32_u8(memory_at_0, 0 + 1084684) == 3 then
										break
									end
									FUNC_LIST[86](1084672)
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
										continue
									end
									break
								end
								while true do
									loc_2 = add_i32(loc_1, wrap_i32_i64(shr_u64(mul_i64(loc_43, loc_44), loc_26)))
									loc_45 = load_i32(memory_at_0, 0 + 1084680)
									if loc_2 >= loc_45 then
										break
									end
									while true do
										loc_43 = load_i64(memory_at_0, add_i32(load_i32(memory_at_0, 0 + 1084676), shl_i32(loc_2, 3)))
										if eq_i64(band_i64(loc_43, loc_15), i64_ZERO) then
											break
										end
										while true do
											if load_i32_u8(memory_at_0, 0 + 1084648) == 3 then
												break
											end
											FUNC_LIST[88](1084136)
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										loc_26 = band_i64(loc_26, i64_from_u32(63, 0))
										loc_46 = band_i64(load_i64(memory_at_0, loc_42), loc_24)
										while true do
											if load_i32_u8(memory_at_0, 0 + 1084684) == 3 then
												break
											end
											FUNC_LIST[86](1084672)
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										loc_2 = add_i32(loc_1, wrap_i32_i64(shr_u64(mul_i64(loc_46, loc_44), loc_26)))
										loc_1 = load_i32(memory_at_0, 0 + 1084680)
										if loc_2 >= loc_1 then
											desired = 4
											break
										end
										loc_26 = load_i64(memory_at_0, add_i32(load_i32(memory_at_0, 0 + 1084676), shl_i32(loc_2, 3)))
										while true do
											if load_i32_u8(memory_at_0, 0 + 1084648) == 3 then
												break
											end
											FUNC_LIST[88](1084136)
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										loc_38 = band_i64(load_i64(memory_at_0, loc_20), shl_i64(i64_ONE, loc_38))
										while true do
											if load_i32_u8(memory_at_0, 0 + 1084684) == 3 then
												break
											end
											FUNC_LIST[86](1084672)
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										loc_2 = add_i32(loc_25, wrap_i32_i64(shr_u64(mul_i64(loc_38, loc_27), loc_40)))
										loc_1 = load_i32(memory_at_0, 0 + 1084680)
										if loc_2 >= loc_1 then
											desired = 3
											break
										end
										loc_39 = bor_i64(band_i64(band_i64(loc_26, load_i64(memory_at_0, add_i32(load_i32(memory_at_0, 0 + 1084676), shl_i32(loc_2, 3)))), loc_41), loc_39)
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									loc_36 = bor_i64(loc_43, loc_36)
									loc_4 = band_i64(add_i64(loc_4, i64_from_u32(4294967295, 4294967295)), loc_4)
									if eq_i64(loc_4, i64_ZERO) then
										desired = 2
										break
									end
									desired = 6
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
										continue
									end
									break
								end
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							FUNC_LIST[189](loc_2, loc_45, 1056408)
							error("out of code bounds")
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						FUNC_LIST[189](loc_2, 64, 1051352)
						error("out of code bounds")
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					FUNC_LIST[189](loc_2, loc_1, 1056408)
					error("out of code bounds")
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[189](loc_2, loc_1, 1056408)
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				while true do
					while true do
						while true do
							while true do
								while true do
									while true do
										while true do
											loc_27 = bor_i64(loc_10, loc_13)
											if eq_i64(loc_27, i64_ZERO) then
												break
											end
											loc_40 = band_i64(loc_31, i64_from_u32(63, 0))
											loc_41 = bxor_i64(loc_15, i64_from_u32(4294967295, 4294967295))
											loc_4 = loc_27
											while true do
												while true do
													if load_i32_u8(memory_at_0, 0 + 1084128) == 3 then
														break
													end
													FUNC_LIST[87](1083616)
													break
												end
												if desired then
													if desired == 10 then
														desired = nil
														continue
													end
													break
												end
												loc_38 = ctz_i64(loc_4)
												loc_2 = wrap_i32_i64(loc_38)
												if gt_u64(loc_38, i64_from_u32(63, 0)) then
													desired = 7
													break
												end
												loc_42 = add_i32(shl_i32(loc_2, 3), 1083616)
												loc_43 = band_i64(band_i64(load_i64(memory_at_0, loc_42), loc_41), loc_24)
												loc_2 = mul_i32(loc_2, 24)
												loc_1 = load_i32(memory_at_0, add_i32(loc_2, 1053336))
												loc_26 = load_i64(memory_at_0, add_i32(loc_2, 1053328))
												loc_44 = load_i64(memory_at_0, add_i32(loc_2, 1053320))
												while true do
													if load_i32_u8(memory_at_0, 0 + 1084668) == 3 then
														break
													end
													FUNC_LIST[89](1084656)
													break
												end
												if desired then
													if desired == 10 then
														desired = nil
														continue
													end
													break
												end
												loc_2 = add_i32(loc_1, wrap_i32_i64(shr_u64(mul_i64(loc_43, loc_44), loc_26)))
												loc_45 = load_i32(memory_at_0, 0 + 1084664)
												if loc_2 >= loc_45 then
													desired = 8
													break
												end
												while true do
													loc_43 = load_i64(memory_at_0, add_i32(load_i32(memory_at_0, 0 + 1084660), shl_i32(loc_2, 3)))
													if eq_i64(band_i64(loc_43, loc_15), i64_ZERO) then
														break
													end
													while true do
														if load_i32_u8(memory_at_0, 0 + 1084128) == 3 then
															break
														end
														FUNC_LIST[87](1083616)
														break
													end
													if desired then
														if desired == 11 then
															desired = nil
														end
														break
													end
													loc_26 = band_i64(loc_26, i64_from_u32(63, 0))
													loc_46 = band_i64(load_i64(memory_at_0, loc_42), loc_24)
													while true do
														if load_i32_u8(memory_at_0, 0 + 1084668) == 3 then
															break
														end
														FUNC_LIST[89](1084656)
														break
													end
													if desired then
														if desired == 11 then
															desired = nil
														end
														break
													end
													loc_2 = add_i32(loc_1, wrap_i32_i64(shr_u64(mul_i64(loc_46, loc_44), loc_26)))
													loc_1 = load_i32(memory_at_0, 0 + 1084664)
													if loc_2 >= loc_1 then
														desired = 6
														break
													end
													loc_26 = load_i64(memory_at_0, add_i32(load_i32(memory_at_0, 0 + 1084660), shl_i32(loc_2, 3)))
													while true do
														if load_i32_u8(memory_at_0, 0 + 1084128) == 3 then
															break
														end
														FUNC_LIST[87](1083616)
														break
													end
													if desired then
														if desired == 11 then
															desired = nil
														end
														break
													end
													loc_38 = band_i64(load_i64(memory_at_0, loc_29), shl_i64(i64_ONE, loc_38))
													while true do
														if load_i32_u8(memory_at_0, 0 + 1084668) == 3 then
															break
														end
														FUNC_LIST[89](1084656)
														break
													end
													if desired then
														if desired == 11 then
															desired = nil
														end
														break
													end
													loc_2 = add_i32(loc_30, wrap_i32_i64(shr_u64(mul_i64(loc_38, loc_32), loc_40)))
													loc_1 = load_i32(memory_at_0, 0 + 1084664)
													if loc_2 >= loc_1 then
														desired = 5
														break
													end
													loc_39 = bor_i64(band_i64(band_i64(loc_26, load_i64(memory_at_0, add_i32(load_i32(memory_at_0, 0 + 1084660), shl_i32(loc_2, 3)))), loc_41), loc_39)
													break
												end
												if desired then
													if desired == 10 then
														desired = nil
														continue
													end
													break
												end
												loc_36 = bor_i64(loc_43, loc_36)
												loc_4 = band_i64(add_i64(loc_4, i64_from_u32(4294967295, 4294967295)), loc_4)
												if (if eq_i64(loc_4, i64_ZERO) then 1 else 0) == 0 then
													continue
												end
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										if eq_i64(loc_14, i64_ZERO) then
											desired = 3
											break
										end
										loc_1 = load_i32_u8(memory_at_0, 0 + 1078408)
										if loc_1 == 3 then
											desired = 4
											break
										end
										while true do
											loc_2 = band_i32(loc_1, 255)
											loc_1 = 3
											while true do
												if loc_2 == 3 then
													break
												end
												FUNC_LIST[92](1077896)
												loc_1 = load_i32_u8(memory_at_0, 0 + 1078408)
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
													continue
												end
												break
											end
											loc_4 = ctz_i64(loc_14)
											loc_2 = wrap_i32_i64(loc_4)
											if ge_u64(loc_4, i64_from_u32(64, 0)) then
												desired = 2
												break
											end
											loc_36 = bor_i64(load_i64(memory_at_0, add_i32(shl_i32(loc_2, 3), 1077896)), loc_36)
											loc_14 = band_i64(add_i64(loc_14, i64_from_u32(4294967295, 4294967295)), loc_14)
											if (if eq_i64(loc_14, i64_ZERO) then 1 else 0) == 0 then
												continue
											end
											desired = 3
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									FUNC_LIST[189](loc_2, loc_45, 1054856)
									error("out of code bounds")
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								FUNC_LIST[189](loc_2, 64, 1051336)
								error("out of code bounds")
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							FUNC_LIST[189](loc_2, loc_1, 1054856)
							error("out of code bounds")
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						FUNC_LIST[189](loc_2, loc_1, 1054856)
						error("out of code bounds")
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					while true do
						loc_4 = ctz_i64(loc_14)
						loc_2 = wrap_i32_i64(loc_4)
						if gt_u64(loc_4, i64_from_u32(63, 0)) then
							desired = 2
							break
						end
						loc_36 = bor_i64(load_i64(memory_at_0, add_i32(shl_i32(loc_2, 3), 1077896)), loc_36)
						loc_14 = band_i64(add_i64(loc_14, i64_from_u32(4294967295, 4294967295)), loc_14)
						if (if eq_i64(loc_14, i64_ZERO) then 1 else 0) == 0 then
							continue
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_47 = (if loc_3 ~= 0 then 2 else 8)
				loc_29 = add_i32(shl_i32(loc_16, 3), 1051392)
				loc_20 = 0
				loc_26 = i64_ZERO
				loc_44 = i64_ZERO
				while true do
					while true do
						loc_2 = load_i32_i8(memory_at_0, add_i32(loc_29, loc_20))
						if lt_i32(loc_2, 1) then
							break
						end
						loc_1 = (if loc_20 < 4 then 1 else 0)
						loc_38 = (if loc_1 ~= 0 then loc_27 else loc_21)
						loc_45 = load_i32_u8(memory_at_0, add_i32(loc_20, 1051384))
						while true do
							if loc_1 ~= 0 then
								break
							end
							loc_1 = 1
							loc_4 = i64_ZERO
							loc_25 = 0
							while true do
								loc_14 = shl_i64(i64_ONE, extend_i64_u32(band_i32(add_i32(mul_i32(loc_1, loc_45), loc_16), 63)))
								loc_4 = bor_i64(loc_14, loc_4)
								while true do
									while true do
										if (if eq_i64(band_i64(loc_14, loc_9), i64_ZERO) then 1 else 0) == 0 then
											break
										end
										if eq_i64(band_i64(loc_14, loc_22), i64_ZERO) then
											desired = 7
											break
										end
										if eq_i64(band_i64(loc_14, loc_38), i64_ZERO) then
											desired = 4
											break
										end
										loc_44 = bor_i64((if band_i32(loc_25, 1) ~= 0 then loc_4 else i64_ZERO), loc_44)
										desired = 7
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									if band_i32(loc_25, 1) ~= 0 then
										desired = 4
										break
									end
									loc_25 = 1
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
										continue
									end
									break
								end
								loc_42 = extend_i32_n8(loc_1)
								if ge_i32(loc_42, loc_2) then
									desired = 4
									break
								end
								loc_1 = extend_i32_n8(add_i32(loc_1, (if lt_i32(loc_42, loc_2) then 1 else 0)))
								if le_i32(loc_1, loc_2) then
									continue
								end
								desired = 4
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_1 = 1
						loc_4 = i64_ZERO
						loc_42 = 0
						while true do
							loc_14 = shl_i64(i64_ONE, extend_i64_u32(band_i32(add_i32(mul_i32(loc_1, loc_45), loc_16), 63)))
							loc_4 = bor_i64(loc_14, loc_4)
							while true do
								while true do
									if eq_i64(band_i64(loc_14, loc_9), i64_ZERO) then
										break
									end
									loc_25 = 1
									if band_i32(loc_42, 1) == 0 then
										desired = 6
										break
									end
									desired = 4
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								while true do
									if eq_i64(band_i64(loc_14, loc_22), i64_ZERO) then
										break
									end
									if eq_i64(band_i64(loc_14, loc_38), i64_ZERO) then
										desired = 4
										break
									end
									loc_26 = bor_i64((if band_i32(loc_42, 1) ~= 0 then loc_4 else i64_ZERO), loc_26)
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								loc_25 = loc_42
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
									continue
								end
								break
							end
							loc_30 = extend_i32_n8(loc_1)
							if ge_i32(loc_30, loc_2) then
								desired = 4
								break
							end
							loc_42 = loc_25
							loc_1 = extend_i32_n8(add_i32(loc_1, (if lt_i32(loc_30, loc_2) then 1 else 0)))
							if le_i32(loc_1, loc_2) then
								continue
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
							continue
						end
						break
					end
					loc_20 = add_i32(loc_20, 1)
					if loc_20 ~= 8 then
						continue
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i32_n8(memory_at_0, loc_0 + 123, loc_3)
				store_i32_n8(memory_at_0, loc_0 + 121, loc_19)
				store_i32_n8(memory_at_0, loc_0 + 120, loc_16)
				store_i64(memory_at_0, loc_0 + 24, loc_23)
				store_i64(memory_at_0, loc_0 + 16, loc_7)
				store_i64(memory_at_0, loc_0 + 8, loc_6)
				store_i64(memory_at_0, loc_0, loc_9)
				store_i64(memory_at_0, loc_0 + 64, loc_24)
				store_i64(memory_at_0, loc_0 + 56, loc_27)
				store_i64(memory_at_0, loc_0 + 48, loc_22)
				store_i64(memory_at_0, loc_0 + 40, loc_36)
				store_i64(memory_at_0, loc_0 + 112, loc_37)
				store_i64(memory_at_0, loc_0 + 88, loc_26)
				store_i64(memory_at_0, loc_0 + 80, loc_44)
				store_i32_n8(memory_at_0, add_i32(loc_0, 122), loc_17)
				store_i64(memory_at_0, loc_0 + 32, bor_i64(loc_5, loc_8))
				store_i64(memory_at_0, loc_0 + 72, bxor_i64(loc_24, i64_from_u32(4294967295, 4294967295)))
				store_i32_n8(memory_at_0, loc_0 + 125, (if band_i32(loc_18, loc_47) ~= 0 then 1 else 0))
				store_i32_n8(memory_at_0, loc_0 + 124, (if band_i32(loc_18, (if loc_3 ~= 0 then 1 else 4)) ~= 0 then 1 else 0))
				loc_14 = bor_i64(bor_i64(bor_i64(band_i64(loc_33, loc_27), band_i64(loc_28, loc_21)), band_i64(loc_34, loc_11)), band_i64(loc_35, loc_12))
				loc_2 = wrap_i32_i64(popcnt_i64(loc_14))
				store_i32_n8(memory_at_0, loc_0 + 127, (if loc_2 > 1 then 1 else 0))
				store_i32_n8(memory_at_0, loc_0 + 126, (if loc_2 ~= 0 then 1 else 0))
				store_i64(memory_at_0, loc_0 + 104, (if loc_2 ~= 0 then loc_39 else i64_from_u32(4294967295, 4294967295)))
				store_i64(memory_at_0, loc_0 + 96, (if loc_2 ~= 0 then loc_14 else i64_from_u32(4294967295, 4294967295)))
				desired = 0
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[189](loc_2, 64, 1051368)
			error("out of code bounds")
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		FUNC_LIST[189](loc_2, 64, 1051272)
		error("out of code bounds")
	end
end
FUNC_LIST[54] = --[[ _ZN6engine14move_generator13MoveGenerator3gen17h10a4b52771a9ece0E ]] function(loc_0, loc_1, loc_2, loc_3)
	local loc_4 = 0
	local loc_5 = i64_ZERO
	local loc_6 = i64_ZERO
	local loc_7 = i64_ZERO
	local loc_8 = i64_ZERO
	local loc_9 = 0
	local loc_10 = 0
	local loc_11 = i64_ZERO
	local loc_12 = i64_ZERO
	local loc_13 = i64_ZERO
	local loc_14 = 0
	local loc_15 = i64_ZERO
	local loc_16 = i64_ZERO
	local loc_17 = i64_ZERO
	local loc_18 = 0
	local loc_19 = i64_ZERO
	local loc_20 = i64_ZERO
	local loc_21 = i64_ZERO
	local loc_22 = i64_ZERO
	local desired
	while true do
		loc_4 = load_i32_i8(memory_at_0, loc_0 + 120)
		while true do
			if load_i32_u8(memory_at_0, 0 + 1078408) == 3 then
				break
			end
			FUNC_LIST[92](1077896)
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		while true do
			while true do
				while true do
					if loc_4 >= 64 then
						break
					end
					while true do
						loc_5 = load_i64(memory_at_0, loc_0 + 40)
						loc_6 = load_i64(memory_at_0, loc_0)
						loc_7 = load_i64(memory_at_0, loc_0 + 48)
						loc_8 = band_i64(band_i64(load_i64(memory_at_0, add_i32(shl_i32(loc_4, 3), 1077896)), bxor_i64(bor_i64(loc_5, loc_6), i64_from_u32(4294967295, 4294967295))), (if loc_3 ~= 0 then loc_7 else i64_from_u32(4294967295, 4294967295)))
						if eq_i64(loc_8, i64_ZERO) then
							break
						end
						loc_9 = shl_i32(band_i32(loc_4, 255), 8)
						loc_10 = load_i32(memory_at_0, loc_2 + 16)
						while true do
							TABLE_LIST[0].data[loc_10](loc_1, bor_i32(shl_i32(wrap_i32_i64(ctz_i64(loc_8)), 16), loc_9))
							loc_8 = band_i64(add_i64(loc_8, i64_from_u32(4294967295, 4294967295)), loc_8)
							if (if eq_i64(loc_8, i64_ZERO) then 1 else 0) == 0 then
								continue
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					if load_i32_u8(memory_at_0, loc_0 + 126) ~= 0 then
						desired = 1
						break
					end
					if loc_3 ~= 0 then
						desired = 1
						break
					end
					loc_11 = load_i64(memory_at_0, loc_0 + 64)
					loc_8 = bor_i64(loc_11, loc_5)
					if load_i32_u8(memory_at_0, loc_0 + 124) == 0 then
						desired = 2
						break
					end
					if ne_i64(band_i64((if load_i32_u8(memory_at_0, loc_0 + 123) ~= 0 then i64_from_u32(96, 0) else i64_from_u32(0, 1610612736)), loc_8), i64_ZERO) then
						desired = 2
						break
					end
					TABLE_LIST[0].data[load_i32(memory_at_0, loc_2 + 16)](loc_1, add_i32(bor_i32(shl_i32(loc_4, 16), shl_i32(band_i32(loc_4, 255), 8)), 131079))
					desired = 2
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[189](loc_4, 64, 1051368)
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			if load_i32_u8(memory_at_0, loc_0 + 125) == 0 then
				break
			end
			loc_9 = load_i32_u8(memory_at_0, loc_0 + 123)
			if ne_i64(band_i64((if loc_9 ~= 0 then i64_from_u32(14, 0) else i64_from_u32(0, 234881024)), loc_11), i64_ZERO) then
				break
			end
			if ne_i64(band_i64((if loc_9 ~= 0 then i64_from_u32(12, 0) else i64_from_u32(0, 201326592)), loc_8), i64_ZERO) then
				break
			end
			TABLE_LIST[0].data[load_i32(memory_at_0, loc_2 + 16)](loc_1, bor_i32(bor_i32(shl_i32(add_i32(loc_4, 4294967294), 16), shl_i32(band_i32(loc_4, 255), 8)), 7))
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		while true do
			while true do
				while true do
					while true do
						while true do
							while true do
								if load_i32_u8(memory_at_0, loc_0 + 127) ~= 0 then
									break
								end
								loc_12 = load_i64(memory_at_0, loc_0 + 8)
								loc_11 = load_i64(memory_at_0, loc_0 + 88)
								loc_13 = bxor_i64(loc_11, i64_from_u32(4294967295, 4294967295))
								loc_5 = band_i64(loc_12, loc_13)
								loc_14 = load_i32_u8(memory_at_0, loc_0 + 123)
								loc_8 = band_i64(loc_5, (if loc_14 ~= 0 then i64_from_u32(4278124286, 4278124286) else i64_from_u32(2139062143, 2139062143)))
								loc_15 = load_i64(memory_at_0, loc_0 + 96)
								loc_16 = band_i64(loc_15, loc_7)
								loc_8 = band_i64((if loc_14 ~= 0 then shl_i64(loc_8, i64_from_u32(7, 0)) else shr_u64(loc_8, i64_from_u32(7, 0))), loc_16)
								loc_17 = (if loc_14 ~= 0 then i64_from_u32(0, 4278190080) else i64_from_u32(255, 0))
								while true do
									loc_5 = band_i64(loc_5, (if loc_14 ~= 0 then i64_from_u32(2139062143, 2139062143) else i64_from_u32(4278124286, 4278124286)))
									loc_5 = band_i64((if loc_14 ~= 0 then shl_i64(loc_5, i64_from_u32(9, 0)) else shr_u64(loc_5, i64_from_u32(9, 0))), loc_16)
									if eq_i64(loc_5, i64_ZERO) then
										break
									end
									loc_18 = (if loc_14 ~= 0 then 4294967287 else 9)
									loc_19 = load_i64(memory_at_0, loc_0 + 80)
									while true do
										loc_20 = ctz_i64(loc_5)
										loc_16 = shl_i64(i64_ONE, loc_20)
										while true do
											while true do
												loc_9 = wrap_i32_i64(loc_20)
												loc_10 = add_i32(loc_18, loc_9)
												if eq_i64(band_i64(shr_u64(loc_19, extend_i64_u32(band_i32(loc_10, 63))), i64_ONE), i64_ZERO) then
													break
												end
												if eq_i64(band_i64(loc_16, loc_19), i64_ZERO) then
													desired = 9
													break
												end
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											while true do
												if ne_i64(band_i64(loc_16, loc_17), i64_ZERO) then
													break
												end
												TABLE_LIST[0].data[load_i32(memory_at_0, loc_2 + 16)](loc_1, bor_i32(shl_i32(band_i32(loc_10, 255), 8), shl_i32(loc_9, 16)))
												desired = 9
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											loc_9 = bor_i32(shl_i32(band_i32(loc_10, 255), 8), shl_i32(loc_9, 16))
											loc_10 = load_i32(memory_at_0, loc_2 + 16)
											TABLE_LIST[0].data[loc_10](loc_1, bor_i32(loc_9, 1))
											TABLE_LIST[0].data[loc_10](loc_1, bor_i32(loc_9, 2))
											TABLE_LIST[0].data[loc_10](loc_1, bor_i32(loc_9, 3))
											TABLE_LIST[0].data[loc_10](loc_1, bor_i32(loc_9, 4))
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
												continue
											end
											break
										end
										loc_5 = band_i64(add_i64(loc_5, i64_from_u32(4294967295, 4294967295)), loc_5)
										if (if eq_i64(loc_5, i64_ZERO) then 1 else 0) == 0 then
											continue
										end
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								while true do
									if eq_i64(loc_8, i64_ZERO) then
										break
									end
									loc_18 = (if loc_14 ~= 0 then 4294967289 else 7)
									loc_20 = load_i64(memory_at_0, loc_0 + 80)
									while true do
										loc_16 = ctz_i64(loc_8)
										loc_5 = shl_i64(i64_ONE, loc_16)
										while true do
											while true do
												loc_9 = wrap_i32_i64(loc_16)
												loc_10 = add_i32(loc_18, loc_9)
												if eq_i64(band_i64(shr_u64(loc_20, extend_i64_u32(band_i32(loc_10, 63))), i64_ONE), i64_ZERO) then
													break
												end
												if eq_i64(band_i64(loc_5, loc_20), i64_ZERO) then
													desired = 9
													break
												end
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											while true do
												if ne_i64(band_i64(loc_5, loc_17), i64_ZERO) then
													break
												end
												TABLE_LIST[0].data[load_i32(memory_at_0, loc_2 + 16)](loc_1, bor_i32(shl_i32(band_i32(loc_10, 255), 8), shl_i32(loc_9, 16)))
												desired = 9
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											loc_9 = bor_i32(shl_i32(band_i32(loc_10, 255), 8), shl_i32(loc_9, 16))
											loc_10 = load_i32(memory_at_0, loc_2 + 16)
											TABLE_LIST[0].data[loc_10](loc_1, bor_i32(loc_9, 1))
											TABLE_LIST[0].data[loc_10](loc_1, bor_i32(loc_9, 2))
											TABLE_LIST[0].data[loc_10](loc_1, bor_i32(loc_9, 3))
											TABLE_LIST[0].data[loc_10](loc_1, bor_i32(loc_9, 4))
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
												continue
											end
											break
										end
										loc_8 = band_i64(add_i64(loc_8, i64_from_u32(4294967295, 4294967295)), loc_8)
										if (if eq_i64(loc_8, i64_ZERO) then 1 else 0) == 0 then
											continue
										end
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								while true do
									if load_i32_u8(memory_at_0, loc_0 + 121) == 0 then
										break
									end
									loc_9 = load_i32_i8(memory_at_0, add_i32(loc_0, 122))
									loc_5 = shl_i64(i64_ONE, extend_i64_u32(band_i32(add_i32(loc_9, (if loc_14 ~= 0 then 56 else 8)), 63)))
									if eq_i64(band_i64(loc_5, loc_15), i64_ZERO) then
										break
									end
									while true do
										if load_i32_u8(memory_at_0, 0 + 1079440) == 3 then
											break
										end
										FUNC_LIST[91](1078416)
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									while true do
										while true do
											while true do
												if loc_14 == 0 then
													break
												end
												while true do
													if loc_9 >= 64 then
														break
													end
													loc_10 = add_i32(shl_i32(loc_9, 3), 1078928)
													desired = 9
													break
												end
												if desired then
													if desired == 10 then
														desired = nil
													end
													break
												end
												FUNC_LIST[189](loc_9, 64, 1051240)
												error("out of code bounds")
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											if loc_9 >= 64 then
												desired = 8
												break
											end
											loc_10 = add_i32(shl_i32(loc_9, 3), 1078416)
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										loc_8 = band_i64(band_i64(load_i64(memory_at_0, loc_10), loc_13), loc_12)
										if eq_i64(loc_8, i64_ZERO) then
											desired = 7
											break
										end
										loc_18 = shl_i32(loc_9, 16)
										loc_19 = bxor_i64(loc_5, i64_from_u32(4294967295, 4294967295))
										loc_16 = load_i64(memory_at_0, loc_0 + 80)
										loc_20 = band_i64(loc_16, shl_i64(i64_ONE, band_i64(extend_i64_u32(loc_9), i64_from_u32(255, 0))))
										loc_21 = load_i64(memory_at_0, loc_0 + 56)
										loc_22 = load_i64(memory_at_0, loc_0 + 64)
										while true do
											while true do
												while true do
													loc_5 = ctz_i64(loc_8)
													if eq_i64(band_i64(shr_u64(loc_16, loc_5), i64_ONE), i64_ZERO) then
														break
													end
													if eq_i64(loc_20, i64_ZERO) then
														desired = 10
														break
													end
													break
												end
												if desired then
													if desired == 10 then
														desired = nil
													end
													break
												end
												while true do
													loc_9 = wrap_i32_i64(loc_5)
													if bxor_i32(loc_4, loc_9) > 7 then
														break
													end
													while true do
														if load_i32_u8(memory_at_0, 0 + 1083608) == 3 then
															break
														end
														FUNC_LIST[90](1079448)
														break
													end
													if desired then
														if desired == 11 then
															desired = nil
														end
														break
													end
													loc_10 = shl_i32(loc_9, 6)
													if ne_i64(band_i64(band_i64(band_i64(load_i64(memory_at_0, add_i32(loc_10, 1079448)), loc_19), loc_22), loc_21), i64_ZERO) then
														desired = 10
														break
													end
													while true do
														if load_i32_u8(memory_at_0, 0 + 1083608) == 3 then
															break
														end
														FUNC_LIST[90](1079448)
														break
													end
													if desired then
														if desired == 11 then
															desired = nil
														end
														break
													end
													if (if eq_i64(band_i64(band_i64(band_i64(load_i64(memory_at_0, add_i32(loc_10, 1079464)), loc_19), loc_22), loc_21), i64_ZERO) then 1 else 0) == 0 then
														desired = 10
														break
													end
													break
												end
												if desired then
													if desired == 10 then
														desired = nil
													end
													break
												end
												TABLE_LIST[0].data[load_i32(memory_at_0, loc_2 + 16)](loc_1, bor_i32(bor_i32(shl_i32(loc_9, 8), loc_18), 5))
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
													continue
												end
												break
											end
											loc_8 = band_i64(add_i64(loc_8, i64_from_u32(4294967295, 4294967295)), loc_8)
											if eq_i64(loc_8, i64_ZERO) then
												desired = 7
												break
											end
											continue
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									FUNC_LIST[189](loc_9, 64, 1051256)
									error("out of code bounds")
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								loc_19 = load_i64(memory_at_0, loc_0 + 80)
								while true do
									while true do
										if loc_3 == 0 then
											break
										end
										loc_20 = load_i64(memory_at_0, loc_0 + 104)
										loc_17 = loc_7
										desired = 7
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									loc_18 = (if loc_14 ~= 0 then 4294967288 else 8)
									while true do
										loc_22 = load_i64(memory_at_0, loc_0 + 72)
										loc_8 = band_i64(loc_12, bxor_i64(loc_19, i64_from_u32(4294967295, 4294967295)))
										loc_21 = band_i64(loc_22, (if loc_14 ~= 0 then shl_i64(loc_8, i64_from_u32(8, 0)) else shr_u64(loc_8, i64_from_u32(8, 0))))
										loc_20 = load_i64(memory_at_0, loc_0 + 104)
										loc_5 = band_i64(loc_21, loc_20)
										loc_8 = band_i64(loc_5, loc_17)
										loc_5 = bxor_i64(loc_8, loc_5)
										if eq_i64(loc_5, i64_ZERO) then
											break
										end
										while true do
											while true do
												while true do
													loc_16 = ctz_i64(loc_5)
													loc_9 = wrap_i32_i64(loc_16)
													loc_10 = add_i32(loc_18, loc_9)
													if eq_i64(band_i64(shr_u64(loc_11, extend_i64_u32(band_i32(loc_10, 63))), i64_ONE), i64_ZERO) then
														break
													end
													if eq_i64(band_i64(shr_u64(loc_11, loc_16), i64_ONE), i64_ZERO) then
														desired = 10
														break
													end
													break
												end
												if desired then
													if desired == 10 then
														desired = nil
													end
													break
												end
												TABLE_LIST[0].data[load_i32(memory_at_0, loc_2 + 16)](loc_1, bor_i32(shl_i32(band_i32(loc_10, 255), 8), shl_i32(loc_9, 16)))
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
													continue
												end
												break
											end
											loc_5 = band_i64(add_i64(loc_5, i64_from_u32(4294967295, 4294967295)), loc_5)
											if (if eq_i64(loc_5, i64_ZERO) then 1 else 0) == 0 then
												continue
											end
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									while true do
										if eq_i64(loc_8, i64_ZERO) then
											break
										end
										while true do
											while true do
												while true do
													loc_5 = ctz_i64(loc_8)
													loc_9 = wrap_i32_i64(loc_5)
													loc_10 = add_i32(loc_18, loc_9)
													if eq_i64(band_i64(shr_u64(loc_11, extend_i64_u32(band_i32(loc_10, 63))), i64_ONE), i64_ZERO) then
														break
													end
													if eq_i64(band_i64(shr_u64(loc_11, loc_5), i64_ONE), i64_ZERO) then
														desired = 10
														break
													end
													break
												end
												if desired then
													if desired == 10 then
														desired = nil
													end
													break
												end
												loc_9 = bor_i32(shl_i32(band_i32(loc_10, 255), 8), shl_i32(loc_9, 16))
												loc_10 = load_i32(memory_at_0, loc_2 + 16)
												TABLE_LIST[0].data[loc_10](loc_1, bor_i32(loc_9, 1))
												TABLE_LIST[0].data[loc_10](loc_1, bor_i32(loc_9, 2))
												TABLE_LIST[0].data[loc_10](loc_1, bor_i32(loc_9, 3))
												TABLE_LIST[0].data[loc_10](loc_1, bor_i32(loc_9, 4))
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
													continue
												end
												break
											end
											loc_8 = band_i64(add_i64(loc_8, i64_from_u32(4294967295, 4294967295)), loc_8)
											if (if eq_i64(loc_8, i64_ZERO) then 1 else 0) == 0 then
												continue
											end
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									while true do
										loc_8 = band_i64(band_i64(band_i64((if loc_14 ~= 0 then i64_from_u32(4278190080, 0) else i64_from_u32(0, 255)), (if loc_14 ~= 0 then shl_i64(loc_21, i64_from_u32(8, 0)) else shr_u64(loc_21, i64_from_u32(8, 0)))), loc_22), loc_20)
										if (if eq_i64(loc_8, i64_ZERO) then 1 else 0) == 0 then
											break
										end
										loc_17 = i64_from_u32(4294967295, 4294967295)
										desired = 7
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									loc_18 = shl_i32(loc_18, 1)
									while true do
										while true do
											while true do
												loc_5 = ctz_i64(loc_8)
												loc_9 = wrap_i32_i64(loc_5)
												loc_10 = add_i32(loc_18, loc_9)
												if eq_i64(band_i64(shr_u64(loc_11, extend_i64_u32(band_i32(loc_10, 63))), i64_ONE), i64_ZERO) then
													break
												end
												if eq_i64(band_i64(shr_u64(loc_11, loc_5), i64_ONE), i64_ZERO) then
													desired = 9
													break
												end
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											TABLE_LIST[0].data[load_i32(memory_at_0, loc_2 + 16)](loc_1, bor_i32(bor_i32(shl_i32(band_i32(loc_10, 255), 8), shl_i32(loc_9, 16)), 6))
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
												continue
											end
											break
										end
										loc_8 = band_i64(add_i64(loc_8, i64_from_u32(4294967295, 4294967295)), loc_8)
										if (if eq_i64(loc_8, i64_ZERO) then 1 else 0) == 0 then
											continue
										end
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									loc_17 = i64_from_u32(4294967295, 4294967295)
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								loc_16 = bxor_i64(loc_6, i64_from_u32(4294967295, 4294967295))
								loc_20 = bor_i64(loc_20, loc_15)
								while true do
									loc_5 = band_i64(load_i64(memory_at_0, loc_0 + 16), bxor_i64(bor_i64(loc_19, loc_11), i64_from_u32(4294967295, 4294967295)))
									if eq_i64(loc_5, i64_ZERO) then
										break
									end
									while true do
										while true do
											if load_i32_u8(memory_at_0, 0 + 1077888) == 3 then
												break
											end
											FUNC_LIST[85](1077376)
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
												continue
											end
											break
										end
										loc_8 = ctz_i64(loc_5)
										loc_9 = wrap_i32_i64(loc_8)
										if ge_u64(loc_8, i64_from_u32(64, 0)) then
											desired = 5
											break
										end
										while true do
											loc_8 = band_i64(band_i64(band_i64(loc_17, load_i64(memory_at_0, add_i32(shl_i32(loc_9, 3), 1077376))), loc_16), loc_20)
											if eq_i64(loc_8, i64_ZERO) then
												break
											end
											loc_9 = shl_i32(loc_9, 8)
											loc_10 = load_i32(memory_at_0, loc_2 + 16)
											while true do
												TABLE_LIST[0].data[loc_10](loc_1, bor_i32(shl_i32(wrap_i32_i64(ctz_i64(loc_8)), 16), loc_9))
												loc_8 = band_i64(add_i64(loc_8, i64_from_u32(4294967295, 4294967295)), loc_8)
												if (if eq_i64(loc_8, i64_ZERO) then 1 else 0) == 0 then
													continue
												end
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
												continue
											end
											break
										end
										loc_5 = band_i64(add_i64(loc_5, i64_from_u32(4294967295, 4294967295)), loc_5)
										if (if eq_i64(loc_5, i64_ZERO) then 1 else 0) == 0 then
											continue
										end
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								while true do
									loc_5 = band_i64(load_i64(memory_at_0, loc_0 + 24), loc_13)
									if eq_i64(loc_5, i64_ZERO) then
										break
									end
									loc_15 = (if loc_3 ~= 0 then loc_7 else i64_from_u32(4294967295, 4294967295))
									loc_22 = load_i64(memory_at_0, loc_0 + 64)
									while true do
										while true do
											if load_i32_u8(memory_at_0, 0 + 1084648) == 3 then
												break
											end
											FUNC_LIST[88](1084136)
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
												continue
											end
											break
										end
										loc_8 = ctz_i64(loc_5)
										loc_9 = wrap_i32_i64(loc_8)
										if gt_u64(loc_8, i64_from_u32(63, 0)) then
											desired = 3
											break
										end
										loc_17 = band_i64(load_i64(memory_at_0, add_i32(shl_i32(loc_9, 3), 1084136)), loc_22)
										loc_10 = mul_i32(loc_9, 24)
										loc_18 = load_i32(memory_at_0, add_i32(loc_10, 1054888))
										loc_6 = load_i64(memory_at_0, add_i32(loc_10, 1054880))
										loc_21 = load_i64(memory_at_0, add_i32(loc_10, 1054872))
										while true do
											if load_i32_u8(memory_at_0, 0 + 1084684) == 3 then
												break
											end
											FUNC_LIST[86](1084672)
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
												continue
											end
											break
										end
										loc_10 = add_i32(loc_18, wrap_i32_i64(shr_u64(mul_i64(loc_21, loc_17), loc_6)))
										loc_18 = load_i32(memory_at_0, 0 + 1084680)
										if loc_10 >= loc_18 then
											desired = 4
											break
										end
										loc_5 = band_i64(add_i64(loc_5, i64_from_u32(4294967295, 4294967295)), loc_5)
										loc_8 = band_i64(band_i64(band_i64(band_i64(loc_15, load_i64(memory_at_0, add_i32(load_i32(memory_at_0, 0 + 1084676), shl_i32(loc_10, 3)))), (if eq_i64(band_i64(shr_u64(loc_19, loc_8), i64_ONE), i64_ZERO) then i64_from_u32(4294967295, 4294967295) else loc_19)), loc_16), loc_20)
										loc_9 = shl_i32(loc_9, 8)
										while true do
											while true do
												if eq_i64(loc_8, i64_ZERO) then
													desired = 9
													break
												end
												TABLE_LIST[0].data[load_i32(memory_at_0, loc_2 + 16)](loc_1, bor_i32(shl_i32(wrap_i32_i64(ctz_i64(loc_8)), 16), loc_9))
												loc_8 = band_i64(add_i64(loc_8, i64_from_u32(4294967295, 4294967295)), loc_8)
												continue
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
												continue
											end
											break
										end
										if (if eq_i64(loc_5, i64_ZERO) then 1 else 0) == 0 then
											continue
										end
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								loc_5 = band_i64(load_i64(memory_at_0, loc_0 + 32), bxor_i64(loc_19, i64_from_u32(4294967295, 4294967295)))
								if eq_i64(loc_5, i64_ZERO) then
									break
								end
								loc_22 = (if loc_3 ~= 0 then loc_7 else i64_from_u32(4294967295, 4294967295))
								loc_21 = load_i64(memory_at_0, loc_0 + 64)
								while true do
									while true do
										if load_i32_u8(memory_at_0, 0 + 1084128) == 3 then
											break
										end
										FUNC_LIST[87](1083616)
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
											continue
										end
										break
									end
									loc_8 = ctz_i64(loc_5)
									loc_9 = wrap_i32_i64(loc_8)
									if gt_u64(loc_8, i64_from_u32(63, 0)) then
										desired = 1
										break
									end
									loc_19 = band_i64(load_i64(memory_at_0, add_i32(shl_i32(loc_9, 3), 1083616)), loc_21)
									loc_10 = mul_i32(loc_9, 24)
									loc_0 = load_i32(memory_at_0, add_i32(loc_10, 1053336))
									loc_17 = load_i64(memory_at_0, add_i32(loc_10, 1053328))
									loc_6 = load_i64(memory_at_0, add_i32(loc_10, 1053320))
									while true do
										if load_i32_u8(memory_at_0, 0 + 1084668) == 3 then
											break
										end
										FUNC_LIST[89](1084656)
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
											continue
										end
										break
									end
									loc_10 = add_i32(loc_0, wrap_i32_i64(shr_u64(mul_i64(loc_6, loc_19), loc_17)))
									loc_0 = load_i32(memory_at_0, 0 + 1084664)
									if loc_10 >= loc_0 then
										desired = 2
										break
									end
									loc_5 = band_i64(add_i64(loc_5, i64_from_u32(4294967295, 4294967295)), loc_5)
									loc_8 = band_i64(band_i64(band_i64(band_i64(loc_22, load_i64(memory_at_0, add_i32(load_i32(memory_at_0, 0 + 1084660), shl_i32(loc_10, 3)))), (if eq_i64(band_i64(shr_u64(loc_11, loc_8), i64_ONE), i64_ZERO) then i64_from_u32(4294967295, 4294967295) else loc_11)), loc_16), loc_20)
									loc_9 = shl_i32(loc_9, 8)
									while true do
										while true do
											if eq_i64(loc_8, i64_ZERO) then
												desired = 8
												break
											end
											TABLE_LIST[0].data[load_i32(memory_at_0, loc_2 + 16)](loc_1, bor_i32(shl_i32(wrap_i32_i64(ctz_i64(loc_8)), 16), loc_9))
											loc_8 = band_i64(add_i64(loc_8, i64_from_u32(4294967295, 4294967295)), loc_8)
											continue
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
											continue
										end
										break
									end
									if ne_i64(loc_5, i64_ZERO) then
										continue
									end
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							desired = 0
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						FUNC_LIST[189](loc_9, 64, 1051272)
						error("out of code bounds")
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					FUNC_LIST[189](loc_10, loc_18, 1056408)
					error("out of code bounds")
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[189](loc_9, 64, 1051288)
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[189](loc_10, loc_0, 1054856)
			error("out of code bounds")
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		FUNC_LIST[189](loc_9, 64, 1051304)
		error("out of code bounds")
	end
end
FUNC_LIST[55] = --[[ _ZN6engine14move_generator13MoveGenerator21calculate_is_in_check17h992d8c9b6c17ac10E ]] function(loc_0)
	local loc_1 = 0
	local loc_2 = i64_ZERO
	local loc_3 = i64_ZERO
	local loc_4 = i64_ZERO
	local loc_5 = i64_ZERO
	local loc_6 = i64_ZERO
	local loc_7 = i64_ZERO
	local loc_8 = i64_ZERO
	local loc_9 = i64_ZERO
	local loc_10 = i64_ZERO
	local loc_11 = i64_ZERO
	local loc_12 = i64_ZERO
	local loc_13 = i64_ZERO
	local loc_14 = i64_ZERO
	local loc_15 = 0
	local reg_0
	local desired
	while true do
		loc_1 = add_i32(loc_0, 32)
		loc_0 = load_i32_u8(memory_at_0, loc_0 + 140)
		loc_2 = load_i64(memory_at_0, add_i32(loc_1, (if loc_0 ~= 0 then 64 else 16)))
		loc_3 = load_i64(memory_at_0, add_i32(loc_1, (if loc_0 ~= 0 then 80 else 32)))
		loc_4 = load_i64(memory_at_0, add_i32(loc_1, (if loc_0 ~= 0 then 0 else 48)))
		loc_5 = load_i64(memory_at_0, add_i32(loc_1, (if loc_0 ~= 0 then 8 else 56)))
		loc_6 = load_i64(memory_at_0, add_i32(loc_1, (if loc_0 ~= 0 then 16 else 64)))
		loc_7 = load_i64(memory_at_0, add_i32(loc_1, (if loc_0 ~= 0 then 24 else 72)))
		loc_8 = load_i64(memory_at_0, add_i32(loc_1, (if loc_0 ~= 0 then 32 else 80)))
		loc_9 = load_i64(memory_at_0, add_i32(loc_1, (if loc_0 ~= 0 then 88 else 40)))
		loc_10 = load_i64(memory_at_0, add_i32(loc_1, (if loc_0 ~= 0 then 48 else 0)))
		loc_11 = load_i64(memory_at_0, add_i32(loc_1, (if loc_0 ~= 0 then 56 else 8)))
		loc_12 = load_i64(memory_at_0, add_i32(loc_1, (if loc_0 ~= 0 then 72 else 24)))
		loc_13 = load_i64(memory_at_0, add_i32(loc_1, (if loc_0 ~= 0 then 40 else 88)))
		loc_14 = ctz_i64(loc_13)
		while true do
			if load_i32_u8(memory_at_0, 0 + 1079440) == 3 then
				break
			end
			FUNC_LIST[91](1078416)
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		loc_1 = wrap_i32_i64(loc_14)
		while true do
			while true do
				while true do
					while true do
						while true do
							if loc_0 ~= 0 then
								break
							end
							while true do
								if ge_u64(loc_14, i64_from_u32(64, 0)) then
									break
								end
								loc_0 = add_i32(shl_i32(loc_1, 3), 1078928)
								desired = 4
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							FUNC_LIST[189](loc_1, 64, 1051240)
							error("out of code bounds")
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						if ge_u64(loc_14, i64_from_u32(64, 0)) then
							desired = 3
							break
						end
						loc_0 = add_i32(shl_i32(loc_1, 3), 1078416)
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					while true do
						while true do
							if ne_i64(band_i64(load_i64(memory_at_0, loc_0), loc_10), i64_ZERO) then
								break
							end
							while true do
								if load_i32_u8(memory_at_0, 0 + 1077888) == 3 then
									break
								end
								FUNC_LIST[85](1077376)
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							if ne_i64(band_i64(load_i64(memory_at_0, add_i32(shl_i32(loc_1, 3), 1077376)), loc_11), i64_ZERO) then
								break
							end
							reg_0 = bor_i64(bor_i64(bor_i64(bor_i64(bor_i64(bor_i64(bor_i64(bor_i64(bor_i64(loc_5, loc_4), loc_6), loc_7), loc_8), loc_9), loc_13), loc_10), loc_11), loc_12)
							loc_4 = bor_i64(loc_3, loc_2)
							loc_14 = bor_i64(reg_0, loc_4)
							while true do
								if load_i32_u8(memory_at_0, 0 + 1084648) == 3 then
									break
								end
								FUNC_LIST[88](1084136)
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_10 = band_i64(load_i64(memory_at_0, add_i32(shl_i32(loc_1, 3), 1084136)), loc_14)
							loc_0 = mul_i32(loc_1, 24)
							loc_15 = load_i32(memory_at_0, add_i32(loc_0, 1054888))
							loc_11 = load_i64(memory_at_0, add_i32(loc_0, 1054880))
							loc_2 = load_i64(memory_at_0, add_i32(loc_0, 1054872))
							while true do
								if load_i32_u8(memory_at_0, 0 + 1084684) == 3 then
									break
								end
								FUNC_LIST[86](1084672)
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_0 = add_i32(loc_15, wrap_i32_i64(shr_u64(mul_i64(loc_2, loc_10), loc_11)))
							loc_15 = load_i32(memory_at_0, 0 + 1084680)
							if loc_0 >= loc_15 then
								desired = 2
								break
							end
							if ne_i64(band_i64(load_i64(memory_at_0, add_i32(load_i32(memory_at_0, 0 + 1084676), shl_i32(loc_0, 3))), loc_4), i64_ZERO) then
								break
							end
							while true do
								if load_i32_u8(memory_at_0, 0 + 1084128) == 3 then
									break
								end
								FUNC_LIST[87](1083616)
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_14 = band_i64(load_i64(memory_at_0, add_i32(shl_i32(loc_1, 3), 1083616)), loc_14)
							loc_0 = mul_i32(loc_1, 24)
							loc_1 = load_i32(memory_at_0, add_i32(loc_0, 1053336))
							loc_10 = load_i64(memory_at_0, add_i32(loc_0, 1053328))
							loc_11 = load_i64(memory_at_0, add_i32(loc_0, 1053320))
							while true do
								if load_i32_u8(memory_at_0, 0 + 1084668) == 3 then
									break
								end
								FUNC_LIST[89](1084656)
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_0 = 0
							loc_1 = add_i32(loc_1, wrap_i32_i64(shr_u64(mul_i64(loc_11, loc_14), loc_10)))
							loc_15 = load_i32(memory_at_0, 0 + 1084664)
							if loc_1 >= loc_15 then
								desired = 1
								break
							end
							if eq_i64(band_i64(load_i64(memory_at_0, add_i32(load_i32(memory_at_0, 0 + 1084660), shl_i32(loc_1, 3))), bor_i64(loc_3, loc_12)), i64_ZERO) then
								desired = 4
								break
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_0 = 1
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					reg_0 = loc_0
					desired = 0
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[189](loc_1, 64, 1051256)
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[189](loc_0, loc_15, 1056408)
			error("out of code bounds")
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		FUNC_LIST[189](loc_1, loc_15, 1054856)
		error("out of code bounds")
	end
	return reg_0
end
FUNC_LIST[56] = --[[ _ZN5alloc7raw_vec11finish_grow17h7f4ae2a8a93e12e5E.llvm.11382298384718449299 ]] function(loc_0, loc_1, loc_2, loc_3)
	local loc_4 = 0
	local reg_0
	local desired
	while true do
		while true do
			while true do
				while true do
					if loc_1 == 0 then
						break
					end
					if le_i32(loc_2, 4294967295) then
						desired = 2
						break
					end
					while true do
						while true do
							while true do
								if load_i32(memory_at_0, loc_3 + 4) == 0 then
									break
								end
								while true do
									loc_4 = load_i32(memory_at_0, add_i32(loc_3, 8))
									if loc_4 ~= 0 then
										break
									end
									while true do
										if loc_2 ~= 0 then
											break
										end
										loc_3 = loc_1
										desired = 4
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									desired = 5
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								reg_0 = FUNC_LIST[23](load_i32(memory_at_0, loc_3), loc_4, loc_1, loc_2)
								loc_3 = reg_0
								desired = 4
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							while true do
								if loc_2 ~= 0 then
									break
								end
								loc_3 = loc_1
								desired = 4
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						reg_0 = FUNC_LIST[21](loc_2, loc_1)
						loc_3 = reg_0
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					while true do
						if loc_3 == 0 then
							break
						end
						store_i32(memory_at_0, loc_0 + 4, loc_3)
						store_i32(memory_at_0, add_i32(loc_0, 8), loc_2)
						store_i32(memory_at_0, loc_0, 0)
						desired = 0
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32(memory_at_0, loc_0 + 4, loc_1)
					store_i32(memory_at_0, add_i32(loc_0, 8), loc_2)
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i32(memory_at_0, loc_0 + 4, 0)
				store_i32(memory_at_0, add_i32(loc_0, 8), loc_2)
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			store_i32(memory_at_0, loc_0 + 4, 0)
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		store_i32(memory_at_0, loc_0, 1)
		break
	end
end
FUNC_LIST[57] = --[[ _ZN5alloc7raw_vec19RawVec$LT$T$C$A$GT$16reserve_for_push17h33c7ea977abd3b59E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local desired
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_2
		while true do
			while true do
				loc_1 = add_i32(loc_1, 1)
				if loc_1 == 0 then
					break
				end
				loc_3 = load_i32(memory_at_0, loc_0)
				loc_4 = shl_i32(loc_3, 1)
				loc_1 = (if loc_4 > loc_1 then loc_4 else loc_1)
				loc_1 = (if loc_1 > 8 then loc_1 else 8)
				loc_4 = shr_u32(bxor_i32(loc_1, 4294967295), 31)
				while true do
					while true do
						if loc_3 ~= 0 then
							break
						end
						store_i32(memory_at_0, loc_2 + 24, 0)
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32(memory_at_0, loc_2 + 28, loc_3)
					store_i32(memory_at_0, loc_2 + 24, 1)
					store_i32(memory_at_0, loc_2 + 20, load_i32(memory_at_0, loc_0 + 4))
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[56](add_i32(loc_2, 8), loc_4, loc_1, add_i32(loc_2, 20))
				loc_3 = load_i32(memory_at_0, loc_2 + 12)
				while true do
					if load_i32(memory_at_0, loc_2 + 8) ~= 0 then
						break
					end
					store_i32(memory_at_0, loc_0, loc_1)
					store_i32(memory_at_0, loc_0 + 4, loc_3)
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				if loc_3 == 2147483649 then
					desired = 1
					break
				end
				if loc_3 == 0 then
					break
				end
				FUNC_LIST[173](loc_3, load_i32(memory_at_0, add_i32(loc_2, 16)))
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[174]()
			error("out of code bounds")
		end
		GLOBAL_LIST[0].value = add_i32(loc_2, 32)
		break
	end
end
FUNC_LIST[58] = --[[ _ZN5alloc7raw_vec19RawVec$LT$T$C$A$GT$16reserve_for_push17hc2e07f77eaf7cd51E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local desired
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_2
		while true do
			while true do
				loc_1 = add_i32(loc_1, 1)
				if loc_1 == 0 then
					break
				end
				loc_3 = load_i32(memory_at_0, loc_0)
				loc_4 = shl_i32(loc_3, 1)
				loc_1 = (if loc_4 > loc_1 then loc_4 else loc_1)
				loc_1 = (if loc_1 > 4 then loc_1 else 4)
				loc_4 = mul_i32(loc_1, 12)
				loc_5 = shl_i32((if loc_1 < 178956971 then 1 else 0), 2)
				while true do
					while true do
						if loc_3 ~= 0 then
							break
						end
						store_i32(memory_at_0, loc_2 + 24, 0)
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32(memory_at_0, loc_2 + 24, 4)
					store_i32(memory_at_0, loc_2 + 28, mul_i32(loc_3, 12))
					store_i32(memory_at_0, loc_2 + 20, load_i32(memory_at_0, loc_0 + 4))
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[56](add_i32(loc_2, 8), loc_5, loc_4, add_i32(loc_2, 20))
				loc_3 = load_i32(memory_at_0, loc_2 + 12)
				while true do
					if load_i32(memory_at_0, loc_2 + 8) ~= 0 then
						break
					end
					store_i32(memory_at_0, loc_0, loc_1)
					store_i32(memory_at_0, loc_0 + 4, loc_3)
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				if loc_3 == 2147483649 then
					desired = 1
					break
				end
				if loc_3 == 0 then
					break
				end
				FUNC_LIST[173](loc_3, load_i32(memory_at_0, add_i32(loc_2, 16)))
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[174]()
			error("out of code bounds")
		end
		GLOBAL_LIST[0].value = add_i32(loc_2, 32)
		break
	end
end
FUNC_LIST[59] = --[[ _ZN5alloc7raw_vec19RawVec$LT$T$C$A$GT$16reserve_for_push17hfb6bdd250fc2c357E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local desired
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_2
		while true do
			while true do
				loc_1 = add_i32(loc_1, 1)
				if loc_1 == 0 then
					break
				end
				loc_3 = load_i32(memory_at_0, loc_0)
				loc_4 = shl_i32(loc_3, 1)
				loc_1 = (if loc_4 > loc_1 then loc_4 else loc_1)
				loc_1 = (if loc_1 > 4 then loc_1 else 4)
				loc_4 = shl_i32(loc_1, 3)
				loc_5 = shl_i32((if loc_1 < 268435456 then 1 else 0), 3)
				while true do
					while true do
						if loc_3 ~= 0 then
							break
						end
						store_i32(memory_at_0, loc_2 + 24, 0)
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32(memory_at_0, loc_2 + 24, 8)
					store_i32(memory_at_0, loc_2 + 28, shl_i32(loc_3, 3))
					store_i32(memory_at_0, loc_2 + 20, load_i32(memory_at_0, loc_0 + 4))
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[56](add_i32(loc_2, 8), loc_5, loc_4, add_i32(loc_2, 20))
				loc_3 = load_i32(memory_at_0, loc_2 + 12)
				while true do
					if load_i32(memory_at_0, loc_2 + 8) ~= 0 then
						break
					end
					store_i32(memory_at_0, loc_0, loc_1)
					store_i32(memory_at_0, loc_0 + 4, loc_3)
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				if loc_3 == 2147483649 then
					desired = 1
					break
				end
				if loc_3 == 0 then
					break
				end
				FUNC_LIST[173](loc_3, load_i32(memory_at_0, add_i32(loc_2, 16)))
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[174]()
			error("out of code bounds")
		end
		GLOBAL_LIST[0].value = add_i32(loc_2, 32)
		break
	end
end
FUNC_LIST[60] = --[[ _ZN5alloc7raw_vec19RawVec$LT$T$C$A$GT$16reserve_for_push17hfdfe975d278438e1E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local desired
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_2
		while true do
			while true do
				loc_1 = add_i32(loc_1, 1)
				if loc_1 == 0 then
					break
				end
				loc_3 = load_i32(memory_at_0, loc_0)
				loc_4 = shl_i32(loc_3, 1)
				loc_1 = (if loc_4 > loc_1 then loc_4 else loc_1)
				loc_1 = (if loc_1 > 4 then loc_1 else 4)
				loc_4 = shl_i32(loc_1, 5)
				loc_5 = shl_i32((if loc_1 < 67108864 then 1 else 0), 3)
				while true do
					while true do
						if loc_3 ~= 0 then
							break
						end
						store_i32(memory_at_0, loc_2 + 24, 0)
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32(memory_at_0, loc_2 + 24, 8)
					store_i32(memory_at_0, loc_2 + 28, shl_i32(loc_3, 5))
					store_i32(memory_at_0, loc_2 + 20, load_i32(memory_at_0, loc_0 + 4))
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[56](add_i32(loc_2, 8), loc_5, loc_4, add_i32(loc_2, 20))
				loc_3 = load_i32(memory_at_0, loc_2 + 12)
				while true do
					if load_i32(memory_at_0, loc_2 + 8) ~= 0 then
						break
					end
					store_i32(memory_at_0, loc_0, loc_1)
					store_i32(memory_at_0, loc_0 + 4, loc_3)
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				if loc_3 == 2147483649 then
					desired = 1
					break
				end
				if loc_3 == 0 then
					break
				end
				FUNC_LIST[173](loc_3, load_i32(memory_at_0, add_i32(loc_2, 16)))
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[174]()
			error("out of code bounds")
		end
		GLOBAL_LIST[0].value = add_i32(loc_2, 32)
		break
	end
end
FUNC_LIST[61] = --[[ _ZN5alloc7raw_vec19RawVec$LT$T$C$A$GT$7reserve21do_reserve_and_handle17h769e7aac2a392d9eE ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local desired
	while true do
		loc_3 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_3
		while true do
			while true do
				loc_2 = add_i32(loc_1, loc_2)
				if loc_2 < loc_1 then
					break
				end
				loc_1 = load_i32(memory_at_0, loc_0)
				loc_4 = shl_i32(loc_1, 1)
				loc_2 = (if loc_4 > loc_2 then loc_4 else loc_2)
				loc_2 = (if loc_2 > 4 then loc_2 else 4)
				loc_4 = mul_i32(loc_2, 24)
				loc_5 = shl_i32((if loc_2 < 89478486 then 1 else 0), 3)
				while true do
					while true do
						if loc_1 ~= 0 then
							break
						end
						store_i32(memory_at_0, loc_3 + 24, 0)
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32(memory_at_0, loc_3 + 24, 8)
					store_i32(memory_at_0, loc_3 + 28, mul_i32(loc_1, 24))
					store_i32(memory_at_0, loc_3 + 20, load_i32(memory_at_0, loc_0 + 4))
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[56](add_i32(loc_3, 8), loc_5, loc_4, add_i32(loc_3, 20))
				loc_1 = load_i32(memory_at_0, loc_3 + 12)
				while true do
					if load_i32(memory_at_0, loc_3 + 8) ~= 0 then
						break
					end
					store_i32(memory_at_0, loc_0, loc_2)
					store_i32(memory_at_0, loc_0 + 4, loc_1)
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				if loc_1 == 2147483649 then
					desired = 1
					break
				end
				if loc_1 == 0 then
					break
				end
				FUNC_LIST[173](loc_1, load_i32(memory_at_0, add_i32(loc_3, 16)))
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[174]()
			error("out of code bounds")
		end
		GLOBAL_LIST[0].value = add_i32(loc_3, 32)
		break
	end
end
FUNC_LIST[62] = --[[ _ZN5alloc7raw_vec19RawVec$LT$T$C$A$GT$7reserve21do_reserve_and_handle17h98f6c96a6db66358E ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	local loc_4 = 0
	local desired
	while true do
		loc_3 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_3
		while true do
			while true do
				loc_2 = add_i32(loc_1, loc_2)
				if loc_2 < loc_1 then
					break
				end
				loc_1 = load_i32(memory_at_0, loc_0)
				loc_4 = shl_i32(loc_1, 1)
				loc_2 = (if loc_4 > loc_2 then loc_4 else loc_2)
				loc_2 = (if loc_2 > 8 then loc_2 else 8)
				loc_4 = shr_u32(bxor_i32(loc_2, 4294967295), 31)
				while true do
					while true do
						if loc_1 ~= 0 then
							break
						end
						store_i32(memory_at_0, loc_3 + 24, 0)
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32(memory_at_0, loc_3 + 28, loc_1)
					store_i32(memory_at_0, loc_3 + 24, 1)
					store_i32(memory_at_0, loc_3 + 20, load_i32(memory_at_0, loc_0 + 4))
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[56](add_i32(loc_3, 8), loc_4, loc_2, add_i32(loc_3, 20))
				loc_1 = load_i32(memory_at_0, loc_3 + 12)
				while true do
					if load_i32(memory_at_0, loc_3 + 8) ~= 0 then
						break
					end
					store_i32(memory_at_0, loc_0, loc_2)
					store_i32(memory_at_0, loc_0 + 4, loc_1)
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				if loc_1 == 2147483649 then
					desired = 1
					break
				end
				if loc_1 == 0 then
					break
				end
				FUNC_LIST[173](loc_1, load_i32(memory_at_0, add_i32(loc_3, 16)))
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[174]()
			error("out of code bounds")
		end
		GLOBAL_LIST[0].value = add_i32(loc_3, 32)
		break
	end
end
FUNC_LIST[63] = --[[ _ZN6engine14move_generator11precomputed30calculate_king_moves_at_square17hc8f342a9d5ce5998E ]] function(loc_0)
	local loc_1 = 0
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local reg_0
	while true do
		loc_1 = sub_i32(GLOBAL_LIST[0].value, 512)
		GLOBAL_LIST[0].value = loc_1
		loc_2 = 0
		reg_0 = FUNC_LIST[259](loc_1, 0, 512)
		loc_3 = reg_0
		loc_1 = 4294966784
		while true do
			loc_4 = add_i32(loc_3, loc_1)
			while true do
				if load_i32_u8(memory_at_0, add_i32(loc_1, 1052508)) == 0 then
					break
				end
				loc_5 = add_i32(loc_4, 512)
				store_i64(memory_at_0, loc_5, bor_i64(load_i64(memory_at_0, loc_5), shl_i64(i64_ONE, extend_i64_u32(band_i32(add_i32(loc_2, 1), 63)))))
				break
			end
			while true do
				if load_i32_u8(memory_at_0, add_i32(loc_1, 1052509)) == 0 then
					break
				end
				loc_5 = add_i32(loc_4, 512)
				store_i64(memory_at_0, loc_5, bor_i64(load_i64(memory_at_0, loc_5), shl_i64(i64_ONE, extend_i64_u32(band_i32(add_i32(loc_2, 8), 63)))))
				break
			end
			while true do
				if load_i32_u8(memory_at_0, add_i32(loc_1, 1052510)) == 0 then
					break
				end
				loc_5 = add_i32(loc_4, 512)
				store_i64(memory_at_0, loc_5, bor_i64(load_i64(memory_at_0, loc_5), shl_i64(i64_ONE, extend_i64_u32(band_i32(add_i32(loc_2, 4294967295), 63)))))
				break
			end
			while true do
				if load_i32_u8(memory_at_0, add_i32(loc_1, 1052511)) == 0 then
					break
				end
				loc_5 = add_i32(loc_4, 512)
				store_i64(memory_at_0, loc_5, bor_i64(load_i64(memory_at_0, loc_5), shl_i64(i64_ONE, extend_i64_u32(band_i32(add_i32(loc_2, 56), 63)))))
				break
			end
			while true do
				if load_i32_u8(memory_at_0, add_i32(loc_1, 1052512)) == 0 then
					break
				end
				loc_5 = add_i32(loc_4, 512)
				store_i64(memory_at_0, loc_5, bor_i64(load_i64(memory_at_0, loc_5), shl_i64(i64_ONE, extend_i64_u32(band_i32(add_i32(loc_2, 7), 63)))))
				break
			end
			while true do
				if load_i32_u8(memory_at_0, add_i32(loc_1, 1052513)) == 0 then
					break
				end
				loc_5 = add_i32(loc_4, 512)
				store_i64(memory_at_0, loc_5, bor_i64(load_i64(memory_at_0, loc_5), shl_i64(i64_ONE, extend_i64_u32(band_i32(add_i32(loc_2, 9), 63)))))
				break
			end
			while true do
				if load_i32_u8(memory_at_0, add_i32(loc_1, 1052514)) == 0 then
					break
				end
				loc_5 = add_i32(loc_4, 512)
				store_i64(memory_at_0, loc_5, bor_i64(load_i64(memory_at_0, loc_5), shl_i64(i64_ONE, extend_i64_u32(band_i32(add_i32(loc_2, 55), 63)))))
				break
			end
			while true do
				if load_i32_u8(memory_at_0, add_i32(loc_1, 1052515)) == 0 then
					break
				end
				loc_4 = add_i32(loc_4, 512)
				store_i64(memory_at_0, loc_4, bor_i64(load_i64(memory_at_0, loc_4), shl_i64(i64_ONE, extend_i64_u32(band_i32(add_i32(loc_2, 57), 63)))))
				break
			end
			loc_2 = add_i32(loc_2, 1)
			loc_1 = add_i32(loc_1, 8)
			if loc_1 ~= 0 then
				continue
			end
			break
		end
		reg_0 = FUNC_LIST[262](loc_0, loc_3, 512)
		GLOBAL_LIST[0].value = add_i32(loc_3, 512)
		break
	end
end
FUNC_LIST[64] = --[[ _ZN6engine6search6Search17quiescence_search17hb35778ea09191f1fE ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = 0
	local loc_8 = 0
	local loc_9 = 0
	local loc_10 = 0
	local loc_11 = 0
	local loc_12 = 0
	local loc_13 = 0
	local loc_14 = 0
	local loc_15 = 0
	local loc_16 = 0
	local loc_17 = i64_ZERO
	local reg_0
	local reg_1
	local reg_2
	local reg_3
	local desired
	while true do
		loc_3 = sub_i32(GLOBAL_LIST[0].value, 1328)
		GLOBAL_LIST[0].value = loc_3
		while true do
			reg_0 = FUNC_LIST[94](loc_0)
			loc_4 = reg_0
			if ge_i32(loc_4, loc_2) then
				break
			end
			FUNC_LIST[53](add_i32(loc_3, 8), load_i32(memory_at_0, loc_0 + 24))
			loc_5 = 0
			while true do
				loc_6 = add_i32(add_i32(loc_3, 732), loc_5)
				store_i32(memory_at_0, loc_6, 0)
				store_i32_n16(memory_at_0, add_i32(loc_6, 12), 0)
				store_i32(memory_at_0, add_i32(loc_6, 8), 0)
				store_i32_n16(memory_at_0, add_i32(loc_6, 4), 0)
				loc_5 = add_i32(loc_5, 16)
				if loc_5 ~= 592 then
					continue
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			store_i32(memory_at_0, loc_3 + 1324, 0)
			store_i32(memory_at_0, loc_3 + 144, loc_0)
			store_i32(memory_at_0, loc_3 + 140, add_i32(loc_3, 1324))
			store_i32(memory_at_0, loc_3 + 136, add_i32(loc_3, 732))
			FUNC_LIST[54](add_i32(loc_3, 8), add_i32(loc_3, 136), 1070252, 1)
			reg_0 = FUNC_LIST[262](add_i32(loc_3, 136), add_i32(loc_3, 732), 592)
			loc_7 = (if gt_i32(loc_4, loc_1) then loc_4 else loc_1)
			while true do
				loc_6 = load_i32(memory_at_0, loc_3 + 1324)
				if loc_6 == 0 then
					break
				end
				loc_8 = add_i32(loc_6, 4294967295)
				while true do
					if loc_6 > 74 then
						break
					end
					loc_9 = sub_i32(0, loc_2)
					loc_10 = add_i32(loc_6, 3)
					loc_11 = add_i32(loc_6, 4294967294)
					loc_12 = 0
					while true do
						loc_13 = add_i32(add_i32(loc_3, 136), shl_i32(loc_8, 3))
						while true do
							while true do
								while true do
									while true do
										if loc_8 == 0 then
											break
										end
										loc_5 = load_i32(memory_at_0, loc_13)
										loc_6 = 0
										while true do
											while true do
												if sub_i32(loc_11, loc_12) >= 3 then
													break
												end
												loc_4 = loc_8
												desired = 9
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											loc_14 = band_i32(loc_8, 4294967292)
											loc_6 = 0
											loc_1 = add_i32(loc_3, 136)
											loc_4 = loc_8
											while true do
												loc_15 = load_i32(memory_at_0, loc_1)
												loc_16 = (if gt_i32(loc_15, loc_5) then 1 else 0)
												reg_3 = (if loc_16 ~= 0 then loc_6 else loc_4)
												loc_4 = load_i32(memory_at_0, add_i32(loc_1, 8))
												loc_5 = (if loc_16 ~= 0 then loc_15 else loc_5)
												loc_15 = (if gt_i32(loc_4, loc_5) then 1 else 0)
												loc_16 = load_i32(memory_at_0, add_i32(loc_1, 16))
												loc_5 = (if loc_15 ~= 0 then loc_4 else loc_5)
												loc_4 = (if gt_i32(loc_16, loc_5) then 1 else 0)
												reg_1 = (if loc_4 ~= 0 then add_i32(loc_6, 2) else (if loc_15 ~= 0 then add_i32(loc_6, 1) else reg_3))
												loc_15 = load_i32(memory_at_0, add_i32(loc_1, 24))
												loc_5 = (if loc_4 ~= 0 then loc_16 else loc_5)
												loc_16 = (if gt_i32(loc_15, loc_5) then 1 else 0)
												loc_4 = (if loc_16 ~= 0 then add_i32(loc_6, 3) else reg_1)
												loc_5 = (if loc_16 ~= 0 then loc_15 else loc_5)
												loc_1 = add_i32(loc_1, 32)
												loc_6 = add_i32(loc_6, 4)
												if loc_6 ~= loc_14 then
													continue
												end
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										while true do
											if band_i32(loc_8, 3) == 0 then
												break
											end
											loc_15 = band_i32(loc_10, 3)
											loc_1 = add_i32(add_i32(loc_3, 136), shl_i32(loc_6, 3))
											while true do
												loc_16 = load_i32(memory_at_0, loc_1)
												loc_14 = (if gt_i32(loc_16, loc_5) then 1 else 0)
												loc_4 = (if loc_14 ~= 0 then loc_6 else loc_4)
												loc_5 = (if loc_14 ~= 0 then loc_16 else loc_5)
												loc_1 = add_i32(loc_1, 8)
												loc_6 = add_i32(loc_6, 1)
												loc_15 = add_i32(loc_15, 4294967295)
												if loc_15 ~= 0 then
													continue
												end
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										if loc_4 == loc_8 then
											break
										end
										if loc_4 >= 74 then
											desired = 7
											break
										end
										loc_6 = add_i32(add_i32(loc_3, 136), shl_i32(loc_4, 3))
										loc_17 = load_i64(memory_at_0, loc_6)
										store_i64(memory_at_0, loc_6, load_i64(memory_at_0, loc_13))
										store_i64(memory_at_0, loc_13, loc_17)
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									loc_6 = load_i32_u16(memory_at_0, loc_13 + 4)
									loc_5 = shr_u32(loc_6, 12)
									loc_6 = extend_i32_n16(loc_6)
									if le_i32(loc_6, 4294967295) then
										desired = 6
										break
									end
									store_i32_n8(memory_at_0, loc_3 + 734, band_i32(shr_u32(loc_6, 6), 63))
									store_i32_n16(memory_at_0, loc_3 + 732, bor_i32(shl_i32(band_i32(loc_6, 63), 8), load_i32_u8(memory_at_0, add_i32(loc_5, 1069940))))
									FUNC_LIST[51](load_i32(memory_at_0, loc_0 + 24), add_i32(loc_3, 732))
									reg_0 = FUNC_LIST[64](loc_0, loc_9, sub_i32(0, loc_7))
									loc_6 = reg_0
									FUNC_LIST[52](load_i32(memory_at_0, loc_0 + 24), add_i32(loc_3, 732))
									loc_6 = sub_i32(0, loc_6)
									if ge_i32(loc_6, loc_2) then
										desired = 1
										break
									end
									loc_7 = (if gt_i32(loc_7, loc_6) then loc_7 else loc_6)
									if loc_8 ~= 0 then
										desired = 5
										break
									end
									desired = 2
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								FUNC_LIST[189](loc_4, 74, 1070148)
								error("out of code bounds")
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							FUNC_LIST[189](loc_5, 8, 1069924)
							error("out of code bounds")
						end
						if desired then
							if desired == 4 then
								desired = nil
								continue
							end
							break
						end
						loc_10 = add_i32(loc_10, 3)
						loc_12 = add_i32(loc_12, 1)
						loc_8 = add_i32(loc_8, 4294967295)
						continue
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[189](loc_8, 74, 1070132)
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_2 = loc_7
			break
		end
		GLOBAL_LIST[0].value = add_i32(loc_3, 1328)
		reg_0 = loc_2
		break
	end
	return reg_0
end
FUNC_LIST[65] = --[[ _ZN6engine6search6Search7negamax17h5df95c941dde207aE.llvm.10409040520022700236 ]] function(loc_0, loc_1, loc_2, loc_3, loc_4, loc_5, loc_6, loc_7)
	local loc_8 = 0
	local loc_9 = 0
	local loc_10 = 0
	local loc_11 = 0
	local loc_12 = i64_ZERO
	local loc_13 = 0
	local loc_14 = 0
	local loc_15 = i64_ZERO
	local loc_16 = 0
	local loc_17 = 0
	local loc_18 = 0
	local loc_19 = 0
	local loc_20 = 0
	local loc_21 = 0
	local loc_22 = 0
	local loc_23 = 0
	local loc_24 = 0
	local loc_25 = 0
	local loc_26 = 0
	local loc_27 = 0
	local loc_28 = 0
	local loc_29 = 0
	local loc_30 = 0
	local loc_31 = 0
	local loc_32 = 0
	local loc_33 = 0
	local loc_34 = i64_ZERO
	local loc_35 = i64_ZERO
	local reg_0
	local reg_1
	local reg_2
	local reg_3
	local desired
	local br_map = {}
	while true do
		loc_8 = sub_i32(GLOBAL_LIST[0].value, 3632)
		GLOBAL_LIST[0].value = loc_8
		loc_9 = 0
		while true do
			loc_10 = load_i32(memory_at_0, loc_5 + 16)
			reg_0 = TABLE_LIST[0].data[loc_10](loc_4)
			if reg_0 ~= 0 then
				break
			end
			loc_11 = load_i32(memory_at_0, loc_0 + 24)
			loc_12 = load_i64(memory_at_0, loc_11 + 16)
			while true do
				if band_i32(loc_2, 65535) == 0 then
					break
				end
				loc_13 = shl_i32(load_i32(memory_at_0, add_i32(loc_0, 20)), 3)
				loc_14 = load_i32(memory_at_0, add_i32(loc_0, 16))
				while true do
					if loc_13 == 0 then
						desired = 2
						break
					end
					loc_13 = add_i32(loc_13, 4294967288)
					loc_15 = load_i64(memory_at_0, loc_14)
					loc_14 = add_i32(loc_14, 8)
					if ne_i64(loc_12, loc_15) then
						continue
					end
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				loc_13 = load_i32(memory_at_0, loc_0 + 8)
				if loc_13 ~= 0 then
					break
				end
				FUNC_LIST[192](1062864, 57, 1062844)
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_14 = 0
			while true do
				while true do
					while true do
						while true do
							while true do
								loc_16 = (wrap_i32_i64(loc_12) % loc_13)
								loc_13 = add_i32(load_i32(memory_at_0, loc_0 + 4), mul_i32(loc_16, 24))
								loc_17 = load_i32_u8(memory_at_0, loc_13 + 16)
								if loc_17 == 3 then
									break
								end
								if ne_i64(load_i64(memory_at_0, loc_13), loc_12) then
									break
								end
								loc_14 = load_i32_u16(memory_at_0, loc_13 + 14)
								if load_i32_u16(memory_at_0, loc_13 + 12) < band_i32(loc_1, 65535) then
									desired = 5
									break
								end
								loc_9 = load_i32(memory_at_0, loc_13 + 8)
								while true do
									while true do
										if not br_map[1] then
											br_map[1] = (function()
												return { [0] = 7, 1, 0, }
											end)()
										end
										temp = br_map[1][loc_17] or 7
										if temp < 1 then
											break
										elseif temp > 1 then
											desired = 1
											break
										else
											desired = 7
											break
										end
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									if gt_i32(loc_9, loc_6) then
										desired = 6
										break
									end
									desired = 1
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								if ge_i32(loc_9, loc_7) then
									desired = 1
									break
								end
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							if band_i32(loc_1, 65535) ~= 0 then
								break
							end
							reg_0 = FUNC_LIST[64](loc_0, loc_6, loc_7)
							loc_9 = reg_0
							loc_13 = load_i32(memory_at_0, loc_0 + 8)
							if loc_16 >= loc_13 then
								desired = 4
								break
							end
							loc_13 = add_i32(load_i32(memory_at_0, loc_0 + 4), mul_i32(loc_16, 24))
							store_i32_n8(memory_at_0, loc_13 + 16, 0)
							store_i32(memory_at_0, loc_13 + 12, 0)
							store_i32(memory_at_0, loc_13 + 8, loc_9)
							store_i64(memory_at_0, loc_13, loc_12)
							desired = 1
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						FUNC_LIST[53](add_i32(loc_8, 8), loc_11)
						if band_i32(loc_1, 65535) < 3 then
							desired = 2
							break
						end
						if loc_3 == 0 then
							desired = 2
							break
						end
						if band_i32(load_i32_u8(memory_at_0, loc_8 + 134), 255) ~= 0 then
							desired = 2
							break
						end
						if add_i32(wrap_i32_i64(popcnt_i64(load_i64(memory_at_0, loc_8 + 16))), 1) == wrap_i32_i64(popcnt_i64(load_i64(memory_at_0, loc_8 + 8))) then
							desired = 2
							break
						end
						loc_3 = add_i32(add_i32(loc_8, 1880), 24)
						loc_13 = load_i32(memory_at_0, loc_0 + 24)
						store_i64(memory_at_0, loc_3, load_i64(memory_at_0, add_i32(loc_13, 24)))
						loc_11 = add_i32(add_i32(loc_8, 1880), 16)
						store_i64(memory_at_0, loc_11, load_i64(memory_at_0, add_i32(loc_13, 16)))
						loc_17 = add_i32(add_i32(loc_8, 1880), 8)
						store_i64(memory_at_0, loc_17, load_i64(memory_at_0, add_i32(loc_13, 8)))
						store_i64(memory_at_0, loc_8 + 1880, load_i64(memory_at_0, loc_13))
						while true do
							loc_9 = load_i32(memory_at_0, add_i32(loc_13, 136))
							if loc_9 ~= load_i32(memory_at_0, loc_13 + 128) then
								break
							end
							FUNC_LIST[60](add_i32(loc_13, 128), loc_9)
							loc_9 = load_i32(memory_at_0, loc_13 + 136)
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_9 = add_i32(load_i32(memory_at_0, add_i32(loc_13, 132)), shl_i32(loc_9, 5))
						store_i64(memory_at_0, loc_9, load_i64(memory_at_0, loc_8 + 1880))
						store_i64(memory_at_0, add_i32(loc_9, 24), load_i64(memory_at_0, loc_3))
						store_i64(memory_at_0, add_i32(loc_9, 16), load_i64(memory_at_0, loc_11))
						store_i64(memory_at_0, add_i32(loc_9, 8), load_i64(memory_at_0, loc_17))
						store_i32(memory_at_0, loc_13 + 136, add_i32(load_i32(memory_at_0, loc_13 + 136), 1))
						store_i32_n8(memory_at_0, loc_13 + 140, bxor_i32(load_i32_u8(memory_at_0, loc_13 + 140), 1))
						loc_15 = bxor_i64(load_i64(memory_at_0, loc_13 + 16), i64_from_u32(4095246069, 424779229))
						store_i64(memory_at_0, loc_13 + 16, loc_15)
						while true do
							if load_i32_u8(memory_at_0, loc_13 + 26) == 0 then
								break
							end
							store_i64(memory_at_0, loc_13 + 16, bxor_i64(load_i64(memory_at_0, add_i32(shl_i32(band_i32(load_i32_u8(memory_at_0, add_i32(loc_13, 27)), 7), 3), 1062720)), loc_15))
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						store_i32_n8(memory_at_0, loc_13 + 26, 0)
						reg_0 = FUNC_LIST[65](loc_0, add_i32(loc_1, 4294967294), add_i32(loc_2, 1), 0, loc_4, loc_5, sub_i32(0, loc_7), sub_i32(1, loc_7))
						loc_17 = reg_0
						loc_13 = load_i32(memory_at_0, loc_0 + 24)
						loc_9 = load_i32(memory_at_0, add_i32(loc_13, 136))
						if loc_9 == 0 then
							desired = 3
							break
						end
						loc_9 = add_i32(loc_9, 4294967295)
						store_i32(memory_at_0, loc_13 + 136, loc_9)
						loc_9 = add_i32(load_i32(memory_at_0, add_i32(loc_13, 132)), shl_i32(loc_9, 5))
						loc_3 = load_i32_u8(memory_at_0, loc_9 + 26)
						if loc_3 == 2 then
							desired = 3
							break
						end
						store_i64(memory_at_0, loc_13, load_i64(memory_at_0, loc_9))
						store_i32_n16(memory_at_0, add_i32(loc_13, 24), load_i32_u16(memory_at_0, add_i32(loc_9, 24)))
						store_i64(memory_at_0, add_i32(loc_13, 16), load_i64(memory_at_0, add_i32(loc_9, 16)))
						store_i64(memory_at_0, add_i32(loc_13, 8), load_i64(memory_at_0, add_i32(loc_9, 8)))
						loc_11 = load_i32_u8(memory_at_0, add_i32(loc_9, 31))
						loc_9 = load_i32(memory_at_0, loc_9 + 27)
						store_i32_n8(memory_at_0, loc_13 + 140, bxor_i32(load_i32_u8(memory_at_0, loc_13 + 140), 1))
						store_i32_n8(memory_at_0, loc_13 + 26, loc_3)
						store_i32(memory_at_0, loc_13 + 27, loc_9)
						store_i32_n8(memory_at_0, add_i32(loc_13, 31), loc_11)
						loc_9 = 0
						reg_0 = TABLE_LIST[0].data[loc_10](loc_4)
						if reg_0 ~= 0 then
							desired = 1
							break
						end
						if lt_i32(sub_i32(0, loc_17), loc_7) then
							desired = 2
							break
						end
						loc_9 = loc_7
						desired = 1
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					FUNC_LIST[189](loc_16, loc_13, 1052528)
					error("out of code bounds")
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[192](1050954, 43, 1051072)
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_18 = band_i32(loc_2, 65535)
			loc_14 = (if loc_18 ~= 0 then loc_14 else load_i32_u16(memory_at_0, loc_0 + 16480))
			loc_13 = 0
			while true do
				if loc_18 >= 32 then
					break
				end
				loc_13 = load_i32_u16(memory_at_0, add_i32(add_i32(loc_0, shl_i32(loc_18, 1)), 28))
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[107](add_i32(loc_8, 1880), loc_0, add_i32(loc_8, 8), loc_14, loc_13)
			reg_0 = FUNC_LIST[262](add_i32(loc_8, 136), add_i32(loc_8, 1880), 1744)
			while true do
				loc_19 = load_i32(memory_at_0, loc_8 + 3624)
				if loc_19 == 0 then
					break
				end
				loc_13 = add_i32(loc_19, 4294967295)
				while true do
					if loc_19 > 218 then
						break
					end
					loc_20 = sub_i32(0, loc_7)
					loc_21 = add_i32(loc_1, 4294967295)
					loc_22 = add_i32(loc_2, 1)
					loc_23 = add_i32(loc_1, 4294967294)
					loc_24 = add_i32(loc_0, 12)
					loc_25 = add_i32(loc_19, 3)
					loc_26 = add_i32(loc_19, 4294967294)
					loc_27 = (if band_i32(loc_1, 65535) < 3 then 1 else 0)
					loc_28 = 0
					loc_29 = 0
					loc_30 = 2
					while true do
						loc_31 = loc_13
						loc_32 = add_i32(add_i32(loc_8, 136), shl_i32(loc_31, 3))
						while true do
							while true do
								while true do
									while true do
										if loc_31 == 0 then
											break
										end
										loc_14 = load_i32(memory_at_0, loc_32)
										loc_13 = 0
										while true do
											while true do
												if sub_i32(loc_26, loc_28) >= 3 then
													break
												end
												loc_3 = loc_31
												desired = 9
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											loc_33 = band_i32(loc_31, 4294967292)
											loc_13 = 0
											loc_9 = add_i32(loc_8, 136)
											loc_3 = loc_31
											while true do
												loc_11 = load_i32(memory_at_0, loc_9)
												loc_17 = (if gt_i32(loc_11, loc_14) then 1 else 0)
												reg_3 = (if loc_17 ~= 0 then loc_13 else loc_3)
												loc_3 = load_i32(memory_at_0, add_i32(loc_9, 8))
												loc_14 = (if loc_17 ~= 0 then loc_11 else loc_14)
												loc_11 = (if gt_i32(loc_3, loc_14) then 1 else 0)
												loc_17 = load_i32(memory_at_0, add_i32(loc_9, 16))
												loc_14 = (if loc_11 ~= 0 then loc_3 else loc_14)
												loc_3 = (if gt_i32(loc_17, loc_14) then 1 else 0)
												reg_1 = (if loc_3 ~= 0 then add_i32(loc_13, 2) else (if loc_11 ~= 0 then add_i32(loc_13, 1) else reg_3))
												loc_11 = load_i32(memory_at_0, add_i32(loc_9, 24))
												loc_14 = (if loc_3 ~= 0 then loc_17 else loc_14)
												loc_17 = (if gt_i32(loc_11, loc_14) then 1 else 0)
												loc_3 = (if loc_17 ~= 0 then add_i32(loc_13, 3) else reg_1)
												loc_14 = (if loc_17 ~= 0 then loc_11 else loc_14)
												loc_9 = add_i32(loc_9, 32)
												loc_13 = add_i32(loc_13, 4)
												if loc_13 ~= loc_33 then
													continue
												end
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										while true do
											if band_i32(loc_31, 3) == 0 then
												break
											end
											loc_11 = band_i32(loc_25, 3)
											loc_9 = add_i32(add_i32(loc_8, 136), shl_i32(loc_13, 3))
											while true do
												loc_17 = load_i32(memory_at_0, loc_9)
												loc_33 = (if gt_i32(loc_17, loc_14) then 1 else 0)
												loc_3 = (if loc_33 ~= 0 then loc_13 else loc_3)
												loc_14 = (if loc_33 ~= 0 then loc_17 else loc_14)
												loc_9 = add_i32(loc_9, 8)
												loc_13 = add_i32(loc_13, 1)
												loc_11 = add_i32(loc_11, 4294967295)
												if loc_11 ~= 0 then
													continue
												end
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										if loc_3 == loc_31 then
											break
										end
										if loc_3 >= 218 then
											desired = 7
											break
										end
										loc_13 = add_i32(add_i32(loc_8, 136), shl_i32(loc_3, 3))
										loc_15 = load_i64(memory_at_0, loc_13)
										store_i64(memory_at_0, loc_13, load_i64(memory_at_0, loc_32))
										store_i64(memory_at_0, loc_32, loc_15)
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									loc_13 = load_i32_u16(memory_at_0, loc_32 + 4)
									loc_14 = shr_u32(loc_13, 12)
									loc_17 = extend_i32_n16(loc_13)
									if le_i32(loc_17, 4294967295) then
										desired = 6
										break
									end
									loc_13 = shr_u32(loc_17, 6)
									store_i32_n8(memory_at_0, loc_8 + 1882, band_i32(loc_13, 63))
									store_i32_n16(memory_at_0, loc_8 + 1880, bor_i32(shl_i32(band_i32(loc_17, 63), 8), load_i32_u8(memory_at_0, add_i32(loc_14, 1069940))))
									loc_15 = extend_i64_u32(loc_13)
									loc_34 = load_i64(memory_at_0, loc_8 + 56)
									loc_35 = load_i64(memory_at_0, load_i32(memory_at_0, loc_0 + 24) + 16)
									while true do
										loc_13 = load_i32(memory_at_0, loc_0 + 20)
										if loc_13 ~= load_i32(memory_at_0, loc_0 + 12) then
											break
										end
										FUNC_LIST[59](loc_24, loc_13)
										loc_13 = load_i32(memory_at_0, loc_0 + 20)
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									loc_34 = band_i64(loc_34, shl_i64(i64_ONE, loc_15))
									store_i64(memory_at_0, add_i32(load_i32(memory_at_0, loc_0 + 16), shl_i32(loc_13, 3)), loc_35)
									store_i32(memory_at_0, loc_0 + 20, add_i32(load_i32(memory_at_0, loc_0 + 20), 1))
									FUNC_LIST[51](load_i32(memory_at_0, loc_0 + 24), add_i32(loc_8, 1880))
									loc_14 = sub_i32(0, loc_6)
									reg_0 = FUNC_LIST[55](load_i32(memory_at_0, loc_0 + 24))
									loc_13 = reg_0
									while true do
										if loc_27 ~= 0 then
											break
										end
										if loc_19 < 4 then
											break
										end
										if ne_i64(loc_34, i64_ZERO) then
											break
										end
										if loc_13 ~= 0 then
											break
										end
										reg_2 = FUNC_LIST[65](loc_0, loc_23, loc_22, 1, loc_4, loc_5, bxor_i32(loc_6, 4294967295), loc_14)
										loc_11 = sub_i32(0, reg_2)
										if ge_i32(loc_6, loc_11) then
											desired = 5
											break
										end
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									reg_1 = FUNC_LIST[65](loc_0, add_i32(loc_21, loc_13), loc_22, 1, loc_4, loc_5, loc_20, loc_14)
									loc_11 = sub_i32(0, reg_1)
									desired = 5
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								FUNC_LIST[189](loc_3, 218, 1070148)
								error("out of code bounds")
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							FUNC_LIST[189](loc_14, 8, 1069924)
							error("out of code bounds")
						end
						if desired then
							if desired == 4 then
								desired = nil
								continue
							end
							break
						end
						loc_14 = load_i32(memory_at_0, loc_0 + 24)
						FUNC_LIST[52](loc_14, add_i32(loc_8, 1880))
						loc_32 = load_i32(memory_at_0, loc_0 + 16)
						loc_9 = add_i32(loc_32, 4294967288)
						loc_33 = load_i32(memory_at_0, loc_0 + 20)
						loc_13 = shl_i32(loc_33, 3)
						loc_15 = load_i64(memory_at_0, loc_14 + 16)
						while true do
							while true do
								while true do
									while true do
										while true do
											while true do
												while true do
													while true do
														while true do
															while true do
																if loc_13 == 0 then
																	desired = 13
																	break
																end
																loc_14 = add_i32(loc_9, loc_13)
																loc_3 = add_i32(loc_13, 4294967288)
																loc_13 = loc_3
																if ne_i64(load_i64(memory_at_0, loc_14), loc_15) then
																	continue
																end
																break
															end
															if desired then
																if desired == 13 then
																	desired = nil
																end
																break
															end
															loc_13 = shr_u32(loc_3, 3)
															if loc_33 <= loc_13 then
																desired = 12
																break
															end
															loc_14 = add_i32(loc_33, 4294967295)
															store_i32(memory_at_0, loc_0 + 20, loc_14)
															store_i64(memory_at_0, add_i32(loc_32, shl_i32(loc_13, 3)), load_i64(memory_at_0, add_i32(loc_32, shl_i32(loc_14, 3))))
															break
														end
														if desired then
															if desired == 12 then
																desired = nil
															end
															break
														end
														while true do
															reg_0 = TABLE_LIST[0].data[loc_10](loc_4)
															if reg_0 == 0 then
																break
															end
															loc_9 = 0
															desired = 1
															break
														end
														if desired then
															if desired == 12 then
																desired = nil
															end
															break
														end
														while true do
															if ge_i32(loc_11, loc_7) then
																break
															end
															loc_9 = (if gt_i32(loc_11, loc_6) then loc_11 else loc_6)
															loc_13 = (if le_i32(loc_11, loc_6) then 1 else 0)
															loc_29 = (if loc_13 ~= 0 then loc_29 else loc_17)
															loc_30 = (if loc_13 ~= 0 then loc_30 else 0)
															if band_i32(loc_2, 65535) ~= 0 then
																desired = 5
																break
															end
															if loc_13 == 0 then
																desired = 11
																break
															end
															desired = 5
															break
														end
														if desired then
															if desired == 12 then
																desired = nil
															end
															break
														end
														if eq_i64(loc_34, i64_ZERO) then
															desired = 10
															break
														end
														desired = 9
														break
													end
													if desired then
														if desired == 11 then
															desired = nil
														end
														break
													end
													FUNC_LIST[183](loc_13, loc_33, 1051980)
													error("out of code bounds")
												end
												if desired then
													if desired == 10 then
														desired = nil
													end
													break
												end
												store_i32(memory_at_0, loc_0 + 16476, loc_11)
												store_i32_n16(memory_at_0, loc_0 + 16480, loc_17)
												loc_30 = 0
												loc_29 = loc_17
												loc_9 = loc_11
												desired = 5
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											while true do
												if band_i32(loc_2, 65535) > 31 then
													break
												end
												if band_i32(load_i32_u8(memory_at_0, loc_8 + 1880), 255) ~= 0 then
													break
												end
												store_i32_n16(memory_at_0, add_i32(add_i32(loc_0, shl_i32(loc_18, 1)), 28), loc_17)
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											loc_13 = load_i32_i8(memory_at_0, loc_8 + 1881)
											if loc_13 >= 64 then
												desired = 8
												break
											end
											loc_14 = load_i32_i8(memory_at_0, loc_8 + 1882)
											if loc_14 >= 64 then
												desired = 7
												break
											end
											loc_13 = add_i32(add_i32(add_i32(add_i32(loc_0, shl_i32(load_i32_u8(memory_at_0, load_i32(memory_at_0, loc_0 + 24) + 140), 13)), shl_i32(loc_13, 7)), shl_i32(loc_14, 1)), 92)
											store_i32_n16(memory_at_0, loc_13, add_i32(load_i32_u16(memory_at_0, loc_13), mul_i32(loc_1, loc_1)))
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										loc_13 = load_i32(memory_at_0, loc_0 + 8)
										if loc_16 >= loc_13 then
											desired = 6
											break
										end
										loc_13 = add_i32(load_i32(memory_at_0, loc_0 + 4), mul_i32(loc_16, 24))
										store_i32_n8(memory_at_0, loc_13 + 16, 1)
										store_i32_n16(memory_at_0, loc_13 + 14, loc_17)
										store_i32_n16(memory_at_0, loc_13 + 12, loc_1)
										store_i32(memory_at_0, loc_13 + 8, loc_11)
										store_i64(memory_at_0, loc_13, loc_12)
										loc_9 = loc_7
										desired = 1
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									FUNC_LIST[189](loc_13, 64, 1052560)
									error("out of code bounds")
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								FUNC_LIST[189](loc_14, 64, 1052560)
								error("out of code bounds")
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							FUNC_LIST[189](loc_16, loc_13, 1052576)
							error("out of code bounds")
						end
						if desired then
							if desired == 4 then
								desired = nil
								continue
							end
							break
						end
						while true do
							if loc_31 ~= 0 then
								break
							end
							while true do
								loc_13 = load_i32(memory_at_0, loc_0 + 8)
								if loc_16 >= loc_13 then
									break
								end
								loc_13 = add_i32(load_i32(memory_at_0, loc_0 + 4), mul_i32(loc_16, 24))
								store_i32_n8(memory_at_0, loc_13 + 16, loc_30)
								store_i32_n16(memory_at_0, loc_13 + 14, loc_29)
								store_i32_n16(memory_at_0, loc_13 + 12, loc_1)
								store_i32(memory_at_0, loc_13 + 8, loc_9)
								store_i64(memory_at_0, loc_13, loc_12)
								desired = 1
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							FUNC_LIST[189](loc_16, loc_13, 1052544)
							error("out of code bounds")
						end
						if desired then
							if desired == 4 then
								desired = nil
								continue
							end
							break
						end
						loc_25 = add_i32(loc_25, 3)
						loc_28 = add_i32(loc_28, 1)
						loc_13 = add_i32(loc_31, 4294967295)
						loc_6 = loc_9
						loc_19 = loc_31
						continue
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[189](loc_13, 218, 1070132)
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				if load_i32_u8(memory_at_0, loc_8 + 134) ~= 0 then
					break
				end
				loc_9 = 0
				if band_i32(loc_2, 65535) ~= 0 then
					desired = 1
					break
				end
				loc_9 = 0
				store_i32(memory_at_0, loc_0 + 16476, 0)
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_9 = 2147483650
			if band_i32(loc_2, 65535) ~= 0 then
				break
			end
			loc_9 = 2147483650
			store_i32(memory_at_0, loc_0 + 16476, 2147483650)
			break
		end
		GLOBAL_LIST[0].value = add_i32(loc_8, 3632)
		reg_0 = loc_9
		break
	end
	return reg_0
end
FUNC_LIST[66] = --[[ _ZN6engine14move_generator13slider_lookup18calculate_all_rays17h9f424232e17b16f1E ]] function(loc_0)
	local loc_1 = 0
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = 0
	local loc_8 = 0
	local loc_9 = i64_ZERO
	local loc_10 = 0
	local loc_11 = 0
	local loc_12 = 0
	local reg_0
	local desired
	while true do
		loc_1 = sub_i32(GLOBAL_LIST[0].value, 4160)
		GLOBAL_LIST[0].value = loc_1
		loc_2 = 0
		reg_0 = FUNC_LIST[259](loc_1, 0, 4160)
		loc_3 = reg_0
		while true do
			loc_4 = add_i32(loc_3, shl_i32(loc_2, 6))
			loc_5 = shl_i32(loc_2, 3)
			loc_6 = add_i32(loc_5, 1052594)
			loc_7 = load_i32_u8(memory_at_0, add_i32(loc_5, 1052593))
			while true do
				loc_8 = load_i32_i8(memory_at_0, add_i32(loc_5, 1052592))
				if lt_i32(loc_8, 1) then
					break
				end
				loc_9 = load_i64(memory_at_0, loc_4)
				loc_1 = 1
				while true do
					while true do
						loc_9 = bor_i64(shl_i64(i64_ONE, extend_i64_u32(band_i32(add_i32(loc_1, loc_2), 63))), loc_9)
						loc_10 = extend_i32_n8(loc_1)
						if ge_i32(loc_10, loc_8) then
							desired = 3
							break
						end
						loc_1 = extend_i32_n8(add_i32(loc_1, (if lt_i32(loc_10, loc_8) then 1 else 0)))
						if le_i32(loc_1, loc_8) then
							continue
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i64(memory_at_0, loc_4, loc_9)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
					continue
				end
				break
			end
			loc_11 = add_i32(loc_5, 1052595)
			loc_6 = load_i32_u8(memory_at_0, loc_6)
			while true do
				loc_8 = extend_i32_n8(loc_7)
				if lt_i32(loc_8, 1) then
					break
				end
				loc_7 = add_i32(loc_4, 8)
				loc_9 = load_i64(memory_at_0, loc_7)
				loc_1 = 1
				while true do
					while true do
						loc_9 = bor_i64(shl_i64(i64_ONE, extend_i64_u32(band_i32(add_i32(shl_i32(loc_1, 3), loc_2), 63))), loc_9)
						loc_10 = extend_i32_n8(loc_1)
						if ge_i32(loc_10, loc_8) then
							desired = 3
							break
						end
						loc_1 = extend_i32_n8(add_i32(loc_1, (if lt_i32(loc_10, loc_8) then 1 else 0)))
						if le_i32(loc_1, loc_8) then
							continue
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i64(memory_at_0, loc_7, loc_9)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
					continue
				end
				break
			end
			loc_7 = add_i32(loc_5, 1052596)
			loc_11 = load_i32_u8(memory_at_0, loc_11)
			while true do
				loc_8 = extend_i32_n8(loc_6)
				if lt_i32(loc_8, 1) then
					break
				end
				loc_6 = add_i32(loc_4, 16)
				loc_9 = load_i64(memory_at_0, loc_6)
				loc_1 = 1
				while true do
					while true do
						loc_9 = bor_i64(shl_i64(i64_ONE, extend_i64_u32(band_i32(sub_i32(loc_2, loc_1), 63))), loc_9)
						loc_10 = extend_i32_n8(loc_1)
						if ge_i32(loc_10, loc_8) then
							desired = 3
							break
						end
						loc_1 = extend_i32_n8(add_i32(loc_1, (if lt_i32(loc_10, loc_8) then 1 else 0)))
						if le_i32(loc_1, loc_8) then
							continue
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i64(memory_at_0, loc_6, loc_9)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
					continue
				end
				break
			end
			loc_6 = add_i32(loc_5, 1052599)
			loc_12 = add_i32(loc_5, 1052598)
			loc_5 = add_i32(loc_5, 1052597)
			loc_7 = load_i32_u8(memory_at_0, loc_7)
			while true do
				loc_8 = extend_i32_n8(loc_11)
				if lt_i32(loc_8, 1) then
					break
				end
				loc_11 = add_i32(loc_4, 24)
				loc_9 = load_i64(memory_at_0, loc_11)
				loc_1 = 1
				while true do
					while true do
						loc_9 = bor_i64(shl_i64(i64_ONE, extend_i64_u32(band_i32(sub_i32(loc_2, shl_i32(loc_1, 3)), 63))), loc_9)
						loc_10 = extend_i32_n8(loc_1)
						if ge_i32(loc_10, loc_8) then
							desired = 3
							break
						end
						loc_1 = extend_i32_n8(add_i32(loc_1, (if lt_i32(loc_10, loc_8) then 1 else 0)))
						if le_i32(loc_1, loc_8) then
							continue
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i64(memory_at_0, loc_11, loc_9)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
					continue
				end
				break
			end
			loc_6 = load_i32_u8(memory_at_0, loc_6)
			loc_11 = load_i32_u8(memory_at_0, loc_12)
			loc_5 = load_i32_u8(memory_at_0, loc_5)
			while true do
				loc_8 = extend_i32_n8(loc_7)
				if lt_i32(loc_8, 1) then
					break
				end
				loc_7 = add_i32(loc_4, 32)
				loc_9 = load_i64(memory_at_0, loc_7)
				loc_1 = 1
				while true do
					while true do
						loc_9 = bor_i64(shl_i64(i64_ONE, extend_i64_u32(band_i32(add_i32(mul_i32(loc_1, 7), loc_2), 63))), loc_9)
						loc_10 = extend_i32_n8(loc_1)
						if ge_i32(loc_10, loc_8) then
							desired = 3
							break
						end
						loc_1 = extend_i32_n8(add_i32(loc_1, (if lt_i32(loc_10, loc_8) then 1 else 0)))
						if le_i32(loc_1, loc_8) then
							continue
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i64(memory_at_0, loc_7, loc_9)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
					continue
				end
				break
			end
			while true do
				loc_8 = extend_i32_n8(loc_5)
				if lt_i32(loc_8, 1) then
					break
				end
				loc_5 = add_i32(loc_4, 40)
				loc_9 = load_i64(memory_at_0, loc_5)
				loc_1 = 1
				while true do
					while true do
						loc_9 = bor_i64(shl_i64(i64_ONE, extend_i64_u32(band_i32(add_i32(mul_i32(loc_1, 9), loc_2), 63))), loc_9)
						loc_10 = extend_i32_n8(loc_1)
						if ge_i32(loc_10, loc_8) then
							desired = 3
							break
						end
						loc_1 = extend_i32_n8(add_i32(loc_1, (if lt_i32(loc_10, loc_8) then 1 else 0)))
						if le_i32(loc_1, loc_8) then
							continue
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i64(memory_at_0, loc_5, loc_9)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
					continue
				end
				break
			end
			while true do
				loc_8 = extend_i32_n8(loc_11)
				if lt_i32(loc_8, 1) then
					break
				end
				loc_5 = add_i32(loc_4, 48)
				loc_9 = load_i64(memory_at_0, loc_5)
				loc_1 = 1
				while true do
					while true do
						loc_9 = bor_i64(shl_i64(i64_ONE, extend_i64_u32(band_i32(add_i32(mul_i32(loc_1, 55), loc_2), 63))), loc_9)
						loc_10 = extend_i32_n8(loc_1)
						if ge_i32(loc_10, loc_8) then
							desired = 3
							break
						end
						loc_1 = extend_i32_n8(add_i32(loc_1, (if lt_i32(loc_10, loc_8) then 1 else 0)))
						if le_i32(loc_1, loc_8) then
							continue
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i64(memory_at_0, loc_5, loc_9)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
					continue
				end
				break
			end
			while true do
				loc_8 = extend_i32_n8(loc_6)
				if lt_i32(loc_8, 1) then
					break
				end
				loc_5 = add_i32(loc_4, 56)
				loc_9 = load_i64(memory_at_0, loc_5)
				loc_1 = 1
				while true do
					while true do
						loc_9 = bor_i64(shl_i64(i64_ONE, extend_i64_u32(band_i32(add_i32(mul_i32(loc_1, 57), loc_2), 63))), loc_9)
						loc_10 = extend_i32_n8(loc_1)
						if ge_i32(loc_10, loc_8) then
							desired = 3
							break
						end
						loc_1 = extend_i32_n8(add_i32(loc_1, (if lt_i32(loc_10, loc_8) then 1 else 0)))
						if le_i32(loc_1, loc_8) then
							continue
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i64(memory_at_0, loc_5, loc_9)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
					continue
				end
				break
			end
			loc_2 = add_i32(loc_2, 1)
			if loc_2 ~= 64 then
				continue
			end
			break
		end
		reg_0 = FUNC_LIST[262](loc_0, loc_3, 4160)
		GLOBAL_LIST[0].value = add_i32(loc_3, 4160)
		break
	end
end
FUNC_LIST[67] = --[[ _ZN6engine14move_generator13slider_lookup23rook_or_bishop_blockers17h36669e189f33a3fdE ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = i64_ZERO
	local loc_6 = 0
	local loc_7 = 0
	local loc_8 = 0
	local loc_9 = i64_ZERO
	local loc_10 = 0
	local loc_11 = 0
	local loc_12 = i64_ZERO
	local loc_13 = i64_ZERO
	local reg_0
	local desired
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_2
		loc_3 = extend_i32_n8(loc_0)
		while true do
			while true do
				while true do
					while true do
						while true do
							if band_i32(loc_0, 255) > 63 then
								break
							end
							store_i64(memory_at_0, loc_2, load_i64(memory_at_0, add_i32(shl_i32(loc_3, 3), 1052592)))
							while true do
								if load_i32_u8(memory_at_0, 0 + 1083608) == 3 then
									break
								end
								FUNC_LIST[90](1079448)
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							if loc_1 >= 8 then
								desired = 4
								break
							end
							loc_4 = shl_i32(loc_3, 6)
							loc_5 = load_i64(memory_at_0, add_i32(add_i32(loc_4, shl_i32(loc_1, 3)), 1079448))
							store_i64(memory_at_0, loc_2 + 8, i64_from_u32(4177463297, 4193716487))
							if loc_1 == 7 then
								desired = 3
								break
							end
							loc_6 = load_i32_u8(memory_at_0, add_i32(loc_2, loc_1))
							loc_7 = load_i32_u8(memory_at_0, add_i32(add_i32(loc_2, 8), loc_1))
							loc_8 = add_i32(loc_1, 1)
							loc_9 = load_i64(memory_at_0, add_i32(add_i32(loc_4, shl_i32(loc_8, 3)), 1079448))
							store_i64(memory_at_0, loc_2 + 8, i64_from_u32(4177463297, 4193716487))
							loc_4 = add_i32(loc_1, 2)
							if loc_1 >= 6 then
								desired = 2
								break
							end
							loc_10 = load_i32_u8(memory_at_0, add_i32(loc_2, loc_8))
							loc_8 = load_i32_u8(memory_at_0, add_i32(add_i32(loc_2, 8), loc_8))
							loc_11 = shl_i32(loc_3, 6)
							loc_12 = load_i64(memory_at_0, add_i32(add_i32(loc_11, shl_i32(loc_4, 3)), 1079448))
							store_i64(memory_at_0, loc_2 + 8, i64_from_u32(4177463297, 4193716487))
							loc_3 = add_i32(loc_1, 3)
							if loc_1 ~= 5 then
								desired = 1
								break
							end
							FUNC_LIST[189](loc_3, 8, 1053204)
							error("out of code bounds")
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						FUNC_LIST[189](loc_3, 64, 1053140)
						error("out of code bounds")
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					FUNC_LIST[189](loc_1, 8, 1053156)
					error("out of code bounds")
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[189](8, 8, 1053172)
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[189](loc_4, 8, 1053188)
			error("out of code bounds")
		end
		loc_1 = load_i32_u8(memory_at_0, add_i32(loc_2, loc_4))
		loc_4 = load_i32_u8(memory_at_0, add_i32(add_i32(loc_2, 8), loc_4))
		loc_13 = load_i64(memory_at_0, add_i32(add_i32(loc_11, shl_i32(loc_3, 3)), 1079448))
		store_i64(memory_at_0, loc_2 + 8, i64_from_u32(4177463297, 4193716487))
		loc_11 = load_i32_u8(memory_at_0, add_i32(loc_2, loc_3))
		loc_3 = load_i32_u8(memory_at_0, add_i32(add_i32(loc_2, 8), loc_3))
		GLOBAL_LIST[0].value = add_i32(loc_2, 16)
		reg_0 = bor_i64(bor_i64(bor_i64(band_i64(loc_9, rotl_i64(i64_from_u32(4294967294, 4294967295), extend_i64_u32(add_i32(mul_i32(loc_10, loc_8), loc_0)))), band_i64(loc_5, rotl_i64(i64_from_u32(4294967294, 4294967295), extend_i64_u32(add_i32(mul_i32(loc_6, loc_7), loc_0))))), band_i64(loc_12, rotl_i64(i64_from_u32(4294967294, 4294967295), extend_i64_u32(add_i32(mul_i32(loc_1, loc_4), loc_0))))), band_i64(loc_13, rotl_i64(i64_from_u32(4294967294, 4294967295), extend_i64_u32(add_i32(mul_i32(loc_11, loc_3), loc_0)))))
		break
	end
	return reg_0
end
FUNC_LIST[68] = --[[ _ZN6engine14move_generator13slider_lookup18gen_rook_or_bishop17hc2051d5b5bfa5808E ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	local loc_4 = i64_ZERO
	local loc_5 = i64_ZERO
	local loc_6 = i64_ZERO
	local loc_7 = i64_ZERO
	local loc_8 = i64_ZERO
	local loc_9 = i64_ZERO
	local loc_10 = i64_ZERO
	local loc_11 = i64_ZERO
	local reg_0
	local desired
	while true do
		while true do
			if load_i32_u8(memory_at_0, 0 + 1083608) == 3 then
				break
			end
			FUNC_LIST[90](1079448)
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		loc_3 = extend_i32_n8(loc_0)
		while true do
			while true do
				while true do
					while true do
						if band_i32(loc_0, 255) > 64 then
							break
						end
						if loc_2 >= 8 then
							desired = 3
							break
						end
						loc_0 = shl_i32(loc_2, 3)
						loc_4 = load_i64(memory_at_0, add_i32(add_i32(shl_i32(loc_3, 6), loc_0), 1079448))
						loc_5 = load_i64(memory_at_0, loc_1)
						while true do
							if load_i32_u8(memory_at_0, 0 + 1083608) == 3 then
								break
							end
							FUNC_LIST[90](1079448)
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						if loc_2 >= 7 then
							desired = 2
							break
						end
						loc_6 = load_i64(memory_at_0, add_i32(add_i32(shl_i32(wrap_i32_i64(ctz_i64(band_i64(loc_5, loc_4))), 6), loc_0), 1079448))
						loc_1 = shl_i32(add_i32(loc_2, 1), 3)
						loc_7 = load_i64(memory_at_0, add_i32(add_i32(shl_i32(loc_3, 6), loc_1), 1079448))
						while true do
							if load_i32_u8(memory_at_0, 0 + 1083608) == 3 then
								break
							end
							FUNC_LIST[90](1079448)
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_0 = add_i32(loc_2, 2)
						if loc_2 >= 6 then
							desired = 1
							break
						end
						loc_8 = load_i64(memory_at_0, add_i32(add_i32(shl_i32(wrap_i32_i64(ctz_i64(band_i64(loc_7, loc_5))), 6), loc_1), 1079448))
						loc_1 = shl_i32(loc_0, 3)
						loc_9 = load_i64(memory_at_0, add_i32(add_i32(shl_i32(loc_3, 6), loc_1), 1079448))
						while true do
							if load_i32_u8(memory_at_0, 0 + 1083608) == 3 then
								break
							end
							FUNC_LIST[90](1079448)
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_0 = add_i32(loc_2, 3)
						while true do
							if loc_2 >= 5 then
								break
							end
							loc_10 = load_i64(memory_at_0, add_i32(add_i32(shl_i32(bxor_i32(wrap_i32_i64(clz_i64(bor_i64(band_i64(loc_9, loc_5), i64_ONE))), 63), 6), loc_1), 1079448))
							loc_2 = shl_i32(loc_0, 3)
							loc_11 = load_i64(memory_at_0, add_i32(add_i32(shl_i32(loc_3, 6), loc_2), 1079448))
							while true do
								if load_i32_u8(memory_at_0, 0 + 1083608) == 3 then
									break
								end
								FUNC_LIST[90](1079448)
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							reg_0 = bor_i64(bor_i64(bor_i64(bxor_i64(loc_8, loc_7), bxor_i64(loc_6, loc_4)), bxor_i64(loc_10, loc_9)), bxor_i64(load_i64(memory_at_0, add_i32(add_i32(shl_i32(bxor_i32(wrap_i32_i64(clz_i64(bor_i64(band_i64(loc_11, loc_5), i64_ONE))), 63), 6), loc_2), 1079448)), loc_11))
							desired = 0
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						FUNC_LIST[189](loc_0, 8, 1053284)
						error("out of code bounds")
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					FUNC_LIST[189](loc_3, 65, 1053220)
					error("out of code bounds")
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[189](loc_2, 8, 1053236)
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[189](8, 8, 1053252)
			error("out of code bounds")
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		FUNC_LIST[189](loc_0, 8, 1053268)
		error("out of code bounds")
	end
	return reg_0
end
FUNC_LIST[69] = --[[ _ZN6engine14move_generator13slider_lookup11init_lookup17h620480a0560b6286E ]] function(loc_0, loc_1, loc_2, loc_3, loc_4)
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = 0
	local loc_8 = 0
	local loc_9 = 0
	local loc_10 = i64_ZERO
	local loc_11 = i64_ZERO
	local loc_12 = 0
	local loc_13 = i64_ZERO
	local loc_14 = i64_ZERO
	local loc_15 = i64_ZERO
	local reg_0
	local desired
	while true do
		loc_5 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_5
		while true do
			while true do
				while true do
					while true do
						if loc_1 ~= 0 then
							break
						end
						loc_6 = 8
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					if loc_1 > 268435455 then
						desired = 1
						break
					end
					loc_7 = shl_i32(loc_1, 3)
					if le_i32(loc_7, 4294967295) then
						desired = 1
						break
					end
					reg_0 = FUNC_LIST[21](loc_7, 8)
					loc_6 = reg_0
					if loc_6 == 0 then
						desired = 2
						break
					end
					loc_8 = loc_6
					while true do
						if loc_1 < 2 then
							break
						end
						loc_7 = add_i32(loc_7, 4294967288)
						reg_0 = FUNC_LIST[259](loc_6, 0, loc_7)
						loc_8 = add_i32(reg_0, loc_7)
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i64(memory_at_0, loc_8, i64_ZERO)
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_9 = 0
				while true do
					loc_8 = loc_9
					loc_9 = add_i32(loc_8, 1)
					loc_7 = add_i32(loc_2, mul_i32(loc_8, 24))
					loc_10 = band_i64(load_i64(memory_at_0, loc_7 + 8), i64_from_u32(63, 0))
					loc_11 = load_i64(memory_at_0, add_i32(loc_3, shl_i32(loc_8, 3)))
					loc_12 = load_i32(memory_at_0, loc_7 + 16)
					loc_13 = load_i64(memory_at_0, loc_7)
					loc_14 = i64_ZERO
					while true do
						while true do
							while true do
								store_i64(memory_at_0, loc_5 + 8, loc_14)
								reg_0 = FUNC_LIST[68](loc_8, add_i32(loc_5, 8), loc_4)
								loc_15 = reg_0
								loc_7 = add_i32(loc_12, wrap_i32_i64(shr_u64(mul_i64(loc_14, loc_13), loc_10)))
								if loc_7 >= loc_1 then
									desired = 5
									break
								end
								store_i64(memory_at_0, add_i32(loc_6, shl_i32(loc_7, 3)), loc_15)
								loc_14 = band_i64(sub_i64(loc_14, loc_11), loc_11)
								if eq_i64(loc_14, i64_ZERO) then
									desired = 4
									break
								end
								continue
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						FUNC_LIST[189](loc_7, loc_1, 1053300)
						error("out of code bounds")
					end
					if desired then
						if desired == 3 then
							desired = nil
							continue
						end
						break
					end
					if loc_9 ~= 64 then
						continue
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i32(memory_at_0, loc_0 + 8, loc_1)
				store_i32(memory_at_0, loc_0 + 4, loc_6)
				store_i32(memory_at_0, loc_0, loc_1)
				GLOBAL_LIST[0].value = add_i32(loc_5, 16)
				desired = 0
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[173](8, loc_7)
			error("out of code bounds")
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		FUNC_LIST[174]()
		error("out of code bounds")
	end
end
FUNC_LIST[70] = --[[ _ZN6engine5board10game_state14CastlingRights16from_fen_section17h76e9d89f78bd0a0dE ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = 0
	local loc_8 = 0
	local reg_0
	local desired
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_2
		while true do
			while true do
				while true do
					while true do
						while true do
							if loc_1 ~= 1 then
								break
							end
							loc_3 = 0
							if load_i32_u8(memory_at_0, loc_0) == 45 then
								desired = 1
								break
							end
							desired = 4
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						while true do
							if loc_1 < 8 then
								break
							end
							FUNC_LIST[240](add_i32(loc_2, 24), 75, loc_0, loc_1)
							loc_3 = load_i32(memory_at_0, loc_2 + 24)
							FUNC_LIST[240](add_i32(loc_2, 16), 81, loc_0, loc_1)
							loc_4 = load_i32(memory_at_0, loc_2 + 16)
							FUNC_LIST[240](add_i32(loc_2, 8), 107, loc_0, loc_1)
							loc_5 = load_i32(memory_at_0, loc_2 + 8)
							FUNC_LIST[240](loc_2, 113, loc_0, loc_1)
							loc_0 = (if loc_3 == 1 then 1 else 0)
							loc_3 = (if loc_4 == 1 then bor_i32(loc_0, 2) else loc_0)
							loc_6 = (if load_i32(memory_at_0, loc_2) == 1 then 1 else 0)
							if loc_5 ~= 1 then
								desired = 2
								break
							end
							desired = 3
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						if loc_1 ~= 0 then
							break
						end
						loc_3 = 0
						desired = 1
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_6 = add_i32(loc_1, 4294967295)
					loc_3 = loc_0
					while true do
						while true do
							loc_4 = loc_6
							loc_5 = load_i32_u8(memory_at_0, loc_3)
							if loc_5 == 75 then
								desired = 4
								break
							end
							loc_3 = add_i32(loc_3, 1)
							loc_6 = add_i32(loc_4, 4294967295)
							if loc_4 ~= 0 then
								continue
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_6 = add_i32(loc_1, 4294967295)
					loc_3 = loc_0
					while true do
						while true do
							loc_4 = loc_6
							loc_7 = load_i32_u8(memory_at_0, loc_3)
							if loc_7 == 81 then
								desired = 4
								break
							end
							loc_3 = add_i32(loc_3, 1)
							loc_6 = add_i32(loc_4, 4294967295)
							if loc_4 ~= 0 then
								continue
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_6 = add_i32(loc_1, 4294967295)
					loc_3 = loc_0
					while true do
						while true do
							loc_4 = loc_6
							loc_8 = load_i32_u8(memory_at_0, loc_3)
							if loc_8 == 107 then
								desired = 4
								break
							end
							loc_3 = add_i32(loc_3, 1)
							loc_6 = add_i32(loc_4, 4294967295)
							if loc_4 ~= 0 then
								continue
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_4 = add_i32(loc_1, 4294967295)
					while true do
						while true do
							loc_3 = loc_4
							loc_6 = (if load_i32_u8(memory_at_0, loc_0) == 113 then 1 else 0)
							if loc_6 ~= 0 then
								desired = 4
								break
							end
							loc_0 = add_i32(loc_0, 1)
							loc_4 = add_i32(loc_3, 4294967295)
							if loc_3 ~= 0 then
								continue
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_0 = (if loc_5 == 75 then 1 else 0)
					loc_3 = (if loc_7 == 81 then bor_i32(loc_0, 2) else loc_0)
					if loc_8 ~= 107 then
						desired = 2
						break
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_3 = bor_i32(loc_3, 4)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			if loc_6 == 0 then
				break
			end
			loc_3 = bor_i32(loc_3, 8)
			break
		end
		GLOBAL_LIST[0].value = add_i32(loc_2, 32)
		reg_0 = loc_3
		break
	end
	return reg_0
end
FUNC_LIST[71] = --[[ _ZN4core3fmt5Write9write_fmt17hd7bbe0e8cfdf7984E ]] function(loc_0, loc_1)
	local reg_0
	while true do
		reg_0 = FUNC_LIST[195](loc_0, 1056424, loc_1)
		break
	end
	return reg_0
end
FUNC_LIST[72] = --[[ _ZN4core3ptr42drop_in_place$LT$alloc..string..String$GT$17h0437b2dce3597bb5E ]] function(loc_0)
	local loc_1 = 0
	while true do
		while true do
			loc_1 = load_i32(memory_at_0, loc_0)
			if loc_1 == 0 then
				break
			end
			FUNC_LIST[22](load_i32(memory_at_0, loc_0 + 4), loc_1, 1)
			break
		end
		break
	end
end
FUNC_LIST[73] = --[[ _ZN58_$LT$alloc..string..String$u20$as$u20$core..fmt..Write$GT$10write_char17h062851a21fa82158E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local reg_0
	local desired
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_2
		while true do
			while true do
				while true do
					while true do
						if loc_1 < 128 then
							break
						end
						store_i32(memory_at_0, loc_2 + 12, 0)
						if loc_1 < 2048 then
							desired = 3
							break
						end
						while true do
							if loc_1 >= 65536 then
								break
							end
							store_i32_n8(memory_at_0, loc_2 + 14, bor_i32(band_i32(loc_1, 63), 128))
							store_i32_n8(memory_at_0, loc_2 + 12, bor_i32(shr_u32(loc_1, 12), 224))
							store_i32_n8(memory_at_0, loc_2 + 13, bor_i32(band_i32(shr_u32(loc_1, 6), 63), 128))
							loc_1 = 3
							desired = 2
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						store_i32_n8(memory_at_0, loc_2 + 15, bor_i32(band_i32(loc_1, 63), 128))
						store_i32_n8(memory_at_0, loc_2 + 14, bor_i32(band_i32(shr_u32(loc_1, 6), 63), 128))
						store_i32_n8(memory_at_0, loc_2 + 13, bor_i32(band_i32(shr_u32(loc_1, 12), 63), 128))
						store_i32_n8(memory_at_0, loc_2 + 12, bor_i32(band_i32(shr_u32(loc_1, 18), 7), 240))
						loc_1 = 4
						desired = 2
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					while true do
						loc_3 = load_i32(memory_at_0, loc_0 + 8)
						if loc_3 ~= load_i32(memory_at_0, loc_0) then
							break
						end
						FUNC_LIST[57](loc_0, loc_3)
						loc_3 = load_i32(memory_at_0, loc_0 + 8)
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32_n8(memory_at_0, add_i32(load_i32(memory_at_0, loc_0 + 4), loc_3), loc_1)
					store_i32(memory_at_0, loc_0 + 8, add_i32(load_i32(memory_at_0, loc_0 + 8), 1))
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i32_n8(memory_at_0, loc_2 + 13, bor_i32(band_i32(loc_1, 63), 128))
				store_i32_n8(memory_at_0, loc_2 + 12, bor_i32(shr_u32(loc_1, 6), 192))
				loc_1 = 2
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				loc_3 = load_i32(memory_at_0, loc_0 + 8)
				if sub_i32(load_i32(memory_at_0, loc_0), loc_3) >= loc_1 then
					break
				end
				FUNC_LIST[62](loc_0, loc_3, loc_1)
				loc_3 = load_i32(memory_at_0, loc_0 + 8)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			reg_0 = FUNC_LIST[262](add_i32(load_i32(memory_at_0, loc_0 + 4), loc_3), add_i32(loc_2, 12), loc_1)
			store_i32(memory_at_0, loc_0 + 8, add_i32(loc_3, loc_1))
			break
		end
		GLOBAL_LIST[0].value = add_i32(loc_2, 16)
		reg_0 = 0
		break
	end
	return reg_0
end
FUNC_LIST[74] = --[[ _ZN58_$LT$alloc..string..String$u20$as$u20$core..fmt..Write$GT$9write_str17hbef94c01d8f2ab7aE ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	local reg_0
	while true do
		while true do
			loc_3 = load_i32(memory_at_0, loc_0 + 8)
			if sub_i32(load_i32(memory_at_0, loc_0), loc_3) >= loc_2 then
				break
			end
			FUNC_LIST[62](loc_0, loc_3, loc_2)
			loc_3 = load_i32(memory_at_0, loc_0 + 8)
			break
		end
		reg_0 = FUNC_LIST[262](add_i32(load_i32(memory_at_0, loc_0 + 4), loc_3), loc_1, loc_2)
		store_i32(memory_at_0, loc_0 + 8, add_i32(loc_3, loc_2))
		reg_0 = 0
		break
	end
	return reg_0
end
FUNC_LIST[75] = --[[ _ZN89_$LT$alloc..string..String$u20$as$u20$core..iter..traits..collect..Extend$LT$char$GT$$GT$6extend17h0314c22b1cebfaf7E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local reg_0
	local desired
	local br_map = {}
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_2
		loc_3 = load_i32(memory_at_0, loc_1 + 8)
		loc_4 = load_i32(memory_at_0, loc_1 + 4)
		loc_5 = 0
		while true do
			while true do
				while true do
					loc_1 = load_i32(memory_at_0, loc_1)
					if not br_map[1] then
						br_map[1] = (function()
							return { [0] = 2, 1, }
						end)()
					end
					temp = br_map[1][add_i32(loc_1, 4293853184)] or 0
					if temp < 1 then
						break
					elseif temp > 1 then
						desired = 1
						break
					else
						desired = 2
						break
					end
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_5 = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				loc_6 = load_i32(memory_at_0, loc_0 + 8)
				loc_5 = add_i32(loc_5, shr_u32(add_i32(sub_i32(loc_3, loc_4), 3), 2))
				if sub_i32(load_i32(memory_at_0, loc_0), loc_6) >= loc_5 then
					break
				end
				FUNC_LIST[62](loc_0, loc_6, loc_5)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				if loc_1 == 1114113 then
					break
				end
				while true do
					while true do
						while true do
							if loc_1 < 128 then
								break
							end
							store_i32(memory_at_0, loc_2 + 12, 0)
							if loc_1 < 2048 then
								desired = 4
								break
							end
							while true do
								if loc_1 >= 65536 then
									break
								end
								store_i32_n8(memory_at_0, loc_2 + 14, bor_i32(band_i32(loc_1, 63), 128))
								store_i32_n8(memory_at_0, loc_2 + 12, bor_i32(shr_u32(loc_1, 12), 224))
								store_i32_n8(memory_at_0, loc_2 + 13, bor_i32(band_i32(shr_u32(loc_1, 6), 63), 128))
								loc_1 = 3
								desired = 3
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							store_i32_n8(memory_at_0, loc_2 + 15, bor_i32(band_i32(loc_1, 63), 128))
							store_i32_n8(memory_at_0, loc_2 + 12, bor_i32(shr_u32(loc_1, 18), 240))
							store_i32_n8(memory_at_0, loc_2 + 14, bor_i32(band_i32(shr_u32(loc_1, 6), 63), 128))
							store_i32_n8(memory_at_0, loc_2 + 13, bor_i32(band_i32(shr_u32(loc_1, 12), 63), 128))
							loc_1 = 4
							desired = 3
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						while true do
							loc_5 = load_i32(memory_at_0, loc_0 + 8)
							if loc_5 ~= load_i32(memory_at_0, loc_0) then
								break
							end
							FUNC_LIST[57](loc_0, loc_5)
							loc_5 = load_i32(memory_at_0, loc_0 + 8)
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						store_i32_n8(memory_at_0, add_i32(load_i32(memory_at_0, loc_0 + 4), loc_5), loc_1)
						store_i32(memory_at_0, loc_0 + 8, add_i32(load_i32(memory_at_0, loc_0 + 8), 1))
						desired = 2
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32_n8(memory_at_0, loc_2 + 13, bor_i32(band_i32(loc_1, 63), 128))
					store_i32_n8(memory_at_0, loc_2 + 12, bor_i32(shr_u32(loc_1, 6), 192))
					loc_1 = 2
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				while true do
					loc_5 = load_i32(memory_at_0, loc_0 + 8)
					if sub_i32(load_i32(memory_at_0, loc_0), loc_5) >= loc_1 then
						break
					end
					FUNC_LIST[62](loc_0, loc_5, loc_1)
					loc_5 = load_i32(memory_at_0, loc_0 + 8)
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				reg_0 = FUNC_LIST[262](add_i32(load_i32(memory_at_0, loc_0 + 4), loc_5), add_i32(loc_2, 12), loc_1)
				store_i32(memory_at_0, loc_0 + 8, add_i32(loc_5, loc_1))
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			if loc_4 == loc_3 then
				break
			end
			while true do
				while true do
					while true do
						while true do
							loc_1 = load_i32_i8(memory_at_0, loc_4)
							if le_i32(loc_1, 4294967295) then
								break
							end
							loc_4 = add_i32(loc_4, 1)
							loc_1 = band_i32(loc_1, 255)
							desired = 4
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_5 = band_i32(load_i32_u8(memory_at_0, loc_4 + 1), 63)
						loc_6 = band_i32(loc_1, 31)
						while true do
							while true do
								if loc_1 > 4294967263 then
									break
								end
								loc_1 = bor_i32(shl_i32(loc_6, 6), loc_5)
								loc_4 = add_i32(loc_4, 2)
								desired = 5
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_5 = bor_i32(shl_i32(loc_5, 6), band_i32(load_i32_u8(memory_at_0, loc_4 + 2), 63))
							while true do
								if loc_1 >= 4294967280 then
									break
								end
								loc_1 = bor_i32(loc_5, shl_i32(loc_6, 12))
								loc_4 = add_i32(loc_4, 3)
								desired = 5
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_1 = bor_i32(bor_i32(shl_i32(loc_5, 6), band_i32(load_i32_u8(memory_at_0, loc_4 + 3), 63)), band_i32(shl_i32(loc_6, 18), 1835008))
							if loc_1 == 1114112 then
								desired = 1
								break
							end
							loc_4 = add_i32(loc_4, 4)
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						if loc_1 < 128 then
							break
						end
						store_i32(memory_at_0, loc_2 + 8, 0)
						while true do
							while true do
								if loc_1 < 2048 then
									break
								end
								while true do
									if loc_1 >= 65536 then
										break
									end
									store_i32_n8(memory_at_0, loc_2 + 10, bor_i32(band_i32(loc_1, 63), 128))
									store_i32_n8(memory_at_0, loc_2 + 8, bor_i32(shr_u32(loc_1, 12), 224))
									store_i32_n8(memory_at_0, loc_2 + 9, bor_i32(band_i32(shr_u32(loc_1, 6), 63), 128))
									loc_1 = 3
									desired = 5
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								store_i32_n8(memory_at_0, loc_2 + 11, bor_i32(band_i32(loc_1, 63), 128))
								store_i32_n8(memory_at_0, loc_2 + 8, bor_i32(shr_u32(loc_1, 18), 240))
								store_i32_n8(memory_at_0, loc_2 + 10, bor_i32(band_i32(shr_u32(loc_1, 6), 63), 128))
								store_i32_n8(memory_at_0, loc_2 + 9, bor_i32(band_i32(shr_u32(loc_1, 12), 63), 128))
								loc_1 = 4
								desired = 5
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							store_i32_n8(memory_at_0, loc_2 + 9, bor_i32(band_i32(loc_1, 63), 128))
							store_i32_n8(memory_at_0, loc_2 + 8, bor_i32(shr_u32(loc_1, 6), 192))
							loc_1 = 2
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						while true do
							loc_5 = load_i32(memory_at_0, loc_0 + 8)
							if sub_i32(load_i32(memory_at_0, loc_0), loc_5) >= loc_1 then
								break
							end
							FUNC_LIST[62](loc_0, loc_5, loc_1)
							loc_5 = load_i32(memory_at_0, loc_0 + 8)
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						reg_0 = FUNC_LIST[262](add_i32(load_i32(memory_at_0, loc_0 + 4), loc_5), add_i32(loc_2, 8), loc_1)
						store_i32(memory_at_0, loc_0 + 8, add_i32(loc_5, loc_1))
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					while true do
						loc_5 = load_i32(memory_at_0, loc_0 + 8)
						if loc_5 ~= load_i32(memory_at_0, loc_0) then
							break
						end
						FUNC_LIST[57](loc_0, loc_5)
						loc_5 = load_i32(memory_at_0, loc_0 + 8)
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32_n8(memory_at_0, add_i32(load_i32(memory_at_0, loc_0 + 4), loc_5), loc_1)
					store_i32(memory_at_0, loc_0 + 8, add_i32(load_i32(memory_at_0, loc_0 + 8), 1))
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
						continue
					end
					break
				end
				if loc_4 ~= loc_3 then
					continue
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			break
		end
		GLOBAL_LIST[0].value = add_i32(loc_2, 16)
		break
	end
end
FUNC_LIST[76] = --[[ _ZN6engine5board6square6Square13from_notation17hc78203265124d3d7E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local reg_0
	local desired
	while true do
		while true do
			while true do
				while true do
					if loc_1 == 0 then
						break
					end
					loc_2 = load_i32_u8(memory_at_0, loc_0)
					loc_3 = load_i32_u8(memory_at_0, add_i32(loc_2, 1062924))
					if loc_3 == loc_1 then
						desired = 2
						break
					end
					while true do
						while true do
							loc_0 = add_i32(loc_0, loc_3)
							loc_1 = load_i32_i8(memory_at_0, loc_0)
							if le_i32(loc_1, 4294967295) then
								break
							end
							loc_1 = band_i32(loc_1, 255)
							desired = 4
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_3 = band_i32(load_i32_u8(memory_at_0, loc_0 + 1), 63)
						loc_4 = band_i32(loc_1, 31)
						while true do
							if loc_1 > 4294967263 then
								break
							end
							loc_1 = bor_i32(shl_i32(loc_4, 6), loc_3)
							desired = 4
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_3 = bor_i32(shl_i32(loc_3, 6), band_i32(load_i32_u8(memory_at_0, loc_0 + 2), 63))
						while true do
							if loc_1 >= 4294967280 then
								break
							end
							loc_1 = bor_i32(loc_3, shl_i32(loc_4, 12))
							desired = 4
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_1 = bor_i32(bor_i32(shl_i32(loc_3, 6), band_i32(load_i32_u8(memory_at_0, loc_0 + 3), 63)), band_i32(shl_i32(loc_4, 18), 1835008))
						if loc_1 == 1114112 then
							desired = 2
							break
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_1 = add_i32(loc_1, 4294967248)
					if loc_1 >= 10 then
						desired = 1
						break
					end
					reg_0 = add_i32(add_i32(loc_2, shl_i32(loc_1, 3)), 4294967191)
					desired = 0
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[210](1063196, 16, 1063232)
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[210](1063196, 16, 1063248)
			error("out of code bounds")
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		FUNC_LIST[210](1063196, 16, 1063264)
		error("out of code bounds")
	end
	return reg_0
end
FUNC_LIST[77] = --[[ _ZN3std3sys4wasm4once4Once4call17h2b1074bf93cb2c8eE ]] function(loc_0, loc_1, loc_2, loc_3)
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = i64_ZERO
	local loc_7 = 0
	local loc_8 = i64_ZERO
	local reg_0
	local desired
	local br_map = {}
	while true do
		loc_4 = sub_i32(GLOBAL_LIST[0].value, 2048)
		GLOBAL_LIST[0].value = loc_4
		while true do
			while true do
				while true do
					while true do
						while true do
							while true do
								if not br_map[1] then
									br_map[1] = (function()
										return { [0] = 1, 0, 5, 2, }
									end)()
								end
								temp = br_map[1][load_i32_u8(memory_at_0, loc_0)] or 1
								if temp < 2 then
									if temp < 1 then
										break
									else
										desired = 5
										break
									end
								elseif temp > 2 then
									desired = 1
									break
								else
									desired = 4
									break
								end
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							if loc_1 == 0 then
								desired = 3
								break
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						store_i32_n8(memory_at_0, loc_0, 2)
						loc_1 = load_i32(memory_at_0, loc_2)
						loc_5 = load_i32(memory_at_0, loc_1)
						loc_2 = 0
						store_i32(memory_at_0, loc_1, 0)
						if loc_5 == 0 then
							desired = 2
							break
						end
						reg_0 = FUNC_LIST[259](add_i32(loc_4, 1024), 0, 512)
						reg_0 = FUNC_LIST[259](add_i32(loc_4, 1536), 0, 512)
						loc_6 = i64_ZERO
						loc_1 = 0
						while true do
							loc_3 = add_i32(add_i32(loc_4, 1536), loc_2)
							loc_7 = add_i32(add_i32(loc_4, 1024), loc_2)
							while true do
								loc_8 = shl_i64(i64_ONE, loc_6)
								if eq_i64(band_i64(loc_8, i64_from_u32(4278124286, 4278124286)), i64_ZERO) then
									break
								end
								while true do
									if ge_u64(loc_6, i64_from_u32(56, 0)) then
										break
									end
									store_i64(memory_at_0, loc_7, bor_i64(load_i64(memory_at_0, loc_7), shl_i64(i64_ONE, extend_i64_u32(band_i32(add_i32(loc_1, 7), 63)))))
									if lt_u64(loc_6, i64_from_u32(8, 0)) then
										desired = 6
										break
									end
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								store_i64(memory_at_0, loc_3, bor_i64(load_i64(memory_at_0, loc_3), shl_i64(i64_ONE, extend_i64_u32(band_i32(add_i32(loc_1, 55), 63)))))
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
									continue
								end
								break
							end
							while true do
								if eq_i64(band_i64(loc_8, i64_from_u32(2139062143, 2139062143)), i64_ZERO) then
									break
								end
								while true do
									if ge_u64(loc_6, i64_from_u32(56, 0)) then
										break
									end
									store_i64(memory_at_0, loc_7, bor_i64(load_i64(memory_at_0, loc_7), shl_i64(i64_ONE, extend_i64_u32(band_i32(add_i32(loc_1, 9), 63)))))
									if lt_u64(loc_6, i64_from_u32(8, 0)) then
										desired = 6
										break
									end
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								store_i64(memory_at_0, loc_3, bor_i64(load_i64(memory_at_0, loc_3), shl_i64(i64_ONE, extend_i64_u32(band_i32(add_i32(loc_1, 57), 63)))))
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
									continue
								end
								break
							end
							loc_1 = add_i32(loc_1, 1)
							loc_2 = add_i32(loc_2, 8)
							loc_6 = add_i64(loc_6, i64_ONE)
							if ne_i64(loc_6, i64_from_u32(64, 0)) then
								continue
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						reg_0 = FUNC_LIST[262](loc_4, add_i32(loc_4, 1024), 512)
						loc_2 = reg_0
						reg_0 = FUNC_LIST[262](add_i32(loc_2, 512), add_i32(loc_2, 1536), 512)
						reg_0 = FUNC_LIST[262](loc_5, loc_2, 1024)
						store_i32_n8(memory_at_0, loc_0, 3)
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					GLOBAL_LIST[0].value = add_i32(loc_4, 2048)
					desired = 0
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i64(memory_at_0, add_i32(loc_4, 12), i64_ZERO)
				store_i32(memory_at_0, loc_4 + 4, 1)
				store_i32(memory_at_0, loc_4, 1063324)
				store_i32(memory_at_0, loc_4 + 8, 1063332)
				FUNC_LIST[187](loc_4, loc_3)
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[192](1063396, 43, 1063516)
			error("out of code bounds")
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		store_i64(memory_at_0, add_i32(loc_4, 12), i64_ZERO)
		store_i32(memory_at_0, loc_4 + 4, 1)
		store_i32(memory_at_0, loc_4, 1063388)
		store_i32(memory_at_0, loc_4 + 8, 1063332)
		FUNC_LIST[187](loc_4, loc_3)
		error("out of code bounds")
	end
end
FUNC_LIST[78] = --[[ _ZN3std3sys4wasm4once4Once4call17h31f2a12b59b93595E ]] function(loc_0, loc_1, loc_2, loc_3)
	local loc_4 = 0
	local reg_0
	local reg_1
	local desired
	local br_map = {}
	while true do
		loc_4 = sub_i32(GLOBAL_LIST[0].value, 1024)
		GLOBAL_LIST[0].value = loc_4
		while true do
			while true do
				while true do
					while true do
						while true do
							while true do
								if not br_map[1] then
									br_map[1] = (function()
										return { [0] = 1, 0, 5, 2, }
									end)()
								end
								temp = br_map[1][load_i32_u8(memory_at_0, loc_0)] or 1
								if temp < 2 then
									if temp < 1 then
										break
									else
										desired = 5
										break
									end
								elseif temp > 2 then
									desired = 1
									break
								else
									desired = 4
									break
								end
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							if loc_1 == 0 then
								desired = 3
								break
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						store_i32_n8(memory_at_0, loc_0, 2)
						loc_1 = load_i32(memory_at_0, loc_2)
						loc_3 = load_i32(memory_at_0, loc_1)
						loc_2 = 0
						store_i32(memory_at_0, loc_1, 0)
						if loc_3 == 0 then
							desired = 2
							break
						end
						reg_0 = FUNC_LIST[259](add_i32(loc_4, 512), 0, 512)
						loc_1 = add_i32(loc_4, 512)
						while true do
							reg_1 = FUNC_LIST[67](loc_2, 4)
							store_i64(memory_at_0, loc_1, reg_1)
							loc_1 = add_i32(loc_1, 8)
							loc_2 = add_i32(loc_2, 1)
							if loc_2 ~= 64 then
								continue
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						reg_1 = FUNC_LIST[262](loc_4, add_i32(loc_4, 512), 512)
						reg_0 = FUNC_LIST[262](loc_3, reg_1, 512)
						store_i32_n8(memory_at_0, loc_0, 3)
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					GLOBAL_LIST[0].value = add_i32(loc_4, 1024)
					desired = 0
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i64(memory_at_0, add_i32(loc_4, 524), i64_ZERO)
				store_i32(memory_at_0, loc_4 + 516, 1)
				store_i32(memory_at_0, loc_4 + 512, 1063324)
				store_i32(memory_at_0, loc_4 + 520, 1063332)
				FUNC_LIST[187](add_i32(loc_4, 512), loc_3)
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[192](1063396, 43, 1063516)
			error("out of code bounds")
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		store_i64(memory_at_0, add_i32(loc_4, 524), i64_ZERO)
		store_i32(memory_at_0, loc_4 + 516, 1)
		store_i32(memory_at_0, loc_4 + 512, 1063388)
		store_i32(memory_at_0, loc_4 + 520, 1063332)
		FUNC_LIST[187](add_i32(loc_4, 512), loc_3)
		error("out of code bounds")
	end
end
FUNC_LIST[79] = --[[ _ZN3std3sys4wasm4once4Once4call17h45e44bb12bbfb87dE ]] function(loc_0, loc_1, loc_2, loc_3)
	local loc_4 = 0
	local reg_0
	local desired
	local br_map = {}
	while true do
		loc_4 = sub_i32(GLOBAL_LIST[0].value, 528)
		GLOBAL_LIST[0].value = loc_4
		while true do
			while true do
				while true do
					while true do
						while true do
							while true do
								if not br_map[1] then
									br_map[1] = (function()
										return { [0] = 1, 0, 5, 2, }
									end)()
								end
								temp = br_map[1][load_i32_u8(memory_at_0, loc_0)] or 1
								if temp < 2 then
									if temp < 1 then
										break
									else
										desired = 5
										break
									end
								elseif temp > 2 then
									desired = 1
									break
								else
									desired = 4
									break
								end
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							if loc_1 == 0 then
								desired = 3
								break
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						store_i32_n8(memory_at_0, loc_0, 2)
						loc_1 = load_i32(memory_at_0, loc_2)
						loc_2 = load_i32(memory_at_0, loc_1)
						store_i32(memory_at_0, loc_1, 0)
						if loc_2 == 0 then
							desired = 2
							break
						end
						while true do
							if load_i32_u8(memory_at_0, 0 + 1084648) == 3 then
								break
							end
							FUNC_LIST[88](1084136)
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						reg_0 = FUNC_LIST[262](add_i32(loc_4, 16), 1084136, 512)
						FUNC_LIST[69](loc_4, 5248, 1065072, add_i32(loc_4, 16), 4)
						store_i32(memory_at_0, add_i32(loc_2, 8), load_i32(memory_at_0, add_i32(loc_4, 8)))
						store_i64(memory_at_0, loc_2, load_i64(memory_at_0, loc_4))
						store_i32_n8(memory_at_0, loc_0, 3)
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					GLOBAL_LIST[0].value = add_i32(loc_4, 528)
					desired = 0
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i64(memory_at_0, add_i32(loc_4, 28), i64_ZERO)
				store_i32(memory_at_0, loc_4 + 20, 1)
				store_i32(memory_at_0, loc_4 + 16, 1063324)
				store_i32(memory_at_0, loc_4 + 24, 1063332)
				FUNC_LIST[187](add_i32(loc_4, 16), loc_3)
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[192](1063396, 43, 1063516)
			error("out of code bounds")
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		store_i64(memory_at_0, add_i32(loc_4, 28), i64_ZERO)
		store_i32(memory_at_0, loc_4 + 20, 1)
		store_i32(memory_at_0, loc_4 + 16, 1063388)
		store_i32(memory_at_0, loc_4 + 24, 1063332)
		FUNC_LIST[187](add_i32(loc_4, 16), loc_3)
		error("out of code bounds")
	end
end
FUNC_LIST[80] = --[[ _ZN3std3sys4wasm4once4Once4call17h5c928739ac90b74fE ]] function(loc_0, loc_1, loc_2, loc_3)
	local loc_4 = 0
	local reg_0
	local desired
	local br_map = {}
	while true do
		loc_4 = sub_i32(GLOBAL_LIST[0].value, 4160)
		GLOBAL_LIST[0].value = loc_4
		while true do
			while true do
				while true do
					while true do
						while true do
							while true do
								if not br_map[1] then
									br_map[1] = (function()
										return { [0] = 1, 0, 5, 2, }
									end)()
								end
								temp = br_map[1][load_i32_u8(memory_at_0, loc_0)] or 1
								if temp < 2 then
									if temp < 1 then
										break
									else
										desired = 5
										break
									end
								elseif temp > 2 then
									desired = 1
									break
								else
									desired = 4
									break
								end
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							if loc_1 == 0 then
								desired = 3
								break
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						store_i32_n8(memory_at_0, loc_0, 2)
						loc_1 = load_i32(memory_at_0, loc_2)
						loc_2 = load_i32(memory_at_0, loc_1)
						store_i32(memory_at_0, loc_1, 0)
						if loc_2 == 0 then
							desired = 2
							break
						end
						FUNC_LIST[66](loc_4)
						reg_0 = FUNC_LIST[262](loc_2, loc_4, 4160)
						store_i32_n8(memory_at_0, loc_0, 3)
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					GLOBAL_LIST[0].value = add_i32(loc_4, 4160)
					desired = 0
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i64(memory_at_0, add_i32(loc_4, 12), i64_ZERO)
				store_i32(memory_at_0, loc_4 + 4, 1)
				store_i32(memory_at_0, loc_4, 1063324)
				store_i32(memory_at_0, loc_4 + 8, 1063332)
				FUNC_LIST[187](loc_4, loc_3)
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[192](1063396, 43, 1063516)
			error("out of code bounds")
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		store_i64(memory_at_0, add_i32(loc_4, 12), i64_ZERO)
		store_i32(memory_at_0, loc_4 + 4, 1)
		store_i32(memory_at_0, loc_4, 1063388)
		store_i32(memory_at_0, loc_4 + 8, 1063332)
		FUNC_LIST[187](loc_4, loc_3)
		error("out of code bounds")
	end
end
FUNC_LIST[81] = --[[ _ZN3std3sys4wasm4once4Once4call17h6de4c265ece1942bE ]] function(loc_0, loc_1, loc_2, loc_3)
	local loc_4 = 0
	local reg_0
	local reg_1
	local desired
	local br_map = {}
	while true do
		loc_4 = sub_i32(GLOBAL_LIST[0].value, 1024)
		GLOBAL_LIST[0].value = loc_4
		while true do
			while true do
				while true do
					while true do
						while true do
							while true do
								if not br_map[1] then
									br_map[1] = (function()
										return { [0] = 1, 0, 5, 2, }
									end)()
								end
								temp = br_map[1][load_i32_u8(memory_at_0, loc_0)] or 1
								if temp < 2 then
									if temp < 1 then
										break
									else
										desired = 5
										break
									end
								elseif temp > 2 then
									desired = 1
									break
								else
									desired = 4
									break
								end
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							if loc_1 == 0 then
								desired = 3
								break
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						store_i32_n8(memory_at_0, loc_0, 2)
						loc_2 = load_i32(memory_at_0, loc_2)
						loc_3 = load_i32(memory_at_0, loc_2)
						store_i32(memory_at_0, loc_2, 0)
						if loc_3 == 0 then
							desired = 2
							break
						end
						reg_0 = FUNC_LIST[259](add_i32(loc_4, 512), 0, 512)
						loc_2 = add_i32(loc_4, 512)
						loc_1 = 0
						while true do
							reg_1 = FUNC_LIST[67](loc_1, 0)
							store_i64(memory_at_0, loc_2, reg_1)
							loc_2 = add_i32(loc_2, 8)
							loc_1 = add_i32(loc_1, 1)
							if loc_1 ~= 64 then
								continue
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						reg_1 = FUNC_LIST[262](loc_4, add_i32(loc_4, 512), 512)
						reg_0 = FUNC_LIST[262](loc_3, reg_1, 512)
						store_i32_n8(memory_at_0, loc_0, 3)
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					GLOBAL_LIST[0].value = add_i32(loc_4, 1024)
					desired = 0
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i64(memory_at_0, add_i32(loc_4, 524), i64_ZERO)
				store_i32(memory_at_0, loc_4 + 516, 1)
				store_i32(memory_at_0, loc_4 + 512, 1063324)
				store_i32(memory_at_0, loc_4 + 520, 1063332)
				FUNC_LIST[187](add_i32(loc_4, 512), loc_3)
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[192](1063396, 43, 1063516)
			error("out of code bounds")
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		store_i64(memory_at_0, add_i32(loc_4, 524), i64_ZERO)
		store_i32(memory_at_0, loc_4 + 516, 1)
		store_i32(memory_at_0, loc_4 + 512, 1063388)
		store_i32(memory_at_0, loc_4 + 520, 1063332)
		FUNC_LIST[187](add_i32(loc_4, 512), loc_3)
		error("out of code bounds")
	end
end
FUNC_LIST[82] = --[[ _ZN3std3sys4wasm4once4Once4call17h7fc2f98864d1774cE ]] function(loc_0, loc_1, loc_2, loc_3)
	local loc_4 = 0
	local reg_0
	local desired
	local br_map = {}
	while true do
		loc_4 = sub_i32(GLOBAL_LIST[0].value, 512)
		GLOBAL_LIST[0].value = loc_4
		while true do
			while true do
				while true do
					while true do
						while true do
							while true do
								if not br_map[1] then
									br_map[1] = (function()
										return { [0] = 1, 0, 5, 2, }
									end)()
								end
								temp = br_map[1][load_i32_u8(memory_at_0, loc_0)] or 1
								if temp < 2 then
									if temp < 1 then
										break
									else
										desired = 5
										break
									end
								elseif temp > 2 then
									desired = 1
									break
								else
									desired = 4
									break
								end
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							if loc_1 == 0 then
								desired = 3
								break
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						store_i32_n8(memory_at_0, loc_0, 2)
						loc_1 = load_i32(memory_at_0, loc_2)
						loc_2 = load_i32(memory_at_0, loc_1)
						store_i32(memory_at_0, loc_1, 0)
						if loc_2 == 0 then
							desired = 2
							break
						end
						FUNC_LIST[63](loc_4)
						reg_0 = FUNC_LIST[262](loc_2, loc_4, 512)
						store_i32_n8(memory_at_0, loc_0, 3)
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					GLOBAL_LIST[0].value = add_i32(loc_4, 512)
					desired = 0
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i64(memory_at_0, add_i32(loc_4, 12), i64_ZERO)
				store_i32(memory_at_0, loc_4 + 4, 1)
				store_i32(memory_at_0, loc_4, 1063324)
				store_i32(memory_at_0, loc_4 + 8, 1063332)
				FUNC_LIST[187](loc_4, loc_3)
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[192](1063396, 43, 1063516)
			error("out of code bounds")
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		store_i64(memory_at_0, add_i32(loc_4, 12), i64_ZERO)
		store_i32(memory_at_0, loc_4 + 4, 1)
		store_i32(memory_at_0, loc_4, 1063388)
		store_i32(memory_at_0, loc_4 + 8, 1063332)
		FUNC_LIST[187](loc_4, loc_3)
		error("out of code bounds")
	end
end
FUNC_LIST[83] = --[[ _ZN3std3sys4wasm4once4Once4call17hd4cc5db4caf22bbeE ]] function(loc_0, loc_1, loc_2, loc_3)
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = 0
	local loc_8 = 0
	local loc_9 = 0
	local reg_0
	local reg_1
	local desired
	local br_map = {}
	while true do
		loc_4 = sub_i32(GLOBAL_LIST[0].value, 1024)
		GLOBAL_LIST[0].value = loc_4
		while true do
			while true do
				while true do
					while true do
						while true do
							while true do
								if not br_map[1] then
									br_map[1] = (function()
										return { [0] = 1, 0, 3, 2, }
									end)()
								end
								temp = br_map[1][load_i32_u8(memory_at_0, loc_0)] or 1
								if temp < 2 then
									if temp < 1 then
										break
									else
										desired = 5
										break
									end
								elseif temp > 2 then
									desired = 3
									break
								else
									desired = 4
									break
								end
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							if loc_1 == 0 then
								desired = 1
								break
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						store_i32_n8(memory_at_0, loc_0, 2)
						loc_2 = load_i32(memory_at_0, loc_2)
						loc_5 = load_i32(memory_at_0, loc_2)
						loc_1 = 0
						store_i32(memory_at_0, loc_2, 0)
						if loc_5 == 0 then
							desired = 2
							break
						end
						reg_0 = FUNC_LIST[259](add_i32(loc_4, 512), 0, 512)
						loc_3 = add_i32(loc_4, 512)
						while true do
							loc_2 = band_i32(loc_1, 7)
							loc_6 = shr_i32(extend_i32_n8(loc_1), 3)
							while true do
								loc_7 = add_i32(loc_1, 15)
								if band_i32(loc_7, 255) > 63 then
									break
								end
								loc_8 = band_i32(loc_7, 7)
								loc_8 = band_i32((if loc_2 < loc_8 then sub_i32(loc_8, loc_2) else sub_i32(loc_2, loc_8)), 255)
								loc_9 = sub_i32(loc_6, shr_u32(band_i32(loc_7, 248), 3))
								reg_1 = loc_9
								loc_9 = shr_i32(extend_i32_n8(loc_9), 7)
								loc_9 = band_i32(sub_i32(bxor_i32(reg_1, loc_9), loc_9), 255)
								if (if loc_8 > loc_9 then loc_8 else loc_9) ~= 2 then
									break
								end
								store_i64(memory_at_0, loc_3, bor_i64(load_i64(memory_at_0, loc_3), shl_i64(i64_ONE, band_i64(extend_i64_u32(loc_7), i64_from_u32(255, 0)))))
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
									continue
								end
								break
							end
							while true do
								loc_7 = add_i32(loc_1, 17)
								if band_i32(loc_7, 255) > 63 then
									break
								end
								loc_8 = band_i32(loc_7, 7)
								loc_8 = band_i32((if loc_2 < loc_8 then sub_i32(loc_8, loc_2) else sub_i32(loc_2, loc_8)), 255)
								loc_9 = sub_i32(loc_6, shr_u32(band_i32(loc_7, 248), 3))
								reg_1 = loc_9
								loc_9 = shr_i32(extend_i32_n8(loc_9), 7)
								loc_9 = band_i32(sub_i32(bxor_i32(reg_1, loc_9), loc_9), 255)
								if (if loc_8 > loc_9 then loc_8 else loc_9) ~= 2 then
									break
								end
								store_i64(memory_at_0, loc_3, bor_i64(load_i64(memory_at_0, loc_3), shl_i64(i64_ONE, band_i64(extend_i64_u32(loc_7), i64_from_u32(255, 0)))))
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
									continue
								end
								break
							end
							while true do
								loc_7 = add_i32(loc_1, 4294967279)
								if band_i32(loc_7, 255) > 63 then
									break
								end
								loc_8 = band_i32(loc_7, 7)
								loc_8 = band_i32((if loc_2 < loc_8 then sub_i32(loc_8, loc_2) else sub_i32(loc_2, loc_8)), 255)
								loc_9 = sub_i32(loc_6, shr_u32(band_i32(loc_7, 248), 3))
								reg_1 = loc_9
								loc_9 = shr_i32(extend_i32_n8(loc_9), 7)
								loc_9 = band_i32(sub_i32(bxor_i32(reg_1, loc_9), loc_9), 255)
								if (if loc_8 > loc_9 then loc_8 else loc_9) ~= 2 then
									break
								end
								store_i64(memory_at_0, loc_3, bor_i64(load_i64(memory_at_0, loc_3), shl_i64(i64_ONE, band_i64(extend_i64_u32(loc_7), i64_from_u32(255, 0)))))
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
									continue
								end
								break
							end
							while true do
								loc_7 = add_i32(loc_1, 4294967281)
								if band_i32(loc_7, 255) > 63 then
									break
								end
								loc_8 = band_i32(loc_7, 7)
								loc_8 = band_i32((if loc_2 < loc_8 then sub_i32(loc_8, loc_2) else sub_i32(loc_2, loc_8)), 255)
								loc_9 = sub_i32(loc_6, shr_u32(band_i32(loc_7, 248), 3))
								reg_1 = loc_9
								loc_9 = shr_i32(extend_i32_n8(loc_9), 7)
								loc_9 = band_i32(sub_i32(bxor_i32(reg_1, loc_9), loc_9), 255)
								if (if loc_8 > loc_9 then loc_8 else loc_9) ~= 2 then
									break
								end
								store_i64(memory_at_0, loc_3, bor_i64(load_i64(memory_at_0, loc_3), shl_i64(i64_ONE, band_i64(extend_i64_u32(loc_7), i64_from_u32(255, 0)))))
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
									continue
								end
								break
							end
							while true do
								loc_7 = add_i32(loc_1, 10)
								if band_i32(loc_7, 255) > 63 then
									break
								end
								loc_8 = band_i32(loc_7, 7)
								loc_8 = band_i32((if loc_2 < loc_8 then sub_i32(loc_8, loc_2) else sub_i32(loc_2, loc_8)), 255)
								loc_9 = sub_i32(loc_6, shr_u32(band_i32(loc_7, 248), 3))
								reg_1 = loc_9
								loc_9 = shr_i32(extend_i32_n8(loc_9), 7)
								loc_9 = band_i32(sub_i32(bxor_i32(reg_1, loc_9), loc_9), 255)
								if (if loc_8 > loc_9 then loc_8 else loc_9) ~= 2 then
									break
								end
								store_i64(memory_at_0, loc_3, bor_i64(load_i64(memory_at_0, loc_3), shl_i64(i64_ONE, band_i64(extend_i64_u32(loc_7), i64_from_u32(255, 0)))))
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
									continue
								end
								break
							end
							while true do
								loc_7 = add_i32(loc_1, 4294967290)
								if band_i32(loc_7, 255) > 63 then
									break
								end
								loc_8 = band_i32(loc_7, 7)
								loc_8 = band_i32((if loc_2 < loc_8 then sub_i32(loc_8, loc_2) else sub_i32(loc_2, loc_8)), 255)
								loc_9 = sub_i32(loc_6, shr_u32(band_i32(loc_7, 248), 3))
								reg_1 = loc_9
								loc_9 = shr_i32(extend_i32_n8(loc_9), 7)
								loc_9 = band_i32(sub_i32(bxor_i32(reg_1, loc_9), loc_9), 255)
								if (if loc_8 > loc_9 then loc_8 else loc_9) ~= 2 then
									break
								end
								store_i64(memory_at_0, loc_3, bor_i64(load_i64(memory_at_0, loc_3), shl_i64(i64_ONE, band_i64(extend_i64_u32(loc_7), i64_from_u32(255, 0)))))
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
									continue
								end
								break
							end
							while true do
								loc_7 = add_i32(loc_1, 6)
								if band_i32(loc_7, 255) > 63 then
									break
								end
								loc_8 = band_i32(loc_7, 7)
								loc_8 = band_i32((if loc_2 < loc_8 then sub_i32(loc_8, loc_2) else sub_i32(loc_2, loc_8)), 255)
								loc_9 = sub_i32(loc_6, shr_u32(band_i32(loc_7, 248), 3))
								reg_1 = loc_9
								loc_9 = shr_i32(extend_i32_n8(loc_9), 7)
								loc_9 = band_i32(sub_i32(bxor_i32(reg_1, loc_9), loc_9), 255)
								if (if loc_8 > loc_9 then loc_8 else loc_9) ~= 2 then
									break
								end
								store_i64(memory_at_0, loc_3, bor_i64(load_i64(memory_at_0, loc_3), shl_i64(i64_ONE, band_i64(extend_i64_u32(loc_7), i64_from_u32(255, 0)))))
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
									continue
								end
								break
							end
							while true do
								loc_7 = add_i32(loc_1, 4294967286)
								if band_i32(loc_7, 255) > 63 then
									break
								end
								loc_8 = band_i32(loc_7, 7)
								loc_2 = band_i32((if loc_2 < loc_8 then sub_i32(loc_8, loc_2) else sub_i32(loc_2, loc_8)), 255)
								loc_6 = sub_i32(loc_6, shr_u32(band_i32(loc_7, 248), 3))
								reg_1 = loc_6
								loc_6 = shr_i32(extend_i32_n8(loc_6), 7)
								loc_6 = band_i32(sub_i32(bxor_i32(reg_1, loc_6), loc_6), 255)
								if (if loc_2 > loc_6 then loc_2 else loc_6) ~= 2 then
									break
								end
								store_i64(memory_at_0, loc_3, bor_i64(load_i64(memory_at_0, loc_3), shl_i64(i64_ONE, band_i64(extend_i64_u32(loc_7), i64_from_u32(255, 0)))))
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
									continue
								end
								break
							end
							loc_3 = add_i32(loc_3, 8)
							loc_1 = add_i32(loc_1, 1)
							if loc_1 ~= 64 then
								continue
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						reg_1 = FUNC_LIST[262](loc_4, add_i32(loc_4, 512), 512)
						reg_0 = FUNC_LIST[262](loc_5, reg_1, 512)
						store_i32_n8(memory_at_0, loc_0, 3)
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					GLOBAL_LIST[0].value = add_i32(loc_4, 1024)
					desired = 0
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i64(memory_at_0, add_i32(loc_4, 524), i64_ZERO)
				store_i32(memory_at_0, loc_4 + 516, 1)
				store_i32(memory_at_0, loc_4 + 512, 1063388)
				store_i32(memory_at_0, loc_4 + 520, 1063332)
				FUNC_LIST[187](add_i32(loc_4, 512), loc_3)
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[192](1063396, 43, 1063516)
			error("out of code bounds")
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		store_i64(memory_at_0, add_i32(loc_4, 524), i64_ZERO)
		store_i32(memory_at_0, loc_4 + 516, 1)
		store_i32(memory_at_0, loc_4 + 512, 1063324)
		store_i32(memory_at_0, loc_4 + 520, 1063332)
		FUNC_LIST[187](add_i32(loc_4, 512), loc_3)
		error("out of code bounds")
	end
end
FUNC_LIST[84] = --[[ _ZN3std3sys4wasm4once4Once4call17he59c5aafee695645E ]] function(loc_0, loc_1, loc_2, loc_3)
	local loc_4 = 0
	local reg_0
	local desired
	local br_map = {}
	while true do
		loc_4 = sub_i32(GLOBAL_LIST[0].value, 528)
		GLOBAL_LIST[0].value = loc_4
		while true do
			while true do
				while true do
					while true do
						while true do
							while true do
								if not br_map[1] then
									br_map[1] = (function()
										return { [0] = 1, 0, 5, 2, }
									end)()
								end
								temp = br_map[1][load_i32_u8(memory_at_0, loc_0)] or 1
								if temp < 2 then
									if temp < 1 then
										break
									else
										desired = 5
										break
									end
								elseif temp > 2 then
									desired = 1
									break
								else
									desired = 4
									break
								end
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							if loc_1 == 0 then
								desired = 3
								break
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						store_i32_n8(memory_at_0, loc_0, 2)
						loc_1 = load_i32(memory_at_0, loc_2)
						loc_2 = load_i32(memory_at_0, loc_1)
						store_i32(memory_at_0, loc_1, 0)
						if loc_2 == 0 then
							desired = 2
							break
						end
						while true do
							if load_i32_u8(memory_at_0, 0 + 1084128) == 3 then
								break
							end
							FUNC_LIST[87](1083616)
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						reg_0 = FUNC_LIST[262](add_i32(loc_4, 16), 1083616, 512)
						FUNC_LIST[69](loc_4, 102400, 1063536, add_i32(loc_4, 16), 0)
						store_i32(memory_at_0, add_i32(loc_2, 8), load_i32(memory_at_0, add_i32(loc_4, 8)))
						store_i64(memory_at_0, loc_2, load_i64(memory_at_0, loc_4))
						store_i32_n8(memory_at_0, loc_0, 3)
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					GLOBAL_LIST[0].value = add_i32(loc_4, 528)
					desired = 0
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i64(memory_at_0, add_i32(loc_4, 28), i64_ZERO)
				store_i32(memory_at_0, loc_4 + 20, 1)
				store_i32(memory_at_0, loc_4 + 16, 1063324)
				store_i32(memory_at_0, loc_4 + 24, 1063332)
				FUNC_LIST[187](add_i32(loc_4, 16), loc_3)
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[192](1063396, 43, 1063516)
			error("out of code bounds")
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		store_i64(memory_at_0, add_i32(loc_4, 28), i64_ZERO)
		store_i32(memory_at_0, loc_4 + 20, 1)
		store_i32(memory_at_0, loc_4 + 16, 1063388)
		store_i32(memory_at_0, loc_4 + 24, 1063332)
		FUNC_LIST[187](add_i32(loc_4, 16), loc_3)
		error("out of code bounds")
	end
end
FUNC_LIST[85] = --[[ _ZN3std4sync9once_lock17OnceLock$LT$T$GT$10initialize17h0a2004869521de34E ]] function(loc_0)
	local loc_1 = 0
	while true do
		loc_1 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_1
		while true do
			if load_i32_u8(memory_at_0, loc_0 + 512) == 3 then
				break
			end
			store_i32(memory_at_0, loc_1, loc_0)
			store_i32(memory_at_0, loc_1 + 4, add_i32(loc_1, 15))
			store_i32(memory_at_0, loc_1 + 8, loc_1)
			FUNC_LIST[83](add_i32(loc_0, 512), 1, add_i32(loc_1, 8), 1066684)
			break
		end
		GLOBAL_LIST[0].value = add_i32(loc_1, 16)
		break
	end
end
FUNC_LIST[86] = --[[ _ZN3std4sync9once_lock17OnceLock$LT$T$GT$10initialize17h1e86b2993cde406bE ]] function(loc_0)
	local loc_1 = 0
	while true do
		loc_1 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_1
		while true do
			if load_i32_u8(memory_at_0, loc_0 + 12) == 3 then
				break
			end
			store_i32(memory_at_0, loc_1, loc_0)
			store_i32(memory_at_0, loc_1 + 4, add_i32(loc_1, 15))
			store_i32(memory_at_0, loc_1 + 8, loc_1)
			FUNC_LIST[79](add_i32(loc_0, 12), 1, add_i32(loc_1, 8), 1066684)
			break
		end
		GLOBAL_LIST[0].value = add_i32(loc_1, 16)
		break
	end
end
FUNC_LIST[87] = --[[ _ZN3std4sync9once_lock17OnceLock$LT$T$GT$10initialize17h29d4a56f244c579bE ]] function(loc_0)
	local loc_1 = 0
	while true do
		loc_1 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_1
		while true do
			if load_i32_u8(memory_at_0, loc_0 + 512) == 3 then
				break
			end
			store_i32(memory_at_0, loc_1, loc_0)
			store_i32(memory_at_0, loc_1 + 4, add_i32(loc_1, 15))
			store_i32(memory_at_0, loc_1 + 8, loc_1)
			FUNC_LIST[81](add_i32(loc_0, 512), 1, add_i32(loc_1, 8), 1066684)
			break
		end
		GLOBAL_LIST[0].value = add_i32(loc_1, 16)
		break
	end
end
FUNC_LIST[88] = --[[ _ZN3std4sync9once_lock17OnceLock$LT$T$GT$10initialize17h44b0ad74ea16cd4eE ]] function(loc_0)
	local loc_1 = 0
	while true do
		loc_1 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_1
		while true do
			if load_i32_u8(memory_at_0, loc_0 + 512) == 3 then
				break
			end
			store_i32(memory_at_0, loc_1, loc_0)
			store_i32(memory_at_0, loc_1 + 4, add_i32(loc_1, 15))
			store_i32(memory_at_0, loc_1 + 8, loc_1)
			FUNC_LIST[78](add_i32(loc_0, 512), 1, add_i32(loc_1, 8), 1066684)
			break
		end
		GLOBAL_LIST[0].value = add_i32(loc_1, 16)
		break
	end
end
FUNC_LIST[89] = --[[ _ZN3std4sync9once_lock17OnceLock$LT$T$GT$10initialize17ha60d617239fb9c28E ]] function(loc_0)
	local loc_1 = 0
	while true do
		loc_1 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_1
		while true do
			if load_i32_u8(memory_at_0, loc_0 + 12) == 3 then
				break
			end
			store_i32(memory_at_0, loc_1, loc_0)
			store_i32(memory_at_0, loc_1 + 4, add_i32(loc_1, 15))
			store_i32(memory_at_0, loc_1 + 8, loc_1)
			FUNC_LIST[84](add_i32(loc_0, 12), 1, add_i32(loc_1, 8), 1066684)
			break
		end
		GLOBAL_LIST[0].value = add_i32(loc_1, 16)
		break
	end
end
FUNC_LIST[90] = --[[ _ZN3std4sync9once_lock17OnceLock$LT$T$GT$10initialize17hb0d226e22a9b8b44E ]] function(loc_0)
	local loc_1 = 0
	while true do
		loc_1 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_1
		while true do
			if load_i32_u8(memory_at_0, loc_0 + 4160) == 3 then
				break
			end
			store_i32(memory_at_0, loc_1, loc_0)
			store_i32(memory_at_0, loc_1 + 4, add_i32(loc_1, 15))
			store_i32(memory_at_0, loc_1 + 8, loc_1)
			FUNC_LIST[80](add_i32(loc_0, 4160), 1, add_i32(loc_1, 8), 1066684)
			break
		end
		GLOBAL_LIST[0].value = add_i32(loc_1, 16)
		break
	end
end
FUNC_LIST[91] = --[[ _ZN3std4sync9once_lock17OnceLock$LT$T$GT$10initialize17hbfa316e3d2057d2bE ]] function(loc_0)
	local loc_1 = 0
	while true do
		loc_1 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_1
		while true do
			if load_i32_u8(memory_at_0, loc_0 + 1024) == 3 then
				break
			end
			store_i32(memory_at_0, loc_1, loc_0)
			store_i32(memory_at_0, loc_1 + 4, add_i32(loc_1, 15))
			store_i32(memory_at_0, loc_1 + 8, loc_1)
			FUNC_LIST[77](add_i32(loc_0, 1024), 1, add_i32(loc_1, 8), 1066684)
			break
		end
		GLOBAL_LIST[0].value = add_i32(loc_1, 16)
		break
	end
end
FUNC_LIST[92] = --[[ _ZN3std4sync9once_lock17OnceLock$LT$T$GT$10initialize17hcf0936f5a5bfa677E ]] function(loc_0)
	local loc_1 = 0
	while true do
		loc_1 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_1
		while true do
			if load_i32_u8(memory_at_0, loc_0 + 512) == 3 then
				break
			end
			store_i32(memory_at_0, loc_1, loc_0)
			store_i32(memory_at_0, loc_1 + 4, add_i32(loc_1, 15))
			store_i32(memory_at_0, loc_1 + 8, loc_1)
			FUNC_LIST[82](add_i32(loc_0, 512), 1, add_i32(loc_1, 8), 1066684)
			break
		end
		GLOBAL_LIST[0].value = add_i32(loc_1, 16)
		break
	end
end
FUNC_LIST[93] = --[[ _ZN5alloc3vec16Vec$LT$T$C$A$GT$11extend_with17h6750a49a8f693c3aE ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = 0
	local loc_8 = 0
	local loc_9 = 0
	local loc_10 = i64_ZERO
	local loc_11 = 0
	local loc_12 = i64_ZERO
	local desired
	while true do
		while true do
			loc_3 = load_i32(memory_at_0, loc_0 + 8)
			if sub_i32(load_i32(memory_at_0, loc_0), loc_3) >= loc_1 then
				break
			end
			FUNC_LIST[61](loc_0, loc_3, loc_1)
			loc_3 = load_i32(memory_at_0, loc_0 + 8)
			break
		end
		loc_4 = add_i32(load_i32(memory_at_0, loc_0 + 4), mul_i32(loc_3, 24))
		while true do
			if loc_1 < 2 then
				break
			end
			loc_5 = add_i32(loc_3, loc_1)
			while true do
				loc_3 = load_i32_u8(memory_at_0, loc_2 + 16)
				if loc_3 == 3 then
					break
				end
				loc_6 = add_i32(loc_2, 17)
				loc_7 = add_i32(loc_1, 4294967295)
				loc_8 = band_i32(loc_7, 1)
				while true do
					if loc_1 == 2 then
						break
					end
					loc_7 = band_i32(loc_7, 4294967294)
					loc_9 = add_i32(loc_6, 3)
					while true do
						store_i32_n8(memory_at_0, loc_4 + 16, loc_3)
						loc_10 = load_i64(memory_at_0, loc_2)
						store_i64(memory_at_0, loc_4, loc_10)
						loc_11 = load_i32(memory_at_0, loc_6)
						store_i32(memory_at_0, loc_4 + 17, loc_11)
						store_i64(memory_at_0, add_i32(loc_4, 24), loc_10)
						store_i32_n8(memory_at_0, add_i32(loc_4, 40), loc_3)
						store_i32(memory_at_0, add_i32(loc_4, 41), loc_11)
						loc_10 = load_i64(memory_at_0, add_i32(loc_2, 8))
						store_i64(memory_at_0, add_i32(loc_4, 8), loc_10)
						loc_11 = load_i32(memory_at_0, loc_9)
						store_i32(memory_at_0, add_i32(loc_4, 20), loc_11)
						store_i64(memory_at_0, add_i32(loc_4, 32), loc_10)
						store_i32(memory_at_0, add_i32(loc_4, 44), loc_11)
						loc_4 = add_i32(loc_4, 48)
						loc_7 = add_i32(loc_7, 4294967294)
						if loc_7 ~= 0 then
							continue
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				while true do
					if loc_8 == 0 then
						break
					end
					loc_10 = load_i64(memory_at_0, add_i32(loc_2, 8))
					loc_12 = load_i64(memory_at_0, loc_2)
					store_i32_n8(memory_at_0, loc_4 + 16, loc_3)
					store_i64(memory_at_0, loc_4, loc_12)
					store_i64(memory_at_0, add_i32(loc_4, 8), loc_10)
					store_i32(memory_at_0, loc_4 + 17, load_i32(memory_at_0, loc_6))
					store_i32(memory_at_0, add_i32(loc_4, 20), load_i32(memory_at_0, add_i32(loc_6, 3)))
					loc_4 = add_i32(loc_4, 24)
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_3 = add_i32(loc_5, 4294967295)
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_7 = add_i32(loc_1, 4294967295)
			loc_3 = band_i32(loc_7, 7)
			while true do
				if add_i32(loc_1, 4294967294) < 7 then
					break
				end
				loc_7 = band_i32(loc_7, 4294967288)
				while true do
					store_i32_n8(memory_at_0, loc_4 + 16, 3)
					store_i32_n8(memory_at_0, add_i32(loc_4, 184), 3)
					store_i32_n8(memory_at_0, add_i32(loc_4, 160), 3)
					store_i32_n8(memory_at_0, add_i32(loc_4, 136), 3)
					store_i32_n8(memory_at_0, add_i32(loc_4, 112), 3)
					store_i32_n8(memory_at_0, add_i32(loc_4, 88), 3)
					store_i32_n8(memory_at_0, add_i32(loc_4, 64), 3)
					store_i32_n8(memory_at_0, add_i32(loc_4, 40), 3)
					loc_4 = add_i32(loc_4, 192)
					loc_7 = add_i32(loc_7, 4294967288)
					if loc_7 ~= 0 then
						continue
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				if loc_3 == 0 then
					break
				end
				while true do
					store_i32_n8(memory_at_0, loc_4 + 16, 3)
					loc_4 = add_i32(loc_4, 24)
					loc_3 = add_i32(loc_3, 4294967295)
					if loc_3 ~= 0 then
						continue
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_3 = add_i32(loc_5, 4294967295)
			break
		end
		while true do
			if loc_1 == 0 then
				break
			end
			store_i64(memory_at_0, loc_4, load_i64(memory_at_0, loc_2))
			store_i64(memory_at_0, add_i32(loc_4, 16), load_i64(memory_at_0, add_i32(loc_2, 16)))
			store_i64(memory_at_0, add_i32(loc_4, 8), load_i64(memory_at_0, add_i32(loc_2, 8)))
			loc_3 = add_i32(loc_3, 1)
			break
		end
		store_i32(memory_at_0, loc_0 + 8, loc_3)
		break
	end
end
FUNC_LIST[94] = --[[ _ZN6engine6search4eval4Eval8evaluate17h09207dae99fe7ff7E ]] function(loc_0)
	local loc_1 = 0
	local loc_2 = i64_ZERO
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local reg_0
	local desired
	while true do
		while true do
			while true do
				loc_1 = load_i32(memory_at_0, loc_0 + 24)
				loc_2 = load_i64(memory_at_0, loc_1 + 32)
				if (if eq_i64(loc_2, i64_ZERO) then 1 else 0) == 0 then
					break
				end
				loc_0 = 0
				loc_3 = 0
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_3 = 0
			loc_0 = 0
			while true do
				loc_4 = shl_i32(bxor_i32(wrap_i32_i64(ctz_i64(loc_2)), 56), 2)
				loc_0 = add_i32(load_i32(memory_at_0, add_i32(loc_4, 1068236)), loc_0)
				loc_3 = add_i32(load_i32(memory_at_0, add_i32(loc_4, 1066700)), loc_3)
				loc_2 = band_i64(add_i64(loc_2, i64_from_u32(4294967295, 4294967295)), loc_2)
				if (if eq_i64(loc_2, i64_ZERO) then 1 else 0) == 0 then
					continue
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			break
		end
		while true do
			loc_2 = load_i64(memory_at_0, add_i32(loc_1, 40))
			if eq_i64(loc_2, i64_ZERO) then
				break
			end
			while true do
				loc_4 = shl_i32(bxor_i32(wrap_i32_i64(ctz_i64(loc_2)), 56), 2)
				loc_0 = add_i32(load_i32(memory_at_0, add_i32(loc_4, 1068492)), loc_0)
				loc_3 = add_i32(load_i32(memory_at_0, add_i32(loc_4, 1066956)), loc_3)
				loc_2 = band_i64(add_i64(loc_2, i64_from_u32(4294967295, 4294967295)), loc_2)
				if ne_i64(loc_2, i64_ZERO) then
					continue
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			break
		end
		while true do
			loc_2 = load_i64(memory_at_0, add_i32(loc_1, 48))
			if eq_i64(loc_2, i64_ZERO) then
				break
			end
			while true do
				loc_4 = shl_i32(bxor_i32(wrap_i32_i64(ctz_i64(loc_2)), 56), 2)
				loc_0 = add_i32(load_i32(memory_at_0, add_i32(loc_4, 1068748)), loc_0)
				loc_3 = add_i32(load_i32(memory_at_0, add_i32(loc_4, 1067212)), loc_3)
				loc_2 = band_i64(add_i64(loc_2, i64_from_u32(4294967295, 4294967295)), loc_2)
				if ne_i64(loc_2, i64_ZERO) then
					continue
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			break
		end
		while true do
			loc_2 = load_i64(memory_at_0, add_i32(loc_1, 56))
			if eq_i64(loc_2, i64_ZERO) then
				break
			end
			while true do
				loc_4 = shl_i32(bxor_i32(wrap_i32_i64(ctz_i64(loc_2)), 56), 2)
				loc_0 = add_i32(load_i32(memory_at_0, add_i32(loc_4, 1069004)), loc_0)
				loc_3 = add_i32(load_i32(memory_at_0, add_i32(loc_4, 1067468)), loc_3)
				loc_2 = band_i64(add_i64(loc_2, i64_from_u32(4294967295, 4294967295)), loc_2)
				if ne_i64(loc_2, i64_ZERO) then
					continue
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			break
		end
		while true do
			loc_2 = load_i64(memory_at_0, add_i32(loc_1, 64))
			if eq_i64(loc_2, i64_ZERO) then
				break
			end
			while true do
				loc_4 = shl_i32(bxor_i32(wrap_i32_i64(ctz_i64(loc_2)), 56), 2)
				loc_0 = add_i32(load_i32(memory_at_0, add_i32(loc_4, 1069260)), loc_0)
				loc_3 = add_i32(load_i32(memory_at_0, add_i32(loc_4, 1067724)), loc_3)
				loc_2 = band_i64(add_i64(loc_2, i64_from_u32(4294967295, 4294967295)), loc_2)
				if ne_i64(loc_2, i64_ZERO) then
					continue
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			break
		end
		while true do
			loc_2 = load_i64(memory_at_0, add_i32(loc_1, 72))
			if eq_i64(loc_2, i64_ZERO) then
				break
			end
			while true do
				loc_4 = shl_i32(bxor_i32(wrap_i32_i64(ctz_i64(loc_2)), 56), 2)
				loc_0 = add_i32(load_i32(memory_at_0, add_i32(loc_4, 1069516)), loc_0)
				loc_3 = add_i32(load_i32(memory_at_0, add_i32(loc_4, 1067980)), loc_3)
				loc_2 = band_i64(add_i64(loc_2, i64_from_u32(4294967295, 4294967295)), loc_2)
				if (if eq_i64(loc_2, i64_ZERO) then 1 else 0) == 0 then
					continue
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			break
		end
		while true do
			while true do
				loc_2 = load_i64(memory_at_0, add_i32(loc_1, 80))
				if (if eq_i64(loc_2, i64_ZERO) then 1 else 0) == 0 then
					break
				end
				loc_4 = 0
				loc_5 = 0
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_5 = 0
			loc_4 = 0
			while true do
				loc_6 = shl_i32(wrap_i32_i64(ctz_i64(loc_2)), 2)
				loc_5 = add_i32(load_i32(memory_at_0, add_i32(loc_6, 1068236)), loc_5)
				loc_4 = add_i32(load_i32(memory_at_0, add_i32(loc_6, 1066700)), loc_4)
				loc_2 = band_i64(add_i64(loc_2, i64_from_u32(4294967295, 4294967295)), loc_2)
				if (if eq_i64(loc_2, i64_ZERO) then 1 else 0) == 0 then
					continue
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			break
		end
		while true do
			loc_2 = load_i64(memory_at_0, add_i32(loc_1, 88))
			if eq_i64(loc_2, i64_ZERO) then
				break
			end
			while true do
				loc_6 = shl_i32(wrap_i32_i64(ctz_i64(loc_2)), 2)
				loc_5 = add_i32(load_i32(memory_at_0, add_i32(loc_6, 1068492)), loc_5)
				loc_4 = add_i32(load_i32(memory_at_0, add_i32(loc_6, 1066956)), loc_4)
				loc_2 = band_i64(add_i64(loc_2, i64_from_u32(4294967295, 4294967295)), loc_2)
				if ne_i64(loc_2, i64_ZERO) then
					continue
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			break
		end
		while true do
			loc_2 = load_i64(memory_at_0, add_i32(loc_1, 96))
			if eq_i64(loc_2, i64_ZERO) then
				break
			end
			while true do
				loc_6 = shl_i32(wrap_i32_i64(ctz_i64(loc_2)), 2)
				loc_5 = add_i32(load_i32(memory_at_0, add_i32(loc_6, 1068748)), loc_5)
				loc_4 = add_i32(load_i32(memory_at_0, add_i32(loc_6, 1067212)), loc_4)
				loc_2 = band_i64(add_i64(loc_2, i64_from_u32(4294967295, 4294967295)), loc_2)
				if ne_i64(loc_2, i64_ZERO) then
					continue
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			break
		end
		while true do
			loc_2 = load_i64(memory_at_0, add_i32(loc_1, 104))
			if eq_i64(loc_2, i64_ZERO) then
				break
			end
			while true do
				loc_6 = shl_i32(wrap_i32_i64(ctz_i64(loc_2)), 2)
				loc_5 = add_i32(load_i32(memory_at_0, add_i32(loc_6, 1069004)), loc_5)
				loc_4 = add_i32(load_i32(memory_at_0, add_i32(loc_6, 1067468)), loc_4)
				loc_2 = band_i64(add_i64(loc_2, i64_from_u32(4294967295, 4294967295)), loc_2)
				if ne_i64(loc_2, i64_ZERO) then
					continue
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			break
		end
		while true do
			loc_2 = load_i64(memory_at_0, add_i32(loc_1, 112))
			if eq_i64(loc_2, i64_ZERO) then
				break
			end
			while true do
				loc_6 = shl_i32(wrap_i32_i64(ctz_i64(loc_2)), 2)
				loc_5 = add_i32(load_i32(memory_at_0, add_i32(loc_6, 1069260)), loc_5)
				loc_4 = add_i32(load_i32(memory_at_0, add_i32(loc_6, 1067724)), loc_4)
				loc_2 = band_i64(add_i64(loc_2, i64_from_u32(4294967295, 4294967295)), loc_2)
				if ne_i64(loc_2, i64_ZERO) then
					continue
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			break
		end
		while true do
			loc_2 = load_i64(memory_at_0, add_i32(loc_1, 120))
			if eq_i64(loc_2, i64_ZERO) then
				break
			end
			while true do
				loc_6 = shl_i32(wrap_i32_i64(ctz_i64(loc_2)), 2)
				loc_5 = add_i32(load_i32(memory_at_0, add_i32(loc_6, 1069516)), loc_5)
				loc_4 = add_i32(load_i32(memory_at_0, add_i32(loc_6, 1067980)), loc_4)
				loc_2 = band_i64(add_i64(loc_2, i64_from_u32(4294967295, 4294967295)), loc_2)
				if ne_i64(loc_2, i64_ZERO) then
					continue
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			break
		end
		loc_6 = add_i32(shl_i32(wrap_i32_i64(popcnt_i64(load_i64(memory_at_0, add_i32(loc_1, 112)))), 2), add_i32(shl_i32(wrap_i32_i64(popcnt_i64(load_i64(memory_at_0, add_i32(loc_1, 104)))), 1), add_i32(add_i32(add_i32(shl_i32(wrap_i32_i64(popcnt_i64(load_i64(memory_at_0, add_i32(loc_1, 64)))), 2), add_i32(shl_i32(wrap_i32_i64(popcnt_i64(load_i64(memory_at_0, add_i32(loc_1, 56)))), 1), add_i32(wrap_i32_i64(popcnt_i64(load_i64(memory_at_0, add_i32(loc_1, 48)))), wrap_i32_i64(popcnt_i64(load_i64(memory_at_0, add_i32(loc_1, 40))))))), wrap_i32_i64(popcnt_i64(load_i64(memory_at_0, add_i32(loc_1, 88))))), wrap_i32_i64(popcnt_i64(load_i64(memory_at_0, add_i32(loc_1, 96)))))))
		loc_6 = (if lt_i32(loc_6, 24) then loc_6 else 24)
		loc_0 = div_i32(add_i32(mul_i32(sub_i32(24, loc_6), sub_i32(loc_0, loc_5)), mul_i32(loc_6, sub_i32(loc_3, loc_4))), 24)
		reg_0 = (if load_i32_u8(memory_at_0, loc_1 + 140) ~= 0 then loc_0 else sub_i32(0, loc_0))
		break
	end
	return reg_0
end
FUNC_LIST[95] = --[[ _ZN42_$LT$$RF$T$u20$as$u20$core..fmt..Debug$GT$3fmt17h234413ee19246975E ]] function(loc_0, loc_1)
	local reg_0
	while true do
		reg_0 = FUNC_LIST[235](load_i32(memory_at_0, loc_0), load_i32(memory_at_0, loc_0 + 4), loc_1)
		break
	end
	return reg_0
end
FUNC_LIST[96] = --[[ _ZN42_$LT$$RF$T$u20$as$u20$core..fmt..Debug$GT$3fmt17h84a4b542545dd42eE ]] function(loc_0, loc_1)
	local reg_0
	while true do
		loc_0 = shl_i32(load_i32_u8(memory_at_0, load_i32(memory_at_0, loc_0)), 2)
		reg_0 = FUNC_LIST[229](loc_1, load_i32(memory_at_0, add_i32(loc_0, 1070344)), load_i32(memory_at_0, add_i32(loc_0, 1070324)))
		break
	end
	return reg_0
end
FUNC_LIST[97] = --[[ _ZN4core3ops8function6FnOnce40call_once$u7b$$u7b$vtable.shim$u7d$$u7d$17h33b5efa3c987facfE.llvm.16079275652155140001 ]] function(loc_0, loc_1)
	while true do
		FUNC_LIST[98](loc_0, loc_1)
		break
	end
end
FUNC_LIST[98] = --[[ _ZN6engine6search13move_ordering11MoveOrderer30get_sorted_moves_captures_only28_$u7b$$u7b$closure$u7d$$u7d$17h76d8b06fadbb6c63E.llvm.16079275652155140001 ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = i64_ZERO
	local loc_8 = 0
	local desired
	local br_map = {}
	while true do
		loc_2 = band_i32(loc_1, 16777215)
		loc_3 = shr_u32(loc_2, 16)
		loc_4 = shr_u32(loc_2, 8)
		loc_2 = load_i32(memory_at_0, add_i32(load_i32(memory_at_0, loc_0 + 8), 24))
		loc_5 = 0
		while true do
			while true do
				while true do
					while true do
						while true do
							while true do
								while true do
									while true do
										while true do
											loc_6 = band_i32(loc_1, 255)
											if not br_map[1] then
												br_map[1] = (function()
													return { [0] = 4, 1, 2, 2, 3, 5, }
												end)()
											end
											temp = br_map[1][loc_6] or 0
											if temp < 3 then
												if temp < 1 then
													break
												elseif temp > 1 then
													desired = 7
													break
												else
													desired = 8
													break
												end
											elseif temp > 3 then
												if temp < 5 then
													desired = 5
													break
												else
													desired = 4
													break
												end
											else
												desired = 6
												break
											end
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										FUNC_LIST[192](1070196, 40, 1070236)
										error("out of code bounds")
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									loc_6 = 1900
									desired = 5
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								loc_6 = 1400
								desired = 5
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_6 = 1500
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_7 = shl_i64(i64_ONE, extend_i64_u32(loc_4))
						while true do
							while true do
								if load_i32_u8(memory_at_0, loc_2 + 140) ~= 0 then
									break
								end
								loc_5 = 6
								while true do
									if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_2, 80)), loc_7), i64_ZERO) then
										break
									end
									loc_5 = 7
									if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_2, 88)), loc_7), i64_ZERO) then
										break
									end
									loc_5 = 8
									if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_2, 96)), loc_7), i64_ZERO) then
										break
									end
									loc_5 = 9
									if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_2, 104)), loc_7), i64_ZERO) then
										break
									end
									loc_5 = 10
									if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_2, 112)), loc_7), i64_ZERO) then
										break
									end
									loc_5 = 11
									if eq_i64(band_i64(load_i64(memory_at_0, add_i32(loc_2, 120)), loc_7), i64_ZERO) then
										desired = 3
										break
									end
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								loc_8 = 0
								loc_7 = shl_i64(i64_ONE, extend_i64_u32(loc_3))
								if ne_i64(band_i64(load_i64(memory_at_0, loc_2 + 32), loc_7), i64_ZERO) then
									desired = 5
									break
								end
								loc_8 = 1
								if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_2, 40)), loc_7), i64_ZERO) then
									desired = 5
									break
								end
								loc_8 = 2
								if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_2, 48)), loc_7), i64_ZERO) then
									desired = 5
									break
								end
								loc_8 = 3
								if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_2, 56)), loc_7), i64_ZERO) then
									desired = 5
									break
								end
								loc_8 = 4
								if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_2, 64)), loc_7), i64_ZERO) then
									desired = 5
									break
								end
								loc_8 = 5
								if (if eq_i64(band_i64(load_i64(memory_at_0, add_i32(loc_2, 72)), loc_7), i64_ZERO) then 1 else 0) == 0 then
									desired = 5
									break
								end
								desired = 1
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_5 = 0
							while true do
								if ne_i64(band_i64(load_i64(memory_at_0, loc_2 + 32), loc_7), i64_ZERO) then
									break
								end
								loc_5 = 1
								if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_2, 40)), loc_7), i64_ZERO) then
									break
								end
								loc_5 = 2
								if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_2, 48)), loc_7), i64_ZERO) then
									break
								end
								loc_5 = 3
								if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_2, 56)), loc_7), i64_ZERO) then
									break
								end
								loc_5 = 4
								if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_2, 64)), loc_7), i64_ZERO) then
									break
								end
								loc_5 = 5
								if eq_i64(band_i64(load_i64(memory_at_0, add_i32(loc_2, 72)), loc_7), i64_ZERO) then
									desired = 3
									break
								end
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_8 = 6
							loc_7 = shl_i64(i64_ONE, extend_i64_u32(loc_3))
							if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_2, 80)), loc_7), i64_ZERO) then
								break
							end
							loc_8 = 7
							if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_2, 88)), loc_7), i64_ZERO) then
								break
							end
							loc_8 = 8
							if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_2, 96)), loc_7), i64_ZERO) then
								break
							end
							loc_8 = 9
							if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_2, 104)), loc_7), i64_ZERO) then
								break
							end
							loc_8 = 10
							if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_2, 112)), loc_7), i64_ZERO) then
								break
							end
							loc_8 = 11
							if eq_i64(band_i64(load_i64(memory_at_0, add_i32(loc_2, 120)), loc_7), i64_ZERO) then
								desired = 1
								break
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_5 = sub_i32(add_i32(load_i32(memory_at_0, add_i32(shl_i32(loc_8, 2), 1070052)), loc_6), load_i32(memory_at_0, add_i32(shl_i32(loc_5, 2), 1070052)))
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_2 = load_i32(memory_at_0, loc_0 + 4)
					loc_6 = load_i32(memory_at_0, loc_2)
					if loc_6 > 73 then
						desired = 2
						break
					end
					loc_0 = add_i32(load_i32(memory_at_0, loc_0), shl_i32(loc_6, 3))
					store_i32(memory_at_0, loc_0, loc_5)
					store_i32_n16(memory_at_0, loc_0 + 4, bor_i32(bor_i32(shl_i32(loc_1, 12), extend_i32_n8(loc_4)), shl_i32(extend_i32_n8(loc_3), 6)))
					store_i32(memory_at_0, loc_2, add_i32(load_i32(memory_at_0, loc_2), 1))
					desired = 0
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[192](1069992, 43, 1070164)
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[189](loc_6, 74, 1070272)
			error("out of code bounds")
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		FUNC_LIST[192](1069992, 43, 1070180)
		error("out of code bounds")
	end
end
FUNC_LIST[99] = --[[ _ZN4core3ops8function6FnOnce40call_once$u7b$$u7b$vtable.shim$u7d$$u7d$17h48efa3117e6bcc00E.llvm.16079275652155140001 ]] function(loc_0, loc_1)
	while true do
		FUNC_LIST[100](loc_0, loc_1)
		break
	end
end
FUNC_LIST[100] = --[[ _ZN6engine5perft10perft_root28_$u7b$$u7b$closure$u7d$$u7d$17h6803c1d1aca648e1E.llvm.16079275652155140001 ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local desired
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 176)
		GLOBAL_LIST[0].value = loc_2
		store_i32_n16(memory_at_0, loc_2, loc_1)
		store_i32_n8(memory_at_0, loc_2 + 2, shr_u32(loc_1, 16))
		loc_3 = 1
		while true do
			while true do
				loc_4 = load_i32(memory_at_0, loc_0)
				if load_i32_u16(memory_at_0, loc_4) ~= 1 then
					break
				end
				loc_3 = load_i32(memory_at_0, load_i32(memory_at_0, loc_0 + 4))
				FUNC_LIST[31](add_i32(loc_2, 20), loc_1)
				store_i64(memory_at_0, add_i32(loc_2, 60), i64_ONE)
				store_i32(memory_at_0, loc_2 + 12, 38)
				store_i32(memory_at_0, loc_2 + 52, 2)
				store_i32(memory_at_0, loc_2 + 48, 1069860)
				store_i32(memory_at_0, loc_2 + 8, add_i32(loc_2, 20))
				store_i32(memory_at_0, loc_2 + 56, add_i32(loc_2, 8))
				FUNC_LIST[178](add_i32(loc_2, 36), add_i32(loc_2, 48))
				while true do
					loc_1 = load_i32(memory_at_0, loc_2 + 20)
					if loc_1 == 0 then
						break
					end
					FUNC_LIST[22](load_i32(memory_at_0, loc_2 + 24), loc_1, 1)
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_1 = load_i32(memory_at_0, loc_2 + 36)
				loc_4 = load_i32(memory_at_0, loc_2 + 40)
				TABLE_LIST[0].data[loc_3](loc_4, load_i32(memory_at_0, loc_2 + 44))
				while true do
					if loc_1 == 0 then
						break
					end
					FUNC_LIST[22](loc_4, loc_1, 1)
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_0 = load_i32(memory_at_0, loc_0 + 8)
				store_i32(memory_at_0, loc_0, add_i32(load_i32(memory_at_0, loc_0), 1))
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_1 = load_i32(memory_at_0, loc_0 + 12)
			FUNC_LIST[51](loc_1, loc_2)
			loc_4 = add_i32(load_i32_u16(memory_at_0, loc_4), 4294967295)
			store_i32_n16(memory_at_0, loc_2 + 8, loc_4)
			while true do
				if band_i32(loc_4, 65535) == 0 then
					break
				end
				store_i32(memory_at_0, loc_2 + 36, 0)
				FUNC_LIST[53](add_i32(loc_2, 48), loc_1)
				store_i32(memory_at_0, loc_2 + 28, loc_1)
				store_i32(memory_at_0, loc_2 + 24, add_i32(loc_2, 36))
				store_i32(memory_at_0, loc_2 + 20, add_i32(loc_2, 8))
				FUNC_LIST[54](add_i32(loc_2, 48), add_i32(loc_2, 20), 1069816, 0)
				loc_3 = load_i32(memory_at_0, loc_2 + 36)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			store_i32(memory_at_0, loc_2 + 4, loc_3)
			loc_4 = load_i32(memory_at_0, loc_0 + 8)
			store_i32(memory_at_0, loc_4, add_i32(load_i32(memory_at_0, loc_4), loc_3))
			loc_3 = load_i32(memory_at_0, load_i32(memory_at_0, loc_0 + 4))
			FUNC_LIST[31](add_i32(loc_2, 36), bor_i32(load_i32_u16(memory_at_0, loc_2), shl_i32(load_i32_u8(memory_at_0, loc_2 + 2), 16)))
			store_i32(memory_at_0, add_i32(add_i32(loc_2, 20), 12), 18)
			store_i64(memory_at_0, add_i32(add_i32(loc_2, 48), 12), i64_from_u32(2, 0))
			store_i32(memory_at_0, loc_2 + 24, 38)
			store_i32(memory_at_0, loc_2 + 52, 2)
			store_i32(memory_at_0, loc_2 + 48, 1069880)
			store_i32(memory_at_0, loc_2 + 28, add_i32(loc_2, 4))
			store_i32(memory_at_0, loc_2 + 20, add_i32(loc_2, 36))
			store_i32(memory_at_0, loc_2 + 56, add_i32(loc_2, 20))
			FUNC_LIST[178](add_i32(loc_2, 8), add_i32(loc_2, 48))
			while true do
				loc_0 = load_i32(memory_at_0, loc_2 + 36)
				if loc_0 == 0 then
					break
				end
				FUNC_LIST[22](load_i32(memory_at_0, loc_2 + 40), loc_0, 1)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_0 = load_i32(memory_at_0, loc_2 + 8)
			loc_4 = load_i32(memory_at_0, loc_2 + 12)
			TABLE_LIST[0].data[loc_3](loc_4, load_i32(memory_at_0, loc_2 + 16))
			while true do
				if loc_0 == 0 then
					break
				end
				FUNC_LIST[22](loc_4, loc_0, 1)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[52](loc_1, loc_2)
			break
		end
		GLOBAL_LIST[0].value = add_i32(loc_2, 176)
		break
	end
end
FUNC_LIST[101] = --[[ _ZN4core3ops8function6FnOnce40call_once$u7b$$u7b$vtable.shim$u7d$$u7d$17h539da048eedee8c9E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local desired
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 160)
		GLOBAL_LIST[0].value = loc_2
		store_i32_n16(memory_at_0, loc_2 + 4, loc_1)
		store_i32_n8(memory_at_0, loc_2 + 6, shr_u32(loc_1, 16))
		loc_1 = 1
		while true do
			while true do
				loc_3 = load_i32(memory_at_0, loc_0)
				if load_i32_u16(memory_at_0, loc_3) ~= 1 then
					break
				end
				loc_0 = load_i32(memory_at_0, loc_0 + 4)
				store_i32(memory_at_0, loc_0, add_i32(load_i32(memory_at_0, loc_0), 1))
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_4 = load_i32(memory_at_0, loc_0 + 8)
			FUNC_LIST[51](loc_4, add_i32(loc_2, 4))
			loc_3 = add_i32(load_i32_u16(memory_at_0, loc_3), 4294967295)
			store_i32_n16(memory_at_0, loc_2 + 10, loc_3)
			while true do
				if band_i32(loc_3, 65535) == 0 then
					break
				end
				store_i32(memory_at_0, loc_2 + 12, 0)
				FUNC_LIST[53](add_i32(loc_2, 16), loc_4)
				store_i32(memory_at_0, loc_2 + 156, loc_4)
				store_i32(memory_at_0, loc_2 + 152, add_i32(loc_2, 12))
				store_i32(memory_at_0, loc_2 + 148, add_i32(loc_2, 10))
				FUNC_LIST[54](add_i32(loc_2, 16), add_i32(loc_2, 148), 1069816, 0)
				loc_1 = load_i32(memory_at_0, loc_2 + 12)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_0 = load_i32(memory_at_0, loc_0 + 4)
			store_i32(memory_at_0, loc_0, add_i32(load_i32(memory_at_0, loc_0), loc_1))
			FUNC_LIST[52](loc_4, add_i32(loc_2, 4))
			break
		end
		GLOBAL_LIST[0].value = add_i32(loc_2, 160)
		break
	end
end
FUNC_LIST[102] = --[[ _ZN4core3ops8function6FnOnce40call_once$u7b$$u7b$vtable.shim$u7d$$u7d$17hd9f125de0f6af48fE.llvm.16079275652155140001 ]] function(loc_0, loc_1)
	while true do
		FUNC_LIST[103](loc_0, loc_1)
		break
	end
end
FUNC_LIST[103] = --[[ _ZN6engine6search13move_ordering11MoveOrderer16get_sorted_moves28_$u7b$$u7b$closure$u7d$$u7d$17hf5d1e87e28976c42E.llvm.16079275652155140001 ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = 0
	local loc_8 = 0
	local loc_9 = i64_ZERO
	local loc_10 = i64_ZERO
	local loc_11 = 0
	local loc_12 = 0
	local desired
	local br_map = {}
	while true do
		loc_2 = 100000
		while true do
			loc_3 = band_i32(loc_1, 16777215)
			loc_4 = shr_u32(loc_3, 8)
			loc_5 = extend_i32_n8(loc_4)
			loc_6 = shr_u32(loc_3, 16)
			loc_7 = extend_i32_n8(loc_6)
			loc_3 = bor_i32(bor_i32(shl_i32(loc_1, 12), loc_5), shl_i32(loc_7, 6))
			if band_i32(loc_3, 65535) == load_i32_u16(memory_at_0, load_i32(memory_at_0, loc_0 + 8)) then
				break
			end
			loc_8 = load_i32(memory_at_0, loc_0 + 12)
			loc_2 = 2800
			while true do
				while true do
					while true do
						while true do
							while true do
								while true do
									while true do
										while true do
											while true do
												while true do
													if not br_map[1] then
														br_map[1] = (function()
															return { [0] = 0, 8, 2, 2, 1, 3, 0, 6, }
														end)()
													end
													temp = br_map[1][band_i32(loc_1, 7)] or 0
													if temp < 3 then
														if temp < 1 then
															break
														elseif temp > 1 then
															desired = 9
															break
														else
															desired = 10
															break
														end
													elseif temp > 3 then
														if temp < 8 then
															desired = 5
															break
														else
															desired = 3
															break
														end
													else
														desired = 8
														break
													end
												end
												if desired then
													if desired == 10 then
														desired = nil
													end
													break
												end
												loc_9 = load_i64(memory_at_0, load_i32(memory_at_0, loc_0 + 16) + 112)
												loc_10 = shl_i64(i64_ONE, extend_i64_u32(loc_4))
												while true do
													while true do
														loc_1 = load_i32(memory_at_0, loc_8 + 24)
														loc_11 = load_i32_u8(memory_at_0, loc_1 + 140)
														if loc_11 ~= 0 then
															break
														end
														loc_2 = 6
														while true do
															if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_1, 80)), loc_10), i64_ZERO) then
																break
															end
															loc_2 = 7
															if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_1, 88)), loc_10), i64_ZERO) then
																break
															end
															loc_2 = 8
															if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_1, 96)), loc_10), i64_ZERO) then
																break
															end
															loc_2 = 9
															if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_1, 104)), loc_10), i64_ZERO) then
																break
															end
															loc_2 = 10
															if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_1, 112)), loc_10), i64_ZERO) then
																break
															end
															loc_2 = 11
															if eq_i64(band_i64(load_i64(memory_at_0, add_i32(loc_1, 120)), loc_10), i64_ZERO) then
																desired = 11
																break
															end
															break
														end
														if desired then
															if desired == 12 then
																desired = nil
															end
															break
														end
														loc_12 = 0
														loc_10 = shl_i64(i64_ONE, extend_i64_u32(loc_6))
														if ne_i64(band_i64(load_i64(memory_at_0, loc_1 + 32), loc_10), i64_ZERO) then
															desired = 2
															break
														end
														loc_12 = 1
														if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_1, 40)), loc_10), i64_ZERO) then
															desired = 2
															break
														end
														loc_12 = 2
														if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_1, 48)), loc_10), i64_ZERO) then
															desired = 2
															break
														end
														loc_12 = 3
														if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_1, 56)), loc_10), i64_ZERO) then
															desired = 2
															break
														end
														loc_12 = 4
														if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_1, 64)), loc_10), i64_ZERO) then
															desired = 2
															break
														end
														loc_12 = 5
														if eq_i64(band_i64(load_i64(memory_at_0, add_i32(loc_1, 72)), loc_10), i64_ZERO) then
															desired = 6
															break
														end
														desired = 2
														break
													end
													if desired then
														if desired == 11 then
															desired = nil
														end
														break
													end
													loc_2 = 0
													if ne_i64(band_i64(load_i64(memory_at_0, loc_1 + 32), loc_10), i64_ZERO) then
														desired = 7
														break
													end
													loc_2 = 1
													if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_1, 40)), loc_10), i64_ZERO) then
														desired = 7
														break
													end
													loc_2 = 2
													if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_1, 48)), loc_10), i64_ZERO) then
														desired = 7
														break
													end
													loc_2 = 3
													if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_1, 56)), loc_10), i64_ZERO) then
														desired = 7
														break
													end
													loc_2 = 4
													if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_1, 64)), loc_10), i64_ZERO) then
														desired = 7
														break
													end
													loc_2 = 5
													if (if eq_i64(band_i64(load_i64(memory_at_0, add_i32(loc_1, 72)), loc_10), i64_ZERO) then 1 else 0) == 0 then
														desired = 7
														break
													end
													break
												end
												if desired then
													if desired == 10 then
														desired = nil
													end
													break
												end
												FUNC_LIST[192](1069992, 43, 1070036)
												error("out of code bounds")
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											loc_2 = 2400
											desired = 3
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										loc_2 = 2300
										desired = 3
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									while true do
										if band_i32(loc_4, 255) < 64 then
											break
										end
										FUNC_LIST[189](loc_5, 64, 1069976)
										error("out of code bounds")
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									if loc_6 < 64 then
										desired = 4
										break
									end
									FUNC_LIST[189](loc_7, 64, 1069976)
									error("out of code bounds")
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								loc_12 = 6
								loc_10 = shl_i64(i64_ONE, extend_i64_u32(loc_6))
								if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_1, 80)), loc_10), i64_ZERO) then
									desired = 2
									break
								end
								loc_12 = 7
								if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_1, 88)), loc_10), i64_ZERO) then
									desired = 2
									break
								end
								loc_12 = 8
								if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_1, 96)), loc_10), i64_ZERO) then
									desired = 2
									break
								end
								loc_12 = 9
								if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_1, 104)), loc_10), i64_ZERO) then
									desired = 2
									break
								end
								loc_12 = 10
								if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_1, 112)), loc_10), i64_ZERO) then
									desired = 2
									break
								end
								loc_12 = 11
								if ne_i64(band_i64(load_i64(memory_at_0, add_i32(loc_1, 120)), loc_10), i64_ZERO) then
									desired = 2
									break
								end
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							while true do
								while true do
									if band_i32(loc_4, 255) >= 64 then
										break
									end
									if loc_6 >= 64 then
										desired = 6
										break
									end
									loc_1 = load_i32_u16(memory_at_0, add_i32(add_i32(add_i32(add_i32(loc_8, shl_i32(loc_11, 13)), shl_i32(loc_5, 7)), shl_i32(loc_7, 1)), 92))
									loc_2 = (if eq_i64(band_i64(shr_u64(loc_9, extend_i64_u32(loc_6)), i64_ONE), i64_ZERO) then loc_1 else add_i32(loc_1, 4294967246))
									desired = 1
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								FUNC_LIST[189](loc_5, 64, 1070100)
								error("out of code bounds")
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							FUNC_LIST[189](loc_7, 64, 1070100)
							error("out of code bounds")
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						while true do
							if band_i32(loc_4, 255) < 64 then
								break
							end
							FUNC_LIST[189](loc_5, 64, 1070116)
							error("out of code bounds")
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						while true do
							if loc_6 < 64 then
								break
							end
							FUNC_LIST[189](loc_7, 64, 1070116)
							error("out of code bounds")
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_2 = load_i32_u16(memory_at_0, add_i32(add_i32(add_i32(add_i32(loc_8, shl_i32(load_i32_u8(memory_at_0, load_i32(memory_at_0, loc_8 + 24) + 140), 13)), shl_i32(loc_5, 7)), shl_i32(loc_7, 1)), 92))
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_2 = load_i32_u16(memory_at_0, add_i32(add_i32(add_i32(add_i32(loc_8, shl_i32(load_i32_u8(memory_at_0, load_i32(memory_at_0, loc_8 + 24) + 140), 13)), shl_i32(loc_5, 7)), shl_i32(loc_7, 1)), 92))
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_2 = band_i32(loc_2, 65535)
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				loc_6 = load_i32(memory_at_0, add_i32(shl_i32(loc_12, 2), 1070052))
				loc_1 = load_i32(memory_at_0, add_i32(shl_i32(loc_2, 2), 1070052))
				loc_2 = (if eq_i64(band_i64(loc_9, loc_10), i64_ZERO) then div_i32(loc_1, 2) else loc_1)
				loc_1 = sub_i32(loc_6, loc_2)
				if gt_i32(loc_1, 0) then
					break
				end
				loc_2 = (if loc_6 == loc_2 then 1000 else add_i32(loc_1, 50))
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_2 = add_i32(loc_1, 2000)
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		while true do
			loc_1 = load_i32(memory_at_0, loc_0 + 4)
			loc_6 = load_i32(memory_at_0, loc_1)
			if loc_6 > 217 then
				break
			end
			loc_4 = load_i32_u16(memory_at_0, load_i32(memory_at_0, loc_0 + 20))
			loc_0 = add_i32(load_i32(memory_at_0, loc_0), shl_i32(loc_6, 3))
			store_i32_n16(memory_at_0, loc_0 + 4, loc_3)
			store_i32(memory_at_0, loc_0, add_i32((if loc_4 == band_i32(loc_3, 65535) then 500 else 0), loc_2))
			store_i32(memory_at_0, loc_1, add_i32(load_i32(memory_at_0, loc_1), 1))
			desired = 0
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		FUNC_LIST[189](loc_6, 218, 1070308)
		error("out of code bounds")
	end
end
FUNC_LIST[104] = --[[ _ZN4core3ptr110drop_in_place$LT$engine..search..move_ordering..MoveOrderer..get_sorted_moves..$u7b$$u7b$closure$u7d$$u7d$$GT$17h3d09670a82364babE.llvm.16079275652155140001 ]] function(loc_0)
	while true do
		break
	end
end
FUNC_LIST[105] = --[[ _ZN60_$LT$alloc..string..String$u20$as$u20$core..fmt..Display$GT$3fmt17h716fe1dd8cfb591fE ]] function(loc_0, loc_1)
	local reg_0
	while true do
		reg_0 = FUNC_LIST[237](load_i32(memory_at_0, loc_0 + 4), load_i32(memory_at_0, loc_0 + 8), loc_1)
		break
	end
	return reg_0
end
FUNC_LIST[106] = --[[ _ZN6engine5perft5perft28_$u7b$$u7b$closure$u7d$$u7d$17h0afb6ae06185ef3cE ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local desired
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 160)
		GLOBAL_LIST[0].value = loc_2
		store_i32_n16(memory_at_0, loc_2 + 4, loc_1)
		store_i32_n8(memory_at_0, loc_2 + 6, shr_u32(loc_1, 16))
		loc_1 = 1
		while true do
			while true do
				loc_3 = load_i32(memory_at_0, loc_0)
				if load_i32_u16(memory_at_0, loc_3) ~= 1 then
					break
				end
				loc_0 = load_i32(memory_at_0, loc_0 + 4)
				store_i32(memory_at_0, loc_0, add_i32(load_i32(memory_at_0, loc_0), 1))
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_4 = load_i32(memory_at_0, loc_0 + 8)
			FUNC_LIST[51](loc_4, add_i32(loc_2, 4))
			loc_3 = add_i32(load_i32_u16(memory_at_0, loc_3), 4294967295)
			store_i32_n16(memory_at_0, loc_2 + 10, loc_3)
			while true do
				if band_i32(loc_3, 65535) == 0 then
					break
				end
				store_i32(memory_at_0, loc_2 + 12, 0)
				FUNC_LIST[53](add_i32(loc_2, 16), loc_4)
				store_i32(memory_at_0, loc_2 + 156, loc_4)
				store_i32(memory_at_0, loc_2 + 152, add_i32(loc_2, 12))
				store_i32(memory_at_0, loc_2 + 148, add_i32(loc_2, 10))
				FUNC_LIST[54](add_i32(loc_2, 16), add_i32(loc_2, 148), 1069816, 0)
				loc_1 = load_i32(memory_at_0, loc_2 + 12)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_0 = load_i32(memory_at_0, loc_0 + 4)
			store_i32(memory_at_0, loc_0, add_i32(load_i32(memory_at_0, loc_0), loc_1))
			FUNC_LIST[52](loc_4, add_i32(loc_2, 4))
			break
		end
		GLOBAL_LIST[0].value = add_i32(loc_2, 160)
		break
	end
end
FUNC_LIST[107] = --[[ _ZN6engine6search13move_ordering11MoveOrderer16get_sorted_moves17h703439151cbcb444E ]] function(loc_0, loc_1, loc_2, loc_3, loc_4)
	local loc_5 = 0
	local reg_0
	while true do
		loc_5 = sub_i32(GLOBAL_LIST[0].value, 1776)
		GLOBAL_LIST[0].value = loc_5
		store_i32_n16(memory_at_0, loc_5 + 2, loc_4)
		store_i32_n16(memory_at_0, loc_5, loc_3)
		loc_3 = 0
		while true do
			loc_4 = add_i32(add_i32(loc_5, 4), loc_3)
			store_i32(memory_at_0, loc_4, 0)
			store_i32_n16(memory_at_0, add_i32(loc_4, 12), 0)
			store_i32(memory_at_0, add_i32(loc_4, 8), 0)
			store_i32_n16(memory_at_0, add_i32(loc_4, 4), 0)
			loc_3 = add_i32(loc_3, 16)
			if loc_3 ~= 1744 then
				continue
			end
			break
		end
		store_i32(memory_at_0, loc_5 + 1748, 0)
		store_i32(memory_at_0, loc_5 + 1768, loc_2)
		store_i32(memory_at_0, loc_5 + 1764, loc_1)
		store_i32(memory_at_0, loc_5 + 1772, add_i32(loc_5, 2))
		store_i32(memory_at_0, loc_5 + 1760, loc_5)
		store_i32(memory_at_0, loc_5 + 1756, add_i32(loc_5, 1748))
		store_i32(memory_at_0, loc_5 + 1752, add_i32(loc_5, 4))
		FUNC_LIST[54](loc_2, add_i32(loc_5, 1752), 1070288, 0)
		reg_0 = FUNC_LIST[262](loc_0, add_i32(loc_5, 4), 1744)
		store_i32(memory_at_0, reg_0 + 1744, load_i32(memory_at_0, loc_5 + 1748))
		GLOBAL_LIST[0].value = add_i32(loc_5, 1776)
		break
	end
end
FUNC_LIST[108] = --[[ _ZN36_$LT$T$u20$as$u20$core..any..Any$GT$7type_id17hb6ab162078ab5f98E ]] function(loc_0, loc_1)
	while true do
		store_i64(memory_at_0, loc_0 + 8, i64_from_u32(11661156, 4256962177))
		store_i64(memory_at_0, loc_0, i64_from_u32(3441327041, 3248670876))
		break
	end
end
FUNC_LIST[109] = --[[ _ZN36_$LT$T$u20$as$u20$core..any..Any$GT$7type_id17hbb1f89ce7a236805E ]] function(loc_0, loc_1)
	while true do
		store_i64(memory_at_0, loc_0 + 8, i64_from_u32(2365997581, 2734931110))
		store_i64(memory_at_0, loc_0, i64_from_u32(589103780, 3142083496))
		break
	end
end
FUNC_LIST[110] = --[[ _ZN36_$LT$T$u20$as$u20$core..any..Any$GT$7type_id17hebe5185c0ef4e16dE ]] function(loc_0, loc_1)
	while true do
		store_i64(memory_at_0, loc_0 + 8, i64_from_u32(2350337771, 121298550))
		store_i64(memory_at_0, loc_0, i64_from_u32(3168134013, 863703598))
		break
	end
end
FUNC_LIST[111] = --[[ _ZN42_$LT$$RF$T$u20$as$u20$core..fmt..Debug$GT$3fmt17h71b8946adb083c1dE ]] function(loc_0, loc_1)
	local reg_0
	while true do
		reg_0 = FUNC_LIST[235](load_i32(memory_at_0, loc_0), load_i32(memory_at_0, loc_0 + 4), loc_1)
		break
	end
	return reg_0
end
FUNC_LIST[112] = --[[ _ZN42_$LT$$RF$T$u20$as$u20$core..fmt..Debug$GT$3fmt17hb46c73bdf4b01c5cE ]] function(loc_0, loc_1)
	local reg_0
	while true do
		reg_0 = FUNC_LIST[234](load_i32(memory_at_0, loc_0), loc_1)
		break
	end
	return reg_0
end
FUNC_LIST[113] = --[[ _ZN42_$LT$$RF$T$u20$as$u20$core..fmt..Debug$GT$3fmt17hf123fc86b557ef8bE ]] function(loc_0, loc_1)
	local reg_0
	while true do
		loc_0 = load_i32(memory_at_0, loc_0)
		reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, load_i32(memory_at_0, add_i32(loc_0, 4)) + 12)](load_i32(memory_at_0, loc_0), loc_1)
		break
	end
	return reg_0
end
FUNC_LIST[114] = --[[ _ZN4core3fmt3num50_$LT$impl$u20$core..fmt..Debug$u20$for$u20$i32$GT$3fmt17h6d4547440a0d45efE ]] function(loc_0, loc_1)
	local loc_2 = 0
	local reg_0
	local desired
	while true do
		while true do
			loc_2 = load_i32(memory_at_0, loc_1 + 28)
			if band_i32(loc_2, 16) ~= 0 then
				break
			end
			while true do
				if band_i32(loc_2, 32) ~= 0 then
					break
				end
				reg_0 = FUNC_LIST[251](loc_0, loc_1)
				desired = 0
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			reg_0 = FUNC_LIST[249](loc_0, loc_1)
			desired = 0
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		reg_0 = FUNC_LIST[213](loc_0, loc_1)
		break
	end
	return reg_0
end
FUNC_LIST[115] = --[[ _ZN5alloc7raw_vec19RawVec$LT$T$C$A$GT$7reserve21do_reserve_and_handle17hc9c35030fae5014dE ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	local loc_4 = 0
	local desired
	while true do
		loc_3 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_3
		while true do
			while true do
				loc_2 = add_i32(loc_1, loc_2)
				if loc_2 < loc_1 then
					break
				end
				loc_1 = load_i32(memory_at_0, loc_0)
				loc_4 = shl_i32(loc_1, 1)
				loc_2 = (if loc_4 > loc_2 then loc_4 else loc_2)
				loc_2 = (if loc_2 > 8 then loc_2 else 8)
				loc_4 = shr_u32(bxor_i32(loc_2, 4294967295), 31)
				while true do
					while true do
						if loc_1 ~= 0 then
							break
						end
						store_i32(memory_at_0, loc_3 + 24, 0)
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32(memory_at_0, loc_3 + 28, loc_1)
					store_i32(memory_at_0, loc_3 + 24, 1)
					store_i32(memory_at_0, loc_3 + 20, load_i32(memory_at_0, loc_0 + 4))
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[129](add_i32(loc_3, 8), loc_4, loc_2, add_i32(loc_3, 20))
				loc_1 = load_i32(memory_at_0, loc_3 + 12)
				while true do
					if load_i32(memory_at_0, loc_3 + 8) ~= 0 then
						break
					end
					store_i32(memory_at_0, loc_0, loc_2)
					store_i32(memory_at_0, loc_0 + 4, loc_1)
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				if loc_1 == 2147483649 then
					desired = 1
					break
				end
				if loc_1 == 0 then
					break
				end
				FUNC_LIST[173](loc_1, load_i32(memory_at_0, add_i32(loc_3, 16)))
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[174]()
			error("out of code bounds")
		end
		GLOBAL_LIST[0].value = add_i32(loc_3, 32)
		break
	end
end
FUNC_LIST[116] = --[[ _ZN4core3fmt5Write9write_fmt17h14074724b2d86e41E ]] function(loc_0, loc_1)
	local reg_0
	while true do
		reg_0 = FUNC_LIST[195](loc_0, 1070512, loc_1)
		break
	end
	return reg_0
end
FUNC_LIST[117] = --[[ _ZN4core3ptr122drop_in_place$LT$$RF$alloc..boxed..Box$LT$dyn$u20$core..error..Error$u2b$core..marker..Sync$u2b$core..marker..Send$GT$$GT$17h1bde1999ec285555E ]] function(loc_0)
	while true do
		break
	end
end
FUNC_LIST[118] = --[[ _ZN3std9panicking11panic_count17is_zero_slow_path17h3b79f2335d61b14dE ]] function()
	local reg_0
	while true do
		reg_0 = (if load_i32(memory_at_0, 0 + 1085244) == 0 then 1 else 0)
		break
	end
	return reg_0
end
FUNC_LIST[119] = --[[ _ZN4core3ptr25drop_in_place$LT$bool$GT$17h3853746b16ffaceaE ]] function(loc_0)
	while true do
		break
	end
end
FUNC_LIST[120] = --[[ _ZN4core3ptr29drop_in_place$LT$$LP$$RP$$GT$17h0fdf7771dc4a7479E ]] function(loc_0)
	while true do
		break
	end
end
FUNC_LIST[121] = --[[ _ZN4core3ptr42drop_in_place$LT$alloc..string..String$GT$17hb9f4a6f09724c4f8E ]] function(loc_0)
	local loc_1 = 0
	while true do
		while true do
			loc_1 = load_i32(memory_at_0, loc_0)
			if loc_1 == 0 then
				break
			end
			FUNC_LIST[22](load_i32(memory_at_0, loc_0 + 4), loc_1, 1)
			break
		end
		break
	end
end
FUNC_LIST[122] = --[[ _ZN4core3ptr77drop_in_place$LT$std..panicking..begin_panic_handler..FormatStringPayload$GT$17hc4e3b9a43e95b213E ]] function(loc_0)
	local loc_1 = 0
	while true do
		while true do
			loc_1 = load_i32(memory_at_0, loc_0)
			if bor_i32(loc_1, 2147483648) == 2147483648 then
				break
			end
			FUNC_LIST[22](load_i32(memory_at_0, loc_0 + 4), loc_1, 1)
			break
		end
		break
	end
end
FUNC_LIST[123] = --[[ _ZN3std6thread8ThreadId3new9exhausted17h792d9ac6082d0b56E ]] function()
	local loc_0 = 0
	while true do
		loc_0 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_0
		store_i64(memory_at_0, add_i32(loc_0, 20), i64_ZERO)
		store_i32(memory_at_0, loc_0 + 12, 1)
		store_i32(memory_at_0, loc_0 + 8, 1070676)
		store_i32(memory_at_0, loc_0 + 16, 1070448)
		FUNC_LIST[187](add_i32(loc_0, 8), 1070684)
		error("out of code bounds")
	end
end
FUNC_LIST[124] = --[[ _ZN4core9panicking13assert_failed17h758826ae8e9759abE ]] function(loc_0, loc_1)
	local loc_2 = 0
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_2
		store_i32(memory_at_0, loc_2 + 12, 1070448)
		store_i32(memory_at_0, loc_2 + 8, loc_0)
		FUNC_LIST[214](0, add_i32(loc_2, 8), 1070452, add_i32(loc_2, 12), 1070452, loc_1, 1071088)
		error("out of code bounds")
	end
end
FUNC_LIST[125] = --[[ _ZN58_$LT$alloc..string..String$u20$as$u20$core..fmt..Debug$GT$3fmt17h7a409ab67051d2cdE ]] function(loc_0, loc_1)
	local reg_0
	while true do
		reg_0 = FUNC_LIST[235](load_i32(memory_at_0, loc_0 + 4), load_i32(memory_at_0, loc_0 + 8), loc_1)
		break
	end
	return reg_0
end
FUNC_LIST[126] = --[[ _ZN58_$LT$alloc..string..String$u20$as$u20$core..fmt..Write$GT$10write_char17h062851a21fa82158E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local reg_0
	local desired
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_2
		while true do
			while true do
				while true do
					while true do
						if loc_1 < 128 then
							break
						end
						store_i32(memory_at_0, loc_2 + 12, 0)
						if loc_1 < 2048 then
							desired = 3
							break
						end
						while true do
							if loc_1 >= 65536 then
								break
							end
							store_i32_n8(memory_at_0, loc_2 + 14, bor_i32(band_i32(loc_1, 63), 128))
							store_i32_n8(memory_at_0, loc_2 + 12, bor_i32(shr_u32(loc_1, 12), 224))
							store_i32_n8(memory_at_0, loc_2 + 13, bor_i32(band_i32(shr_u32(loc_1, 6), 63), 128))
							loc_1 = 3
							desired = 2
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						store_i32_n8(memory_at_0, loc_2 + 15, bor_i32(band_i32(loc_1, 63), 128))
						store_i32_n8(memory_at_0, loc_2 + 14, bor_i32(band_i32(shr_u32(loc_1, 6), 63), 128))
						store_i32_n8(memory_at_0, loc_2 + 13, bor_i32(band_i32(shr_u32(loc_1, 12), 63), 128))
						store_i32_n8(memory_at_0, loc_2 + 12, bor_i32(band_i32(shr_u32(loc_1, 18), 7), 240))
						loc_1 = 4
						desired = 2
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					while true do
						loc_3 = load_i32(memory_at_0, loc_0 + 8)
						if loc_3 ~= load_i32(memory_at_0, loc_0) then
							break
						end
						FUNC_LIST[127](loc_0, loc_3)
						loc_3 = load_i32(memory_at_0, loc_0 + 8)
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32(memory_at_0, loc_0 + 8, add_i32(loc_3, 1))
					store_i32_n8(memory_at_0, add_i32(load_i32(memory_at_0, loc_0 + 4), loc_3), loc_1)
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i32_n8(memory_at_0, loc_2 + 13, bor_i32(band_i32(loc_1, 63), 128))
				store_i32_n8(memory_at_0, loc_2 + 12, bor_i32(shr_u32(loc_1, 6), 192))
				loc_1 = 2
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				loc_3 = load_i32(memory_at_0, loc_0 + 8)
				if sub_i32(load_i32(memory_at_0, loc_0), loc_3) >= loc_1 then
					break
				end
				FUNC_LIST[115](loc_0, loc_3, loc_1)
				loc_3 = load_i32(memory_at_0, loc_0 + 8)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			reg_0 = FUNC_LIST[262](add_i32(load_i32(memory_at_0, loc_0 + 4), loc_3), add_i32(loc_2, 12), loc_1)
			store_i32(memory_at_0, loc_0 + 8, add_i32(loc_3, loc_1))
			break
		end
		GLOBAL_LIST[0].value = add_i32(loc_2, 16)
		reg_0 = 0
		break
	end
	return reg_0
end
FUNC_LIST[127] = --[[ _ZN5alloc7raw_vec19RawVec$LT$T$C$A$GT$16reserve_for_push17h657ccf3b43de7ebfE ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local desired
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_2
		while true do
			while true do
				loc_1 = add_i32(loc_1, 1)
				if loc_1 == 0 then
					break
				end
				loc_3 = load_i32(memory_at_0, loc_0)
				loc_4 = shl_i32(loc_3, 1)
				loc_1 = (if loc_4 > loc_1 then loc_4 else loc_1)
				loc_1 = (if loc_1 > 8 then loc_1 else 8)
				loc_4 = shr_u32(bxor_i32(loc_1, 4294967295), 31)
				while true do
					while true do
						if loc_3 ~= 0 then
							break
						end
						store_i32(memory_at_0, loc_2 + 24, 0)
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32(memory_at_0, loc_2 + 28, loc_3)
					store_i32(memory_at_0, loc_2 + 24, 1)
					store_i32(memory_at_0, loc_2 + 20, load_i32(memory_at_0, loc_0 + 4))
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[129](add_i32(loc_2, 8), loc_4, loc_1, add_i32(loc_2, 20))
				loc_3 = load_i32(memory_at_0, loc_2 + 12)
				while true do
					if load_i32(memory_at_0, loc_2 + 8) ~= 0 then
						break
					end
					store_i32(memory_at_0, loc_0, loc_1)
					store_i32(memory_at_0, loc_0 + 4, loc_3)
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				if loc_3 == 2147483649 then
					desired = 1
					break
				end
				if loc_3 == 0 then
					break
				end
				FUNC_LIST[173](loc_3, load_i32(memory_at_0, add_i32(loc_2, 16)))
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[174]()
			error("out of code bounds")
		end
		GLOBAL_LIST[0].value = add_i32(loc_2, 32)
		break
	end
end
FUNC_LIST[128] = --[[ _ZN58_$LT$alloc..string..String$u20$as$u20$core..fmt..Write$GT$9write_str17hbef94c01d8f2ab7aE ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	local reg_0
	while true do
		while true do
			loc_3 = load_i32(memory_at_0, loc_0 + 8)
			if sub_i32(load_i32(memory_at_0, loc_0), loc_3) >= loc_2 then
				break
			end
			FUNC_LIST[115](loc_0, loc_3, loc_2)
			loc_3 = load_i32(memory_at_0, loc_0 + 8)
			break
		end
		reg_0 = FUNC_LIST[262](add_i32(load_i32(memory_at_0, loc_0 + 4), loc_3), loc_1, loc_2)
		store_i32(memory_at_0, loc_0 + 8, add_i32(loc_3, loc_2))
		reg_0 = 0
		break
	end
	return reg_0
end
FUNC_LIST[129] = --[[ _ZN5alloc7raw_vec11finish_grow17h868010b59f1cf961E ]] function(loc_0, loc_1, loc_2, loc_3)
	local loc_4 = 0
	local reg_0
	local desired
	while true do
		while true do
			while true do
				while true do
					if loc_1 == 0 then
						break
					end
					if le_i32(loc_2, 4294967295) then
						desired = 2
						break
					end
					while true do
						while true do
							while true do
								if load_i32(memory_at_0, loc_3 + 4) == 0 then
									break
								end
								while true do
									loc_4 = load_i32(memory_at_0, add_i32(loc_3, 8))
									if loc_4 ~= 0 then
										break
									end
									while true do
										if loc_2 ~= 0 then
											break
										end
										loc_3 = loc_1
										desired = 4
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									desired = 5
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								reg_0 = FUNC_LIST[23](load_i32(memory_at_0, loc_3), loc_4, loc_1, loc_2)
								loc_3 = reg_0
								desired = 4
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							while true do
								if loc_2 ~= 0 then
									break
								end
								loc_3 = loc_1
								desired = 4
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						reg_0 = FUNC_LIST[21](loc_2, loc_1)
						loc_3 = reg_0
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					while true do
						if loc_3 == 0 then
							break
						end
						store_i32(memory_at_0, loc_0 + 4, loc_3)
						store_i32(memory_at_0, add_i32(loc_0, 8), loc_2)
						store_i32(memory_at_0, loc_0, 0)
						desired = 0
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32(memory_at_0, loc_0 + 4, loc_1)
					store_i32(memory_at_0, add_i32(loc_0, 8), loc_2)
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i32(memory_at_0, loc_0 + 4, 0)
				store_i32(memory_at_0, add_i32(loc_0, 8), loc_2)
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			store_i32(memory_at_0, loc_0 + 4, 0)
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		store_i32(memory_at_0, loc_0, 1)
		break
	end
end
FUNC_LIST[130] = --[[ _ZN8dlmalloc8dlmalloc17Dlmalloc$LT$A$GT$12unlink_chunk17h60d3fb17c4a254a8E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local reg_0
	local desired
	while true do
		loc_2 = load_i32(memory_at_0, loc_0 + 12)
		while true do
			while true do
				while true do
					if loc_1 < 256 then
						break
					end
					loc_3 = load_i32(memory_at_0, loc_0 + 24)
					while true do
						while true do
							while true do
								if loc_2 ~= loc_0 then
									break
								end
								loc_2 = add_i32(loc_0, 20)
								loc_4 = load_i32(memory_at_0, loc_2)
								loc_1 = load_i32(memory_at_0, add_i32(loc_0, (if loc_4 ~= 0 then 20 else 16)))
								if loc_1 ~= 0 then
									desired = 5
									break
								end
								loc_2 = 0
								desired = 4
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_1 = load_i32(memory_at_0, loc_0 + 8)
							store_i32(memory_at_0, loc_1 + 12, loc_2)
							store_i32(memory_at_0, loc_2 + 8, loc_1)
							desired = 4
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_4 = (if loc_4 ~= 0 then loc_2 else add_i32(loc_0, 16))
						while true do
							loc_5 = loc_4
							loc_2 = loc_1
							loc_1 = add_i32(loc_2, 20)
							reg_0 = loc_1
							loc_1 = load_i32(memory_at_0, loc_1)
							loc_4 = (if loc_1 ~= 0 then reg_0 else add_i32(loc_2, 16))
							loc_1 = load_i32(memory_at_0, add_i32(loc_2, (if loc_1 ~= 0 then 20 else 16)))
							if loc_1 ~= 0 then
								continue
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						store_i32(memory_at_0, loc_5, 0)
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					if loc_3 == 0 then
						desired = 1
						break
					end
					while true do
						loc_1 = add_i32(shl_i32(load_i32(memory_at_0, loc_0 + 28), 2), 1084792)
						if load_i32(memory_at_0, loc_1) == loc_0 then
							break
						end
						store_i32(memory_at_0, add_i32(loc_3, (if load_i32(memory_at_0, loc_3 + 16) == loc_0 then 16 else 20)), loc_2)
						if loc_2 == 0 then
							desired = 1
							break
						end
						desired = 2
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32(memory_at_0, loc_1, loc_2)
					if loc_2 ~= 0 then
						desired = 2
						break
					end
					store_i32(memory_at_0, 0 + 1085204, band_i32(load_i32(memory_at_0, 0 + 1085204), rotl_i32(4294967294, load_i32(memory_at_0, loc_0 + 28))))
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				while true do
					loc_4 = load_i32(memory_at_0, loc_0 + 8)
					if loc_2 == loc_4 then
						break
					end
					store_i32(memory_at_0, loc_4 + 12, loc_2)
					store_i32(memory_at_0, loc_2 + 8, loc_4)
					desired = 0
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i32(memory_at_0, 0 + 1085200, band_i32(load_i32(memory_at_0, 0 + 1085200), rotl_i32(4294967294, shr_u32(loc_1, 3))))
				desired = 0
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			store_i32(memory_at_0, loc_2 + 24, loc_3)
			while true do
				loc_1 = load_i32(memory_at_0, loc_0 + 16)
				if loc_1 == 0 then
					break
				end
				store_i32(memory_at_0, loc_2 + 16, loc_1)
				store_i32(memory_at_0, loc_1 + 24, loc_2)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_1 = load_i32(memory_at_0, add_i32(loc_0, 20))
			if loc_1 == 0 then
				break
			end
			store_i32(memory_at_0, add_i32(loc_2, 20), loc_1)
			store_i32(memory_at_0, loc_1 + 24, loc_2)
			desired = 0
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		break
	end
end
FUNC_LIST[131] = --[[ _ZN8dlmalloc8dlmalloc17Dlmalloc$LT$A$GT$13dispose_chunk17h220aa72febfe28ffE ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local desired
	while true do
		loc_2 = add_i32(loc_0, loc_1)
		while true do
			while true do
				loc_3 = load_i32(memory_at_0, loc_0 + 4)
				if band_i32(loc_3, 1) ~= 0 then
					break
				end
				if band_i32(loc_3, 3) == 0 then
					desired = 1
					break
				end
				loc_3 = load_i32(memory_at_0, loc_0)
				loc_1 = add_i32(loc_3, loc_1)
				while true do
					loc_0 = sub_i32(loc_0, loc_3)
					if loc_0 ~= load_i32(memory_at_0, 0 + 1085216) then
						break
					end
					if band_i32(load_i32(memory_at_0, loc_2 + 4), 3) ~= 3 then
						desired = 2
						break
					end
					store_i32(memory_at_0, 0 + 1085208, loc_1)
					store_i32(memory_at_0, loc_2 + 4, band_i32(load_i32(memory_at_0, loc_2 + 4), 4294967294))
					store_i32(memory_at_0, loc_0 + 4, bor_i32(loc_1, 1))
					store_i32(memory_at_0, loc_2, loc_1)
					desired = 0
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[130](loc_0, loc_3)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				while true do
					while true do
						while true do
							loc_3 = load_i32(memory_at_0, loc_2 + 4)
							if band_i32(loc_3, 2) ~= 0 then
								break
							end
							if loc_2 == load_i32(memory_at_0, 0 + 1085220) then
								desired = 3
								break
							end
							if loc_2 == load_i32(memory_at_0, 0 + 1085216) then
								desired = 2
								break
							end
							loc_3 = band_i32(loc_3, 4294967288)
							FUNC_LIST[130](loc_2, loc_3)
							loc_1 = add_i32(loc_3, loc_1)
							store_i32(memory_at_0, loc_0 + 4, bor_i32(loc_1, 1))
							store_i32(memory_at_0, add_i32(loc_0, loc_1), loc_1)
							if loc_0 ~= load_i32(memory_at_0, 0 + 1085216) then
								desired = 4
								break
							end
							store_i32(memory_at_0, 0 + 1085208, loc_1)
							desired = 0
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						store_i32(memory_at_0, loc_2 + 4, band_i32(loc_3, 4294967294))
						store_i32(memory_at_0, loc_0 + 4, bor_i32(loc_1, 1))
						store_i32(memory_at_0, add_i32(loc_0, loc_1), loc_1)
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					while true do
						if loc_1 < 256 then
							break
						end
						FUNC_LIST[132](loc_0, loc_1)
						desired = 1
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_2 = add_i32(band_i32(loc_1, 4294967288), 1084936)
					while true do
						while true do
							loc_3 = load_i32(memory_at_0, 0 + 1085200)
							loc_1 = shl_i32(1, shr_u32(loc_1, 3))
							if band_i32(loc_3, loc_1) ~= 0 then
								break
							end
							store_i32(memory_at_0, 0 + 1085200, bor_i32(loc_3, loc_1))
							loc_1 = loc_2
							desired = 4
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_1 = load_i32(memory_at_0, loc_2 + 8)
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32(memory_at_0, loc_2 + 8, loc_0)
					store_i32(memory_at_0, loc_1 + 12, loc_0)
					store_i32(memory_at_0, loc_0 + 12, loc_2)
					store_i32(memory_at_0, loc_0 + 8, loc_1)
					desired = 0
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i32(memory_at_0, 0 + 1085220, loc_0)
				loc_1 = add_i32(load_i32(memory_at_0, 0 + 1085212), loc_1)
				store_i32(memory_at_0, 0 + 1085212, loc_1)
				store_i32(memory_at_0, loc_0 + 4, bor_i32(loc_1, 1))
				if loc_0 ~= load_i32(memory_at_0, 0 + 1085216) then
					desired = 1
					break
				end
				store_i32(memory_at_0, 0 + 1085208, 0)
				store_i32(memory_at_0, 0 + 1085216, 0)
				desired = 0
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			store_i32(memory_at_0, 0 + 1085216, loc_0)
			loc_1 = add_i32(load_i32(memory_at_0, 0 + 1085208), loc_1)
			store_i32(memory_at_0, 0 + 1085208, loc_1)
			store_i32(memory_at_0, loc_0 + 4, bor_i32(loc_1, 1))
			store_i32(memory_at_0, add_i32(loc_0, loc_1), loc_1)
			desired = 0
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		break
	end
end
FUNC_LIST[132] = --[[ _ZN8dlmalloc8dlmalloc17Dlmalloc$LT$A$GT$18insert_large_chunk17h37edb9edd104b6bfE ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local desired
	while true do
		loc_2 = 0
		while true do
			if loc_1 < 256 then
				break
			end
			loc_2 = 31
			if loc_1 > 16777215 then
				break
			end
			loc_2 = clz_i32(shr_u32(loc_1, 8))
			loc_2 = add_i32(sub_i32(band_i32(shr_u32(loc_1, sub_i32(6, loc_2)), 1), shl_i32(loc_2, 1)), 62)
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		store_i64(memory_at_0, loc_0 + 16, i64_ZERO)
		store_i32(memory_at_0, loc_0 + 28, loc_2)
		loc_3 = add_i32(shl_i32(loc_2, 2), 1084792)
		while true do
			while true do
				loc_4 = load_i32(memory_at_0, 0 + 1085204)
				loc_5 = shl_i32(1, loc_2)
				if band_i32(loc_4, loc_5) ~= 0 then
					break
				end
				store_i32(memory_at_0, 0 + 1085204, bor_i32(loc_4, loc_5))
				store_i32(memory_at_0, loc_3, loc_0)
				store_i32(memory_at_0, loc_0 + 24, loc_3)
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				while true do
					while true do
						loc_4 = load_i32(memory_at_0, loc_3)
						if band_i32(load_i32(memory_at_0, loc_4 + 4), 4294967288) ~= loc_1 then
							break
						end
						loc_2 = loc_4
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_3 = shl_i32(loc_1, (if loc_2 == 31 then 0 else sub_i32(25, shr_u32(loc_2, 1))))
					while true do
						loc_5 = add_i32(add_i32(loc_4, band_i32(shr_u32(loc_3, 29), 4)), 16)
						loc_2 = load_i32(memory_at_0, loc_5)
						if loc_2 == 0 then
							desired = 2
							break
						end
						loc_3 = shl_i32(loc_3, 1)
						loc_4 = loc_2
						if band_i32(load_i32(memory_at_0, loc_2 + 4), 4294967288) ~= loc_1 then
							continue
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_3 = load_i32(memory_at_0, loc_2 + 8)
				store_i32(memory_at_0, loc_3 + 12, loc_0)
				store_i32(memory_at_0, loc_2 + 8, loc_0)
				store_i32(memory_at_0, loc_0 + 24, 0)
				store_i32(memory_at_0, loc_0 + 12, loc_2)
				store_i32(memory_at_0, loc_0 + 8, loc_3)
				desired = 0
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			store_i32(memory_at_0, loc_5, loc_0)
			store_i32(memory_at_0, loc_0 + 24, loc_4)
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		store_i32(memory_at_0, loc_0 + 12, loc_0)
		store_i32(memory_at_0, loc_0 + 8, loc_0)
		break
	end
end
FUNC_LIST[133] = --[[ _ZN8dlmalloc8dlmalloc17Dlmalloc$LT$A$GT$4free17h44cc7ea745237aceE ]] function(loc_0)
	local loc_1 = 0
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local desired
	while true do
		loc_1 = add_i32(loc_0, 4294967288)
		loc_2 = load_i32(memory_at_0, add_i32(loc_0, 4294967292))
		loc_0 = band_i32(loc_2, 4294967288)
		loc_3 = add_i32(loc_1, loc_0)
		while true do
			while true do
				while true do
					while true do
						if band_i32(loc_2, 1) ~= 0 then
							break
						end
						if band_i32(loc_2, 3) == 0 then
							desired = 3
							break
						end
						loc_2 = load_i32(memory_at_0, loc_1)
						loc_0 = add_i32(loc_2, loc_0)
						while true do
							loc_1 = sub_i32(loc_1, loc_2)
							if loc_1 ~= load_i32(memory_at_0, 0 + 1085216) then
								break
							end
							if band_i32(load_i32(memory_at_0, loc_3 + 4), 3) ~= 3 then
								desired = 4
								break
							end
							store_i32(memory_at_0, 0 + 1085208, loc_0)
							store_i32(memory_at_0, loc_3 + 4, band_i32(load_i32(memory_at_0, loc_3 + 4), 4294967294))
							store_i32(memory_at_0, loc_1 + 4, bor_i32(loc_0, 1))
							store_i32(memory_at_0, loc_3, loc_0)
							desired = 0
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						FUNC_LIST[130](loc_1, loc_2)
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					while true do
						while true do
							while true do
								loc_2 = load_i32(memory_at_0, loc_3 + 4)
								if band_i32(loc_2, 2) ~= 0 then
									break
								end
								if loc_3 == load_i32(memory_at_0, 0 + 1085220) then
									desired = 4
									break
								end
								if loc_3 == load_i32(memory_at_0, 0 + 1085216) then
									desired = 1
									break
								end
								loc_2 = band_i32(loc_2, 4294967288)
								FUNC_LIST[130](loc_3, loc_2)
								loc_0 = add_i32(loc_2, loc_0)
								store_i32(memory_at_0, loc_1 + 4, bor_i32(loc_0, 1))
								store_i32(memory_at_0, add_i32(loc_1, loc_0), loc_0)
								if loc_1 ~= load_i32(memory_at_0, 0 + 1085216) then
									desired = 5
									break
								end
								store_i32(memory_at_0, 0 + 1085208, loc_0)
								desired = 0
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							store_i32(memory_at_0, loc_3 + 4, band_i32(loc_2, 4294967294))
							store_i32(memory_at_0, loc_1 + 4, bor_i32(loc_0, 1))
							store_i32(memory_at_0, add_i32(loc_1, loc_0), loc_0)
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						if loc_0 < 256 then
							desired = 2
							break
						end
						FUNC_LIST[132](loc_1, loc_0)
						loc_1 = 0
						loc_0 = add_i32(load_i32(memory_at_0, 0 + 1085240), 4294967295)
						store_i32(memory_at_0, 0 + 1085240, loc_0)
						if loc_0 ~= 0 then
							desired = 3
							break
						end
						while true do
							loc_0 = load_i32(memory_at_0, 0 + 1084928)
							if loc_0 == 0 then
								break
							end
							loc_1 = 0
							while true do
								loc_1 = add_i32(loc_1, 1)
								loc_0 = load_i32(memory_at_0, loc_0 + 8)
								if loc_0 ~= 0 then
									continue
								end
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						store_i32(memory_at_0, 0 + 1085240, (if loc_1 > 4095 then loc_1 else 4095))
						desired = 0
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32(memory_at_0, 0 + 1085220, loc_1)
					loc_0 = add_i32(load_i32(memory_at_0, 0 + 1085212), loc_0)
					store_i32(memory_at_0, 0 + 1085212, loc_0)
					store_i32(memory_at_0, loc_1 + 4, bor_i32(loc_0, 1))
					while true do
						if loc_1 ~= load_i32(memory_at_0, 0 + 1085216) then
							break
						end
						store_i32(memory_at_0, 0 + 1085208, 0)
						store_i32(memory_at_0, 0 + 1085216, 0)
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_4 = load_i32(memory_at_0, 0 + 1085232)
					if loc_0 <= loc_4 then
						break
					end
					loc_3 = load_i32(memory_at_0, 0 + 1085220)
					if loc_3 == 0 then
						break
					end
					loc_1 = 0
					while true do
						loc_5 = load_i32(memory_at_0, 0 + 1085212)
						if loc_5 < 41 then
							break
						end
						loc_0 = 1084920
						while true do
							while true do
								loc_2 = load_i32(memory_at_0, loc_0)
								if loc_2 > loc_3 then
									break
								end
								if add_i32(loc_2, load_i32(memory_at_0, loc_0 + 4)) > loc_3 then
									desired = 4
									break
								end
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
									continue
								end
								break
							end
							loc_0 = load_i32(memory_at_0, loc_0 + 8)
							if loc_0 ~= 0 then
								continue
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					while true do
						loc_0 = load_i32(memory_at_0, 0 + 1084928)
						if loc_0 == 0 then
							break
						end
						loc_1 = 0
						while true do
							loc_1 = add_i32(loc_1, 1)
							loc_0 = load_i32(memory_at_0, loc_0 + 8)
							if loc_0 ~= 0 then
								continue
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32(memory_at_0, 0 + 1085240, (if loc_1 > 4095 then loc_1 else 4095))
					if loc_5 <= loc_4 then
						break
					end
					store_i32(memory_at_0, 0 + 1085232, 4294967295)
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				desired = 0
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_3 = add_i32(band_i32(loc_0, 4294967288), 1084936)
			while true do
				while true do
					loc_2 = load_i32(memory_at_0, 0 + 1085200)
					loc_0 = shl_i32(1, shr_u32(loc_0, 3))
					if band_i32(loc_2, loc_0) ~= 0 then
						break
					end
					store_i32(memory_at_0, 0 + 1085200, bor_i32(loc_2, loc_0))
					loc_0 = loc_3
					desired = 2
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_0 = load_i32(memory_at_0, loc_3 + 8)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			store_i32(memory_at_0, loc_3 + 8, loc_1)
			store_i32(memory_at_0, loc_0 + 12, loc_1)
			store_i32(memory_at_0, loc_1 + 12, loc_3)
			store_i32(memory_at_0, loc_1 + 8, loc_0)
			desired = 0
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		store_i32(memory_at_0, 0 + 1085216, loc_1)
		loc_0 = add_i32(load_i32(memory_at_0, 0 + 1085208), loc_0)
		store_i32(memory_at_0, 0 + 1085208, loc_0)
		store_i32(memory_at_0, loc_1 + 4, bor_i32(loc_0, 1))
		store_i32(memory_at_0, add_i32(loc_1, loc_0), loc_0)
		break
	end
end
FUNC_LIST[134] = --[[ _ZN8dlmalloc8dlmalloc17Dlmalloc$LT$A$GT$6malloc17hd53665cffe060528E ]] function(loc_0)
	local loc_1 = 0
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = 0
	local loc_8 = 0
	local loc_9 = 0
	local loc_10 = i64_ZERO
	local reg_0
	local reg_1
	local desired
	while true do
		loc_1 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_1
		while true do
			while true do
				while true do
					while true do
						while true do
							while true do
								while true do
									while true do
										if loc_0 < 245 then
											break
										end
										loc_2 = 0
										if loc_0 >= 4294901709 then
											desired = 1
											break
										end
										loc_0 = add_i32(loc_0, 11)
										loc_3 = band_i32(loc_0, 4294967288)
										loc_4 = load_i32(memory_at_0, 0 + 1085204)
										if loc_4 == 0 then
											desired = 4
											break
										end
										loc_5 = 0
										while true do
											if loc_3 < 256 then
												break
											end
											loc_5 = 31
											if loc_3 > 16777215 then
												break
											end
											loc_0 = clz_i32(shr_u32(loc_0, 8))
											loc_5 = add_i32(sub_i32(band_i32(shr_u32(loc_3, sub_i32(6, loc_0)), 1), shl_i32(loc_0, 1)), 62)
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										loc_2 = sub_i32(0, loc_3)
										while true do
											loc_6 = load_i32(memory_at_0, add_i32(shl_i32(loc_5, 2), 1084792))
											if loc_6 ~= 0 then
												break
											end
											loc_0 = 0
											loc_7 = 0
											desired = 7
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										loc_0 = 0
										loc_8 = shl_i32(loc_3, (if loc_5 == 31 then 0 else sub_i32(25, shr_u32(loc_5, 1))))
										loc_7 = 0
										while true do
											while true do
												loc_9 = band_i32(load_i32(memory_at_0, loc_6 + 4), 4294967288)
												if loc_9 < loc_3 then
													break
												end
												loc_9 = sub_i32(loc_9, loc_3)
												if loc_9 >= loc_2 then
													break
												end
												loc_2 = loc_9
												loc_7 = loc_6
												if loc_9 ~= 0 then
													break
												end
												loc_2 = 0
												loc_7 = loc_6
												loc_0 = loc_6
												desired = 6
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
													continue
												end
												break
											end
											loc_9 = load_i32(memory_at_0, add_i32(loc_6, 20))
											loc_6 = load_i32(memory_at_0, add_i32(add_i32(loc_6, band_i32(shr_u32(loc_8, 29), 4)), 16))
											loc_0 = (if loc_9 ~= 0 then (if loc_9 ~= loc_6 then loc_9 else loc_0) else loc_0)
											loc_8 = shl_i32(loc_8, 1)
											if loc_6 == 0 then
												desired = 7
												break
											end
											continue
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									while true do
										loc_7 = load_i32(memory_at_0, 0 + 1085200)
										loc_3 = (if loc_0 < 11 then 16 else band_i32(add_i32(loc_0, 11), 4294967288))
										loc_2 = shr_u32(loc_3, 3)
										loc_0 = shr_u32(loc_7, loc_2)
										if band_i32(loc_0, 3) == 0 then
											break
										end
										while true do
											while true do
												loc_3 = add_i32(band_i32(bxor_i32(loc_0, 4294967295), 1), loc_2)
												loc_0 = shl_i32(loc_3, 3)
												loc_2 = add_i32(loc_0, 1084936)
												loc_0 = load_i32(memory_at_0, add_i32(loc_0, 1084944))
												loc_6 = load_i32(memory_at_0, loc_0 + 8)
												if loc_2 == loc_6 then
													break
												end
												store_i32(memory_at_0, loc_6 + 12, loc_2)
												store_i32(memory_at_0, loc_2 + 8, loc_6)
												desired = 9
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											store_i32(memory_at_0, 0 + 1085200, band_i32(loc_7, rotl_i32(4294967294, loc_3)))
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										loc_2 = add_i32(loc_0, 8)
										loc_3 = shl_i32(loc_3, 3)
										store_i32(memory_at_0, loc_0 + 4, bor_i32(loc_3, 3))
										loc_0 = add_i32(loc_0, loc_3)
										store_i32(memory_at_0, loc_0 + 4, bor_i32(load_i32(memory_at_0, loc_0 + 4), 1))
										desired = 1
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									if loc_3 <= load_i32(memory_at_0, 0 + 1085208) then
										desired = 4
										break
									end
									while true do
										while true do
											while true do
												if loc_0 ~= 0 then
													break
												end
												loc_0 = load_i32(memory_at_0, 0 + 1085204)
												if loc_0 == 0 then
													desired = 4
													break
												end
												loc_6 = load_i32(memory_at_0, add_i32(shl_i32(ctz_i32(loc_0), 2), 1084792))
												loc_2 = sub_i32(band_i32(load_i32(memory_at_0, loc_6 + 4), 4294967288), loc_3)
												loc_7 = loc_6
												while true do
													while true do
														loc_0 = load_i32(memory_at_0, loc_6 + 16)
														if loc_0 ~= 0 then
															break
														end
														loc_0 = load_i32(memory_at_0, add_i32(loc_6, 20))
														if loc_0 ~= 0 then
															break
														end
														loc_5 = load_i32(memory_at_0, loc_7 + 24)
														while true do
															while true do
																while true do
																	loc_0 = load_i32(memory_at_0, loc_7 + 12)
																	if loc_0 ~= loc_7 then
																		break
																	end
																	loc_0 = add_i32(loc_7, 20)
																	loc_8 = load_i32(memory_at_0, loc_0)
																	loc_6 = load_i32(memory_at_0, add_i32(loc_7, (if loc_8 ~= 0 then 20 else 16)))
																	if loc_6 ~= 0 then
																		desired = 14
																		break
																	end
																	loc_0 = 0
																	desired = 13
																	break
																end
																if desired then
																	if desired == 14 then
																		desired = nil
																	end
																	break
																end
																loc_6 = load_i32(memory_at_0, loc_7 + 8)
																store_i32(memory_at_0, loc_6 + 12, loc_0)
																store_i32(memory_at_0, loc_0 + 8, loc_6)
																desired = 13
																break
															end
															if desired then
																if desired == 13 then
																	desired = nil
																end
																break
															end
															loc_8 = (if loc_8 ~= 0 then loc_0 else add_i32(loc_7, 16))
															while true do
																loc_9 = loc_8
																loc_0 = loc_6
																loc_6 = add_i32(loc_0, 20)
																reg_0 = loc_6
																loc_6 = load_i32(memory_at_0, loc_6)
																loc_8 = (if loc_6 ~= 0 then reg_0 else add_i32(loc_0, 16))
																loc_6 = load_i32(memory_at_0, add_i32(loc_0, (if loc_6 ~= 0 then 20 else 16)))
																if loc_6 ~= 0 then
																	continue
																end
																break
															end
															if desired then
																if desired == 13 then
																	desired = nil
																end
																break
															end
															store_i32(memory_at_0, loc_9, 0)
															break
														end
														if desired then
															if desired == 12 then
																desired = nil
															end
															break
														end
														if loc_5 == 0 then
															desired = 8
															break
														end
														while true do
															loc_6 = add_i32(shl_i32(load_i32(memory_at_0, loc_7 + 28), 2), 1084792)
															if load_i32(memory_at_0, loc_6) == loc_7 then
																break
															end
															store_i32(memory_at_0, add_i32(loc_5, (if load_i32(memory_at_0, loc_5 + 16) == loc_7 then 16 else 20)), loc_0)
															if loc_0 == 0 then
																desired = 8
																break
															end
															desired = 9
															break
														end
														if desired then
															if desired == 12 then
																desired = nil
															end
															break
														end
														store_i32(memory_at_0, loc_6, loc_0)
														if loc_0 ~= 0 then
															desired = 9
															break
														end
														store_i32(memory_at_0, 0 + 1085204, band_i32(load_i32(memory_at_0, 0 + 1085204), rotl_i32(4294967294, load_i32(memory_at_0, loc_7 + 28))))
														desired = 8
														break
													end
													if desired then
														if desired == 11 then
															desired = nil
															continue
														end
														break
													end
													loc_6 = sub_i32(band_i32(load_i32(memory_at_0, loc_0 + 4), 4294967288), loc_3)
													reg_0 = loc_6
													loc_6 = (if loc_6 < loc_2 then 1 else 0)
													loc_2 = (if loc_6 ~= 0 then reg_0 else loc_2)
													loc_7 = (if loc_6 ~= 0 then loc_0 else loc_7)
													loc_6 = loc_0
													continue
												end
												if desired then
													if desired == 10 then
														desired = nil
													end
													break
												end
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											while true do
												while true do
													reg_0 = shl_i32(loc_0, loc_2)
													loc_0 = shl_i32(2, loc_2)
													loc_2 = ctz_i32(band_i32(reg_0, bor_i32(loc_0, sub_i32(0, loc_0))))
													loc_0 = shl_i32(loc_2, 3)
													loc_6 = add_i32(loc_0, 1084936)
													loc_0 = load_i32(memory_at_0, add_i32(loc_0, 1084944))
													loc_8 = load_i32(memory_at_0, loc_0 + 8)
													if loc_6 == loc_8 then
														break
													end
													store_i32(memory_at_0, loc_8 + 12, loc_6)
													store_i32(memory_at_0, loc_6 + 8, loc_8)
													desired = 10
													break
												end
												if desired then
													if desired == 10 then
														desired = nil
													end
													break
												end
												store_i32(memory_at_0, 0 + 1085200, band_i32(loc_7, rotl_i32(4294967294, loc_2)))
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											store_i32(memory_at_0, loc_0 + 4, bor_i32(loc_3, 3))
											loc_8 = add_i32(loc_0, loc_3)
											loc_2 = shl_i32(loc_2, 3)
											loc_6 = sub_i32(loc_2, loc_3)
											store_i32(memory_at_0, loc_8 + 4, bor_i32(loc_6, 1))
											store_i32(memory_at_0, add_i32(loc_0, loc_2), loc_6)
											while true do
												loc_7 = load_i32(memory_at_0, 0 + 1085208)
												if loc_7 == 0 then
													break
												end
												loc_2 = add_i32(band_i32(loc_7, 4294967288), 1084936)
												loc_3 = load_i32(memory_at_0, 0 + 1085216)
												while true do
													while true do
														loc_9 = load_i32(memory_at_0, 0 + 1085200)
														loc_7 = shl_i32(1, shr_u32(loc_7, 3))
														if band_i32(loc_9, loc_7) ~= 0 then
															break
														end
														store_i32(memory_at_0, 0 + 1085200, bor_i32(loc_9, loc_7))
														loc_7 = loc_2
														desired = 11
														break
													end
													if desired then
														if desired == 11 then
															desired = nil
														end
														break
													end
													loc_7 = load_i32(memory_at_0, loc_2 + 8)
													break
												end
												if desired then
													if desired == 10 then
														desired = nil
													end
													break
												end
												store_i32(memory_at_0, loc_2 + 8, loc_3)
												store_i32(memory_at_0, loc_7 + 12, loc_3)
												store_i32(memory_at_0, loc_3 + 12, loc_2)
												store_i32(memory_at_0, loc_3 + 8, loc_7)
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											loc_2 = add_i32(loc_0, 8)
											store_i32(memory_at_0, 0 + 1085216, loc_8)
											store_i32(memory_at_0, 0 + 1085208, loc_6)
											desired = 1
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										store_i32(memory_at_0, loc_0 + 24, loc_5)
										while true do
											loc_6 = load_i32(memory_at_0, loc_7 + 16)
											if loc_6 == 0 then
												break
											end
											store_i32(memory_at_0, loc_0 + 16, loc_6)
											store_i32(memory_at_0, loc_6 + 24, loc_0)
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										loc_6 = load_i32(memory_at_0, add_i32(loc_7, 20))
										if loc_6 == 0 then
											break
										end
										store_i32(memory_at_0, add_i32(loc_0, 20), loc_6)
										store_i32(memory_at_0, loc_6 + 24, loc_0)
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									while true do
										while true do
											while true do
												if loc_2 < 16 then
													break
												end
												store_i32(memory_at_0, loc_7 + 4, bor_i32(loc_3, 3))
												loc_3 = add_i32(loc_7, loc_3)
												store_i32(memory_at_0, loc_3 + 4, bor_i32(loc_2, 1))
												store_i32(memory_at_0, add_i32(loc_3, loc_2), loc_2)
												loc_8 = load_i32(memory_at_0, 0 + 1085208)
												if loc_8 == 0 then
													desired = 9
													break
												end
												loc_6 = add_i32(band_i32(loc_8, 4294967288), 1084936)
												loc_0 = load_i32(memory_at_0, 0 + 1085216)
												while true do
													while true do
														loc_9 = load_i32(memory_at_0, 0 + 1085200)
														loc_8 = shl_i32(1, shr_u32(loc_8, 3))
														if band_i32(loc_9, loc_8) ~= 0 then
															break
														end
														store_i32(memory_at_0, 0 + 1085200, bor_i32(loc_9, loc_8))
														loc_8 = loc_6
														desired = 11
														break
													end
													if desired then
														if desired == 11 then
															desired = nil
														end
														break
													end
													loc_8 = load_i32(memory_at_0, loc_6 + 8)
													break
												end
												if desired then
													if desired == 10 then
														desired = nil
													end
													break
												end
												store_i32(memory_at_0, loc_6 + 8, loc_0)
												store_i32(memory_at_0, loc_8 + 12, loc_0)
												store_i32(memory_at_0, loc_0 + 12, loc_6)
												store_i32(memory_at_0, loc_0 + 8, loc_8)
												desired = 9
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											loc_0 = add_i32(loc_2, loc_3)
											store_i32(memory_at_0, loc_7 + 4, bor_i32(loc_0, 3))
											loc_0 = add_i32(loc_7, loc_0)
											store_i32(memory_at_0, loc_0 + 4, bor_i32(load_i32(memory_at_0, loc_0 + 4), 1))
											desired = 8
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										store_i32(memory_at_0, 0 + 1085216, loc_3)
										store_i32(memory_at_0, 0 + 1085208, loc_2)
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									loc_2 = add_i32(loc_7, 8)
									desired = 1
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								while true do
									if bor_i32(loc_0, loc_7) ~= 0 then
										break
									end
									loc_7 = 0
									loc_0 = shl_i32(2, loc_5)
									loc_0 = band_i32(bor_i32(loc_0, sub_i32(0, loc_0)), loc_4)
									if loc_0 == 0 then
										desired = 4
										break
									end
									loc_0 = load_i32(memory_at_0, add_i32(shl_i32(ctz_i32(loc_0), 2), 1084792))
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								if loc_0 == 0 then
									desired = 5
									break
								end
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							while true do
								loc_6 = band_i32(load_i32(memory_at_0, loc_0 + 4), 4294967288)
								loc_9 = sub_i32(loc_6, loc_3)
								loc_5 = (if loc_9 < loc_2 then 1 else 0)
								loc_4 = (if loc_5 ~= 0 then loc_0 else loc_7)
								loc_8 = (if loc_6 < loc_3 then 1 else 0)
								loc_9 = (if loc_5 ~= 0 then loc_9 else loc_2)
								while true do
									loc_6 = load_i32(memory_at_0, loc_0 + 16)
									if loc_6 ~= 0 then
										break
									end
									loc_6 = load_i32(memory_at_0, add_i32(loc_0, 20))
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
										continue
									end
									break
								end
								loc_7 = (if loc_8 ~= 0 then loc_7 else loc_4)
								loc_2 = (if loc_8 ~= 0 then loc_2 else loc_9)
								loc_0 = loc_6
								if loc_6 ~= 0 then
									continue
								end
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						if loc_7 == 0 then
							break
						end
						while true do
							loc_0 = load_i32(memory_at_0, 0 + 1085208)
							if loc_0 < loc_3 then
								break
							end
							if loc_2 >= sub_i32(loc_0, loc_3) then
								desired = 4
								break
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_5 = load_i32(memory_at_0, loc_7 + 24)
						while true do
							while true do
								while true do
									loc_0 = load_i32(memory_at_0, loc_7 + 12)
									if loc_0 ~= loc_7 then
										break
									end
									loc_0 = add_i32(loc_7, 20)
									loc_8 = load_i32(memory_at_0, loc_0)
									loc_6 = load_i32(memory_at_0, add_i32(loc_7, (if loc_8 ~= 0 then 20 else 16)))
									if loc_6 ~= 0 then
										desired = 6
										break
									end
									loc_0 = 0
									desired = 5
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								loc_6 = load_i32(memory_at_0, loc_7 + 8)
								store_i32(memory_at_0, loc_6 + 12, loc_0)
								store_i32(memory_at_0, loc_0 + 8, loc_6)
								desired = 5
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_8 = (if loc_8 ~= 0 then loc_0 else add_i32(loc_7, 16))
							while true do
								loc_9 = loc_8
								loc_0 = loc_6
								loc_6 = add_i32(loc_0, 20)
								reg_0 = loc_6
								loc_6 = load_i32(memory_at_0, loc_6)
								loc_8 = (if loc_6 ~= 0 then reg_0 else add_i32(loc_0, 16))
								loc_6 = load_i32(memory_at_0, add_i32(loc_0, (if loc_6 ~= 0 then 20 else 16)))
								if loc_6 ~= 0 then
									continue
								end
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							store_i32(memory_at_0, loc_9, 0)
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						if loc_5 == 0 then
							desired = 2
							break
						end
						while true do
							loc_6 = add_i32(shl_i32(load_i32(memory_at_0, loc_7 + 28), 2), 1084792)
							if load_i32(memory_at_0, loc_6) == loc_7 then
								break
							end
							store_i32(memory_at_0, add_i32(loc_5, (if load_i32(memory_at_0, loc_5 + 16) == loc_7 then 16 else 20)), loc_0)
							if loc_0 == 0 then
								desired = 2
								break
							end
							desired = 3
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						store_i32(memory_at_0, loc_6, loc_0)
						if loc_0 ~= 0 then
							desired = 3
							break
						end
						store_i32(memory_at_0, 0 + 1085204, band_i32(load_i32(memory_at_0, 0 + 1085204), rotl_i32(4294967294, load_i32(memory_at_0, loc_7 + 28))))
						desired = 2
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					while true do
						while true do
							while true do
								while true do
									while true do
										while true do
											loc_0 = load_i32(memory_at_0, 0 + 1085208)
											if loc_0 >= loc_3 then
												break
											end
											while true do
												loc_0 = load_i32(memory_at_0, 0 + 1085212)
												if loc_0 > loc_3 then
													break
												end
												FUNC_LIST[165](add_i32(loc_1, 4), 1085244, band_i32(add_i32(loc_3, 65583), 4294901760))
												while true do
													loc_7 = load_i32(memory_at_0, loc_1 + 4)
													if loc_7 ~= 0 then
														break
													end
													loc_2 = 0
													desired = 1
													break
												end
												if desired then
													if desired == 10 then
														desired = nil
													end
													break
												end
												loc_5 = load_i32(memory_at_0, loc_1 + 12)
												loc_9 = load_i32(memory_at_0, loc_1 + 8)
												loc_0 = add_i32(load_i32(memory_at_0, 0 + 1085224), loc_9)
												store_i32(memory_at_0, 0 + 1085224, loc_0)
												loc_2 = load_i32(memory_at_0, 0 + 1085228)
												store_i32(memory_at_0, 0 + 1085228, (if loc_2 > loc_0 then loc_2 else loc_0))
												while true do
													while true do
														while true do
															loc_2 = load_i32(memory_at_0, 0 + 1085220)
															if loc_2 == 0 then
																break
															end
															loc_0 = 1084920
															while true do
																loc_6 = load_i32(memory_at_0, loc_0)
																loc_8 = load_i32(memory_at_0, loc_0 + 4)
																if loc_7 == add_i32(loc_6, loc_8) then
																	desired = 12
																	break
																end
																loc_0 = load_i32(memory_at_0, loc_0 + 8)
																if loc_0 ~= 0 then
																	continue
																end
																desired = 11
																break
															end
															if desired then
																if desired == 13 then
																	desired = nil
																end
																break
															end
															break
														end
														if desired then
															if desired == 12 then
																desired = nil
															end
															break
														end
														while true do
															while true do
																loc_0 = load_i32(memory_at_0, 0 + 1085236)
																if loc_0 == 0 then
																	break
																end
																if loc_7 >= loc_0 then
																	desired = 13
																	break
																end
																break
															end
															if desired then
																if desired == 13 then
																	desired = nil
																end
																break
															end
															store_i32(memory_at_0, 0 + 1085236, loc_7)
															break
														end
														if desired then
															if desired == 12 then
																desired = nil
															end
															break
														end
														store_i32(memory_at_0, 0 + 1085240, 4095)
														store_i32(memory_at_0, 0 + 1084932, loc_5)
														store_i32(memory_at_0, 0 + 1084924, loc_9)
														store_i32(memory_at_0, 0 + 1084920, loc_7)
														store_i32(memory_at_0, 0 + 1084948, 1084936)
														store_i32(memory_at_0, 0 + 1084956, 1084944)
														store_i32(memory_at_0, 0 + 1084944, 1084936)
														store_i32(memory_at_0, 0 + 1084964, 1084952)
														store_i32(memory_at_0, 0 + 1084952, 1084944)
														store_i32(memory_at_0, 0 + 1084972, 1084960)
														store_i32(memory_at_0, 0 + 1084960, 1084952)
														store_i32(memory_at_0, 0 + 1084980, 1084968)
														store_i32(memory_at_0, 0 + 1084968, 1084960)
														store_i32(memory_at_0, 0 + 1084988, 1084976)
														store_i32(memory_at_0, 0 + 1084976, 1084968)
														store_i32(memory_at_0, 0 + 1084996, 1084984)
														store_i32(memory_at_0, 0 + 1084984, 1084976)
														store_i32(memory_at_0, 0 + 1085004, 1084992)
														store_i32(memory_at_0, 0 + 1084992, 1084984)
														store_i32(memory_at_0, 0 + 1085012, 1085000)
														store_i32(memory_at_0, 0 + 1085000, 1084992)
														store_i32(memory_at_0, 0 + 1085008, 1085000)
														store_i32(memory_at_0, 0 + 1085020, 1085008)
														store_i32(memory_at_0, 0 + 1085016, 1085008)
														store_i32(memory_at_0, 0 + 1085028, 1085016)
														store_i32(memory_at_0, 0 + 1085024, 1085016)
														store_i32(memory_at_0, 0 + 1085036, 1085024)
														store_i32(memory_at_0, 0 + 1085032, 1085024)
														store_i32(memory_at_0, 0 + 1085044, 1085032)
														store_i32(memory_at_0, 0 + 1085040, 1085032)
														store_i32(memory_at_0, 0 + 1085052, 1085040)
														store_i32(memory_at_0, 0 + 1085048, 1085040)
														store_i32(memory_at_0, 0 + 1085060, 1085048)
														store_i32(memory_at_0, 0 + 1085056, 1085048)
														store_i32(memory_at_0, 0 + 1085068, 1085056)
														store_i32(memory_at_0, 0 + 1085064, 1085056)
														store_i32(memory_at_0, 0 + 1085076, 1085064)
														store_i32(memory_at_0, 0 + 1085084, 1085072)
														store_i32(memory_at_0, 0 + 1085072, 1085064)
														store_i32(memory_at_0, 0 + 1085092, 1085080)
														store_i32(memory_at_0, 0 + 1085080, 1085072)
														store_i32(memory_at_0, 0 + 1085100, 1085088)
														store_i32(memory_at_0, 0 + 1085088, 1085080)
														store_i32(memory_at_0, 0 + 1085108, 1085096)
														store_i32(memory_at_0, 0 + 1085096, 1085088)
														store_i32(memory_at_0, 0 + 1085116, 1085104)
														store_i32(memory_at_0, 0 + 1085104, 1085096)
														store_i32(memory_at_0, 0 + 1085124, 1085112)
														store_i32(memory_at_0, 0 + 1085112, 1085104)
														store_i32(memory_at_0, 0 + 1085132, 1085120)
														store_i32(memory_at_0, 0 + 1085120, 1085112)
														store_i32(memory_at_0, 0 + 1085140, 1085128)
														store_i32(memory_at_0, 0 + 1085128, 1085120)
														store_i32(memory_at_0, 0 + 1085148, 1085136)
														store_i32(memory_at_0, 0 + 1085136, 1085128)
														store_i32(memory_at_0, 0 + 1085156, 1085144)
														store_i32(memory_at_0, 0 + 1085144, 1085136)
														store_i32(memory_at_0, 0 + 1085164, 1085152)
														store_i32(memory_at_0, 0 + 1085152, 1085144)
														store_i32(memory_at_0, 0 + 1085172, 1085160)
														store_i32(memory_at_0, 0 + 1085160, 1085152)
														store_i32(memory_at_0, 0 + 1085180, 1085168)
														store_i32(memory_at_0, 0 + 1085168, 1085160)
														store_i32(memory_at_0, 0 + 1085188, 1085176)
														store_i32(memory_at_0, 0 + 1085176, 1085168)
														store_i32(memory_at_0, 0 + 1085196, 1085184)
														store_i32(memory_at_0, 0 + 1085184, 1085176)
														loc_0 = band_i32(add_i32(loc_7, 15), 4294967288)
														loc_2 = add_i32(loc_0, 4294967288)
														store_i32(memory_at_0, 0 + 1085220, loc_2)
														store_i32(memory_at_0, 0 + 1085192, 1085184)
														reg_1 = sub_i32(loc_7, loc_0)
														loc_0 = add_i32(loc_9, 4294967256)
														loc_6 = add_i32(add_i32(reg_1, loc_0), 8)
														store_i32(memory_at_0, 0 + 1085212, loc_6)
														store_i32(memory_at_0, loc_2 + 4, bor_i32(loc_6, 1))
														store_i32(memory_at_0, add_i32(loc_7, loc_0) + 4, 40)
														store_i32(memory_at_0, 0 + 1085232, 2097152)
														desired = 4
														break
													end
													if desired then
														if desired == 11 then
															desired = nil
														end
														break
													end
													if loc_2 >= loc_7 then
														break
													end
													if loc_6 > loc_2 then
														break
													end
													loc_6 = load_i32(memory_at_0, loc_0 + 12)
													if band_i32(loc_6, 1) ~= 0 then
														break
													end
													if shr_u32(loc_6, 1) == loc_5 then
														desired = 8
														break
													end
													break
												end
												if desired then
													if desired == 10 then
														desired = nil
													end
													break
												end
												loc_0 = load_i32(memory_at_0, 0 + 1085236)
												store_i32(memory_at_0, 0 + 1085236, (if loc_7 > loc_0 then loc_0 else loc_7))
												loc_6 = add_i32(loc_7, loc_9)
												loc_0 = 1084920
												while true do
													while true do
														while true do
															while true do
																if load_i32(memory_at_0, loc_0) == loc_6 then
																	desired = 13
																	break
																end
																loc_0 = load_i32(memory_at_0, loc_0 + 8)
																if loc_0 ~= 0 then
																	continue
																end
																desired = 12
																break
															end
															if desired then
																if desired == 13 then
																	desired = nil
																end
																break
															end
															break
														end
														if desired then
															if desired == 12 then
																desired = nil
															end
															break
														end
														loc_8 = load_i32(memory_at_0, loc_0 + 12)
														if band_i32(loc_8, 1) ~= 0 then
															break
														end
														if shr_u32(loc_8, 1) == loc_5 then
															desired = 11
															break
														end
														break
													end
													if desired then
														if desired == 11 then
															desired = nil
														end
														break
													end
													loc_0 = 1084920
													while true do
														while true do
															while true do
																loc_6 = load_i32(memory_at_0, loc_0)
																if loc_6 > loc_2 then
																	break
																end
																loc_6 = add_i32(loc_6, load_i32(memory_at_0, loc_0 + 4))
																if loc_6 > loc_2 then
																	desired = 12
																	break
																end
																break
															end
															if desired then
																if desired == 13 then
																	desired = nil
																	continue
																end
																break
															end
															loc_0 = load_i32(memory_at_0, loc_0 + 8)
															continue
														end
														if desired then
															if desired == 12 then
																desired = nil
															end
															break
														end
														break
													end
													if desired then
														if desired == 11 then
															desired = nil
														end
														break
													end
													loc_0 = band_i32(add_i32(loc_7, 15), 4294967288)
													loc_8 = add_i32(loc_0, 4294967288)
													store_i32(memory_at_0, 0 + 1085220, loc_8)
													reg_1 = sub_i32(loc_7, loc_0)
													loc_0 = add_i32(loc_9, 4294967256)
													loc_4 = add_i32(add_i32(reg_1, loc_0), 8)
													store_i32(memory_at_0, 0 + 1085212, loc_4)
													store_i32(memory_at_0, loc_8 + 4, bor_i32(loc_4, 1))
													store_i32(memory_at_0, add_i32(loc_7, loc_0) + 4, 40)
													store_i32(memory_at_0, 0 + 1085232, 2097152)
													loc_0 = add_i32(band_i32(add_i32(loc_6, 4294967264), 4294967288), 4294967288)
													loc_8 = (if loc_0 < add_i32(loc_2, 16) then loc_2 else loc_0)
													store_i32(memory_at_0, loc_8 + 4, 27)
													loc_10 = load_i64(memory_at_0, 0 + 1084920)
													store_i64(memory_at_0, add_i32(loc_8, 16), load_i64(memory_at_0, 0 + 1084928))
													store_i64(memory_at_0, loc_8 + 8, loc_10)
													store_i32(memory_at_0, 0 + 1084932, loc_5)
													store_i32(memory_at_0, 0 + 1084924, loc_9)
													store_i32(memory_at_0, 0 + 1084920, loc_7)
													store_i32(memory_at_0, 0 + 1084928, add_i32(loc_8, 8))
													loc_0 = add_i32(loc_8, 28)
													while true do
														store_i32(memory_at_0, loc_0, 7)
														loc_0 = add_i32(loc_0, 4)
														if loc_0 < loc_6 then
															continue
														end
														break
													end
													if desired then
														if desired == 11 then
															desired = nil
														end
														break
													end
													if loc_8 == loc_2 then
														desired = 4
														break
													end
													store_i32(memory_at_0, loc_8 + 4, band_i32(load_i32(memory_at_0, loc_8 + 4), 4294967294))
													loc_0 = sub_i32(loc_8, loc_2)
													store_i32(memory_at_0, loc_2 + 4, bor_i32(loc_0, 1))
													store_i32(memory_at_0, loc_8, loc_0)
													while true do
														if loc_0 < 256 then
															break
														end
														FUNC_LIST[132](loc_2, loc_0)
														desired = 4
														break
													end
													if desired then
														if desired == 11 then
															desired = nil
														end
														break
													end
													loc_6 = add_i32(band_i32(loc_0, 4294967288), 1084936)
													while true do
														while true do
															loc_7 = load_i32(memory_at_0, 0 + 1085200)
															loc_0 = shl_i32(1, shr_u32(loc_0, 3))
															if band_i32(loc_7, loc_0) ~= 0 then
																break
															end
															store_i32(memory_at_0, 0 + 1085200, bor_i32(loc_7, loc_0))
															loc_0 = loc_6
															desired = 12
															break
														end
														if desired then
															if desired == 12 then
																desired = nil
															end
															break
														end
														loc_0 = load_i32(memory_at_0, loc_6 + 8)
														break
													end
													if desired then
														if desired == 11 then
															desired = nil
														end
														break
													end
													store_i32(memory_at_0, loc_6 + 8, loc_2)
													store_i32(memory_at_0, loc_0 + 12, loc_2)
													store_i32(memory_at_0, loc_2 + 12, loc_6)
													store_i32(memory_at_0, loc_2 + 8, loc_0)
													desired = 4
													break
												end
												if desired then
													if desired == 10 then
														desired = nil
													end
													break
												end
												store_i32(memory_at_0, loc_0, loc_7)
												store_i32(memory_at_0, loc_0 + 4, add_i32(load_i32(memory_at_0, loc_0 + 4), loc_9))
												loc_7 = add_i32(band_i32(add_i32(loc_7, 15), 4294967288), 4294967288)
												store_i32(memory_at_0, loc_7 + 4, bor_i32(loc_3, 3))
												loc_2 = add_i32(band_i32(add_i32(loc_6, 15), 4294967288), 4294967288)
												loc_0 = add_i32(loc_7, loc_3)
												loc_3 = sub_i32(loc_2, loc_0)
												if loc_2 == load_i32(memory_at_0, 0 + 1085220) then
													desired = 7
													break
												end
												if loc_2 == load_i32(memory_at_0, 0 + 1085216) then
													desired = 6
													break
												end
												while true do
													loc_6 = load_i32(memory_at_0, loc_2 + 4)
													if band_i32(loc_6, 3) ~= 1 then
														break
													end
													loc_6 = band_i32(loc_6, 4294967288)
													FUNC_LIST[130](loc_2, loc_6)
													loc_3 = add_i32(loc_6, loc_3)
													loc_2 = add_i32(loc_2, loc_6)
													loc_6 = load_i32(memory_at_0, loc_2 + 4)
													break
												end
												if desired then
													if desired == 10 then
														desired = nil
													end
													break
												end
												store_i32(memory_at_0, loc_2 + 4, band_i32(loc_6, 4294967294))
												store_i32(memory_at_0, loc_0 + 4, bor_i32(loc_3, 1))
												store_i32(memory_at_0, add_i32(loc_0, loc_3), loc_3)
												while true do
													if loc_3 < 256 then
														break
													end
													FUNC_LIST[132](loc_0, loc_3)
													desired = 5
													break
												end
												if desired then
													if desired == 10 then
														desired = nil
													end
													break
												end
												loc_2 = add_i32(band_i32(loc_3, 4294967288), 1084936)
												while true do
													while true do
														loc_6 = load_i32(memory_at_0, 0 + 1085200)
														loc_3 = shl_i32(1, shr_u32(loc_3, 3))
														if band_i32(loc_6, loc_3) ~= 0 then
															break
														end
														store_i32(memory_at_0, 0 + 1085200, bor_i32(loc_6, loc_3))
														loc_3 = loc_2
														desired = 11
														break
													end
													if desired then
														if desired == 11 then
															desired = nil
														end
														break
													end
													loc_3 = load_i32(memory_at_0, loc_2 + 8)
													break
												end
												if desired then
													if desired == 10 then
														desired = nil
													end
													break
												end
												store_i32(memory_at_0, loc_2 + 8, loc_0)
												store_i32(memory_at_0, loc_3 + 12, loc_0)
												store_i32(memory_at_0, loc_0 + 12, loc_2)
												store_i32(memory_at_0, loc_0 + 8, loc_3)
												desired = 5
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											loc_2 = sub_i32(loc_0, loc_3)
											store_i32(memory_at_0, 0 + 1085212, loc_2)
											loc_0 = load_i32(memory_at_0, 0 + 1085220)
											loc_6 = add_i32(loc_0, loc_3)
											store_i32(memory_at_0, 0 + 1085220, loc_6)
											store_i32(memory_at_0, loc_6 + 4, bor_i32(loc_2, 1))
											store_i32(memory_at_0, loc_0 + 4, bor_i32(loc_3, 3))
											loc_2 = add_i32(loc_0, 8)
											desired = 1
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										loc_2 = load_i32(memory_at_0, 0 + 1085216)
										while true do
											while true do
												loc_6 = sub_i32(loc_0, loc_3)
												if loc_6 > 15 then
													break
												end
												store_i32(memory_at_0, 0 + 1085216, 0)
												store_i32(memory_at_0, 0 + 1085208, 0)
												store_i32(memory_at_0, loc_2 + 4, bor_i32(loc_0, 3))
												loc_0 = add_i32(loc_2, loc_0)
												store_i32(memory_at_0, loc_0 + 4, bor_i32(load_i32(memory_at_0, loc_0 + 4), 1))
												desired = 9
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											store_i32(memory_at_0, 0 + 1085208, loc_6)
											loc_7 = add_i32(loc_2, loc_3)
											store_i32(memory_at_0, 0 + 1085216, loc_7)
											store_i32(memory_at_0, loc_7 + 4, bor_i32(loc_6, 1))
											store_i32(memory_at_0, add_i32(loc_2, loc_0), loc_6)
											store_i32(memory_at_0, loc_2 + 4, bor_i32(loc_3, 3))
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										loc_2 = add_i32(loc_2, 8)
										desired = 1
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									store_i32(memory_at_0, loc_0 + 4, add_i32(loc_8, loc_9))
									loc_0 = load_i32(memory_at_0, 0 + 1085220)
									loc_2 = band_i32(add_i32(loc_0, 15), 4294967288)
									loc_6 = add_i32(loc_2, 4294967288)
									store_i32(memory_at_0, 0 + 1085220, loc_6)
									reg_1 = sub_i32(loc_0, loc_2)
									loc_2 = add_i32(load_i32(memory_at_0, 0 + 1085212), loc_9)
									loc_7 = add_i32(add_i32(reg_1, loc_2), 8)
									store_i32(memory_at_0, 0 + 1085212, loc_7)
									store_i32(memory_at_0, loc_6 + 4, bor_i32(loc_7, 1))
									store_i32(memory_at_0, add_i32(loc_0, loc_2) + 4, 40)
									store_i32(memory_at_0, 0 + 1085232, 2097152)
									desired = 4
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								store_i32(memory_at_0, 0 + 1085220, loc_0)
								loc_3 = add_i32(load_i32(memory_at_0, 0 + 1085212), loc_3)
								store_i32(memory_at_0, 0 + 1085212, loc_3)
								store_i32(memory_at_0, loc_0 + 4, bor_i32(loc_3, 1))
								desired = 5
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							store_i32(memory_at_0, 0 + 1085216, loc_0)
							loc_3 = add_i32(load_i32(memory_at_0, 0 + 1085208), loc_3)
							store_i32(memory_at_0, 0 + 1085208, loc_3)
							store_i32(memory_at_0, loc_0 + 4, bor_i32(loc_3, 1))
							store_i32(memory_at_0, add_i32(loc_0, loc_3), loc_3)
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_2 = add_i32(loc_7, 8)
						desired = 1
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_2 = 0
					loc_0 = load_i32(memory_at_0, 0 + 1085212)
					if loc_0 <= loc_3 then
						desired = 1
						break
					end
					loc_2 = sub_i32(loc_0, loc_3)
					store_i32(memory_at_0, 0 + 1085212, loc_2)
					loc_0 = load_i32(memory_at_0, 0 + 1085220)
					loc_6 = add_i32(loc_0, loc_3)
					store_i32(memory_at_0, 0 + 1085220, loc_6)
					store_i32(memory_at_0, loc_6 + 4, bor_i32(loc_2, 1))
					store_i32(memory_at_0, loc_0 + 4, bor_i32(loc_3, 3))
					loc_2 = add_i32(loc_0, 8)
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i32(memory_at_0, loc_0 + 24, loc_5)
				while true do
					loc_6 = load_i32(memory_at_0, loc_7 + 16)
					if loc_6 == 0 then
						break
					end
					store_i32(memory_at_0, loc_0 + 16, loc_6)
					store_i32(memory_at_0, loc_6 + 24, loc_0)
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_6 = load_i32(memory_at_0, add_i32(loc_7, 20))
				if loc_6 == 0 then
					break
				end
				store_i32(memory_at_0, add_i32(loc_0, 20), loc_6)
				store_i32(memory_at_0, loc_6 + 24, loc_0)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				while true do
					if loc_2 < 16 then
						break
					end
					store_i32(memory_at_0, loc_7 + 4, bor_i32(loc_3, 3))
					loc_0 = add_i32(loc_7, loc_3)
					store_i32(memory_at_0, loc_0 + 4, bor_i32(loc_2, 1))
					store_i32(memory_at_0, add_i32(loc_0, loc_2), loc_2)
					while true do
						if loc_2 < 256 then
							break
						end
						FUNC_LIST[132](loc_0, loc_2)
						desired = 2
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_3 = add_i32(band_i32(loc_2, 4294967288), 1084936)
					while true do
						while true do
							loc_6 = load_i32(memory_at_0, 0 + 1085200)
							loc_2 = shl_i32(1, shr_u32(loc_2, 3))
							if band_i32(loc_6, loc_2) ~= 0 then
								break
							end
							store_i32(memory_at_0, 0 + 1085200, bor_i32(loc_6, loc_2))
							loc_2 = loc_3
							desired = 4
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_2 = load_i32(memory_at_0, loc_3 + 8)
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32(memory_at_0, loc_3 + 8, loc_0)
					store_i32(memory_at_0, loc_2 + 12, loc_0)
					store_i32(memory_at_0, loc_0 + 12, loc_3)
					store_i32(memory_at_0, loc_0 + 8, loc_2)
					desired = 2
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_0 = add_i32(loc_2, loc_3)
				store_i32(memory_at_0, loc_7 + 4, bor_i32(loc_0, 3))
				loc_0 = add_i32(loc_7, loc_0)
				store_i32(memory_at_0, loc_0 + 4, bor_i32(load_i32(memory_at_0, loc_0 + 4), 1))
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_2 = add_i32(loc_7, 8)
			break
		end
		GLOBAL_LIST[0].value = add_i32(loc_1, 16)
		reg_0 = loc_2
		break
	end
	return reg_0
end
FUNC_LIST[135] = --[[ _ZN8dlmalloc8dlmalloc17Dlmalloc$LT$A$GT$8memalign17h95a0dc8e51b400b1E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local reg_0
	local desired
	while true do
		loc_2 = 0
		while true do
			loc_0 = (if loc_0 > 16 then loc_0 else 16)
			if sub_i32(4294901709, loc_0) <= loc_1 then
				break
			end
			loc_3 = (if loc_1 < 11 then 16 else band_i32(add_i32(loc_1, 11), 4294967288))
			reg_0 = FUNC_LIST[134](add_i32(add_i32(loc_0, loc_3), 12))
			loc_1 = reg_0
			if loc_1 == 0 then
				break
			end
			loc_2 = add_i32(loc_1, 4294967288)
			while true do
				while true do
					loc_4 = add_i32(loc_0, 4294967295)
					if band_i32(loc_4, loc_1) ~= 0 then
						break
					end
					loc_0 = loc_2
					desired = 2
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_5 = add_i32(loc_1, 4294967292)
				loc_6 = load_i32(memory_at_0, loc_5)
				loc_1 = add_i32(band_i32(add_i32(loc_4, loc_1), sub_i32(0, loc_0)), 4294967288)
				loc_0 = add_i32(loc_1, (if sub_i32(loc_1, loc_2) > 16 then 0 else loc_0))
				loc_1 = sub_i32(loc_0, loc_2)
				loc_4 = sub_i32(band_i32(loc_6, 4294967288), loc_1)
				while true do
					if band_i32(loc_6, 3) == 0 then
						break
					end
					store_i32(memory_at_0, loc_0 + 4, bor_i32(bor_i32(loc_4, band_i32(load_i32(memory_at_0, loc_0 + 4), 1)), 2))
					loc_4 = add_i32(loc_0, loc_4)
					store_i32(memory_at_0, loc_4 + 4, bor_i32(load_i32(memory_at_0, loc_4 + 4), 1))
					store_i32(memory_at_0, loc_5, bor_i32(bor_i32(loc_1, band_i32(load_i32(memory_at_0, loc_5), 1)), 2))
					loc_4 = add_i32(loc_2, loc_1)
					store_i32(memory_at_0, loc_4 + 4, bor_i32(load_i32(memory_at_0, loc_4 + 4), 1))
					FUNC_LIST[131](loc_2, loc_1)
					desired = 2
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_2 = load_i32(memory_at_0, loc_2)
				store_i32(memory_at_0, loc_0 + 4, loc_4)
				store_i32(memory_at_0, loc_0, add_i32(loc_2, loc_1))
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				loc_1 = load_i32(memory_at_0, loc_0 + 4)
				if band_i32(loc_1, 3) == 0 then
					break
				end
				loc_2 = band_i32(loc_1, 4294967288)
				if loc_2 <= add_i32(loc_3, 16) then
					break
				end
				store_i32(memory_at_0, loc_0 + 4, bor_i32(bor_i32(loc_3, band_i32(loc_1, 1)), 2))
				loc_1 = add_i32(loc_0, loc_3)
				loc_3 = sub_i32(loc_2, loc_3)
				store_i32(memory_at_0, loc_1 + 4, bor_i32(loc_3, 3))
				loc_2 = add_i32(loc_0, loc_2)
				store_i32(memory_at_0, loc_2 + 4, bor_i32(load_i32(memory_at_0, loc_2 + 4), 1))
				FUNC_LIST[131](loc_1, loc_3)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_2 = add_i32(loc_0, 8)
			break
		end
		reg_0 = loc_2
		break
	end
	return reg_0
end
FUNC_LIST[136] = --[[ _ZN3std3sys4wasm4once4Once4call17h89a68a06e72dc815E ]] function(loc_0)
	local loc_1 = 0
	local loc_2 = 0
	local loc_3 = 0
	local desired
	local br_map = {}
	while true do
		loc_1 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_1
		while true do
			while true do
				while true do
					while true do
						while true do
							while true do
								while true do
									if not br_map[1] then
										br_map[1] = (function()
											return { [0] = 0, 2, 6, 1, }
										end)()
									end
									temp = br_map[1][load_i32_u8(memory_at_0, 0 + 1084688)] or 0
									if temp < 2 then
										if temp < 1 then
											break
										else
											desired = 6
											break
										end
									elseif temp > 2 then
										desired = 1
										break
									else
										desired = 5
										break
									end
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								store_i32_n8(memory_at_0, 0 + 1084688, 2)
								loc_2 = load_i32_u8(memory_at_0, loc_0)
								store_i32_n8(memory_at_0, loc_0, 0)
								if loc_2 == 0 then
									desired = 4
									break
								end
								store_i32_n8(memory_at_0, loc_1 + 8, 0)
								while true do
									while true do
										if load_i32_u8(memory_at_0, 0 + 1084752) == 3 then
											break
										end
										FUNC_LIST[147](add_i32(loc_1, 8))
										if load_i32_u8(memory_at_0, loc_1 + 8) ~= 0 then
											desired = 7
											break
										end
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									while true do
										while true do
											if load_i32(memory_at_0, 0 + 1084720) == 1085256 then
												break
											end
											loc_2 = load_i32_u8(memory_at_0, 0 + 1084748)
											loc_0 = 1
											store_i32_n8(memory_at_0, 0 + 1084748, 1)
											if loc_2 ~= 0 then
												desired = 7
												break
											end
											store_i32(memory_at_0, 0 + 1084720, 1085256)
											desired = 8
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										loc_0 = add_i32(load_i32(memory_at_0, 0 + 1084724), 1)
										if loc_0 == 0 then
											desired = 3
											break
										end
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									loc_2 = 0
									store_i32(memory_at_0, 0 + 1084724, loc_0)
									if load_i32(memory_at_0, 0 + 1084728) ~= 0 then
										desired = 2
										break
									end
									store_i32(memory_at_0, 0 + 1084728, 4294967295)
									while true do
										loc_3 = load_i32(memory_at_0, 0 + 1084732)
										if loc_3 == 0 then
											break
										end
										FUNC_LIST[22](load_i32(memory_at_0, 0 + 1084736), loc_3, 1)
										loc_2 = add_i32(load_i32(memory_at_0, 0 + 1084728), 1)
										loc_0 = load_i32(memory_at_0, 0 + 1084724)
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									store_i64(memory_at_0, 0 + 1084732, i64_from_u32(0, 1))
									store_i32(memory_at_0, 0 + 1084728, loc_2)
									loc_0 = add_i32(loc_0, 4294967295)
									store_i32(memory_at_0, 0 + 1084724, loc_0)
									store_i32_n8(memory_at_0, 0 + 1084744, 0)
									store_i32(memory_at_0, 0 + 1084740, 0)
									if loc_0 ~= 0 then
										break
									end
									store_i32_n8(memory_at_0, 0 + 1084748, 0)
									store_i32(memory_at_0, 0 + 1084720, 0)
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								store_i32_n8(memory_at_0, 0 + 1084688, 3)
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							GLOBAL_LIST[0].value = add_i32(loc_1, 32)
							desired = 0
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						store_i64(memory_at_0, add_i32(loc_1, 20), i64_ZERO)
						store_i32(memory_at_0, loc_1 + 12, 1)
						store_i32(memory_at_0, loc_1 + 8, 1072096)
						store_i32(memory_at_0, loc_1 + 16, 1070448)
						FUNC_LIST[187](add_i32(loc_1, 8), 1070564)
						error("out of code bounds")
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					FUNC_LIST[192](1070468, 43, 1071132)
					error("out of code bounds")
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[210](1071180, 38, 1071252)
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[201](1070900)
			error("out of code bounds")
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		store_i64(memory_at_0, add_i32(loc_1, 20), i64_ZERO)
		store_i32(memory_at_0, loc_1 + 12, 1)
		store_i32(memory_at_0, loc_1 + 8, 1072160)
		store_i32(memory_at_0, loc_1 + 16, 1070448)
		FUNC_LIST[187](add_i32(loc_1, 8), 1070564)
		error("out of code bounds")
	end
end
FUNC_LIST[137] = --[[ _ZN3std2rt19lang_start_internal17h658afcf1f1425f65E ]] function(loc_0, loc_1, loc_2, loc_3, loc_4)
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = 0
	local loc_8 = 0
	local loc_9 = 0
	local loc_10 = 0
	local loc_11 = i64_ZERO
	local loc_12 = i64_ZERO
	local loc_13 = i64_ZERO
	local reg_0
	local desired
	while true do
		loc_5 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_5
		FUNC_LIST[176](add_i32(loc_5, 16), 1070536, 4)
		while true do
			if load_i32(memory_at_0, loc_5 + 16) ~= 2147483648 then
				break
			end
			loc_6 = load_i32(memory_at_0, add_i32(add_i32(loc_5, 16), 8))
			loc_7 = load_i32(memory_at_0, loc_5 + 20)
			FUNC_LIST[182](add_i32(loc_5, 8), 8, 16)
			loc_8 = load_i32(memory_at_0, loc_5 + 8)
			while true do
				while true do
					loc_9 = load_i32(memory_at_0, loc_5 + 12)
					if loc_9 ~= 0 then
						break
					end
					loc_10 = loc_8
					desired = 2
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				reg_0 = FUNC_LIST[21](loc_9, loc_8)
				loc_10 = reg_0
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				while true do
					if loc_10 == 0 then
						break
					end
					store_i64(memory_at_0, loc_10, i64_from_u32(1, 1))
					store_i32(memory_at_0, loc_10 + 20, loc_6)
					store_i32(memory_at_0, add_i32(loc_10, 16), loc_7)
					loc_11 = load_i64(memory_at_0, 0 + 1084784)
					while true do
						loc_12 = add_i64(loc_11, i64_ONE)
						if eq_i64(loc_12, i64_ZERO) then
							desired = 2
							break
						end
						loc_13 = load_i64(memory_at_0, 0 + 1084784)
						loc_8 = (if eq_i64(loc_13, loc_11) then 1 else 0)
						store_i64(memory_at_0, 0 + 1084784, (if loc_8 ~= 0 then loc_12 else loc_13))
						loc_11 = loc_13
						if loc_8 == 0 then
							continue
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i64(memory_at_0, loc_10 + 8, loc_12)
					if load_i32(memory_at_0, 0 + 1085252) ~= 0 then
						desired = 1
						break
					end
					store_i32(memory_at_0, 0 + 1085252, loc_10)
					reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, add_i32(loc_1, 20))](loc_0)
					loc_8 = reg_0
					while true do
						if load_i32_u8(memory_at_0, 0 + 1084688) == 3 then
							break
						end
						store_i32_n8(memory_at_0, loc_5 + 16, 1)
						FUNC_LIST[136](add_i32(loc_5, 16))
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					GLOBAL_LIST[0].value = add_i32(loc_5, 32)
					reg_0 = loc_8
					desired = 0
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[173](loc_8, loc_9)
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[123]()
			error("out of code bounds")
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		error("out of code bounds")
	end
	return reg_0
end
FUNC_LIST[138] = --[[ _ZN68_$LT$std..thread..local..AccessError$u20$as$u20$core..fmt..Debug$GT$3fmt17h498983a7dac61261E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local reg_0
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_2
		FUNC_LIST[230](add_i32(loc_2, 8), loc_1, 1070580, 11)
		reg_0 = FUNC_LIST[219](add_i32(loc_2, 8))
		loc_1 = reg_0
		GLOBAL_LIST[0].value = add_i32(loc_2, 16)
		reg_0 = loc_1
		break
	end
	return reg_0
end
FUNC_LIST[139] = --[[ _ZN58_$LT$std..io..error..Error$u20$as$u20$core..fmt..Debug$GT$3fmt17h1c9cd98c11ab059eE ]] function(loc_0, loc_1)
	local reg_0
	while true do
		reg_0 = FUNC_LIST[140](loc_0, loc_1)
		break
	end
	return reg_0
end
FUNC_LIST[140] = --[[ _ZN3std2io5error82_$LT$impl$u20$core..fmt..Debug$u20$for$u20$std..io..error..repr_unpacked..Repr$GT$3fmt17h286ed803140782a4E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local reg_0
	local desired
	local br_map = {}
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_2
		while true do
			while true do
				while true do
					while true do
						while true do
							while true do
								if not br_map[1] then
									br_map[1] = (function()
										return { [0] = 0, 1, 2, 3, }
									end)()
								end
								temp = br_map[1][load_i32_u8(memory_at_0, loc_0)] or 0
								if temp < 2 then
									if temp < 1 then
										break
									else
										desired = 5
										break
									end
								elseif temp > 2 then
									desired = 3
									break
								else
									desired = 4
									break
								end
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							store_i32(memory_at_0, loc_2 + 4, load_i32(memory_at_0, loc_0 + 4))
							FUNC_LIST[230](add_i32(loc_2, 8), loc_1, 1070748, 2)
							reg_0 = FUNC_LIST[207](add_i32(loc_2, 8), 1070750, 4, add_i32(loc_2, 4), 1070756)
							loc_0 = reg_0
							store_i32_n8(memory_at_0, loc_2 + 19, 40)
							reg_0 = FUNC_LIST[207](loc_0, 1070772, 4, add_i32(loc_2, 19), 1070776)
							loc_1 = reg_0
							reg_0 = FUNC_LIST[21](20, 1)
							loc_0 = reg_0
							if loc_0 == 0 then
								desired = 1
								break
							end
							store_i32(memory_at_0, add_i32(loc_0, 16), load_i32(memory_at_0, 0 + 1072050))
							store_i64(memory_at_0, add_i32(loc_0, 8), load_i64(memory_at_0, 0 + 1072042))
							store_i64(memory_at_0, loc_0, load_i64(memory_at_0, 0 + 1072034))
							store_i32(memory_at_0, loc_2 + 28, 20)
							store_i32(memory_at_0, loc_2 + 24, loc_0)
							store_i32(memory_at_0, loc_2 + 20, 20)
							reg_0 = FUNC_LIST[207](loc_1, 1070792, 7, add_i32(loc_2, 20), 1070800)
							reg_0 = FUNC_LIST[219](reg_0)
							loc_0 = reg_0
							loc_1 = load_i32(memory_at_0, loc_2 + 20)
							if loc_1 == 0 then
								desired = 2
								break
							end
							FUNC_LIST[22](load_i32(memory_at_0, loc_2 + 24), loc_1, 1)
							desired = 2
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						store_i32_n8(memory_at_0, loc_2 + 8, load_i32_u8(memory_at_0, loc_0 + 1))
						FUNC_LIST[233](add_i32(loc_2, 20), loc_1, 1070816, 4)
						reg_0 = FUNC_LIST[220](add_i32(loc_2, 20), add_i32(loc_2, 8), 1070776)
						reg_0 = FUNC_LIST[221](reg_0)
						loc_0 = reg_0
						desired = 2
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_0 = load_i32(memory_at_0, loc_0 + 4)
					FUNC_LIST[230](add_i32(loc_2, 20), loc_1, 1070820, 5)
					reg_0 = FUNC_LIST[207](add_i32(loc_2, 20), 1070772, 4, add_i32(loc_0, 8), 1070776)
					reg_0 = FUNC_LIST[207](reg_0, 1070792, 7, loc_0, 1070828)
					reg_0 = FUNC_LIST[219](reg_0)
					loc_0 = reg_0
					desired = 2
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_0 = load_i32(memory_at_0, loc_0 + 4)
				store_i32(memory_at_0, loc_2 + 20, loc_0)
				reg_0 = FUNC_LIST[232](loc_1, 1070844, 6, 1070772, 4, add_i32(loc_0, 8), 1070776, 1070850, 5, add_i32(loc_2, 20), 1070856)
				loc_0 = reg_0
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			GLOBAL_LIST[0].value = add_i32(loc_2, 32)
			reg_0 = loc_0
			desired = 0
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		FUNC_LIST[173](1, 20)
		error("out of code bounds")
	end
	return reg_0
end
FUNC_LIST[141] = --[[ _ZN3std2io5stdio5stdin17h5382090909bd7dbfE ]] function()
	local reg_0
	while true do
		while true do
			if load_i32_u8(memory_at_0, 0 + 1084716) == 3 then
				break
			end
			FUNC_LIST[142]()
			break
		end
		reg_0 = 1084692
		break
	end
	return reg_0
end
FUNC_LIST[142] = --[[ _ZN3std4sync9once_lock17OnceLock$LT$T$GT$10initialize17h3d3ac07aebd63781E ]] function()
	local loc_0 = 0
	while true do
		loc_0 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_0
		while true do
			if load_i32_u8(memory_at_0, 0 + 1084716) == 3 then
				break
			end
			store_i32(memory_at_0, loc_0 + 4, 1084692)
			store_i32(memory_at_0, loc_0 + 8, add_i32(loc_0, 15))
			FUNC_LIST[146](add_i32(loc_0, 4))
			break
		end
		GLOBAL_LIST[0].value = add_i32(loc_0, 16)
		break
	end
end
FUNC_LIST[143] = --[[ _ZN3std2io5stdio5Stdin4lock17ha1b79d1e4f12230fE ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local reg_0
	local desired
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_2
		loc_1 = load_i32(memory_at_0, loc_1)
		loc_3 = load_i32_u8(memory_at_0, loc_1)
		store_i32_n8(memory_at_0, loc_2 + 7, loc_3)
		store_i32_n8(memory_at_0, loc_1, 1)
		while true do
			if loc_3 ~= 0 then
				break
			end
			loc_3 = 0
			while true do
				if band_i32(load_i32(memory_at_0, 0 + 1084776), 2147483647) == 0 then
					break
				end
				reg_0 = FUNC_LIST[118]()
				loc_3 = bxor_i32(reg_0, 1)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			store_i32_n8(memory_at_0, loc_0 + 4, loc_3)
			store_i32(memory_at_0, loc_0, loc_1)
			GLOBAL_LIST[0].value = add_i32(loc_2, 32)
			desired = 0
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		store_i64(memory_at_0, loc_2 + 20, i64_ZERO)
		store_i32(memory_at_0, loc_2 + 16, 1070448)
		store_i32(memory_at_0, loc_2 + 12, 1)
		store_i32(memory_at_0, loc_2 + 8, 1071024)
		FUNC_LIST[124](add_i32(loc_2, 7), add_i32(loc_2, 8))
		error("out of code bounds")
	end
end
FUNC_LIST[144] = --[[ _ZN3std2io10read_until17hfef2f3e6672dcd94E ]] function(loc_0, loc_1, loc_2, loc_3)
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = 0
	local loc_8 = 0
	local loc_9 = 0
	local loc_10 = 0
	local loc_11 = 0
	local loc_12 = 0
	local loc_13 = 0
	local loc_14 = 0
	local loc_15 = 0
	local loc_16 = 0
	local reg_0
	local desired
	while true do
		loc_4 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_4
		loc_5 = load_i32(memory_at_0, loc_1 + 16)
		loc_6 = load_i32(memory_at_0, loc_1)
		loc_7 = load_i32(memory_at_0, loc_1 + 4)
		loc_8 = load_i32(memory_at_0, loc_1 + 12)
		loc_9 = load_i32(memory_at_0, loc_1 + 8)
		loc_10 = 0
		loc_11 = band_i32(loc_2, 255)
		while true do
			while true do
				while true do
					if loc_9 < loc_8 then
						break
					end
					if loc_7 < loc_5 then
						desired = 1
						break
					end
					loc_8 = 0
					reg_0 = FUNC_LIST[259](add_i32(loc_6, loc_5), 0, sub_i32(loc_7, loc_5))
					store_i32(memory_at_0, loc_1 + 16, loc_7)
					store_i32(memory_at_0, loc_1 + 12, 0)
					loc_5 = loc_7
					loc_9 = 0
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
						continue
					end
					break
				end
				loc_12 = add_i32(loc_6, loc_9)
				while true do
					while true do
						loc_13 = sub_i32(loc_8, loc_9)
						if loc_13 < 8 then
							break
						end
						FUNC_LIST[240](add_i32(loc_4, 8), loc_2, loc_12, loc_13)
						loc_14 = load_i32(memory_at_0, loc_4 + 12)
						loc_15 = load_i32(memory_at_0, loc_4 + 8)
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_14 = 0
					while true do
						if loc_13 ~= 0 then
							break
						end
						loc_15 = 0
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					while true do
						while true do
							if load_i32_u8(memory_at_0, add_i32(loc_12, loc_14)) ~= loc_11 then
								break
							end
							loc_15 = 1
							desired = 3
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
								continue
							end
							break
						end
						loc_14 = add_i32(loc_14, 1)
						if loc_13 ~= loc_14 then
							continue
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_15 = 0
					loc_14 = loc_13
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
						continue
					end
					break
				end
				while true do
					while true do
						if loc_15 ~= 0 then
							break
						end
						while true do
							loc_14 = load_i32(memory_at_0, loc_3 + 8)
							if sub_i32(load_i32(memory_at_0, loc_3), loc_14) >= loc_13 then
								break
							end
							FUNC_LIST[115](loc_3, loc_14, loc_13)
							loc_14 = load_i32(memory_at_0, loc_3 + 8)
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						reg_0 = FUNC_LIST[262](add_i32(load_i32(memory_at_0, loc_3 + 4), loc_14), loc_12, loc_13)
						loc_14 = add_i32(loc_14, loc_13)
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					while true do
						while true do
							if loc_14 == 4294967295 then
								break
							end
							loc_16 = add_i32(loc_14, 1)
							if loc_14 < loc_13 then
								desired = 4
								break
							end
							FUNC_LIST[190](loc_16, loc_13, 1070976)
							error("out of code bounds")
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						FUNC_LIST[241](1070976)
						error("out of code bounds")
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					while true do
						loc_13 = load_i32(memory_at_0, loc_3 + 8)
						if sub_i32(load_i32(memory_at_0, loc_3), loc_13) > loc_14 then
							break
						end
						FUNC_LIST[115](loc_3, loc_13, loc_16)
						loc_13 = load_i32(memory_at_0, loc_3 + 8)
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					reg_0 = FUNC_LIST[262](add_i32(load_i32(memory_at_0, loc_3 + 4), loc_13), loc_12, loc_16)
					loc_14 = add_i32(loc_13, loc_16)
					loc_13 = loc_16
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
						continue
					end
					break
				end
				store_i32(memory_at_0, loc_3 + 8, loc_14)
				loc_14 = add_i32(loc_9, loc_13)
				loc_9 = (if loc_14 < loc_8 then loc_14 else loc_8)
				store_i32(memory_at_0, loc_1 + 8, loc_9)
				loc_10 = add_i32(loc_13, loc_10)
				while true do
					if loc_15 ~= 0 then
						break
					end
					if loc_13 ~= 0 then
						desired = 2
						break
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
						continue
					end
					break
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			store_i32_n8(memory_at_0, loc_0, 4)
			store_i32(memory_at_0, loc_0 + 4, loc_10)
			GLOBAL_LIST[0].value = add_i32(loc_4, 16)
			desired = 0
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		FUNC_LIST[188](loc_5, loc_7, 1070960)
		error("out of code bounds")
	end
end
FUNC_LIST[145] = --[[ _ZN62_$LT$std..io..stdio..StdinLock$u20$as$u20$std..io..BufRead$GT$9read_line17hec86edcf99cac387E ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	local loc_4 = 0
	local desired
	while true do
		loc_3 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_3
		loc_4 = load_i32(memory_at_0, loc_2 + 8)
		FUNC_LIST[144](add_i32(loc_3, 8), add_i32(load_i32(memory_at_0, loc_1), 4), 10, loc_2)
		while true do
			loc_1 = load_i32(memory_at_0, loc_2 + 8)
			if loc_1 < loc_4 then
				break
			end
			FUNC_LIST[206](add_i32(loc_3, 20), add_i32(load_i32(memory_at_0, loc_2 + 4), loc_4), sub_i32(loc_1, loc_4))
			while true do
				while true do
					if load_i32(memory_at_0, loc_3 + 20) ~= 0 then
						break
					end
					store_i64(memory_at_0, loc_0, load_i64(memory_at_0, loc_3 + 8))
					desired = 2
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				while true do
					while true do
						if load_i32_u8(memory_at_0, loc_3 + 8) ~= 4 then
							break
						end
						store_i32(memory_at_0, loc_0 + 4, 1070736)
						store_i32_n8(memory_at_0, loc_0, 2)
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i64(memory_at_0, loc_0, load_i64(memory_at_0, loc_3 + 8))
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_1 = loc_4
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			store_i32(memory_at_0, loc_2 + 8, loc_1)
			GLOBAL_LIST[0].value = add_i32(loc_3, 32)
			desired = 0
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		FUNC_LIST[188](loc_4, loc_1, 1070944)
		error("out of code bounds")
	end
end
FUNC_LIST[146] = --[[ _ZN3std3sys4wasm4once4Once4call17h83916232652af72dE ]] function(loc_0)
	local loc_1 = 0
	local loc_2 = 0
	local desired
	local br_map = {}
	while true do
		loc_1 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_1
		while true do
			while true do
				while true do
					while true do
						loc_2 = load_i32_u8(memory_at_0, 0 + 1084716)
						if loc_2 < 2 then
							break
						end
						if not br_map[1] then
							br_map[1] = (function()
								return { [0] = 3, 1, }
							end)()
						end
						temp = br_map[1][add_i32(loc_2, 4294967294)] or 3
						if temp < 3 then
							desired = 3
							break
						else
							desired = 1
							break
						end
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32_n8(memory_at_0, 0 + 1084716, 2)
					loc_2 = load_i32(memory_at_0, loc_0)
					store_i32(memory_at_0, loc_0, 0)
					if loc_2 == 0 then
						desired = 2
						break
					end
					store_i64(memory_at_0, loc_2 + 8, i64_ZERO)
					store_i32(memory_at_0, loc_2 + 4, 1)
					store_i32_n16(memory_at_0, loc_2, 0)
					store_i64(memory_at_0, add_i32(loc_2, 16), i64_ZERO)
					store_i32_n8(memory_at_0, 0 + 1084716, 3)
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				GLOBAL_LIST[0].value = add_i32(loc_1, 32)
				desired = 0
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[192](1070468, 43, 1071164)
			error("out of code bounds")
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		store_i64(memory_at_0, add_i32(loc_1, 20), i64_ZERO)
		store_i32(memory_at_0, loc_1 + 12, 1)
		store_i32(memory_at_0, loc_1 + 8, 1072160)
		store_i32(memory_at_0, loc_1 + 16, 1070448)
		FUNC_LIST[187](add_i32(loc_1, 8), 1071148)
		error("out of code bounds")
	end
end
FUNC_LIST[147] = --[[ _ZN3std4sync9once_lock17OnceLock$LT$T$GT$10initialize17h3fce35109527e82bE ]] function(loc_0)
	local loc_1 = 0
	while true do
		loc_1 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_1
		while true do
			if load_i32_u8(memory_at_0, 0 + 1084752) == 3 then
				break
			end
			store_i32(memory_at_0, loc_1 + 4, 1084720)
			store_i32(memory_at_0, loc_1, loc_0)
			store_i32(memory_at_0, loc_1 + 8, add_i32(loc_1, 15))
			FUNC_LIST[148](loc_1)
			break
		end
		GLOBAL_LIST[0].value = add_i32(loc_1, 16)
		break
	end
end
FUNC_LIST[148] = --[[ _ZN3std3sys4wasm4once4Once4call17h0c0d678e40b69330E ]] function(loc_0)
	local loc_1 = 0
	local loc_2 = 0
	local desired
	local br_map = {}
	while true do
		loc_1 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_1
		while true do
			while true do
				while true do
					while true do
						loc_2 = load_i32_u8(memory_at_0, 0 + 1084752)
						if loc_2 < 2 then
							break
						end
						if not br_map[1] then
							br_map[1] = (function()
								return { [0] = 3, 1, }
							end)()
						end
						temp = br_map[1][add_i32(loc_2, 4294967294)] or 3
						if temp < 3 then
							desired = 3
							break
						else
							desired = 1
							break
						end
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32_n8(memory_at_0, 0 + 1084752, 2)
					loc_2 = load_i32(memory_at_0, loc_0)
					store_i32(memory_at_0, loc_0, 0)
					if loc_2 == 0 then
						desired = 2
						break
					end
					loc_0 = load_i32(memory_at_0, loc_0 + 4)
					store_i32_n8(memory_at_0, loc_2, 1)
					store_i64(memory_at_0, add_i32(loc_0, 8), i64_ZERO)
					store_i64(memory_at_0, loc_0, i64_ZERO)
					store_i32_n8(memory_at_0, loc_0 + 28, 0)
					store_i32_n8(memory_at_0, loc_0 + 24, 0)
					store_i64(memory_at_0, loc_0 + 16, i64_ONE)
					store_i32_n8(memory_at_0, 0 + 1084752, 3)
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				GLOBAL_LIST[0].value = add_i32(loc_1, 32)
				desired = 0
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[192](1070468, 43, 1071164)
			error("out of code bounds")
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		store_i64(memory_at_0, add_i32(loc_1, 20), i64_ZERO)
		store_i32(memory_at_0, loc_1 + 12, 1)
		store_i32(memory_at_0, loc_1 + 8, 1072160)
		store_i32(memory_at_0, loc_1 + 16, 1070448)
		FUNC_LIST[187](add_i32(loc_1, 8), 1071148)
		error("out of code bounds")
	end
end
FUNC_LIST[149] = --[[ _ZN3std10sys_common9backtrace26__rust_end_short_backtrace17h19f35d272c126e7cE ]] function(loc_0)
	while true do
		FUNC_LIST[150](loc_0)
		error("out of code bounds")
	end
end
FUNC_LIST[150] = --[[ _ZN3std9panicking19begin_panic_handler28_$u7b$$u7b$closure$u7d$$u7d$17h24b0f4622f2766a5E ]] function(loc_0)
	local loc_1 = 0
	local loc_2 = 0
	local loc_3 = 0
	local desired
	local br_map = {}
	while true do
		loc_1 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_1
		loc_2 = load_i32(memory_at_0, loc_0)
		loc_3 = load_i32(memory_at_0, add_i32(loc_2, 12))
		while true do
			while true do
				while true do
					while true do
						if not br_map[1] then
							br_map[1] = (function()
								return { [0] = 0, 1, }
							end)()
						end
						temp = br_map[1][load_i32(memory_at_0, loc_2 + 4)] or 3
						if temp < 1 then
							break
						elseif temp > 1 then
							desired = 1
							break
						else
							desired = 3
							break
						end
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					if loc_3 ~= 0 then
						desired = 1
						break
					end
					loc_2 = 1070448
					loc_3 = 0
					desired = 2
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				if loc_3 ~= 0 then
					desired = 1
					break
				end
				loc_2 = load_i32(memory_at_0, loc_2)
				loc_3 = load_i32(memory_at_0, loc_2 + 4)
				loc_2 = load_i32(memory_at_0, loc_2)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			store_i32(memory_at_0, loc_1 + 4, loc_3)
			store_i32(memory_at_0, loc_1, loc_2)
			loc_2 = load_i32(memory_at_0, loc_0 + 4)
			FUNC_LIST[160](loc_1, 1071436, load_i32(memory_at_0, loc_2 + 8), load_i32(memory_at_0, loc_0 + 8), load_i32_u8(memory_at_0, loc_2 + 16), load_i32_u8(memory_at_0, loc_2 + 17))
			error("out of code bounds")
		end
		store_i32(memory_at_0, loc_1 + 12, loc_2)
		store_i32(memory_at_0, loc_1, 2147483648)
		loc_2 = load_i32(memory_at_0, loc_0 + 4)
		FUNC_LIST[160](loc_1, 1071456, load_i32(memory_at_0, loc_2 + 8), load_i32(memory_at_0, loc_0 + 8), load_i32_u8(memory_at_0, loc_2 + 16), load_i32_u8(memory_at_0, loc_2 + 17))
		error("out of code bounds")
	end
end
FUNC_LIST[151] = --[[ _ZN3std5alloc24default_alloc_error_hook17h53c93b47f409675bE ]] function(loc_0, loc_1)
	local loc_2 = 0
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 48)
		GLOBAL_LIST[0].value = loc_2
		while true do
			if load_i32_u8(memory_at_0, 0 + 1077372) == 0 then
				break
			end
			store_i64(memory_at_0, add_i32(loc_2, 24), i64_ONE)
			store_i32(memory_at_0, loc_2 + 16, 2)
			store_i32(memory_at_0, loc_2 + 12, 1071304)
			store_i32(memory_at_0, loc_2 + 40, 18)
			store_i32(memory_at_0, loc_2 + 44, loc_1)
			store_i32(memory_at_0, loc_2 + 20, add_i32(loc_2, 36))
			store_i32(memory_at_0, loc_2 + 36, add_i32(loc_2, 44))
			FUNC_LIST[187](add_i32(loc_2, 12), 1071344)
			error("out of code bounds")
		end
		GLOBAL_LIST[0].value = add_i32(loc_2, 48)
		break
	end
end
FUNC_LIST[152] = --[[ __rdl_alloc ]] function(loc_0, loc_1)
	local reg_0
	local desired
	while true do
		while true do
			if loc_1 < 9 then
				break
			end
			reg_0 = FUNC_LIST[135](loc_1, loc_0)
			desired = 0
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		reg_0 = FUNC_LIST[134](loc_0)
		break
	end
	return reg_0
end
FUNC_LIST[153] = --[[ __rdl_dealloc ]] function(loc_0, loc_1, loc_2)
	while true do
		FUNC_LIST[133](loc_0)
		break
	end
end
FUNC_LIST[154] = --[[ __rdl_realloc ]] function(loc_0, loc_1, loc_2, loc_3)
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = 0
	local loc_8 = 0
	local reg_0
	local desired
	while true do
		while true do
			while true do
				while true do
					while true do
						if loc_2 < 9 then
							break
						end
						reg_0 = FUNC_LIST[135](loc_2, loc_3)
						loc_2 = reg_0
						if loc_2 ~= 0 then
							desired = 3
							break
						end
						reg_0 = 0
						desired = 0
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_2 = 0
					if loc_3 > 4294901708 then
						desired = 2
						break
					end
					loc_1 = (if loc_3 < 11 then 16 else band_i32(add_i32(loc_3, 11), 4294967288))
					loc_4 = add_i32(loc_0, 4294967292)
					loc_5 = load_i32(memory_at_0, loc_4)
					loc_6 = band_i32(loc_5, 4294967288)
					while true do
						while true do
							if band_i32(loc_5, 3) ~= 0 then
								break
							end
							if loc_1 < 256 then
								desired = 4
								break
							end
							if loc_6 < bor_i32(loc_1, 4) then
								desired = 4
								break
							end
							if sub_i32(loc_6, loc_1) >= 131073 then
								desired = 4
								break
							end
							reg_0 = loc_0
							desired = 0
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_7 = add_i32(loc_0, 4294967288)
						loc_8 = add_i32(loc_7, loc_6)
						while true do
							while true do
								while true do
									while true do
										while true do
											if loc_6 >= loc_1 then
												break
											end
											if loc_8 == load_i32(memory_at_0, 0 + 1085220) then
												desired = 5
												break
											end
											if loc_8 == load_i32(memory_at_0, 0 + 1085216) then
												desired = 7
												break
											end
											loc_5 = load_i32(memory_at_0, loc_8 + 4)
											if band_i32(loc_5, 2) ~= 0 then
												desired = 4
												break
											end
											loc_5 = band_i32(loc_5, 4294967288)
											loc_6 = add_i32(loc_5, loc_6)
											if loc_6 < loc_1 then
												desired = 4
												break
											end
											FUNC_LIST[130](loc_8, loc_5)
											loc_3 = sub_i32(loc_6, loc_1)
											if loc_3 < 16 then
												desired = 8
												break
											end
											store_i32(memory_at_0, loc_4, bor_i32(bor_i32(loc_1, band_i32(load_i32(memory_at_0, loc_4), 1)), 2))
											loc_2 = add_i32(loc_7, loc_1)
											store_i32(memory_at_0, loc_2 + 4, bor_i32(loc_3, 3))
											loc_1 = add_i32(loc_7, loc_6)
											store_i32(memory_at_0, loc_1 + 4, bor_i32(load_i32(memory_at_0, loc_1 + 4), 1))
											FUNC_LIST[131](loc_2, loc_3)
											reg_0 = loc_0
											desired = 0
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										loc_3 = sub_i32(loc_6, loc_1)
										if loc_3 > 15 then
											desired = 6
											break
										end
										reg_0 = loc_0
										desired = 0
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									store_i32(memory_at_0, loc_4, bor_i32(bor_i32(loc_6, band_i32(load_i32(memory_at_0, loc_4), 1)), 2))
									loc_3 = add_i32(loc_7, loc_6)
									store_i32(memory_at_0, loc_3 + 4, bor_i32(load_i32(memory_at_0, loc_3 + 4), 1))
									reg_0 = loc_0
									desired = 0
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								loc_6 = add_i32(load_i32(memory_at_0, 0 + 1085208), loc_6)
								if loc_6 < loc_1 then
									desired = 4
									break
								end
								while true do
									while true do
										loc_3 = sub_i32(loc_6, loc_1)
										if loc_3 > 15 then
											break
										end
										store_i32(memory_at_0, loc_4, bor_i32(bor_i32(band_i32(loc_5, 1), loc_6), 2))
										loc_3 = add_i32(loc_7, loc_6)
										store_i32(memory_at_0, loc_3 + 4, bor_i32(load_i32(memory_at_0, loc_3 + 4), 1))
										loc_3 = 0
										loc_2 = 0
										desired = 7
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									store_i32(memory_at_0, loc_4, bor_i32(bor_i32(loc_1, band_i32(loc_5, 1)), 2))
									loc_2 = add_i32(loc_7, loc_1)
									store_i32(memory_at_0, loc_2 + 4, bor_i32(loc_3, 1))
									loc_1 = add_i32(loc_7, loc_6)
									store_i32(memory_at_0, loc_1, loc_3)
									store_i32(memory_at_0, loc_1 + 4, band_i32(load_i32(memory_at_0, loc_1 + 4), 4294967294))
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								store_i32(memory_at_0, 0 + 1085216, loc_2)
								store_i32(memory_at_0, 0 + 1085208, loc_3)
								reg_0 = loc_0
								desired = 0
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							store_i32(memory_at_0, loc_4, bor_i32(bor_i32(loc_1, band_i32(loc_5, 1)), 2))
							loc_2 = add_i32(loc_7, loc_1)
							store_i32(memory_at_0, loc_2 + 4, bor_i32(loc_3, 3))
							store_i32(memory_at_0, loc_8 + 4, bor_i32(load_i32(memory_at_0, loc_8 + 4), 1))
							FUNC_LIST[131](loc_2, loc_3)
							reg_0 = loc_0
							desired = 0
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_6 = add_i32(load_i32(memory_at_0, 0 + 1085212), loc_6)
						if loc_6 > loc_1 then
							desired = 1
							break
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					reg_0 = FUNC_LIST[134](loc_3)
					loc_1 = reg_0
					if loc_1 == 0 then
						desired = 2
						break
					end
					loc_2 = load_i32(memory_at_0, loc_4)
					loc_2 = add_i32((if band_i32(loc_2, 3) ~= 0 then 4294967292 else 4294967288), band_i32(loc_2, 4294967288))
					reg_0 = FUNC_LIST[262](loc_1, loc_0, (if loc_2 < loc_3 then loc_2 else loc_3))
					loc_3 = reg_0
					FUNC_LIST[133](loc_0)
					reg_0 = loc_3
					desired = 0
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				reg_0 = FUNC_LIST[262](loc_2, loc_0, (if loc_1 < loc_3 then loc_1 else loc_3))
				FUNC_LIST[133](loc_0)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			reg_0 = loc_2
			desired = 0
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		store_i32(memory_at_0, loc_4, bor_i32(bor_i32(loc_1, band_i32(loc_5, 1)), 2))
		loc_3 = add_i32(loc_7, loc_1)
		loc_2 = sub_i32(loc_6, loc_1)
		store_i32(memory_at_0, loc_3 + 4, bor_i32(loc_2, 1))
		store_i32(memory_at_0, 0 + 1085212, loc_2)
		store_i32(memory_at_0, 0 + 1085220, loc_3)
		reg_0 = loc_0
		break
	end
	return reg_0
end
FUNC_LIST[155] = --[[ rust_begin_unwind ]] function(loc_0)
	local loc_1 = 0
	local loc_2 = 0
	while true do
		loc_1 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_1
		while true do
			loc_2 = load_i32(memory_at_0, loc_0 + 8)
			if loc_2 ~= 0 then
				break
			end
			FUNC_LIST[192](1070468, 43, 1071388)
			error("out of code bounds")
		end
		store_i32(memory_at_0, loc_1 + 12, load_i32(memory_at_0, loc_0 + 12))
		store_i32(memory_at_0, loc_1 + 8, loc_0)
		store_i32(memory_at_0, loc_1 + 4, loc_2)
		FUNC_LIST[149](add_i32(loc_1, 4))
		error("out of code bounds")
	end
end
FUNC_LIST[156] = --[[ _ZN102_$LT$std..panicking..begin_panic_handler..FormatStringPayload$u20$as$u20$core..panic..PanicPayload$GT$8take_box17h38a8f47fadd53c0fE ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = i64_ZERO
	local reg_0
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 48)
		GLOBAL_LIST[0].value = loc_2
		while true do
			if load_i32(memory_at_0, loc_1) ~= 2147483648 then
				break
			end
			loc_3 = load_i32(memory_at_0, loc_1 + 12)
			loc_4 = add_i32(add_i32(loc_2, 36), 8)
			store_i32(memory_at_0, loc_4, 0)
			store_i64(memory_at_0, loc_2 + 36, i64_from_u32(0, 1))
			reg_0 = FUNC_LIST[195](add_i32(loc_2, 36), 1070512, loc_3)
			loc_3 = load_i32(memory_at_0, loc_4)
			store_i32(memory_at_0, add_i32(add_i32(loc_2, 24), 8), loc_3)
			loc_5 = load_i64(memory_at_0, loc_2 + 36)
			store_i64(memory_at_0, loc_2 + 24, loc_5)
			store_i32(memory_at_0, add_i32(loc_1, 8), loc_3)
			store_i64(memory_at_0, loc_1, loc_5)
			break
		end
		loc_5 = load_i64(memory_at_0, loc_1)
		store_i64(memory_at_0, loc_1, i64_from_u32(0, 1))
		loc_3 = add_i32(add_i32(loc_2, 8), 8)
		loc_1 = add_i32(loc_1, 8)
		store_i32(memory_at_0, loc_3, load_i32(memory_at_0, loc_1))
		store_i32(memory_at_0, loc_1, 0)
		store_i64(memory_at_0, loc_2 + 8, loc_5)
		while true do
			reg_0 = FUNC_LIST[21](12, 4)
			loc_1 = reg_0
			if loc_1 ~= 0 then
				break
			end
			FUNC_LIST[173](4, 12)
			error("out of code bounds")
		end
		store_i64(memory_at_0, loc_1, load_i64(memory_at_0, loc_2 + 8))
		store_i32(memory_at_0, add_i32(loc_1, 8), load_i32(memory_at_0, loc_3))
		store_i32(memory_at_0, loc_0 + 4, 1071404)
		store_i32(memory_at_0, loc_0, loc_1)
		GLOBAL_LIST[0].value = add_i32(loc_2, 48)
		break
	end
end
FUNC_LIST[157] = --[[ _ZN102_$LT$std..panicking..begin_panic_handler..FormatStringPayload$u20$as$u20$core..panic..PanicPayload$GT$3get17ha9921fb3303902c9E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = i64_ZERO
	local reg_0
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_2
		while true do
			if load_i32(memory_at_0, loc_1) ~= 2147483648 then
				break
			end
			loc_3 = load_i32(memory_at_0, loc_1 + 12)
			loc_4 = add_i32(add_i32(loc_2, 20), 8)
			store_i32(memory_at_0, loc_4, 0)
			store_i64(memory_at_0, loc_2 + 20, i64_from_u32(0, 1))
			reg_0 = FUNC_LIST[195](add_i32(loc_2, 20), 1070512, loc_3)
			loc_3 = load_i32(memory_at_0, loc_4)
			store_i32(memory_at_0, add_i32(add_i32(loc_2, 8), 8), loc_3)
			loc_5 = load_i64(memory_at_0, loc_2 + 20)
			store_i64(memory_at_0, loc_2 + 8, loc_5)
			store_i32(memory_at_0, add_i32(loc_1, 8), loc_3)
			store_i64(memory_at_0, loc_1, loc_5)
			break
		end
		store_i32(memory_at_0, loc_0 + 4, 1071404)
		store_i32(memory_at_0, loc_0, loc_1)
		GLOBAL_LIST[0].value = add_i32(loc_2, 32)
		break
	end
end
FUNC_LIST[158] = --[[ _ZN99_$LT$std..panicking..begin_panic_handler..StaticStrPayload$u20$as$u20$core..panic..PanicPayload$GT$8take_box17h9ea8d38f6fb2d648E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local reg_0
	while true do
		loc_2 = load_i32(memory_at_0, loc_1 + 4)
		loc_3 = load_i32(memory_at_0, loc_1)
		while true do
			reg_0 = FUNC_LIST[21](8, 4)
			loc_1 = reg_0
			if loc_1 ~= 0 then
				break
			end
			FUNC_LIST[173](4, 8)
			error("out of code bounds")
		end
		store_i32(memory_at_0, loc_1 + 4, loc_2)
		store_i32(memory_at_0, loc_1, loc_3)
		store_i32(memory_at_0, loc_0 + 4, 1071420)
		store_i32(memory_at_0, loc_0, loc_1)
		break
	end
end
FUNC_LIST[159] = --[[ _ZN99_$LT$std..panicking..begin_panic_handler..StaticStrPayload$u20$as$u20$core..panic..PanicPayload$GT$3get17hdb520a6b24258d73E ]] function(loc_0, loc_1)
	while true do
		store_i32(memory_at_0, loc_0 + 4, 1071420)
		store_i32(memory_at_0, loc_0, loc_1)
		break
	end
end
FUNC_LIST[160] = --[[ _ZN3std9panicking20rust_panic_with_hook17h1e6ac5d404b8e31bE ]] function(loc_0, loc_1, loc_2, loc_3, loc_4, loc_5)
	local loc_6 = 0
	local loc_7 = 0
	local desired
	while true do
		loc_6 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_6
		loc_7 = load_i32(memory_at_0, 0 + 1084776)
		store_i32(memory_at_0, 0 + 1084776, add_i32(loc_7, 1))
		while true do
			while true do
				if lt_i32(loc_7, 0) then
					break
				end
				if band_i32(load_i32_u8(memory_at_0, 0 + 1085248), 255) ~= 0 then
					break
				end
				store_i32_n8(memory_at_0, 0 + 1085248, 1)
				store_i32(memory_at_0, 0 + 1085244, add_i32(load_i32(memory_at_0, 0 + 1085244), 1))
				store_i32_n8(memory_at_0, loc_6 + 29, loc_5)
				store_i32_n8(memory_at_0, loc_6 + 28, loc_4)
				store_i32(memory_at_0, loc_6 + 24, loc_3)
				store_i32(memory_at_0, loc_6 + 20, loc_2)
				store_i32(memory_at_0, loc_6 + 16, 1071476)
				store_i32(memory_at_0, loc_6 + 12, 1070448)
				loc_7 = load_i32(memory_at_0, 0 + 1084760)
				if le_i32(loc_7, 4294967295) then
					break
				end
				store_i32(memory_at_0, 0 + 1084760, add_i32(loc_7, 1))
				while true do
					if load_i32(memory_at_0, 0 + 1084768) == 0 then
						break
					end
					TABLE_LIST[0].data[load_i32(memory_at_0, loc_1 + 16)](loc_6, loc_0)
					store_i64(memory_at_0, loc_6 + 12, load_i64(memory_at_0, loc_6))
					TABLE_LIST[0].data[load_i32(memory_at_0, load_i32(memory_at_0, 0 + 1084772) + 20)](load_i32(memory_at_0, 0 + 1084768), add_i32(loc_6, 12))
					loc_7 = add_i32(load_i32(memory_at_0, 0 + 1084760), 4294967295)
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i32(memory_at_0, 0 + 1084760, loc_7)
				store_i32_n8(memory_at_0, 0 + 1085248, 0)
				if loc_4 ~= 0 then
					desired = 1
					break
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			error("out of code bounds")
		end
		FUNC_LIST[161](loc_0, loc_1)
		error("out of code bounds")
	end
end
FUNC_LIST[161] = --[[ rust_panic ]] function(loc_0, loc_1)
	local reg_0
	while true do
		reg_0 = FUNC_LIST[164](loc_0, loc_1)
		error("out of code bounds")
	end
end
FUNC_LIST[162] = --[[ _ZN62_$LT$std..io..error..ErrorKind$u20$as$u20$core..fmt..Debug$GT$3fmt17hd0f26e5d4caa796fE ]] function(loc_0, loc_1)
	local reg_0
	while true do
		loc_0 = shl_i32(load_i32_u8(memory_at_0, loc_0), 2)
		reg_0 = FUNC_LIST[229](loc_1, load_i32(memory_at_0, add_i32(loc_0, 1072332)), load_i32(memory_at_0, add_i32(loc_0, 1072168)))
		break
	end
	return reg_0
end
FUNC_LIST[163] = --[[ __rg_oom ]] function(loc_0, loc_1)
	local loc_2 = 0
	while true do
		loc_2 = load_i32(memory_at_0, 0 + 1084756)
		TABLE_LIST[0].data[(if loc_2 ~= 0 then loc_2 else 48)](loc_1, loc_0)
		error("out of code bounds")
	end
end
FUNC_LIST[164] = --[[ __rust_start_panic ]] function(loc_0, loc_1)
	while true do
		error("out of code bounds")
	end
	return reg_spill[1]
end
FUNC_LIST[165] = --[[ _ZN61_$LT$dlmalloc..sys..System$u20$as$u20$dlmalloc..Allocator$GT$5alloc17h77c12e0261fba7efE ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	local reg_0
	local reg_1
	local reg_2
	while true do
		reg_0 = rt.allocator.grow(memory_at_0, shr_u32(loc_2, 16))
		loc_3 = reg_0
		store_i32(memory_at_0, loc_0 + 8, 0)
		reg_2 = band_i32(loc_2, 4294901760)
		loc_2 = (if loc_3 == 4294967295 then 1 else 0)
		store_i32(memory_at_0, loc_0 + 4, (if loc_2 ~= 0 then 0 else reg_2))
		store_i32(memory_at_0, loc_0, (if loc_2 ~= 0 then 0 else shl_i32(loc_3, 16)))
		break
	end
end
FUNC_LIST[166] = --[[ _ZN4core3fmt5Write9write_fmt17h60128eda8224193aE ]] function(loc_0, loc_1)
	local reg_0
	while true do
		reg_0 = FUNC_LIST[195](loc_0, 1072512, loc_1)
		break
	end
	return reg_0
end
FUNC_LIST[167] = --[[ _ZN4core3ptr37drop_in_place$LT$core..fmt..Error$GT$17hf5072dd215ca1c9fE ]] function(loc_0)
	while true do
		break
	end
end
FUNC_LIST[168] = --[[ _ZN4core3ptr42drop_in_place$LT$alloc..string..String$GT$17hab725859e3c1a5cbE ]] function(loc_0)
	local loc_1 = 0
	while true do
		while true do
			loc_1 = load_i32(memory_at_0, loc_0)
			if loc_1 == 0 then
				break
			end
			FUNC_LIST[22](load_i32(memory_at_0, loc_0 + 4), loc_1, 1)
			break
		end
		break
	end
end
FUNC_LIST[169] = --[[ _ZN53_$LT$core..fmt..Error$u20$as$u20$core..fmt..Debug$GT$3fmt17h1738d1094ba0f72dE ]] function(loc_0, loc_1)
	local reg_0
	while true do
		reg_0 = FUNC_LIST[229](loc_1, 1072496, 5)
		break
	end
	return reg_0
end
FUNC_LIST[170] = --[[ _ZN69_$LT$core..alloc..layout..LayoutError$u20$as$u20$core..fmt..Debug$GT$3fmt17h481db91ace1b9e85E ]] function(loc_0, loc_1)
	local reg_0
	while true do
		reg_0 = FUNC_LIST[229](loc_1, 1072501, 11)
		break
	end
	return reg_0
end
FUNC_LIST[171] = --[[ _ZN5alloc7raw_vec19RawVec$LT$T$C$A$GT$7reserve21do_reserve_and_handle17h88525aad0d39db78E ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	local loc_4 = 0
	local desired
	while true do
		loc_3 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_3
		while true do
			while true do
				loc_2 = add_i32(loc_1, loc_2)
				if loc_2 < loc_1 then
					break
				end
				loc_1 = load_i32(memory_at_0, loc_0)
				loc_4 = shl_i32(loc_1, 1)
				loc_2 = (if loc_4 > loc_2 then loc_4 else loc_2)
				loc_2 = (if loc_2 > 8 then loc_2 else 8)
				loc_4 = shr_u32(bxor_i32(loc_2, 4294967295), 31)
				while true do
					while true do
						if loc_1 ~= 0 then
							break
						end
						store_i32(memory_at_0, loc_3 + 24, 0)
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32(memory_at_0, loc_3 + 28, loc_1)
					store_i32(memory_at_0, loc_3 + 24, 1)
					store_i32(memory_at_0, loc_3 + 20, load_i32(memory_at_0, loc_0 + 4))
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[172](add_i32(loc_3, 8), loc_4, loc_2, add_i32(loc_3, 20))
				loc_1 = load_i32(memory_at_0, loc_3 + 12)
				while true do
					if load_i32(memory_at_0, loc_3 + 8) ~= 0 then
						break
					end
					store_i32(memory_at_0, loc_0, loc_2)
					store_i32(memory_at_0, loc_0 + 4, loc_1)
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				if loc_1 == 2147483649 then
					desired = 1
					break
				end
				if loc_1 == 0 then
					break
				end
				FUNC_LIST[173](loc_1, load_i32(memory_at_0, add_i32(loc_3, 16)))
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[174]()
			error("out of code bounds")
		end
		GLOBAL_LIST[0].value = add_i32(loc_3, 32)
		break
	end
end
FUNC_LIST[172] = --[[ _ZN5alloc7raw_vec11finish_grow17h782bde3ec596d344E ]] function(loc_0, loc_1, loc_2, loc_3)
	local reg_0
	local desired
	while true do
		while true do
			while true do
				if loc_1 == 0 then
					break
				end
				if le_i32(loc_2, 4294967295) then
					desired = 1
					break
				end
				while true do
					while true do
						while true do
							while true do
								if load_i32(memory_at_0, loc_3 + 4) == 0 then
									break
								end
								while true do
									loc_1 = load_i32(memory_at_0, add_i32(loc_3, 8))
									if loc_1 ~= 0 then
										break
									end
									while true do
										if loc_2 ~= 0 then
											break
										end
										loc_1 = 1
										desired = 4
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									reg_0 = FUNC_LIST[21](loc_2, 1)
									loc_1 = reg_0
									desired = 5
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								reg_0 = FUNC_LIST[23](load_i32(memory_at_0, loc_3), loc_1, 1, loc_2)
								loc_1 = reg_0
								desired = 5
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							while true do
								if loc_2 ~= 0 then
									break
								end
								loc_1 = 1
								desired = 4
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							reg_0 = FUNC_LIST[21](loc_2, 1)
							loc_1 = reg_0
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						if loc_1 == 0 then
							desired = 3
							break
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32(memory_at_0, loc_0 + 4, loc_1)
					store_i32(memory_at_0, add_i32(loc_0, 8), loc_2)
					store_i32(memory_at_0, loc_0, 0)
					desired = 0
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i32(memory_at_0, loc_0 + 4, 1)
				store_i32(memory_at_0, add_i32(loc_0, 8), loc_2)
				store_i32(memory_at_0, loc_0, 1)
				desired = 0
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			store_i32(memory_at_0, loc_0 + 4, 0)
			store_i32(memory_at_0, add_i32(loc_0, 8), loc_2)
			store_i32(memory_at_0, loc_0, 1)
			desired = 0
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		store_i32(memory_at_0, loc_0 + 4, 0)
		store_i32(memory_at_0, loc_0, 1)
		break
	end
end
FUNC_LIST[173] = --[[ _ZN5alloc5alloc18handle_alloc_error17h73bbc8dacf22ba44E ]] function(loc_0, loc_1)
	while true do
		FUNC_LIST[24](loc_1, loc_0)
		error("out of code bounds")
	end
end
FUNC_LIST[174] = --[[ _ZN5alloc7raw_vec17capacity_overflow17h3ed2cd9d8dd02a35E ]] function()
	local loc_0 = 0
	while true do
		loc_0 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_0
		store_i64(memory_at_0, add_i32(loc_0, 20), i64_ZERO)
		store_i32(memory_at_0, loc_0 + 12, 1)
		store_i32(memory_at_0, loc_0 + 8, 1072584)
		store_i32(memory_at_0, loc_0 + 16, 1072496)
		FUNC_LIST[187](add_i32(loc_0, 8), 1072592)
		error("out of code bounds")
	end
end
FUNC_LIST[175] = --[[ _ZN5alloc7raw_vec19RawVec$LT$T$C$A$GT$16reserve_for_push17h833169ef62dc13aaE ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local desired
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_2
		while true do
			while true do
				loc_1 = add_i32(loc_1, 1)
				if loc_1 == 0 then
					break
				end
				loc_3 = load_i32(memory_at_0, loc_0)
				loc_4 = shl_i32(loc_3, 1)
				loc_1 = (if loc_4 > loc_1 then loc_4 else loc_1)
				loc_1 = (if loc_1 > 8 then loc_1 else 8)
				loc_4 = shr_u32(bxor_i32(loc_1, 4294967295), 31)
				while true do
					while true do
						if loc_3 ~= 0 then
							break
						end
						store_i32(memory_at_0, loc_2 + 24, 0)
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32(memory_at_0, loc_2 + 28, loc_3)
					store_i32(memory_at_0, loc_2 + 24, 1)
					store_i32(memory_at_0, loc_2 + 20, load_i32(memory_at_0, loc_0 + 4))
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[172](add_i32(loc_2, 8), loc_4, loc_1, add_i32(loc_2, 20))
				loc_3 = load_i32(memory_at_0, loc_2 + 12)
				while true do
					if load_i32(memory_at_0, loc_2 + 8) ~= 0 then
						break
					end
					store_i32(memory_at_0, loc_0, loc_1)
					store_i32(memory_at_0, loc_0 + 4, loc_3)
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				if loc_3 == 2147483649 then
					desired = 1
					break
				end
				if loc_3 == 0 then
					break
				end
				FUNC_LIST[173](loc_3, load_i32(memory_at_0, add_i32(loc_2, 16)))
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[174]()
			error("out of code bounds")
		end
		GLOBAL_LIST[0].value = add_i32(loc_2, 32)
		break
	end
end
FUNC_LIST[176] = --[[ _ZN72_$LT$$RF$str$u20$as$u20$alloc..ffi..c_str..CString..new..SpecNewImpl$GT$13spec_new_impl17hfcbd7fe73484c1d8E ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = 0
	local reg_0
	local desired
	while true do
		loc_3 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_3
		while true do
			while true do
				while true do
					while true do
						while true do
							loc_4 = add_i32(loc_2, 1)
							if loc_4 == 0 then
								break
							end
							if le_i32(loc_4, 4294967295) then
								desired = 4
								break
							end
							reg_0 = FUNC_LIST[21](loc_4, 1)
							loc_5 = reg_0
							if loc_5 == 0 then
								desired = 3
								break
							end
							reg_0 = FUNC_LIST[262](loc_5, loc_1, loc_2)
							loc_6 = reg_0
							while true do
								if loc_2 < 8 then
									break
								end
								FUNC_LIST[240](add_i32(loc_3, 8), 0, loc_1, loc_2)
								loc_7 = load_i32(memory_at_0, loc_3 + 12)
								loc_5 = load_i32(memory_at_0, loc_3 + 8)
								desired = 1
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							while true do
								if loc_2 ~= 0 then
									break
								end
								loc_7 = 0
								loc_5 = 0
								desired = 1
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							while true do
								if load_i32_u8(memory_at_0, loc_1) ~= 0 then
									break
								end
								loc_5 = 1
								loc_7 = 0
								desired = 1
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_5 = 1
							if loc_2 == 1 then
								desired = 2
								break
							end
							while true do
								if load_i32_u8(memory_at_0, loc_1 + 1) ~= 0 then
									break
								end
								loc_7 = 1
								desired = 1
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_7 = 2
							if loc_2 == 2 then
								desired = 2
								break
							end
							if load_i32_u8(memory_at_0, loc_1 + 2) == 0 then
								desired = 1
								break
							end
							loc_7 = 3
							if loc_2 == 3 then
								desired = 2
								break
							end
							if load_i32_u8(memory_at_0, loc_1 + 3) == 0 then
								desired = 1
								break
							end
							loc_7 = 4
							if loc_2 == 4 then
								desired = 2
								break
							end
							if load_i32_u8(memory_at_0, loc_1 + 4) == 0 then
								desired = 1
								break
							end
							loc_7 = 5
							if loc_2 == 5 then
								desired = 2
								break
							end
							if load_i32_u8(memory_at_0, loc_1 + 5) == 0 then
								desired = 1
								break
							end
							loc_7 = loc_2
							loc_5 = 0
							if loc_2 == 6 then
								desired = 1
								break
							end
							loc_1 = load_i32_u8(memory_at_0, loc_1 + 6)
							loc_7 = (if loc_1 ~= 0 then loc_2 else 6)
							loc_5 = (if loc_1 == 0 then 1 else 0)
							desired = 1
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						FUNC_LIST[192](1072608, 43, 1072684)
						error("out of code bounds")
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					FUNC_LIST[174]()
					error("out of code bounds")
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[173](1, loc_4)
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_7 = loc_2
			loc_5 = 0
			break
		end
		while true do
			while true do
				if loc_5 ~= 0 then
					break
				end
				store_i32(memory_at_0, loc_3 + 28, loc_2)
				store_i32(memory_at_0, loc_3 + 24, loc_6)
				store_i32(memory_at_0, loc_3 + 20, loc_4)
				FUNC_LIST[177](loc_3, add_i32(loc_3, 20))
				store_i64(memory_at_0, loc_0 + 4, load_i64(memory_at_0, loc_3))
				loc_4 = 2147483648
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			store_i32(memory_at_0, loc_0 + 8, loc_2)
			store_i32(memory_at_0, loc_0 + 4, loc_6)
			store_i32(memory_at_0, loc_0 + 12, loc_7)
			break
		end
		store_i32(memory_at_0, loc_0, loc_4)
		GLOBAL_LIST[0].value = add_i32(loc_3, 32)
		break
	end
end
FUNC_LIST[177] = --[[ _ZN5alloc3ffi5c_str7CString19_from_vec_unchecked17h9c68378f89ffd4f8E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local reg_0
	local desired
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_2
		while true do
			loc_3 = load_i32(memory_at_0, loc_1)
			loc_4 = load_i32(memory_at_0, loc_1 + 8)
			if sub_i32(loc_3, loc_4) ~= 0 then
				break
			end
			while true do
				loc_5 = add_i32(loc_4, 1)
				if loc_5 == 0 then
					break
				end
				loc_6 = shr_u32(bxor_i32(loc_5, 4294967295), 31)
				while true do
					while true do
						if loc_3 ~= 0 then
							break
						end
						store_i32(memory_at_0, loc_2 + 24, 0)
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32(memory_at_0, loc_2 + 28, loc_3)
					store_i32(memory_at_0, loc_2 + 24, 1)
					store_i32(memory_at_0, loc_2 + 20, load_i32(memory_at_0, loc_1 + 4))
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[172](add_i32(loc_2, 8), loc_6, loc_5, add_i32(loc_2, 20))
				loc_6 = load_i32(memory_at_0, loc_2 + 12)
				while true do
					if load_i32(memory_at_0, loc_2 + 8) ~= 0 then
						break
					end
					store_i32(memory_at_0, loc_1, loc_5)
					store_i32(memory_at_0, loc_1 + 4, loc_6)
					loc_3 = loc_5
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				if loc_6 == 2147483649 then
					desired = 1
					break
				end
				if loc_6 == 0 then
					break
				end
				FUNC_LIST[173](loc_6, load_i32(memory_at_0, add_i32(loc_2, 16)))
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[174]()
			error("out of code bounds")
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		while true do
			if loc_4 ~= loc_3 then
				break
			end
			FUNC_LIST[175](loc_1, loc_4)
			loc_3 = load_i32(memory_at_0, loc_1)
			loc_4 = load_i32(memory_at_0, loc_1 + 8)
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		loc_5 = add_i32(loc_4, 1)
		store_i32(memory_at_0, loc_1 + 8, loc_5)
		loc_1 = load_i32(memory_at_0, loc_1 + 4)
		store_i32_n8(memory_at_0, add_i32(loc_1, loc_4), 0)
		while true do
			while true do
				while true do
					if loc_3 > loc_5 then
						break
					end
					loc_4 = loc_1
					desired = 2
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				while true do
					if loc_5 ~= 0 then
						break
					end
					loc_4 = 1
					FUNC_LIST[22](loc_1, loc_3, 1)
					desired = 2
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				reg_0 = FUNC_LIST[23](loc_1, loc_3, 1, loc_5)
				loc_4 = reg_0
				if loc_4 == 0 then
					desired = 1
					break
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			store_i32(memory_at_0, loc_0 + 4, loc_5)
			store_i32(memory_at_0, loc_0, loc_4)
			GLOBAL_LIST[0].value = add_i32(loc_2, 32)
			desired = 0
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		FUNC_LIST[173](1, loc_5)
		error("out of code bounds")
	end
end
FUNC_LIST[178] = --[[ _ZN5alloc3fmt6format12format_inner17hc8b33988183e73f8E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = 0
	local loc_8 = 0
	local reg_0
	local desired
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_2
		while true do
			while true do
				while true do
					while true do
						while true do
							while true do
								loc_3 = load_i32(memory_at_0, loc_1 + 4)
								if loc_3 == 0 then
									break
								end
								loc_4 = load_i32(memory_at_0, loc_1)
								loc_5 = band_i32(loc_3, 3)
								while true do
									while true do
										if loc_3 >= 4 then
											break
										end
										loc_3 = 0
										loc_6 = 0
										desired = 7
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									loc_7 = add_i32(loc_4, 28)
									loc_8 = band_i32(loc_3, 4294967292)
									loc_3 = 0
									loc_6 = 0
									while true do
										loc_3 = add_i32(load_i32(memory_at_0, loc_7), add_i32(load_i32(memory_at_0, add_i32(loc_7, 4294967288)), add_i32(load_i32(memory_at_0, add_i32(loc_7, 4294967280)), add_i32(load_i32(memory_at_0, add_i32(loc_7, 4294967272)), loc_3))))
										loc_7 = add_i32(loc_7, 32)
										loc_6 = add_i32(loc_6, 4)
										if loc_8 ~= loc_6 then
											continue
										end
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								while true do
									if loc_5 == 0 then
										break
									end
									loc_7 = add_i32(add_i32(shl_i32(loc_6, 3), loc_4), 4)
									while true do
										loc_3 = add_i32(load_i32(memory_at_0, loc_7), loc_3)
										loc_7 = add_i32(loc_7, 8)
										loc_5 = add_i32(loc_5, 4294967295)
										if loc_5 ~= 0 then
											continue
										end
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								while true do
									if load_i32(memory_at_0, add_i32(loc_1, 12)) == 0 then
										break
									end
									if lt_i32(loc_3, 0) then
										desired = 6
										break
									end
									if band_i32((if loc_3 < 16 then 1 else 0), (if load_i32(memory_at_0, loc_4 + 4) == 0 then 1 else 0)) ~= 0 then
										desired = 6
										break
									end
									loc_3 = shl_i32(loc_3, 1)
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								if loc_3 ~= 0 then
									desired = 5
									break
								end
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_7 = 1
							loc_3 = 0
							desired = 4
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						if le_i32(loc_3, 4294967295) then
							desired = 3
							break
						end
						reg_0 = FUNC_LIST[21](loc_3, 1)
						loc_7 = reg_0
						if loc_7 == 0 then
							desired = 2
							break
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32(memory_at_0, loc_2 + 8, 0)
					store_i32(memory_at_0, loc_2 + 4, loc_7)
					store_i32(memory_at_0, loc_2, loc_3)
					reg_0 = FUNC_LIST[195](loc_2, 1072512, loc_1)
					if reg_0 == 0 then
						desired = 1
						break
					end
					FUNC_LIST[208](1072700, 51, add_i32(loc_2, 15), 1072752, 1072792)
					error("out of code bounds")
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[174]()
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[173](1, loc_3)
			error("out of code bounds")
		end
		store_i64(memory_at_0, loc_0, load_i64(memory_at_0, loc_2))
		store_i32(memory_at_0, add_i32(loc_0, 8), load_i32(memory_at_0, add_i32(loc_2, 8)))
		GLOBAL_LIST[0].value = add_i32(loc_2, 16)
		break
	end
end
FUNC_LIST[179] = --[[ _ZN5alloc6string6String4push17ha2b9c9843872cdd1E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local reg_0
	local desired
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_2
		while true do
			while true do
				while true do
					while true do
						if loc_1 < 128 then
							break
						end
						store_i32(memory_at_0, loc_2 + 12, 0)
						if loc_1 < 2048 then
							desired = 3
							break
						end
						while true do
							if loc_1 >= 65536 then
								break
							end
							store_i32_n8(memory_at_0, loc_2 + 14, bor_i32(band_i32(loc_1, 63), 128))
							store_i32_n8(memory_at_0, loc_2 + 12, bor_i32(shr_u32(loc_1, 12), 224))
							store_i32_n8(memory_at_0, loc_2 + 13, bor_i32(band_i32(shr_u32(loc_1, 6), 63), 128))
							loc_1 = 3
							desired = 2
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						store_i32_n8(memory_at_0, loc_2 + 15, bor_i32(band_i32(loc_1, 63), 128))
						store_i32_n8(memory_at_0, loc_2 + 14, bor_i32(band_i32(shr_u32(loc_1, 6), 63), 128))
						store_i32_n8(memory_at_0, loc_2 + 13, bor_i32(band_i32(shr_u32(loc_1, 12), 63), 128))
						store_i32_n8(memory_at_0, loc_2 + 12, bor_i32(band_i32(shr_u32(loc_1, 18), 7), 240))
						loc_1 = 4
						desired = 2
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					while true do
						loc_3 = load_i32(memory_at_0, loc_0 + 8)
						if loc_3 ~= load_i32(memory_at_0, loc_0) then
							break
						end
						FUNC_LIST[175](loc_0, loc_3)
						loc_3 = load_i32(memory_at_0, loc_0 + 8)
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32(memory_at_0, loc_0 + 8, add_i32(loc_3, 1))
					store_i32_n8(memory_at_0, add_i32(load_i32(memory_at_0, loc_0 + 4), loc_3), loc_1)
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i32_n8(memory_at_0, loc_2 + 13, bor_i32(band_i32(loc_1, 63), 128))
				store_i32_n8(memory_at_0, loc_2 + 12, bor_i32(shr_u32(loc_1, 6), 192))
				loc_1 = 2
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				loc_3 = load_i32(memory_at_0, loc_0 + 8)
				if sub_i32(load_i32(memory_at_0, loc_0), loc_3) >= loc_1 then
					break
				end
				FUNC_LIST[171](loc_0, loc_3, loc_1)
				loc_3 = load_i32(memory_at_0, loc_0 + 8)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			reg_0 = FUNC_LIST[262](add_i32(load_i32(memory_at_0, loc_0 + 4), loc_3), add_i32(loc_2, 12), loc_1)
			store_i32(memory_at_0, loc_0 + 8, add_i32(loc_3, loc_1))
			break
		end
		GLOBAL_LIST[0].value = add_i32(loc_2, 16)
		break
	end
end
FUNC_LIST[180] = --[[ _ZN58_$LT$alloc..string..String$u20$as$u20$core..fmt..Write$GT$9write_str17hbef94c01d8f2ab7aE ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	local reg_0
	while true do
		while true do
			loc_3 = load_i32(memory_at_0, loc_0 + 8)
			if sub_i32(load_i32(memory_at_0, loc_0), loc_3) >= loc_2 then
				break
			end
			FUNC_LIST[171](loc_0, loc_3, loc_2)
			loc_3 = load_i32(memory_at_0, loc_0 + 8)
			break
		end
		reg_0 = FUNC_LIST[262](add_i32(load_i32(memory_at_0, loc_0 + 4), loc_3), loc_1, loc_2)
		store_i32(memory_at_0, loc_0 + 8, add_i32(loc_3, loc_2))
		reg_0 = 0
		break
	end
	return reg_0
end
FUNC_LIST[181] = --[[ _ZN58_$LT$alloc..string..String$u20$as$u20$core..fmt..Write$GT$10write_char17h062851a21fa82158E ]] function(loc_0, loc_1)
	local reg_0
	while true do
		FUNC_LIST[179](loc_0, loc_1)
		reg_0 = 0
		break
	end
	return reg_0
end
FUNC_LIST[182] = --[[ _ZN5alloc4sync32arcinner_layout_for_value_layout17hfa4717d9f33eddccE ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	local loc_4 = 0
	local desired
	while true do
		loc_3 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_3
		while true do
			loc_4 = band_i32(add_i32(loc_1, 7), sub_i32(0, loc_1))
			if loc_4 < add_i32(loc_4, 4294967288) then
				break
			end
			loc_2 = add_i32(loc_4, loc_2)
			if loc_2 < loc_4 then
				break
			end
			loc_1 = (if loc_1 > 4 then loc_1 else 4)
			if loc_2 > sub_i32(2147483648, loc_1) then
				break
			end
			store_i32(memory_at_0, loc_0, loc_1)
			store_i32(memory_at_0, loc_0 + 4, band_i32(add_i32(add_i32(loc_1, loc_2), 4294967295), sub_i32(0, loc_1)))
			GLOBAL_LIST[0].value = add_i32(loc_3, 16)
			desired = 0
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		FUNC_LIST[208](1072808, 43, add_i32(loc_3, 15), 1072852, 1072896)
		error("out of code bounds")
	end
end
FUNC_LIST[183] = --[[ _ZN5alloc3vec16Vec$LT$T$C$A$GT$11swap_remove13assert_failed17he104d4c0d6ebba71E ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	while true do
		loc_3 = sub_i32(GLOBAL_LIST[0].value, 48)
		GLOBAL_LIST[0].value = loc_3
		store_i32(memory_at_0, loc_3 + 4, loc_1)
		store_i32(memory_at_0, loc_3, loc_0)
		store_i64(memory_at_0, add_i32(add_i32(loc_3, 8), 12), i64_from_u32(2, 0))
		store_i32(memory_at_0, add_i32(add_i32(loc_3, 32), 12), 18)
		store_i32(memory_at_0, loc_3 + 12, 3)
		store_i32(memory_at_0, loc_3 + 8, 1072960)
		store_i32(memory_at_0, loc_3 + 36, 18)
		store_i32(memory_at_0, loc_3 + 16, add_i32(loc_3, 32))
		store_i32(memory_at_0, loc_3 + 40, add_i32(loc_3, 4))
		store_i32(memory_at_0, loc_3 + 32, loc_3)
		FUNC_LIST[187](add_i32(loc_3, 8), loc_2)
		error("out of code bounds")
	end
end
FUNC_LIST[184] = --[[ _ZN4core3ops8function6FnOnce9call_once17h7ad08a4d952a39edE ]] function(loc_0, loc_1)
	local reg_0
	while true do
		while true do
			continue
		end
		break
	end
	return reg_0
end
FUNC_LIST[185] = --[[ _ZN4core3ptr25drop_in_place$LT$char$GT$17h9001cc437f19b03aE ]] function(loc_0)
	while true do
		break
	end
end
FUNC_LIST[186] = --[[ _ZN4core3ptr37drop_in_place$LT$core..fmt..Error$GT$17h0f47ae79b5b8f0aeE ]] function(loc_0)
	while true do
		break
	end
end
FUNC_LIST[187] = --[[ _ZN4core9panicking9panic_fmt17h87755523850ece9eE ]] function(loc_0, loc_1)
	local loc_2 = 0
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_2
		store_i32_n16(memory_at_0, loc_2 + 28, 1)
		store_i32(memory_at_0, loc_2 + 24, loc_1)
		store_i32(memory_at_0, loc_2 + 20, loc_0)
		store_i32(memory_at_0, loc_2 + 16, 1073180)
		store_i32(memory_at_0, loc_2 + 12, 1072984)
		FUNC_LIST[155](add_i32(loc_2, 12))
		error("out of code bounds")
	end
end
FUNC_LIST[188] = --[[ _ZN4core5slice5index26slice_start_index_len_fail17hcf0397736729de60E ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	while true do
		loc_3 = sub_i32(GLOBAL_LIST[0].value, 48)
		GLOBAL_LIST[0].value = loc_3
		store_i32(memory_at_0, loc_3, loc_0)
		store_i32(memory_at_0, loc_3 + 4, loc_1)
		store_i64(memory_at_0, add_i32(add_i32(loc_3, 8), 12), i64_from_u32(2, 0))
		store_i32(memory_at_0, add_i32(add_i32(loc_3, 32), 12), 18)
		store_i32(memory_at_0, loc_3 + 12, 2)
		store_i32(memory_at_0, loc_3 + 8, 1073884)
		store_i32(memory_at_0, loc_3 + 36, 18)
		store_i32(memory_at_0, loc_3 + 16, add_i32(loc_3, 32))
		store_i32(memory_at_0, loc_3 + 40, add_i32(loc_3, 4))
		store_i32(memory_at_0, loc_3 + 32, loc_3)
		FUNC_LIST[187](add_i32(loc_3, 8), loc_2)
		error("out of code bounds")
	end
end
FUNC_LIST[189] = --[[ _ZN4core9panicking18panic_bounds_check17h29a91b9711c376afE ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	while true do
		loc_3 = sub_i32(GLOBAL_LIST[0].value, 48)
		GLOBAL_LIST[0].value = loc_3
		store_i32(memory_at_0, loc_3 + 4, loc_1)
		store_i32(memory_at_0, loc_3, loc_0)
		store_i64(memory_at_0, add_i32(add_i32(loc_3, 8), 12), i64_from_u32(2, 0))
		store_i32(memory_at_0, add_i32(add_i32(loc_3, 32), 12), 18)
		store_i32(memory_at_0, loc_3 + 12, 2)
		store_i32(memory_at_0, loc_3 + 8, 1073272)
		store_i32(memory_at_0, loc_3 + 36, 18)
		store_i32(memory_at_0, loc_3 + 16, add_i32(loc_3, 32))
		store_i32(memory_at_0, loc_3 + 40, loc_3)
		store_i32(memory_at_0, loc_3 + 32, add_i32(loc_3, 4))
		FUNC_LIST[187](add_i32(loc_3, 8), loc_2)
		error("out of code bounds")
	end
end
FUNC_LIST[190] = --[[ _ZN4core5slice5index24slice_end_index_len_fail17h9a753e8fe2fb89b9E ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	while true do
		loc_3 = sub_i32(GLOBAL_LIST[0].value, 48)
		GLOBAL_LIST[0].value = loc_3
		store_i32(memory_at_0, loc_3, loc_0)
		store_i32(memory_at_0, loc_3 + 4, loc_1)
		store_i64(memory_at_0, add_i32(add_i32(loc_3, 8), 12), i64_from_u32(2, 0))
		store_i32(memory_at_0, add_i32(add_i32(loc_3, 32), 12), 18)
		store_i32(memory_at_0, loc_3 + 12, 2)
		store_i32(memory_at_0, loc_3 + 8, 1073916)
		store_i32(memory_at_0, loc_3 + 36, 18)
		store_i32(memory_at_0, loc_3 + 16, add_i32(loc_3, 32))
		store_i32(memory_at_0, loc_3 + 40, add_i32(loc_3, 4))
		store_i32(memory_at_0, loc_3 + 32, loc_3)
		FUNC_LIST[187](add_i32(loc_3, 8), loc_2)
		error("out of code bounds")
	end
end
FUNC_LIST[191] = --[[ _ZN4core3fmt9Formatter3pad17h73f218cb892cda46E ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = 0
	local loc_8 = 0
	local loc_9 = 0
	local loc_10 = 0
	local reg_0
	local desired
	local br_map = {}
	while true do
		while true do
			loc_3 = load_i32(memory_at_0, loc_0)
			loc_4 = load_i32(memory_at_0, loc_0 + 8)
			if bor_i32(loc_3, loc_4) == 0 then
				break
			end
			while true do
				if loc_4 == 0 then
					break
				end
				loc_5 = add_i32(loc_1, loc_2)
				loc_6 = add_i32(load_i32(memory_at_0, add_i32(loc_0, 12)), 1)
				loc_7 = 0
				loc_8 = loc_1
				while true do
					while true do
						loc_4 = loc_8
						loc_6 = add_i32(loc_6, 4294967295)
						if loc_6 == 0 then
							desired = 3
							break
						end
						if loc_4 == loc_5 then
							desired = 2
							break
						end
						while true do
							while true do
								loc_9 = load_i32_i8(memory_at_0, loc_4)
								if le_i32(loc_9, 4294967295) then
									break
								end
								loc_8 = add_i32(loc_4, 1)
								loc_9 = band_i32(loc_9, 255)
								desired = 5
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_10 = band_i32(load_i32_u8(memory_at_0, loc_4 + 1), 63)
							loc_8 = band_i32(loc_9, 31)
							while true do
								if loc_9 > 4294967263 then
									break
								end
								loc_9 = bor_i32(shl_i32(loc_8, 6), loc_10)
								loc_8 = add_i32(loc_4, 2)
								desired = 5
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_10 = bor_i32(shl_i32(loc_10, 6), band_i32(load_i32_u8(memory_at_0, loc_4 + 2), 63))
							while true do
								if loc_9 >= 4294967280 then
									break
								end
								loc_9 = bor_i32(loc_10, shl_i32(loc_8, 12))
								loc_8 = add_i32(loc_4, 3)
								desired = 5
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_9 = bor_i32(bor_i32(shl_i32(loc_10, 6), band_i32(load_i32_u8(memory_at_0, loc_4 + 3), 63)), band_i32(shl_i32(loc_8, 18), 1835008))
							if loc_9 == 1114112 then
								desired = 2
								break
							end
							loc_8 = add_i32(loc_4, 4)
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
								continue
							end
							break
						end
						loc_7 = add_i32(sub_i32(loc_7, loc_4), loc_8)
						if loc_9 ~= 1114112 then
							continue
						end
						desired = 2
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				if loc_4 == loc_5 then
					break
				end
				while true do
					loc_8 = load_i32_i8(memory_at_0, loc_4)
					if gt_i32(loc_8, 4294967295) then
						break
					end
					if loc_8 < 4294967264 then
						break
					end
					if loc_8 < 4294967280 then
						break
					end
					if bor_i32(bor_i32(bor_i32(shl_i32(band_i32(load_i32_u8(memory_at_0, loc_4 + 2), 63), 6), shl_i32(band_i32(load_i32_u8(memory_at_0, loc_4 + 1), 63), 12)), band_i32(load_i32_u8(memory_at_0, loc_4 + 3), 63)), band_i32(shl_i32(band_i32(loc_8, 255), 18), 1835008)) == 1114112 then
						desired = 2
						break
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				while true do
					while true do
						if loc_7 == 0 then
							break
						end
						while true do
							if loc_7 < loc_2 then
								break
							end
							loc_4 = 0
							if loc_7 == loc_2 then
								desired = 4
								break
							end
							desired = 3
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_4 = 0
						if lt_i32(load_i32_i8(memory_at_0, add_i32(loc_1, loc_7)), 4294967232) then
							desired = 3
							break
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_4 = loc_1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_2 = (if loc_4 ~= 0 then loc_7 else loc_2)
				loc_1 = (if loc_4 ~= 0 then loc_4 else loc_1)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				if loc_3 ~= 0 then
					break
				end
				reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, load_i32(memory_at_0, add_i32(loc_0, 24)) + 12)](load_i32(memory_at_0, loc_0 + 20), loc_1, loc_2)
				desired = 0
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_5 = load_i32(memory_at_0, loc_0 + 4)
			while true do
				while true do
					if loc_2 < 16 then
						break
					end
					reg_0 = FUNC_LIST[227](loc_1, loc_2)
					loc_4 = reg_0
					desired = 2
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				while true do
					if loc_2 ~= 0 then
						break
					end
					loc_4 = 0
					desired = 2
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_6 = band_i32(loc_2, 3)
				while true do
					while true do
						if loc_2 >= 4 then
							break
						end
						loc_4 = 0
						loc_9 = 0
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_7 = band_i32(loc_2, 4294967292)
					loc_4 = 0
					loc_9 = 0
					while true do
						loc_8 = add_i32(loc_1, loc_9)
						loc_4 = add_i32(add_i32(add_i32(add_i32(loc_4, (if gt_i32(load_i32_i8(memory_at_0, loc_8), 4294967231) then 1 else 0)), (if gt_i32(load_i32_i8(memory_at_0, add_i32(loc_8, 1)), 4294967231) then 1 else 0)), (if gt_i32(load_i32_i8(memory_at_0, add_i32(loc_8, 2)), 4294967231) then 1 else 0)), (if gt_i32(load_i32_i8(memory_at_0, add_i32(loc_8, 3)), 4294967231) then 1 else 0))
						loc_9 = add_i32(loc_9, 4)
						if loc_7 ~= loc_9 then
							continue
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				if loc_6 == 0 then
					break
				end
				loc_8 = add_i32(loc_1, loc_9)
				while true do
					loc_4 = add_i32(loc_4, (if gt_i32(load_i32_i8(memory_at_0, loc_8), 4294967231) then 1 else 0))
					loc_8 = add_i32(loc_8, 1)
					loc_6 = add_i32(loc_6, 4294967295)
					if loc_6 ~= 0 then
						continue
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				while true do
					if loc_5 <= loc_4 then
						break
					end
					loc_7 = sub_i32(loc_5, loc_4)
					loc_4 = 0
					while true do
						while true do
							while true do
								if not br_map[1] then
									br_map[1] = (function()
										return { [0] = 2, 0, 1, 2, }
									end)()
								end
								temp = br_map[1][load_i32_u8(memory_at_0, loc_0 + 32)] or 2
								if temp < 1 then
									break
								elseif temp > 1 then
									desired = 4
									break
								else
									desired = 5
									break
								end
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_4 = loc_7
							loc_7 = 0
							desired = 4
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_4 = shr_u32(loc_7, 1)
						loc_7 = shr_u32(add_i32(loc_7, 1), 1)
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_4 = add_i32(loc_4, 1)
					loc_8 = load_i32(memory_at_0, add_i32(loc_0, 24))
					loc_6 = load_i32(memory_at_0, loc_0 + 16)
					loc_9 = load_i32(memory_at_0, loc_0 + 20)
					while true do
						loc_4 = add_i32(loc_4, 4294967295)
						if loc_4 == 0 then
							desired = 2
							break
						end
						reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, loc_8 + 16)](loc_9, loc_6)
						if reg_0 == 0 then
							continue
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					reg_0 = 1
					desired = 0
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, load_i32(memory_at_0, add_i32(loc_0, 24)) + 12)](load_i32(memory_at_0, loc_0 + 20), loc_1, loc_2)
				desired = 0
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_4 = 1
			while true do
				reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, loc_8 + 12)](loc_9, loc_1, loc_2)
				if reg_0 ~= 0 then
					break
				end
				loc_4 = 0
				while true do
					while true do
						while true do
							if loc_7 ~= loc_4 then
								break
							end
							loc_4 = loc_7
							desired = 3
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
								continue
							end
							break
						end
						loc_4 = add_i32(loc_4, 1)
						reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, loc_8 + 16)](loc_9, loc_6)
						if reg_0 == 0 then
							continue
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_4 = add_i32(loc_4, 4294967295)
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_4 = (if loc_4 < loc_7 then 1 else 0)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			reg_0 = loc_4
			desired = 0
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, load_i32(memory_at_0, add_i32(loc_0, 24)) + 12)](load_i32(memory_at_0, loc_0 + 20), loc_1, loc_2)
		break
	end
	return reg_0
end
FUNC_LIST[192] = --[[ _ZN4core9panicking5panic17hf4ba1575e20e9f91E ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	while true do
		loc_3 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_3
		store_i64(memory_at_0, add_i32(loc_3, 12), i64_ZERO)
		store_i32(memory_at_0, loc_3 + 4, 1)
		store_i32(memory_at_0, loc_3 + 8, 1072984)
		store_i32(memory_at_0, loc_3 + 28, loc_1)
		store_i32(memory_at_0, loc_3 + 24, loc_0)
		store_i32(memory_at_0, loc_3, add_i32(loc_3, 24))
		FUNC_LIST[187](loc_3, loc_2)
		error("out of code bounds")
	end
end
FUNC_LIST[193] = --[[ _ZN4core3fmt3num3imp52_$LT$impl$u20$core..fmt..Display$u20$for$u20$u32$GT$3fmt17hef52134108805594E ]] function(loc_0, loc_1)
	local reg_0
	while true do
		reg_0 = FUNC_LIST[248](load_i64_u32(memory_at_0, loc_0), 1, loc_1)
		break
	end
	return reg_0
end
FUNC_LIST[194] = --[[ _ZN4core3fmt3num50_$LT$impl$u20$core..fmt..Debug$u20$for$u20$u32$GT$3fmt17h736963acc73d1e44E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local reg_0
	local desired
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 128)
		GLOBAL_LIST[0].value = loc_2
		while true do
			while true do
				while true do
					while true do
						while true do
							loc_3 = load_i32(memory_at_0, loc_1 + 28)
							if band_i32(loc_3, 16) ~= 0 then
								break
							end
							if band_i32(loc_3, 32) ~= 0 then
								desired = 4
								break
							end
							reg_0 = FUNC_LIST[248](load_i64_u32(memory_at_0, loc_0), 1, loc_1)
							loc_0 = reg_0
							desired = 3
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_0 = load_i32(memory_at_0, loc_0)
						loc_3 = 0
						while true do
							loc_4 = band_i32(loc_0, 15)
							store_i32_n8(memory_at_0, add_i32(add_i32(loc_2, loc_3), 127), add_i32((if loc_4 < 10 then 48 else 87), loc_4))
							loc_3 = add_i32(loc_3, 4294967295)
							loc_4 = (if loc_0 < 16 then 1 else 0)
							loc_0 = shr_u32(loc_0, 4)
							if loc_4 == 0 then
								continue
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_0 = add_i32(loc_3, 128)
						if loc_0 > 128 then
							desired = 2
							break
						end
						reg_0 = FUNC_LIST[225](loc_1, 1, 1073540, 2, add_i32(add_i32(loc_2, loc_3), 128), sub_i32(0, loc_3))
						loc_0 = reg_0
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_0 = load_i32(memory_at_0, loc_0)
					loc_3 = 0
					while true do
						loc_4 = band_i32(loc_0, 15)
						store_i32_n8(memory_at_0, add_i32(add_i32(loc_2, loc_3), 127), add_i32((if loc_4 < 10 then 48 else 55), loc_4))
						loc_3 = add_i32(loc_3, 4294967295)
						loc_4 = (if loc_0 < 16 then 1 else 0)
						loc_0 = shr_u32(loc_0, 4)
						if loc_4 == 0 then
							continue
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_0 = add_i32(loc_3, 128)
					if loc_0 > 128 then
						desired = 1
						break
					end
					reg_0 = FUNC_LIST[225](loc_1, 1, 1073540, 2, add_i32(add_i32(loc_2, loc_3), 128), sub_i32(0, loc_3))
					loc_0 = reg_0
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				GLOBAL_LIST[0].value = add_i32(loc_2, 128)
				reg_0 = loc_0
				desired = 0
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[188](loc_0, 128, 1073524)
			error("out of code bounds")
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		FUNC_LIST[188](loc_0, 128, 1073524)
		error("out of code bounds")
	end
	return reg_0
end
FUNC_LIST[195] = --[[ _ZN4core3fmt5write17ha50ab7591d59af2dE ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = 0
	local loc_8 = 0
	local loc_9 = 0
	local loc_10 = 0
	local loc_11 = 0
	local loc_12 = 0
	local loc_13 = 0
	local reg_0
	local desired
	local br_map = {}
	while true do
		loc_3 = sub_i32(GLOBAL_LIST[0].value, 48)
		GLOBAL_LIST[0].value = loc_3
		store_i32(memory_at_0, add_i32(loc_3, 36), loc_1)
		store_i32_n8(memory_at_0, loc_3 + 44, 3)
		store_i32(memory_at_0, loc_3 + 28, 32)
		loc_4 = 0
		store_i32(memory_at_0, loc_3 + 40, 0)
		store_i32(memory_at_0, loc_3 + 32, loc_0)
		store_i32(memory_at_0, loc_3 + 20, 0)
		store_i32(memory_at_0, loc_3 + 12, 0)
		while true do
			while true do
				while true do
					while true do
						while true do
							loc_5 = load_i32(memory_at_0, loc_2 + 16)
							if loc_5 ~= 0 then
								break
							end
							loc_0 = load_i32(memory_at_0, add_i32(loc_2, 12))
							if loc_0 == 0 then
								desired = 4
								break
							end
							loc_1 = load_i32(memory_at_0, loc_2 + 8)
							loc_6 = add_i32(loc_1, shl_i32(loc_0, 3))
							loc_4 = add_i32(band_i32(add_i32(loc_0, 4294967295), 536870911), 1)
							loc_0 = load_i32(memory_at_0, loc_2)
							loc_7 = 0
							while true do
								while true do
									loc_8 = load_i32(memory_at_0, add_i32(loc_0, 4))
									if loc_8 == 0 then
										break
									end
									reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, load_i32(memory_at_0, loc_3 + 36) + 12)](load_i32(memory_at_0, loc_3 + 32), load_i32(memory_at_0, loc_0), loc_8)
									if reg_0 ~= 0 then
										desired = 3
										break
									end
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
										continue
									end
									break
								end
								reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, add_i32(loc_1, 4))](load_i32(memory_at_0, loc_1), add_i32(loc_3, 12))
								if reg_0 ~= 0 then
									desired = 3
									break
								end
								loc_7 = add_i32(loc_7, 1)
								loc_0 = add_i32(loc_0, 8)
								loc_1 = add_i32(loc_1, 8)
								if loc_1 ~= loc_6 then
									continue
								end
								desired = 4
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_1 = load_i32(memory_at_0, add_i32(loc_2, 20))
						if loc_1 == 0 then
							break
						end
						loc_9 = shl_i32(loc_1, 5)
						loc_4 = add_i32(band_i32(add_i32(loc_1, 4294967295), 134217727), 1)
						loc_10 = load_i32(memory_at_0, loc_2 + 8)
						loc_0 = load_i32(memory_at_0, loc_2)
						loc_7 = 0
						loc_11 = 0
						while true do
							while true do
								loc_1 = load_i32(memory_at_0, add_i32(loc_0, 4))
								if loc_1 == 0 then
									break
								end
								reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, load_i32(memory_at_0, loc_3 + 36) + 12)](load_i32(memory_at_0, loc_3 + 32), load_i32(memory_at_0, loc_0), loc_1)
								if reg_0 ~= 0 then
									desired = 3
									break
								end
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
									continue
								end
								break
							end
							loc_1 = add_i32(loc_5, loc_7)
							store_i32(memory_at_0, loc_3 + 28, load_i32(memory_at_0, add_i32(loc_1, 16)))
							store_i32_n8(memory_at_0, loc_3 + 44, load_i32_u8(memory_at_0, add_i32(loc_1, 28)))
							store_i32(memory_at_0, loc_3 + 40, load_i32(memory_at_0, add_i32(loc_1, 24)))
							loc_6 = load_i32(memory_at_0, add_i32(loc_1, 12))
							loc_12 = 0
							loc_8 = 0
							while true do
								while true do
									while true do
										if not br_map[1] then
											br_map[1] = (function()
												return { [0] = 1, 0, 2, }
											end)()
										end
										temp = br_map[1][load_i32(memory_at_0, add_i32(loc_1, 8))] or 1
										if temp < 1 then
											break
										elseif temp > 1 then
											desired = 6
											break
										else
											desired = 7
											break
										end
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									loc_13 = shl_i32(loc_6, 3)
									loc_8 = 0
									loc_13 = add_i32(loc_10, loc_13)
									if load_i32(memory_at_0, loc_13 + 4) ~= 77 then
										desired = 6
										break
									end
									loc_6 = load_i32(memory_at_0, load_i32(memory_at_0, loc_13))
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								loc_8 = 1
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
									continue
								end
								break
							end
							store_i32(memory_at_0, loc_3 + 16, loc_6)
							store_i32(memory_at_0, loc_3 + 12, loc_8)
							loc_8 = load_i32(memory_at_0, add_i32(loc_1, 4))
							while true do
								while true do
									while true do
										if not br_map[2] then
											br_map[2] = (function()
												return { [0] = 1, 0, 2, }
											end)()
										end
										temp = br_map[2][load_i32(memory_at_0, loc_1)] or 1
										if temp < 1 then
											break
										elseif temp > 1 then
											desired = 6
											break
										else
											desired = 7
											break
										end
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									loc_6 = shl_i32(loc_8, 3)
									loc_6 = add_i32(loc_10, loc_6)
									if load_i32(memory_at_0, loc_6 + 4) ~= 77 then
										desired = 6
										break
									end
									loc_8 = load_i32(memory_at_0, load_i32(memory_at_0, loc_6))
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								loc_12 = 1
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
									continue
								end
								break
							end
							store_i32(memory_at_0, loc_3 + 24, loc_8)
							store_i32(memory_at_0, loc_3 + 20, loc_12)
							loc_1 = add_i32(loc_10, shl_i32(load_i32(memory_at_0, add_i32(loc_1, 20)), 3))
							reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, add_i32(loc_1, 4))](load_i32(memory_at_0, loc_1), add_i32(loc_3, 12))
							if reg_0 ~= 0 then
								desired = 3
								break
							end
							loc_11 = add_i32(loc_11, 1)
							loc_0 = add_i32(loc_0, 8)
							loc_7 = add_i32(loc_7, 32)
							if loc_9 ~= loc_7 then
								continue
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					if loc_4 >= load_i32(memory_at_0, loc_2 + 4) then
						desired = 2
						break
					end
					loc_1 = add_i32(load_i32(memory_at_0, loc_2), shl_i32(loc_4, 3))
					reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, load_i32(memory_at_0, loc_3 + 36) + 12)](load_i32(memory_at_0, loc_3 + 32), load_i32(memory_at_0, loc_1), load_i32(memory_at_0, loc_1 + 4))
					if reg_0 == 0 then
						desired = 2
						break
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_1 = 1
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_1 = 0
			break
		end
		GLOBAL_LIST[0].value = add_i32(loc_3, 48)
		reg_0 = loc_1
		break
	end
	return reg_0
end
FUNC_LIST[196] = --[[ _ZN71_$LT$core..ops..range..Range$LT$Idx$GT$$u20$as$u20$core..fmt..Debug$GT$3fmt17h13ff8f221a029881E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local reg_0
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_2
		loc_3 = 1
		while true do
			reg_0 = FUNC_LIST[194](loc_0, loc_1)
			if reg_0 ~= 0 then
				break
			end
			store_i64(memory_at_0, add_i32(loc_2, 20), i64_ZERO)
			loc_3 = 1
			store_i32(memory_at_0, loc_2 + 12, 1)
			store_i32(memory_at_0, loc_2 + 8, 1073060)
			store_i32(memory_at_0, loc_2 + 16, 1072984)
			reg_0 = FUNC_LIST[195](load_i32(memory_at_0, loc_1 + 20), load_i32(memory_at_0, add_i32(loc_1, 24)), add_i32(loc_2, 8))
			if reg_0 ~= 0 then
				break
			end
			reg_0 = FUNC_LIST[194](add_i32(loc_0, 4), loc_1)
			loc_3 = reg_0
			break
		end
		GLOBAL_LIST[0].value = add_i32(loc_2, 32)
		reg_0 = loc_3
		break
	end
	return reg_0
end
FUNC_LIST[197] = --[[ _ZN36_$LT$T$u20$as$u20$core..any..Any$GT$7type_id17hdf0bbf5ea3e8f209E ]] function(loc_0, loc_1)
	while true do
		store_i64(memory_at_0, loc_0 + 8, i64_from_u32(2365997581, 2734931110))
		store_i64(memory_at_0, loc_0, i64_from_u32(589103780, 3142083496))
		break
	end
end
FUNC_LIST[198] = --[[ _ZN4core5slice5index22slice_index_order_fail17hc9e96c77993e8a69E ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	while true do
		loc_3 = sub_i32(GLOBAL_LIST[0].value, 48)
		GLOBAL_LIST[0].value = loc_3
		store_i32(memory_at_0, loc_3, loc_0)
		store_i32(memory_at_0, loc_3 + 4, loc_1)
		store_i64(memory_at_0, add_i32(add_i32(loc_3, 8), 12), i64_from_u32(2, 0))
		store_i32(memory_at_0, add_i32(add_i32(loc_3, 32), 12), 18)
		store_i32(memory_at_0, loc_3 + 12, 2)
		store_i32(memory_at_0, loc_3 + 8, 1073968)
		store_i32(memory_at_0, loc_3 + 36, 18)
		store_i32(memory_at_0, loc_3 + 16, add_i32(loc_3, 32))
		store_i32(memory_at_0, loc_3 + 40, add_i32(loc_3, 4))
		store_i32(memory_at_0, loc_3 + 32, loc_3)
		FUNC_LIST[187](add_i32(loc_3, 8), loc_2)
		error("out of code bounds")
	end
end
FUNC_LIST[199] = --[[ _ZN60_$LT$core..cell..BorrowError$u20$as$u20$core..fmt..Debug$GT$3fmt17h573443824b73d2e6E ]] function(loc_0, loc_1)
	local reg_0
	while true do
		reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, load_i32(memory_at_0, add_i32(loc_1, 24)) + 12)](load_i32(memory_at_0, loc_1 + 20), 1073084, 11)
		break
	end
	return reg_0
end
FUNC_LIST[200] = --[[ _ZN63_$LT$core..cell..BorrowMutError$u20$as$u20$core..fmt..Debug$GT$3fmt17hfb2526f8f8c4e89dE ]] function(loc_0, loc_1)
	local reg_0
	while true do
		reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, load_i32(memory_at_0, add_i32(loc_1, 24)) + 12)](load_i32(memory_at_0, loc_1 + 20), 1073095, 14)
		break
	end
	return reg_0
end
FUNC_LIST[201] = --[[ _ZN4core4cell22panic_already_borrowed17hdfd15bcb019b1598E ]] function(loc_0)
	local loc_1 = 0
	while true do
		loc_1 = sub_i32(GLOBAL_LIST[0].value, 48)
		GLOBAL_LIST[0].value = loc_1
		store_i64(memory_at_0, add_i32(loc_1, 24), i64_ONE)
		store_i32(memory_at_0, loc_1 + 16, 1)
		store_i32(memory_at_0, loc_1 + 12, 1073128)
		store_i32(memory_at_0, loc_1 + 40, 78)
		store_i32(memory_at_0, loc_1 + 20, add_i32(loc_1, 36))
		store_i32(memory_at_0, loc_1 + 36, add_i32(loc_1, 47))
		FUNC_LIST[187](add_i32(loc_1, 12), loc_0)
		error("out of code bounds")
	end
end
FUNC_LIST[202] = --[[ _ZN4core4cell30panic_already_mutably_borrowed17h4c55f518769d0ec4E ]] function(loc_0)
	local loc_1 = 0
	while true do
		loc_1 = sub_i32(GLOBAL_LIST[0].value, 48)
		GLOBAL_LIST[0].value = loc_1
		store_i64(memory_at_0, add_i32(loc_1, 24), i64_ONE)
		store_i32(memory_at_0, loc_1 + 16, 1)
		store_i32(memory_at_0, loc_1 + 12, 1073164)
		store_i32(memory_at_0, loc_1 + 40, 79)
		store_i32(memory_at_0, loc_1 + 20, add_i32(loc_1, 36))
		store_i32(memory_at_0, loc_1 + 36, add_i32(loc_1, 47))
		FUNC_LIST[187](add_i32(loc_1, 12), loc_0)
		error("out of code bounds")
	end
end
FUNC_LIST[203] = --[[ _ZN4core4char7methods22_$LT$impl$u20$char$GT$16escape_debug_ext17h7caaa1213990ba6eE ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	local reg_0
	local desired
	local br_map = {}
	while true do
		loc_3 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_3
		while true do
			while true do
				while true do
					while true do
						while true do
							while true do
								while true do
									while true do
										while true do
											while true do
												if not br_map[1] then
													br_map[1] = (function()
														return { [0] = 5, 8, 8, 8, 8, 8, 8, 8, 8, 1, 3, 8, 8, 2, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 6, 8, 8, 8, 8, 7, }
													end)()
												end
												temp = br_map[1][loc_1] or 0
												if temp < 5 then
													if temp < 2 then
														if temp < 1 then
															break
														else
															desired = 9
															break
														end
													elseif temp > 2 then
														desired = 7
														break
													else
														desired = 8
														break
													end
												elseif temp > 5 then
													if temp < 7 then
														desired = 4
														break
													elseif temp > 7 then
														desired = 2
														break
													else
														desired = 3
														break
													end
												else
													desired = 5
													break
												end
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											if loc_1 == 92 then
												desired = 6
												break
											end
											desired = 2
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										store_i32_n16(memory_at_0, loc_0 + 10, 512)
										store_i64(memory_at_0, loc_0 + 2, i64_ZERO)
										store_i32_n16(memory_at_0, loc_0, 29788)
										desired = 1
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									store_i32_n16(memory_at_0, loc_0 + 10, 512)
									store_i64(memory_at_0, loc_0 + 2, i64_ZERO)
									store_i32_n16(memory_at_0, loc_0, 29276)
									desired = 1
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								store_i32_n16(memory_at_0, loc_0 + 10, 512)
								store_i64(memory_at_0, loc_0 + 2, i64_ZERO)
								store_i32_n16(memory_at_0, loc_0, 28252)
								desired = 1
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							store_i32_n16(memory_at_0, loc_0 + 10, 512)
							store_i64(memory_at_0, loc_0 + 2, i64_ZERO)
							store_i32_n16(memory_at_0, loc_0, 23644)
							desired = 1
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						store_i32_n16(memory_at_0, loc_0 + 10, 512)
						store_i64(memory_at_0, loc_0 + 2, i64_ZERO)
						store_i32_n16(memory_at_0, loc_0, 12380)
						desired = 1
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					if band_i32(loc_2, 65536) == 0 then
						desired = 2
						break
					end
					store_i32_n16(memory_at_0, loc_0 + 10, 512)
					store_i64(memory_at_0, loc_0 + 2, i64_ZERO)
					store_i32_n16(memory_at_0, loc_0, 8796)
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				if band_i32(loc_2, 256) == 0 then
					break
				end
				store_i32_n16(memory_at_0, loc_0 + 10, 512)
				store_i64(memory_at_0, loc_0 + 2, i64_ZERO)
				store_i32_n16(memory_at_0, loc_0, 10076)
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				while true do
					while true do
						while true do
							while true do
								if band_i32(loc_2, 1) == 0 then
									break
								end
								reg_0 = FUNC_LIST[204](loc_1)
								if reg_0 ~= 0 then
									desired = 5
									break
								end
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							reg_0 = FUNC_LIST[205](loc_1)
							if reg_0 == 0 then
								desired = 4
								break
							end
							store_i32(memory_at_0, loc_0 + 4, loc_1)
							store_i32_n8(memory_at_0, loc_0, 128)
							desired = 1
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						store_i32_n8(memory_at_0, add_i32(add_i32(loc_3, 6), 2), 0)
						store_i32_n16(memory_at_0, loc_3 + 6, 0)
						store_i32_n8(memory_at_0, loc_3 + 15, 125)
						store_i32_n8(memory_at_0, loc_3 + 14, load_i32_u8(memory_at_0, add_i32(band_i32(loc_1, 15), 1073068)))
						store_i32_n8(memory_at_0, loc_3 + 13, load_i32_u8(memory_at_0, add_i32(band_i32(shr_u32(loc_1, 4), 15), 1073068)))
						store_i32_n8(memory_at_0, loc_3 + 12, load_i32_u8(memory_at_0, add_i32(band_i32(shr_u32(loc_1, 8), 15), 1073068)))
						store_i32_n8(memory_at_0, loc_3 + 11, load_i32_u8(memory_at_0, add_i32(band_i32(shr_u32(loc_1, 12), 15), 1073068)))
						store_i32_n8(memory_at_0, loc_3 + 10, load_i32_u8(memory_at_0, add_i32(band_i32(shr_u32(loc_1, 16), 15), 1073068)))
						store_i32_n8(memory_at_0, loc_3 + 9, load_i32_u8(memory_at_0, add_i32(band_i32(shr_u32(loc_1, 20), 15), 1073068)))
						loc_1 = add_i32(shr_u32(clz_i32(bor_i32(loc_1, 1)), 2), 4294967294)
						if loc_1 >= 11 then
							desired = 3
							break
						end
						loc_2 = add_i32(add_i32(loc_3, 6), loc_1)
						store_i32_n16(memory_at_0, loc_2, load_i32_u16(memory_at_0, 0 + 1076152))
						store_i32_n8(memory_at_0, add_i32(loc_2, 2), load_i32_u8(memory_at_0, 0 + 1076154))
						store_i64(memory_at_0, loc_0, load_i64(memory_at_0, loc_3 + 6))
						store_i32_n16(memory_at_0, add_i32(loc_0, 8), load_i32_u16(memory_at_0, add_i32(add_i32(loc_3, 6), 8)))
						store_i32_n8(memory_at_0, loc_0 + 11, 10)
						store_i32_n8(memory_at_0, loc_0 + 10, loc_1)
						desired = 1
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32_n8(memory_at_0, add_i32(add_i32(loc_3, 6), 2), 0)
					store_i32_n16(memory_at_0, loc_3 + 6, 0)
					store_i32_n8(memory_at_0, loc_3 + 15, 125)
					store_i32_n8(memory_at_0, loc_3 + 14, load_i32_u8(memory_at_0, add_i32(band_i32(loc_1, 15), 1073068)))
					store_i32_n8(memory_at_0, loc_3 + 13, load_i32_u8(memory_at_0, add_i32(band_i32(shr_u32(loc_1, 4), 15), 1073068)))
					store_i32_n8(memory_at_0, loc_3 + 12, load_i32_u8(memory_at_0, add_i32(band_i32(shr_u32(loc_1, 8), 15), 1073068)))
					store_i32_n8(memory_at_0, loc_3 + 11, load_i32_u8(memory_at_0, add_i32(band_i32(shr_u32(loc_1, 12), 15), 1073068)))
					store_i32_n8(memory_at_0, loc_3 + 10, load_i32_u8(memory_at_0, add_i32(band_i32(shr_u32(loc_1, 16), 15), 1073068)))
					store_i32_n8(memory_at_0, loc_3 + 9, load_i32_u8(memory_at_0, add_i32(band_i32(shr_u32(loc_1, 20), 15), 1073068)))
					loc_1 = add_i32(shr_u32(clz_i32(bor_i32(loc_1, 1)), 2), 4294967294)
					if loc_1 >= 11 then
						desired = 2
						break
					end
					loc_2 = add_i32(add_i32(loc_3, 6), loc_1)
					store_i32_n16(memory_at_0, loc_2, load_i32_u16(memory_at_0, 0 + 1076152))
					store_i32_n8(memory_at_0, add_i32(loc_2, 2), load_i32_u8(memory_at_0, 0 + 1076154))
					store_i64(memory_at_0, loc_0, load_i64(memory_at_0, loc_3 + 6))
					store_i32_n16(memory_at_0, add_i32(loc_0, 8), load_i32_u16(memory_at_0, add_i32(add_i32(loc_3, 6), 8)))
					store_i32_n8(memory_at_0, loc_0 + 11, 10)
					store_i32_n8(memory_at_0, loc_0 + 10, loc_1)
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[188](loc_1, 10, 1076136)
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[188](loc_1, 10, 1076136)
			error("out of code bounds")
		end
		GLOBAL_LIST[0].value = add_i32(loc_3, 16)
		break
	end
end
FUNC_LIST[204] = --[[ _ZN4core7unicode12unicode_data15grapheme_extend6lookup17hcf7332614736cfcaE ]] function(loc_0)
	local loc_1 = 0
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local reg_0
	local desired
	while true do
		loc_1 = shl_i32(loc_0, 11)
		loc_2 = 0
		loc_3 = 33
		loc_4 = 33
		while true do
			while true do
				while true do
					loc_3 = add_i32(shr_u32(loc_3, 1), loc_2)
					loc_5 = shl_i32(load_i32(memory_at_0, add_i32(shl_i32(loc_3, 2), 1076172)), 11)
					if loc_5 == loc_1 then
						desired = 2
						break
					end
					loc_4 = (if loc_5 > loc_1 then loc_3 else loc_4)
					loc_2 = (if loc_5 < loc_1 then add_i32(loc_3, 1) else loc_2)
					loc_3 = sub_i32(loc_4, loc_2)
					if loc_4 > loc_2 then
						continue
					end
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_2 = add_i32(loc_3, 1)
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		while true do
			while true do
				while true do
					while true do
						if loc_2 > 32 then
							break
						end
						loc_3 = shl_i32(loc_2, 2)
						loc_1 = shr_u32(load_i32(memory_at_0, add_i32(loc_3, 1076172)), 21)
						if loc_2 ~= 32 then
							desired = 3
							break
						end
						loc_2 = 31
						loc_5 = 727
						desired = 2
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					FUNC_LIST[189](loc_2, 33, 1076076)
					error("out of code bounds")
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_5 = shr_u32(load_i32(memory_at_0, add_i32(loc_3, 1076176)), 21)
				while true do
					if loc_2 ~= 0 then
						break
					end
					loc_2 = 0
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_2 = add_i32(loc_2, 4294967295)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_2 = band_i32(load_i32(memory_at_0, add_i32(shl_i32(loc_2, 2), 1076172)), 2097151)
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		while true do
			while true do
				if add_i32(loc_5, bxor_i32(loc_1, 4294967295)) == 0 then
					break
				end
				loc_4 = sub_i32(loc_0, loc_2)
				loc_3 = (if loc_1 > 727 then loc_1 else 727)
				loc_5 = add_i32(loc_5, 4294967295)
				loc_2 = 0
				while true do
					if loc_3 == loc_1 then
						desired = 1
						break
					end
					loc_2 = add_i32(loc_2, load_i32_u8(memory_at_0, add_i32(loc_1, 1076304)))
					if loc_2 > loc_4 then
						desired = 2
						break
					end
					loc_1 = add_i32(loc_1, 1)
					if loc_5 ~= loc_1 then
						continue
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_1 = loc_5
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			reg_0 = band_i32(loc_1, 1)
			desired = 0
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		FUNC_LIST[189](loc_3, 727, 1076092)
		error("out of code bounds")
	end
	return reg_0
end
FUNC_LIST[205] = --[[ _ZN4core7unicode9printable12is_printable17h1abd1ee70f8981ccE ]] function(loc_0)
	local loc_1 = 0
	local reg_0
	local desired
	while true do
		while true do
			if loc_0 >= 32 then
				break
			end
			reg_0 = 0
			desired = 0
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		loc_1 = 1
		while true do
			while true do
				if loc_0 < 127 then
					break
				end
				if loc_0 < 65536 then
					desired = 1
					break
				end
				while true do
					while true do
						if loc_0 < 131072 then
							break
						end
						while true do
							if add_i32(loc_0, 4294761552) >= 712016 then
								break
							end
							reg_0 = 0
							desired = 0
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						while true do
							if add_i32(loc_0, 4294765749) >= 5 then
								break
							end
							reg_0 = 0
							desired = 0
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						while true do
							if add_i32(loc_0, 4294772194) >= 1506 then
								break
							end
							reg_0 = 0
							desired = 0
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						while true do
							if add_i32(loc_0, 4294775839) >= 3103 then
								break
							end
							reg_0 = 0
							desired = 0
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						while true do
							if add_i32(loc_0, 4294783326) >= 14 then
								break
							end
							reg_0 = 0
							desired = 0
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						while true do
							if band_i32(loc_0, 4294967294) ~= 178206 then
								break
							end
							reg_0 = 0
							desired = 0
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						if band_i32(loc_0, 4294967264) ~= 173792 then
							desired = 3
							break
						end
						reg_0 = 0
						desired = 0
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					reg_0 = FUNC_LIST[244](loc_0, 1074632, 44, 1074720, 196, 1074916, 450)
					desired = 0
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_1 = 0
				if add_i32(loc_0, 4294789318) < 6 then
					break
				end
				loc_1 = (if add_i32(loc_0, 4293853184) < 4294771184 then 1 else 0)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			reg_0 = loc_1
			desired = 0
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		reg_0 = FUNC_LIST[244](loc_0, 1075366, 40, 1075446, 287, 1075733, 303)
		break
	end
	return reg_0
end
FUNC_LIST[206] = --[[ _ZN4core3str8converts9from_utf817h1d8752563d759f2eE ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = 0
	local loc_8 = i64_ZERO
	local loc_9 = i64_ZERO
	local loc_10 = 0
	local desired
	local br_map = {}
	while true do
		while true do
			if loc_2 == 0 then
				break
			end
			loc_3 = add_i32(loc_2, 4294967289)
			loc_4 = (if loc_3 > loc_2 then 0 else loc_3)
			loc_5 = sub_i32(band_i32(add_i32(loc_1, 3), 4294967292), loc_1)
			loc_3 = 0
			while true do
				while true do
					while true do
						while true do
							while true do
								loc_6 = load_i32_u8(memory_at_0, add_i32(loc_1, loc_3))
								loc_7 = extend_i32_n8(loc_6)
								if lt_i32(loc_7, 0) then
									break
								end
								if band_i32(sub_i32(loc_5, loc_3), 3) ~= 0 then
									desired = 5
									break
								end
								if loc_3 >= loc_4 then
									desired = 4
									break
								end
								while true do
									loc_6 = add_i32(loc_1, loc_3)
									if band_i32(bor_i32(load_i32(memory_at_0, add_i32(loc_6, 4)), load_i32(memory_at_0, loc_6)), 2155905152) ~= 0 then
										desired = 4
										break
									end
									loc_3 = add_i32(loc_3, 8)
									if loc_3 < loc_4 then
										continue
									end
									desired = 4
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_8 = i64_from_u32(0, 256)
							loc_9 = i64_from_u32(0, 1)
							while true do
								while true do
									while true do
										while true do
											while true do
												while true do
													while true do
														while true do
															while true do
																while true do
																	while true do
																		while true do
																			if not br_map[1] then
																				br_map[1] = (function()
																					return { [0] = 0, 1, 2, }
																				end)()
																			end
																			temp = br_map[1][add_i32(load_i32_u8(memory_at_0, add_i32(loc_6, 1074036)), 4294967294)] or 10
																			if temp < 2 then
																				if temp < 1 then
																					break
																				else
																					desired = 16
																					break
																				end
																			elseif temp > 2 then
																				desired = 7
																				break
																			else
																				desired = 15
																				break
																			end
																		end
																		if desired then
																			if desired == 16 then
																				desired = nil
																			end
																			break
																		end
																		loc_6 = add_i32(loc_3, 1)
																		if loc_6 < loc_2 then
																			desired = 14
																			break
																		end
																		loc_8 = i64_ZERO
																		loc_9 = i64_ZERO
																		desired = 7
																		break
																	end
																	if desired then
																		if desired == 15 then
																			desired = nil
																		end
																		break
																	end
																	loc_8 = i64_ZERO
																	loc_10 = add_i32(loc_3, 1)
																	if loc_10 < loc_2 then
																		desired = 13
																		break
																	end
																	loc_9 = i64_ZERO
																	desired = 7
																	break
																end
																if desired then
																	if desired == 14 then
																		desired = nil
																	end
																	break
																end
																loc_8 = i64_ZERO
																loc_10 = add_i32(loc_3, 1)
																if loc_10 < loc_2 then
																	desired = 12
																	break
																end
																loc_9 = i64_ZERO
																desired = 7
																break
															end
															if desired then
																if desired == 13 then
																	desired = nil
																end
																break
															end
															loc_8 = i64_from_u32(0, 256)
															loc_9 = i64_from_u32(0, 1)
															if gt_i32(load_i32_i8(memory_at_0, add_i32(loc_1, loc_6)), 4294967231) then
																desired = 7
																break
															end
															desired = 6
															break
														end
														if desired then
															if desired == 12 then
																desired = nil
															end
															break
														end
														loc_10 = load_i32_i8(memory_at_0, add_i32(loc_1, loc_10))
														while true do
															while true do
																while true do
																	if not br_map[2] then
																		br_map[2] = (function()
																			return { [0] = 0, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, }
																		end)()
																	end
																	temp = br_map[2][add_i32(loc_6, 4294967072)] or 2
																	if temp < 1 then
																		break
																	elseif temp > 1 then
																		desired = 13
																		break
																	else
																		desired = 14
																		break
																	end
																end
																if desired then
																	if desired == 14 then
																		desired = nil
																	end
																	break
																end
																if band_i32(loc_10, 4294967264) == 4294967200 then
																	desired = 10
																	break
																end
																desired = 11
																break
															end
															if desired then
																if desired == 13 then
																	desired = nil
																end
																break
															end
															if gt_i32(loc_10, 4294967199) then
																desired = 11
																break
															end
															desired = 10
															break
														end
														if desired then
															if desired == 12 then
																desired = nil
															end
															break
														end
														while true do
															if band_i32(add_i32(loc_7, 31), 255) < 12 then
																break
															end
															if band_i32(loc_7, 4294967294) ~= 4294967278 then
																desired = 11
																break
															end
															if lt_i32(loc_10, 4294967232) then
																desired = 10
																break
															end
															desired = 11
															break
														end
														if desired then
															if desired == 12 then
																desired = nil
															end
															break
														end
														if lt_i32(loc_10, 4294967232) then
															desired = 10
															break
														end
														desired = 11
														break
													end
													if desired then
														if desired == 11 then
															desired = nil
														end
														break
													end
													loc_10 = load_i32_i8(memory_at_0, add_i32(loc_1, loc_10))
													while true do
														while true do
															while true do
																while true do
																	if not br_map[3] then
																		br_map[3] = (function()
																			return { [0] = 1, 0, 0, 0, 2, }
																		end)()
																	end
																	temp = br_map[3][add_i32(loc_6, 4294967056)] or 0
																	if temp < 1 then
																		break
																	elseif temp > 1 then
																		desired = 13
																		break
																	else
																		desired = 14
																		break
																	end
																end
																if desired then
																	if desired == 14 then
																		desired = nil
																	end
																	break
																end
																if band_i32(add_i32(loc_7, 15), 255) > 2 then
																	desired = 11
																	break
																end
																if ge_i32(loc_10, 4294967232) then
																	desired = 11
																	break
																end
																desired = 12
																break
															end
															if desired then
																if desired == 13 then
																	desired = nil
																end
																break
															end
															if band_i32(add_i32(loc_10, 112), 255) >= 48 then
																desired = 11
																break
															end
															desired = 12
															break
														end
														if desired then
															if desired == 12 then
																desired = nil
															end
															break
														end
														if gt_i32(loc_10, 4294967183) then
															desired = 11
															break
														end
														break
													end
													if desired then
														if desired == 11 then
															desired = nil
														end
														break
													end
													while true do
														loc_6 = add_i32(loc_3, 2)
														if loc_6 < loc_2 then
															break
														end
														loc_9 = i64_ZERO
														desired = 7
														break
													end
													if desired then
														if desired == 11 then
															desired = nil
														end
														break
													end
													if gt_i32(load_i32_i8(memory_at_0, add_i32(loc_1, loc_6)), 4294967231) then
														desired = 9
														break
													end
													loc_9 = i64_ZERO
													loc_6 = add_i32(loc_3, 3)
													if loc_6 >= loc_2 then
														desired = 7
														break
													end
													if le_i32(load_i32_i8(memory_at_0, add_i32(loc_1, loc_6)), 4294967231) then
														desired = 6
														break
													end
													loc_8 = i64_from_u32(0, 768)
													desired = 8
													break
												end
												if desired then
													if desired == 10 then
														desired = nil
													end
													break
												end
												loc_8 = i64_from_u32(0, 256)
												desired = 8
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											loc_9 = i64_ZERO
											loc_6 = add_i32(loc_3, 2)
											if loc_6 >= loc_2 then
												desired = 7
												break
											end
											if le_i32(load_i32_i8(memory_at_0, add_i32(loc_1, loc_6)), 4294967231) then
												desired = 6
												break
											end
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										loc_8 = i64_from_u32(0, 512)
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									loc_9 = i64_from_u32(0, 1)
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								store_i64(memory_at_0, loc_0 + 4, bor_i64(bor_i64(loc_8, extend_i64_u32(loc_3)), loc_9))
								store_i32(memory_at_0, loc_0, 1)
								desired = 0
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_3 = add_i32(loc_6, 1)
							desired = 3
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_3 = add_i32(loc_3, 1)
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					if loc_3 >= loc_2 then
						break
					end
					while true do
						if lt_i32(load_i32_i8(memory_at_0, add_i32(loc_1, loc_3)), 0) then
							desired = 3
							break
						end
						loc_3 = add_i32(loc_3, 1)
						if loc_2 ~= loc_3 then
							continue
						end
						desired = 1
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
						continue
					end
					break
				end
				if loc_3 < loc_2 then
					continue
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		store_i32(memory_at_0, loc_0 + 4, loc_1)
		store_i32(memory_at_0, add_i32(loc_0, 8), loc_2)
		store_i32(memory_at_0, loc_0, 0)
		break
	end
end
FUNC_LIST[207] = --[[ _ZN4core3fmt8builders11DebugStruct5field17h652ff94e161d8713E ]] function(loc_0, loc_1, loc_2, loc_3, loc_4)
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = 0
	local loc_8 = 0
	local loc_9 = 0
	local loc_10 = i64_ZERO
	local reg_0
	local desired
	while true do
		loc_5 = sub_i32(GLOBAL_LIST[0].value, 64)
		GLOBAL_LIST[0].value = loc_5
		loc_6 = 1
		while true do
			if load_i32_u8(memory_at_0, loc_0 + 4) ~= 0 then
				break
			end
			loc_7 = load_i32_u8(memory_at_0, loc_0 + 5)
			while true do
				loc_8 = load_i32(memory_at_0, loc_0)
				loc_9 = load_i32(memory_at_0, loc_8 + 28)
				if band_i32(loc_9, 4) ~= 0 then
					break
				end
				loc_6 = 1
				loc_7 = band_i32(loc_7, 255)
				reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, load_i32(memory_at_0, add_i32(loc_8, 24)) + 12)](load_i32(memory_at_0, loc_8 + 20), (if loc_7 ~= 0 then 1073483 else 1073480), (if loc_7 ~= 0 then 2 else 3))
				if reg_0 ~= 0 then
					desired = 1
					break
				end
				loc_6 = 1
				reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, load_i32(memory_at_0, loc_8 + 24) + 12)](load_i32(memory_at_0, loc_8 + 20), loc_1, loc_2)
				if reg_0 ~= 0 then
					desired = 1
					break
				end
				loc_6 = 1
				reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, load_i32(memory_at_0, loc_8 + 24) + 12)](load_i32(memory_at_0, loc_8 + 20), 1073432, 2)
				if reg_0 ~= 0 then
					desired = 1
					break
				end
				reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, loc_4 + 12)](loc_3, loc_8)
				loc_6 = reg_0
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				if band_i32(loc_7, 255) ~= 0 then
					break
				end
				loc_6 = 1
				reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, load_i32(memory_at_0, add_i32(loc_8, 24)) + 12)](load_i32(memory_at_0, loc_8 + 20), 1073485, 3)
				if reg_0 ~= 0 then
					desired = 1
					break
				end
				loc_9 = load_i32(memory_at_0, loc_8 + 28)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_6 = 1
			store_i32_n8(memory_at_0, loc_5 + 27, 1)
			store_i32(memory_at_0, add_i32(loc_5, 52), 1073452)
			store_i64(memory_at_0, loc_5 + 12, load_i64(memory_at_0, loc_8 + 20))
			store_i32(memory_at_0, loc_5 + 20, add_i32(loc_5, 27))
			store_i64(memory_at_0, loc_5 + 36, load_i64(memory_at_0, loc_8 + 8))
			loc_10 = load_i64(memory_at_0, loc_8)
			store_i32(memory_at_0, loc_5 + 56, loc_9)
			store_i32(memory_at_0, loc_5 + 44, load_i32(memory_at_0, loc_8 + 16))
			store_i32_n8(memory_at_0, loc_5 + 60, load_i32_u8(memory_at_0, loc_8 + 32))
			store_i64(memory_at_0, loc_5 + 28, loc_10)
			store_i32(memory_at_0, loc_5 + 48, add_i32(loc_5, 12))
			reg_0 = FUNC_LIST[217](add_i32(loc_5, 12), loc_1, loc_2)
			if reg_0 ~= 0 then
				break
			end
			reg_0 = FUNC_LIST[217](add_i32(loc_5, 12), 1073432, 2)
			if reg_0 ~= 0 then
				break
			end
			reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, loc_4 + 12)](loc_3, add_i32(loc_5, 28))
			if reg_0 ~= 0 then
				break
			end
			reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, load_i32(memory_at_0, loc_5 + 52) + 12)](load_i32(memory_at_0, loc_5 + 48), 1073488, 2)
			loc_6 = reg_0
			break
		end
		store_i32_n8(memory_at_0, loc_0 + 5, 1)
		store_i32_n8(memory_at_0, loc_0 + 4, loc_6)
		GLOBAL_LIST[0].value = add_i32(loc_5, 64)
		reg_0 = loc_0
		break
	end
	return reg_0
end
FUNC_LIST[208] = --[[ _ZN4core6result13unwrap_failed17hd86007cff22dcd83E ]] function(loc_0, loc_1, loc_2, loc_3, loc_4)
	local loc_5 = 0
	while true do
		loc_5 = sub_i32(GLOBAL_LIST[0].value, 64)
		GLOBAL_LIST[0].value = loc_5
		store_i32(memory_at_0, loc_5 + 12, loc_1)
		store_i32(memory_at_0, loc_5 + 8, loc_0)
		store_i32(memory_at_0, loc_5 + 20, loc_3)
		store_i32(memory_at_0, loc_5 + 16, loc_2)
		store_i64(memory_at_0, add_i32(add_i32(loc_5, 24), 12), i64_from_u32(2, 0))
		store_i32(memory_at_0, add_i32(add_i32(loc_5, 48), 12), 80)
		store_i32(memory_at_0, loc_5 + 28, 2)
		store_i32(memory_at_0, loc_5 + 24, 1073436)
		store_i32(memory_at_0, loc_5 + 52, 81)
		store_i32(memory_at_0, loc_5 + 32, add_i32(loc_5, 48))
		store_i32(memory_at_0, loc_5 + 56, add_i32(loc_5, 16))
		store_i32(memory_at_0, loc_5 + 48, add_i32(loc_5, 8))
		FUNC_LIST[187](add_i32(loc_5, 24), loc_4)
		error("out of code bounds")
	end
end
FUNC_LIST[209] = --[[ _ZN4core3fmt3num3imp52_$LT$impl$u20$core..fmt..Display$u20$for$u20$u16$GT$3fmt17h508c343672db7580E ]] function(loc_0, loc_1)
	local reg_0
	while true do
		reg_0 = FUNC_LIST[248](load_i64_u16(memory_at_0, loc_0), 1, loc_1)
		break
	end
	return reg_0
end
FUNC_LIST[210] = --[[ _ZN4core6option13expect_failed17h65a8ce8e046de7dbE ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	while true do
		loc_3 = sub_i32(GLOBAL_LIST[0].value, 48)
		GLOBAL_LIST[0].value = loc_3
		store_i32(memory_at_0, loc_3 + 12, loc_1)
		store_i32(memory_at_0, loc_3 + 8, loc_0)
		store_i64(memory_at_0, add_i32(loc_3, 28), i64_ONE)
		store_i32(memory_at_0, loc_3 + 20, 1)
		store_i32(memory_at_0, loc_3 + 16, 1073172)
		store_i32(memory_at_0, loc_3 + 44, 81)
		store_i32(memory_at_0, loc_3 + 24, add_i32(loc_3, 40))
		store_i32(memory_at_0, loc_3 + 40, add_i32(loc_3, 8))
		FUNC_LIST[187](add_i32(loc_3, 16), loc_2)
		error("out of code bounds")
	end
end
FUNC_LIST[211] = --[[ _ZN44_$LT$$RF$T$u20$as$u20$core..fmt..Display$GT$3fmt17had2bfb80f48ecce7E ]] function(loc_0, loc_1)
	local reg_0
	while true do
		reg_0 = FUNC_LIST[191](loc_1, load_i32(memory_at_0, loc_0), load_i32(memory_at_0, loc_0 + 4))
		break
	end
	return reg_0
end
FUNC_LIST[212] = --[[ _ZN4core9panicking14panic_explicit17hcbd1be61b5e67796E ]] function(loc_0)
	local loc_1 = 0
	while true do
		loc_1 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_1
		store_i64(memory_at_0, add_i32(loc_1, 12), i64_ONE)
		store_i32(memory_at_0, loc_1 + 4, 1)
		store_i32(memory_at_0, loc_1, 1073172)
		store_i32(memory_at_0, loc_1 + 28, 81)
		store_i32(memory_at_0, loc_1 + 24, 1073212)
		store_i32(memory_at_0, loc_1 + 8, add_i32(loc_1, 24))
		FUNC_LIST[187](loc_1, loc_0)
		error("out of code bounds")
	end
end
FUNC_LIST[213] = --[[ _ZN4core3fmt3num53_$LT$impl$u20$core..fmt..LowerHex$u20$for$u20$i32$GT$3fmt17h5d4b35a80534cf61E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local reg_0
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 128)
		GLOBAL_LIST[0].value = loc_2
		loc_0 = load_i32(memory_at_0, loc_0)
		loc_3 = 0
		while true do
			loc_4 = band_i32(loc_0, 15)
			store_i32_n8(memory_at_0, add_i32(add_i32(loc_2, loc_3), 127), add_i32((if loc_4 < 10 then 48 else 87), loc_4))
			loc_3 = add_i32(loc_3, 4294967295)
			loc_4 = (if loc_0 < 16 then 1 else 0)
			loc_0 = shr_u32(loc_0, 4)
			if loc_4 == 0 then
				continue
			end
			break
		end
		while true do
			loc_0 = add_i32(loc_3, 128)
			if loc_0 <= 128 then
				break
			end
			FUNC_LIST[188](loc_0, 128, 1073524)
			error("out of code bounds")
		end
		reg_0 = FUNC_LIST[225](loc_1, 1, 1073540, 2, add_i32(add_i32(loc_2, loc_3), 128), sub_i32(0, loc_3))
		loc_0 = reg_0
		GLOBAL_LIST[0].value = add_i32(loc_2, 128)
		reg_0 = loc_0
		break
	end
	return reg_0
end
FUNC_LIST[214] = --[[ _ZN4core9panicking19assert_failed_inner17h161125ff96c9e54aE ]] function(loc_0, loc_1, loc_2, loc_3, loc_4, loc_5, loc_6)
	local loc_7 = 0
	local desired
	local br_map = {}
	while true do
		loc_7 = sub_i32(GLOBAL_LIST[0].value, 112)
		GLOBAL_LIST[0].value = loc_7
		store_i32(memory_at_0, loc_7 + 12, loc_2)
		store_i32(memory_at_0, loc_7 + 8, loc_1)
		store_i32(memory_at_0, loc_7 + 20, loc_4)
		store_i32(memory_at_0, loc_7 + 16, loc_3)
		while true do
			while true do
				while true do
					while true do
						if not br_map[1] then
							br_map[1] = (function()
								return { [0] = 0, 1, 2, }
							end)()
						end
						temp = br_map[1][band_i32(loc_0, 255)] or 0
						if temp < 1 then
							break
						elseif temp > 1 then
							desired = 2
							break
						else
							desired = 3
							break
						end
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32(memory_at_0, loc_7 + 24, 1073288)
					loc_2 = 2
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i32(memory_at_0, loc_7 + 24, 1073290)
				loc_2 = 2
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			store_i32(memory_at_0, loc_7 + 24, 1073292)
			loc_2 = 7
			break
		end
		store_i32(memory_at_0, loc_7 + 28, loc_2)
		while true do
			if load_i32(memory_at_0, loc_5) ~= 0 then
				break
			end
			store_i32(memory_at_0, add_i32(loc_7, 76), 80)
			store_i32(memory_at_0, add_i32(add_i32(loc_7, 56), 12), 80)
			store_i64(memory_at_0, add_i32(add_i32(loc_7, 88), 12), i64_from_u32(3, 0))
			store_i32(memory_at_0, loc_7 + 92, 3)
			store_i32(memory_at_0, loc_7 + 88, 1073348)
			store_i32(memory_at_0, loc_7 + 60, 81)
			store_i32(memory_at_0, loc_7 + 96, add_i32(loc_7, 56))
			store_i32(memory_at_0, loc_7 + 72, add_i32(loc_7, 16))
			store_i32(memory_at_0, loc_7 + 64, add_i32(loc_7, 8))
			store_i32(memory_at_0, loc_7 + 56, add_i32(loc_7, 24))
			FUNC_LIST[187](add_i32(loc_7, 88), loc_6)
			error("out of code bounds")
		end
		store_i64(memory_at_0, add_i32(add_i32(loc_7, 32), 16), load_i64(memory_at_0, add_i32(loc_5, 16)))
		store_i64(memory_at_0, add_i32(add_i32(loc_7, 32), 8), load_i64(memory_at_0, add_i32(loc_5, 8)))
		store_i64(memory_at_0, loc_7 + 32, load_i64(memory_at_0, loc_5))
		store_i64(memory_at_0, add_i32(add_i32(loc_7, 88), 12), i64_from_u32(4, 0))
		store_i32(memory_at_0, add_i32(loc_7, 84), 80)
		store_i32(memory_at_0, add_i32(loc_7, 76), 80)
		store_i32(memory_at_0, add_i32(add_i32(loc_7, 56), 12), 82)
		store_i32(memory_at_0, loc_7 + 92, 4)
		store_i32(memory_at_0, loc_7 + 88, 1073400)
		store_i32(memory_at_0, loc_7 + 60, 81)
		store_i32(memory_at_0, loc_7 + 96, add_i32(loc_7, 56))
		store_i32(memory_at_0, loc_7 + 80, add_i32(loc_7, 16))
		store_i32(memory_at_0, loc_7 + 72, add_i32(loc_7, 8))
		store_i32(memory_at_0, loc_7 + 64, add_i32(loc_7, 32))
		store_i32(memory_at_0, loc_7 + 56, add_i32(loc_7, 24))
		FUNC_LIST[187](add_i32(loc_7, 88), loc_6)
		error("out of code bounds")
	end
end
FUNC_LIST[215] = --[[ _ZN42_$LT$$RF$T$u20$as$u20$core..fmt..Debug$GT$3fmt17hb65107c98ca4ff83E ]] function(loc_0, loc_1)
	local reg_0
	while true do
		reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, load_i32(memory_at_0, loc_0 + 4) + 12)](load_i32(memory_at_0, loc_0), loc_1)
		break
	end
	return reg_0
end
FUNC_LIST[216] = --[[ _ZN59_$LT$core..fmt..Arguments$u20$as$u20$core..fmt..Display$GT$3fmt17hb592aa44d0511c35E ]] function(loc_0, loc_1)
	local reg_0
	while true do
		reg_0 = FUNC_LIST[195](load_i32(memory_at_0, loc_1 + 20), load_i32(memory_at_0, add_i32(loc_1, 24)), loc_0)
		break
	end
	return reg_0
end
FUNC_LIST[217] = --[[ _ZN68_$LT$core..fmt..builders..PadAdapter$u20$as$u20$core..fmt..Write$GT$9write_str17h2a4b3be5f6da6eebE ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = 0
	local loc_8 = 0
	local loc_9 = 0
	local loc_10 = 0
	local loc_11 = 0
	local loc_12 = 0
	local loc_13 = 0
	local reg_0
	local desired
	while true do
		loc_3 = load_i32(memory_at_0, loc_0 + 4)
		loc_4 = load_i32(memory_at_0, loc_0)
		loc_5 = load_i32(memory_at_0, loc_0 + 8)
		loc_6 = 0
		loc_7 = 0
		loc_8 = 0
		loc_9 = 0
		while true do
			while true do
				if band_i32(loc_9, 255) ~= 0 then
					desired = 1
					break
				end
				while true do
					while true do
						if loc_8 > loc_2 then
							break
						end
						while true do
							loc_10 = add_i32(loc_1, loc_8)
							while true do
								while true do
									while true do
										while true do
											while true do
												loc_11 = sub_i32(loc_2, loc_8)
												if loc_11 < 8 then
													break
												end
												loc_0 = band_i32(add_i32(loc_10, 3), 4294967292)
												if loc_0 == loc_10 then
													desired = 9
													break
												end
												loc_0 = sub_i32(loc_0, loc_10)
												if loc_0 == 0 then
													desired = 9
													break
												end
												loc_12 = 0
												while true do
													if load_i32_u8(memory_at_0, add_i32(loc_10, loc_12)) == 10 then
														desired = 6
														break
													end
													loc_12 = add_i32(loc_12, 1)
													if loc_0 ~= loc_12 then
														continue
													end
													break
												end
												if desired then
													if desired == 10 then
														desired = nil
													end
													break
												end
												loc_13 = add_i32(loc_11, 4294967288)
												if loc_0 > loc_13 then
													desired = 7
													break
												end
												desired = 8
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											while true do
												if loc_2 ~= loc_8 then
													break
												end
												loc_8 = loc_2
												desired = 4
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											loc_12 = 0
											while true do
												if load_i32_u8(memory_at_0, add_i32(loc_10, loc_12)) == 10 then
													desired = 6
													break
												end
												loc_12 = add_i32(loc_12, 1)
												if loc_11 ~= loc_12 then
													continue
												end
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											loc_8 = loc_2
											desired = 4
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										loc_13 = add_i32(loc_11, 4294967288)
										loc_0 = 0
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									while true do
										loc_12 = add_i32(loc_10, loc_0)
										loc_9 = load_i32(memory_at_0, add_i32(loc_12, 4))
										loc_12 = load_i32(memory_at_0, loc_12)
										if band_i32(bor_i32(band_i32(add_i32(bxor_i32(loc_9, 168430090), 4278124287), bxor_i32(loc_9, 4294967295)), band_i32(add_i32(bxor_i32(loc_12, 168430090), 4278124287), bxor_i32(loc_12, 4294967295))), 2155905152) ~= 0 then
											desired = 7
											break
										end
										loc_0 = add_i32(loc_0, 8)
										if loc_0 <= loc_13 then
											continue
										end
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								while true do
									if loc_0 ~= loc_11 then
										break
									end
									loc_8 = loc_2
									desired = 4
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								while true do
									while true do
										if load_i32_u8(memory_at_0, add_i32(loc_10, loc_0)) ~= 10 then
											break
										end
										loc_12 = loc_0
										desired = 6
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
											continue
										end
										break
									end
									loc_0 = add_i32(loc_0, 1)
									if loc_11 ~= loc_0 then
										continue
									end
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								loc_8 = loc_2
								desired = 4
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
									continue
								end
								break
							end
							loc_0 = add_i32(loc_8, loc_12)
							loc_8 = add_i32(loc_0, 1)
							while true do
								if loc_0 >= loc_2 then
									break
								end
								if load_i32_u8(memory_at_0, add_i32(loc_1, loc_0)) ~= 10 then
									break
								end
								loc_9 = 0
								loc_13 = loc_8
								loc_0 = loc_8
								desired = 3
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
									continue
								end
								break
							end
							if loc_8 <= loc_2 then
								continue
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_9 = 1
					loc_13 = loc_7
					loc_0 = loc_2
					if loc_7 == loc_2 then
						desired = 1
						break
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
						continue
					end
					break
				end
				while true do
					while true do
						if load_i32_u8(memory_at_0, loc_5) == 0 then
							break
						end
						reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, loc_3 + 12)](loc_4, 1073476, 4)
						if reg_0 ~= 0 then
							desired = 3
							break
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_12 = add_i32(loc_1, loc_7)
					loc_10 = sub_i32(loc_0, loc_7)
					loc_11 = 0
					while true do
						if loc_0 == loc_7 then
							break
						end
						loc_11 = (if load_i32_u8(memory_at_0, add_i32(add_i32(loc_10, loc_12), 4294967295)) == 10 then 1 else 0)
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32_n8(memory_at_0, loc_5, loc_11)
					loc_7 = loc_13
					reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, loc_3 + 12)](loc_4, loc_12, loc_10)
					if reg_0 == 0 then
						desired = 2
						break
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
						continue
					end
					break
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_6 = 1
			break
		end
		reg_0 = loc_6
		break
	end
	return reg_0
end
FUNC_LIST[218] = --[[ _ZN68_$LT$core..fmt..builders..PadAdapter$u20$as$u20$core..fmt..Write$GT$10write_char17hfbb5d2a2cb4d7d55E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local reg_0
	local desired
	while true do
		loc_2 = load_i32(memory_at_0, loc_0 + 4)
		loc_3 = load_i32(memory_at_0, loc_0)
		while true do
			loc_0 = load_i32(memory_at_0, loc_0 + 8)
			if load_i32_u8(memory_at_0, loc_0) == 0 then
				break
			end
			reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, loc_2 + 12)](loc_3, 1073476, 4)
			if reg_0 == 0 then
				break
			end
			reg_0 = 1
			desired = 0
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		store_i32_n8(memory_at_0, loc_0, (if loc_1 == 10 then 1 else 0))
		reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, loc_2 + 16)](loc_3, loc_1)
		break
	end
	return reg_0
end
FUNC_LIST[219] = --[[ _ZN4core3fmt8builders11DebugStruct6finish17h89660c69ec90ce03E ]] function(loc_0)
	local loc_1 = 0
	local loc_2 = 0
	local reg_0
	local reg_1
	local desired
	while true do
		loc_1 = load_i32_u8(memory_at_0, loc_0 + 4)
		while true do
			if load_i32_u8(memory_at_0, loc_0 + 5) ~= 0 then
				break
			end
			reg_0 = (if band_i32(loc_1, 255) ~= 0 then 1 else 0)
			desired = 0
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		loc_2 = 1
		while true do
			if band_i32(loc_1, 255) ~= 0 then
				break
			end
			while true do
				loc_1 = load_i32(memory_at_0, loc_0)
				if band_i32(load_i32_u8(memory_at_0, loc_1 + 28), 4) ~= 0 then
					break
				end
				reg_1 = TABLE_LIST[0].data[load_i32(memory_at_0, load_i32(memory_at_0, loc_1 + 24) + 12)](load_i32(memory_at_0, loc_1 + 20), 1073491, 2)
				loc_1 = reg_1
				store_i32_n8(memory_at_0, loc_0 + 4, loc_1)
				reg_0 = loc_1
				desired = 0
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, load_i32(memory_at_0, loc_1 + 24) + 12)](load_i32(memory_at_0, loc_1 + 20), 1073490, 1)
			loc_2 = reg_0
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		store_i32_n8(memory_at_0, loc_0 + 4, loc_2)
		reg_0 = loc_2
		break
	end
	return reg_0
end
FUNC_LIST[220] = --[[ _ZN4core3fmt8builders10DebugTuple5field17hd4872990ab4972f4E ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = 0
	local loc_8 = i64_ZERO
	local reg_0
	local desired
	while true do
		loc_3 = sub_i32(GLOBAL_LIST[0].value, 64)
		GLOBAL_LIST[0].value = loc_3
		loc_4 = load_i32(memory_at_0, loc_0)
		loc_5 = 1
		while true do
			if load_i32_u8(memory_at_0, loc_0 + 8) ~= 0 then
				break
			end
			while true do
				loc_6 = load_i32(memory_at_0, loc_0 + 4)
				loc_7 = load_i32(memory_at_0, loc_6 + 28)
				if band_i32(loc_7, 4) ~= 0 then
					break
				end
				loc_5 = 1
				reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, load_i32(memory_at_0, add_i32(loc_6, 24)) + 12)](load_i32(memory_at_0, loc_6 + 20), (if loc_4 ~= 0 then 1073483 else 1073493), (if loc_4 ~= 0 then 2 else 1))
				if reg_0 ~= 0 then
					desired = 1
					break
				end
				reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, loc_2 + 12)](loc_1, loc_6)
				loc_5 = reg_0
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				if loc_4 ~= 0 then
					break
				end
				loc_5 = 1
				reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, load_i32(memory_at_0, add_i32(loc_6, 24)) + 12)](load_i32(memory_at_0, loc_6 + 20), 1073494, 2)
				if reg_0 ~= 0 then
					desired = 1
					break
				end
				loc_7 = load_i32(memory_at_0, loc_6 + 28)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_5 = 1
			store_i32_n8(memory_at_0, loc_3 + 27, 1)
			store_i32(memory_at_0, add_i32(loc_3, 52), 1073452)
			store_i64(memory_at_0, loc_3 + 12, load_i64(memory_at_0, loc_6 + 20))
			store_i32(memory_at_0, loc_3 + 20, add_i32(loc_3, 27))
			store_i64(memory_at_0, loc_3 + 36, load_i64(memory_at_0, loc_6 + 8))
			loc_8 = load_i64(memory_at_0, loc_6)
			store_i32(memory_at_0, loc_3 + 56, loc_7)
			store_i32(memory_at_0, loc_3 + 44, load_i32(memory_at_0, loc_6 + 16))
			store_i32_n8(memory_at_0, loc_3 + 60, load_i32_u8(memory_at_0, loc_6 + 32))
			store_i64(memory_at_0, loc_3 + 28, loc_8)
			store_i32(memory_at_0, loc_3 + 48, add_i32(loc_3, 12))
			reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, loc_2 + 12)](loc_1, add_i32(loc_3, 28))
			if reg_0 ~= 0 then
				break
			end
			reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, load_i32(memory_at_0, loc_3 + 52) + 12)](load_i32(memory_at_0, loc_3 + 48), 1073488, 2)
			loc_5 = reg_0
			break
		end
		store_i32_n8(memory_at_0, loc_0 + 8, loc_5)
		store_i32(memory_at_0, loc_0, add_i32(loc_4, 1))
		GLOBAL_LIST[0].value = add_i32(loc_3, 64)
		reg_0 = loc_0
		break
	end
	return reg_0
end
FUNC_LIST[221] = --[[ _ZN4core3fmt8builders10DebugTuple6finish17hca74b5c4c359be11E ]] function(loc_0)
	local loc_1 = 0
	local loc_2 = 0
	local loc_3 = 0
	local reg_0
	local reg_1
	local desired
	while true do
		loc_1 = load_i32_u8(memory_at_0, loc_0 + 8)
		while true do
			loc_2 = load_i32(memory_at_0, loc_0)
			if loc_2 ~= 0 then
				break
			end
			reg_0 = (if band_i32(loc_1, 255) ~= 0 then 1 else 0)
			desired = 0
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		loc_3 = 1
		while true do
			while true do
				if band_i32(loc_1, 255) ~= 0 then
					break
				end
				loc_1 = load_i32(memory_at_0, loc_0 + 4)
				if loc_2 ~= 1 then
					desired = 1
					break
				end
				if band_i32(load_i32_u8(memory_at_0, loc_0 + 9), 255) == 0 then
					desired = 1
					break
				end
				if band_i32(load_i32_u8(memory_at_0, loc_1 + 28), 4) ~= 0 then
					desired = 1
					break
				end
				loc_3 = 1
				reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, load_i32(memory_at_0, add_i32(loc_1, 24)) + 12)](load_i32(memory_at_0, loc_1 + 20), 1073496, 1)
				if reg_0 == 0 then
					desired = 1
					break
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			store_i32_n8(memory_at_0, loc_0 + 8, loc_3)
			reg_0 = loc_3
			desired = 0
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		reg_1 = TABLE_LIST[0].data[load_i32(memory_at_0, load_i32(memory_at_0, add_i32(loc_1, 24)) + 12)](load_i32(memory_at_0, loc_1 + 20), 1073054, 1)
		loc_1 = reg_1
		store_i32_n8(memory_at_0, loc_0 + 8, loc_1)
		reg_0 = loc_1
		break
	end
	return reg_0
end
FUNC_LIST[222] = --[[ _ZN4core3fmt3num14parse_u64_into17hac94ba559dab585fE ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = i64_ZERO
	local loc_6 = 0
	local loc_7 = i64_ZERO
	local loc_8 = 0
	local loc_9 = 0
	local desired
	while true do
		while true do
			loc_3 = load_i32(memory_at_0, loc_2)
			if loc_3 <= 19 then
				break
			end
			while true do
				while true do
					while true do
						if lt_u64(loc_0, i64_from_u32(1874919424, 2328306)) then
							break
						end
						loc_4 = add_i32(loc_3, 4294967280)
						store_i32(memory_at_0, loc_2, loc_4)
						loc_5 = div_u64(loc_0, i64_from_u32(1874919424, 2328306))
						loc_0 = sub_i64(loc_0, mul_i64(loc_5, i64_from_u32(1874919424, 2328306)))
						store_i32_n16(memory_at_0, add_i32(loc_1, loc_4), load_i32_u16(memory_at_0, add_i32(shl_i32(wrap_i32_i64(div_u64(loc_0, i64_from_u32(276447232, 23283))), 1), 1073542)))
						loc_6 = add_i32(loc_3, loc_1)
						loc_7 = div_u64(loc_0, i64_from_u32(100, 0))
						store_i32_n16(memory_at_0, add_i32(loc_6, 4294967292), load_i32_u16(memory_at_0, add_i32(shl_i32(wrap_i32_i64(rem_u64(loc_7, i64_from_u32(100, 0))), 1), 1073542)))
						store_i32_n16(memory_at_0, add_i32(loc_6, 4294967290), load_i32_u16(memory_at_0, add_i32(shl_i32(wrap_i32_i64(rem_u64(div_u64(loc_0, i64_from_u32(10000, 0)), i64_from_u32(100, 0))), 1), 1073542)))
						store_i32_n16(memory_at_0, add_i32(loc_6, 4294967288), load_i32_u16(memory_at_0, add_i32(shl_i32(wrap_i32_i64(rem_u64(div_u64(loc_0, i64_from_u32(1000000, 0)), i64_from_u32(100, 0))), 1), 1073542)))
						store_i32_n16(memory_at_0, add_i32(loc_6, 4294967286), load_i32_u16(memory_at_0, add_i32(shl_i32((wrap_i32_i64(div_u64(loc_0, i64_from_u32(100000000, 0))) % 100), 1), 1073542)))
						store_i32_n16(memory_at_0, add_i32(loc_6, 4294967284), load_i32_u16(memory_at_0, add_i32(shl_i32((wrap_i32_i64(div_u64(loc_0, i64_from_u32(1410065408, 2))) % 100), 1), 1073542)))
						store_i32_n16(memory_at_0, add_i32(loc_6, 4294967282), load_i32_u16(memory_at_0, add_i32(shl_i32((band_i32(wrap_i32_i64(div_u64(loc_0, i64_from_u32(3567587328, 232))), 65535) % 100), 1), 1073542)))
						loc_6 = wrap_i32_i64(sub_i64(loc_0, mul_i64(loc_7, i64_from_u32(100, 0))))
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					while true do
						if ge_u64(loc_0, i64_from_u32(100000000, 0)) then
							break
						end
						loc_4 = loc_3
						loc_5 = loc_0
						desired = 2
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_4 = add_i32(loc_3, 4294967288)
					loc_5 = div_u64(loc_0, i64_from_u32(100000000, 0))
					loc_6 = wrap_i32_i64(sub_i64(loc_0, mul_i64(loc_5, i64_from_u32(100000000, 0))))
					store_i32_n16(memory_at_0, add_i32(loc_1, loc_4), load_i32_u16(memory_at_0, add_i32(shl_i32(div_u32(loc_6, 1000000), 1), 1073542)))
					loc_8 = add_i32(loc_3, loc_1)
					loc_9 = div_u32(loc_6, 100)
					store_i32_n16(memory_at_0, add_i32(loc_8, 4294967292), load_i32_u16(memory_at_0, add_i32(shl_i32((loc_9 % 100), 1), 1073542)))
					store_i32_n16(memory_at_0, add_i32(loc_8, 4294967290), load_i32_u16(memory_at_0, add_i32(shl_i32((band_i32(div_u32(loc_6, 10000), 65535) % 100), 1), 1073542)))
					loc_6 = sub_i32(loc_6, mul_i32(loc_9, 100))
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i32_n16(memory_at_0, add_i32(add_i32(loc_3, loc_1), 4294967294), load_i32_u16(memory_at_0, add_i32(shl_i32(loc_6, 1), 1073542)))
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				while true do
					loc_8 = wrap_i32_i64(loc_5)
					if loc_8 >= 10000 then
						break
					end
					loc_3 = loc_4
					loc_6 = loc_8
					desired = 2
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_3 = add_i32(loc_4, 4294967292)
				loc_6 = div_u32(loc_8, 10000)
				loc_8 = sub_i32(loc_8, mul_i32(loc_6, 10000))
				loc_9 = div_u32(band_i32(loc_8, 65535), 100)
				store_i32_n16(memory_at_0, add_i32(loc_1, loc_3), load_i32_u16(memory_at_0, add_i32(shl_i32(loc_9, 1), 1073542)))
				store_i32_n16(memory_at_0, add_i32(add_i32(loc_4, loc_1), 4294967294), load_i32_u16(memory_at_0, add_i32(shl_i32(band_i32(sub_i32(loc_8, mul_i32(loc_9, 100)), 65535), 1), 1073542)))
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				while true do
					loc_4 = band_i32(loc_6, 65535)
					if loc_4 >= 100 then
						break
					end
					loc_4 = loc_6
					desired = 2
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_3 = add_i32(loc_3, 4294967294)
				loc_4 = div_u32(loc_4, 100)
				store_i32_n16(memory_at_0, add_i32(loc_1, loc_3), load_i32_u16(memory_at_0, add_i32(shl_i32(band_i32(sub_i32(loc_6, mul_i32(loc_4, 100)), 65535), 1), 1073542)))
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				if band_i32(loc_4, 65535) < 10 then
					break
				end
				loc_3 = add_i32(loc_3, 4294967294)
				store_i32_n16(memory_at_0, add_i32(loc_1, loc_3), load_i32_u16(memory_at_0, add_i32(shl_i32(band_i32(loc_4, 65535), 1), 1073542)))
				store_i32(memory_at_0, loc_2, loc_3)
				desired = 0
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_3 = add_i32(loc_3, 4294967295)
			store_i32_n8(memory_at_0, add_i32(loc_1, loc_3), add_i32(loc_4, 48))
			store_i32(memory_at_0, loc_2, loc_3)
			desired = 0
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		FUNC_LIST[192](1073742, 28, 1073772)
		error("out of code bounds")
	end
end
FUNC_LIST[223] = --[[ _ZN4core3fmt3num53_$LT$impl$u20$core..fmt..Display$u20$for$u20$u128$GT$3fmt17hf950231f84149bd9E ]] function(loc_0, loc_1)
	local reg_0
	while true do
		reg_0 = FUNC_LIST[224](load_i64(memory_at_0, loc_0), load_i64(memory_at_0, add_i32(loc_0, 8)), 1, loc_1)
		break
	end
	return reg_0
end
FUNC_LIST[224] = --[[ _ZN4core3fmt3num8fmt_u12817hce39f83a803eae7bE ]] function(loc_0, loc_1, loc_2, loc_3)
	local loc_4 = 0
	local loc_5 = i64_ZERO
	local loc_6 = i64_ZERO
	local loc_7 = 0
	local reg_0
	local desired
	while true do
		loc_4 = sub_i32(GLOBAL_LIST[0].value, 144)
		GLOBAL_LIST[0].value = loc_4
		store_i32(memory_at_0, loc_4 + 140, 39)
		while true do
			while true do
				if lt_u64(loc_1, i64_from_u32(524288, 0)) then
					break
				end
				FUNC_LIST[258](add_i32(loc_4, 48), loc_0, i64_ZERO, i64_from_u32(3895859571, 2509829361), i64_ZERO)
				FUNC_LIST[258](add_i32(loc_4, 32), loc_0, i64_ZERO, i64_from_u32(3679105234, 1980704062), i64_ZERO)
				FUNC_LIST[258](add_i32(loc_4, 80), loc_1, i64_ZERO, i64_from_u32(3895859571, 2509829361), i64_ZERO)
				FUNC_LIST[258](add_i32(loc_4, 64), loc_1, i64_ZERO, i64_from_u32(3679105234, 1980704062), i64_ZERO)
				loc_5 = load_i64(memory_at_0, add_i32(add_i32(loc_4, 48), 8))
				loc_1 = add_i64(loc_5, load_i64(memory_at_0, loc_4 + 32))
				loc_6 = add_i64(load_i64(memory_at_0, add_i32(add_i32(loc_4, 32), 8)), extend_i64_u32((if lt_u64(loc_1, loc_5) then 1 else 0)))
				loc_5 = add_i64(loc_6, load_i64(memory_at_0, loc_4 + 64))
				loc_1 = add_i64(loc_5, add_i64(load_i64(memory_at_0, add_i32(add_i32(loc_4, 80), 8)), extend_i64_u32((if lt_u64(add_i64(loc_1, load_i64(memory_at_0, loc_4 + 80)), loc_1) then 1 else 0))))
				loc_6 = add_i64(add_i64(load_i64(memory_at_0, add_i32(add_i32(loc_4, 64), 8)), extend_i64_u32((if lt_u64(loc_5, loc_6) then 1 else 0))), extend_i64_u32((if lt_u64(loc_1, loc_5) then 1 else 0)))
				loc_5 = shr_u64(loc_6, i64_from_u32(62, 0))
				loc_1 = bor_i64(shr_u64(loc_1, i64_from_u32(62, 0)), shl_i64(loc_6, i64_from_u32(2, 0)))
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_1 = div_u64(bor_i64(shr_u64(loc_0, i64_from_u32(19, 0)), shl_i64(loc_1, i64_from_u32(45, 0))), i64_from_u32(3831533885, 4440))
			loc_5 = i64_ZERO
			break
		end
		FUNC_LIST[258](add_i32(loc_4, 16), loc_1, loc_5, i64_from_u32(1981284352, 1966660859), i64_ZERO)
		FUNC_LIST[222](add_i64(load_i64(memory_at_0, loc_4 + 16), loc_0), add_i32(loc_4, 101), add_i32(loc_4, 140))
		loc_7 = load_i32(memory_at_0, loc_4 + 140)
		while true do
			if eq_i64(bor_i64(loc_1, loc_5), i64_ZERO) then
				break
			end
			reg_0 = FUNC_LIST[259](add_i32(add_i32(loc_4, 101), 20), 48, add_i32(loc_7, 4294967276))
			store_i32(memory_at_0, loc_4 + 140, 20)
			loc_5 = bor_i64(shr_u64(loc_1, i64_from_u32(19, 0)), shl_i64(loc_5, i64_from_u32(45, 0)))
			loc_0 = div_u64(loc_5, i64_from_u32(3831533885, 4440))
			FUNC_LIST[258](loc_4, loc_0, loc_1, i64_from_u32(1981284352, 1966660859), i64_ZERO)
			FUNC_LIST[222](add_i64(load_i64(memory_at_0, loc_4), loc_1), add_i32(loc_4, 101), add_i32(loc_4, 140))
			loc_7 = load_i32(memory_at_0, loc_4 + 140)
			if lt_u64(loc_5, i64_from_u32(3831533885, 4440)) then
				break
			end
			reg_0 = FUNC_LIST[259](add_i32(loc_4, 102), 48, add_i32(loc_7, 4294967295))
			store_i32_n8(memory_at_0, loc_4 + 101, bor_i32(wrap_i32_i64(loc_0), 48))
			loc_7 = 0
			break
		end
		reg_0 = FUNC_LIST[225](loc_3, loc_2, 1072984, 0, add_i32(add_i32(loc_4, 101), loc_7), sub_i32(39, loc_7))
		loc_7 = reg_0
		GLOBAL_LIST[0].value = add_i32(loc_4, 144)
		reg_0 = loc_7
		break
	end
	return reg_0
end
FUNC_LIST[225] = --[[ _ZN4core3fmt9Formatter12pad_integral17h1b9ab4229b529a1dE ]] function(loc_0, loc_1, loc_2, loc_3, loc_4, loc_5)
	local loc_6 = 0
	local loc_7 = 0
	local loc_8 = 0
	local loc_9 = 0
	local loc_10 = 0
	local loc_11 = 0
	local loc_12 = 0
	local reg_0
	local desired
	local br_map = {}
	while true do
		while true do
			while true do
				if loc_1 ~= 0 then
					break
				end
				loc_6 = add_i32(loc_5, 1)
				loc_7 = load_i32(memory_at_0, loc_0 + 28)
				loc_8 = 45
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_7 = load_i32(memory_at_0, loc_0 + 28)
			loc_1 = band_i32(loc_7, 1)
			loc_8 = (if loc_1 ~= 0 then 43 else 1114112)
			loc_6 = add_i32(loc_1, loc_5)
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		while true do
			while true do
				if band_i32(loc_7, 4) ~= 0 then
					break
				end
				loc_2 = 0
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				while true do
					if loc_3 < 16 then
						break
					end
					reg_0 = FUNC_LIST[227](loc_2, loc_3)
					loc_1 = reg_0
					desired = 2
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				while true do
					if loc_3 ~= 0 then
						break
					end
					loc_1 = 0
					desired = 2
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_9 = band_i32(loc_3, 3)
				while true do
					while true do
						if loc_3 >= 4 then
							break
						end
						loc_1 = 0
						loc_10 = 0
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_11 = band_i32(loc_3, 4294967292)
					loc_1 = 0
					loc_10 = 0
					while true do
						loc_12 = add_i32(loc_2, loc_10)
						loc_1 = add_i32(add_i32(add_i32(add_i32(loc_1, (if gt_i32(load_i32_i8(memory_at_0, loc_12), 4294967231) then 1 else 0)), (if gt_i32(load_i32_i8(memory_at_0, add_i32(loc_12, 1)), 4294967231) then 1 else 0)), (if gt_i32(load_i32_i8(memory_at_0, add_i32(loc_12, 2)), 4294967231) then 1 else 0)), (if gt_i32(load_i32_i8(memory_at_0, add_i32(loc_12, 3)), 4294967231) then 1 else 0))
						loc_10 = add_i32(loc_10, 4)
						if loc_11 ~= loc_10 then
							continue
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				if loc_9 == 0 then
					break
				end
				loc_12 = add_i32(loc_2, loc_10)
				while true do
					loc_1 = add_i32(loc_1, (if gt_i32(load_i32_i8(memory_at_0, loc_12), 4294967231) then 1 else 0))
					loc_12 = add_i32(loc_12, 1)
					loc_9 = add_i32(loc_9, 4294967295)
					if loc_9 ~= 0 then
						continue
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_6 = add_i32(loc_1, loc_6)
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		while true do
			while true do
				if load_i32(memory_at_0, loc_0) ~= 0 then
					break
				end
				loc_1 = 1
				loc_12 = load_i32(memory_at_0, loc_0 + 20)
				loc_10 = load_i32(memory_at_0, loc_0 + 24)
				reg_0 = FUNC_LIST[228](loc_12, loc_10, loc_8, loc_2, loc_3)
				if reg_0 ~= 0 then
					desired = 1
					break
				end
				reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, loc_10 + 12)](loc_12, loc_4, loc_5)
				desired = 0
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				loc_9 = load_i32(memory_at_0, loc_0 + 4)
				if loc_9 > loc_6 then
					break
				end
				loc_1 = 1
				loc_12 = load_i32(memory_at_0, loc_0 + 20)
				loc_10 = load_i32(memory_at_0, loc_0 + 24)
				reg_0 = FUNC_LIST[228](loc_12, loc_10, loc_8, loc_2, loc_3)
				if reg_0 ~= 0 then
					desired = 1
					break
				end
				reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, loc_10 + 12)](loc_12, loc_4, loc_5)
				desired = 0
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				if band_i32(loc_7, 8) == 0 then
					break
				end
				loc_11 = load_i32(memory_at_0, loc_0 + 16)
				store_i32(memory_at_0, loc_0 + 16, 48)
				loc_7 = load_i32_u8(memory_at_0, loc_0 + 32)
				loc_1 = 1
				store_i32_n8(memory_at_0, loc_0 + 32, 1)
				loc_12 = load_i32(memory_at_0, loc_0 + 20)
				loc_10 = load_i32(memory_at_0, loc_0 + 24)
				reg_0 = FUNC_LIST[228](loc_12, loc_10, loc_8, loc_2, loc_3)
				if reg_0 ~= 0 then
					desired = 1
					break
				end
				loc_1 = add_i32(sub_i32(loc_9, loc_6), 1)
				while true do
					while true do
						loc_1 = add_i32(loc_1, 4294967295)
						if loc_1 == 0 then
							desired = 3
							break
						end
						reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, loc_10 + 16)](loc_12, 48)
						if reg_0 == 0 then
							continue
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					reg_0 = 1
					desired = 0
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_1 = 1
				reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, loc_10 + 12)](loc_12, loc_4, loc_5)
				if reg_0 ~= 0 then
					desired = 1
					break
				end
				store_i32_n8(memory_at_0, loc_0 + 32, loc_7)
				store_i32(memory_at_0, loc_0 + 16, loc_11)
				loc_1 = 0
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_6 = sub_i32(loc_9, loc_6)
			while true do
				while true do
					while true do
						loc_1 = load_i32_u8(memory_at_0, loc_0 + 32)
						if not br_map[1] then
							br_map[1] = (function()
								return { [0] = 2, 0, 1, 0, }
							end)()
						end
						temp = br_map[1][loc_1] or 2
						if temp < 1 then
							break
						elseif temp > 1 then
							desired = 2
							break
						else
							desired = 3
							break
						end
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_1 = loc_6
					loc_6 = 0
					desired = 2
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_1 = shr_u32(loc_6, 1)
				loc_6 = shr_u32(add_i32(loc_6, 1), 1)
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_1 = add_i32(loc_1, 1)
			loc_12 = load_i32(memory_at_0, add_i32(loc_0, 24))
			loc_9 = load_i32(memory_at_0, loc_0 + 16)
			loc_10 = load_i32(memory_at_0, loc_0 + 20)
			while true do
				while true do
					loc_1 = add_i32(loc_1, 4294967295)
					if loc_1 == 0 then
						desired = 2
						break
					end
					reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, loc_12 + 16)](loc_10, loc_9)
					if reg_0 == 0 then
						continue
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				reg_0 = 1
				desired = 0
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_1 = 1
			reg_0 = FUNC_LIST[228](loc_10, loc_12, loc_8, loc_2, loc_3)
			if reg_0 ~= 0 then
				break
			end
			reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, loc_12 + 12)](loc_10, loc_4, loc_5)
			if reg_0 ~= 0 then
				break
			end
			loc_1 = 0
			while true do
				while true do
					if loc_6 ~= loc_1 then
						break
					end
					reg_0 = (if loc_6 < loc_6 then 1 else 0)
					desired = 0
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
						continue
					end
					break
				end
				loc_1 = add_i32(loc_1, 1)
				reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, loc_12 + 16)](loc_10, loc_9)
				if reg_0 == 0 then
					continue
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			reg_0 = (if add_i32(loc_1, 4294967295) < loc_6 then 1 else 0)
			desired = 0
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		reg_0 = loc_1
		break
	end
	return reg_0
end
FUNC_LIST[226] = --[[ _ZN4core3fmt5Write9write_fmt17h628ed859590e3c1bE ]] function(loc_0, loc_1)
	local reg_0
	while true do
		reg_0 = FUNC_LIST[195](loc_0, 1073452, loc_1)
		break
	end
	return reg_0
end
FUNC_LIST[227] = --[[ _ZN4core3str5count14do_count_chars17he917c17c44db8964E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = 0
	local loc_8 = 0
	local loc_9 = 0
	local reg_0
	local reg_1
	local reg_2
	local desired
	while true do
		while true do
			while true do
				loc_2 = band_i32(add_i32(loc_0, 3), 4294967292)
				loc_3 = sub_i32(loc_2, loc_0)
				if loc_1 < loc_3 then
					break
				end
				loc_4 = sub_i32(loc_1, loc_3)
				if loc_4 < 4 then
					break
				end
				loc_5 = band_i32(loc_4, 3)
				loc_6 = 0
				loc_1 = 0
				while true do
					loc_7 = (if loc_2 == loc_0 then 1 else 0)
					if loc_7 ~= 0 then
						break
					end
					loc_1 = 0
					while true do
						while true do
							if add_i32(loc_2, bxor_i32(loc_0, 4294967295)) >= 3 then
								break
							end
							loc_8 = 0
							desired = 4
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_8 = 0
						while true do
							loc_9 = add_i32(loc_0, loc_8)
							loc_1 = add_i32(add_i32(add_i32(add_i32(loc_1, (if gt_i32(load_i32_i8(memory_at_0, loc_9), 4294967231) then 1 else 0)), (if gt_i32(load_i32_i8(memory_at_0, add_i32(loc_9, 1)), 4294967231) then 1 else 0)), (if gt_i32(load_i32_i8(memory_at_0, add_i32(loc_9, 2)), 4294967231) then 1 else 0)), (if gt_i32(load_i32_i8(memory_at_0, add_i32(loc_9, 3)), 4294967231) then 1 else 0))
							loc_8 = add_i32(loc_8, 4)
							if loc_8 ~= 0 then
								continue
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					if loc_7 ~= 0 then
						break
					end
					loc_2 = sub_i32(loc_0, loc_2)
					loc_9 = add_i32(loc_0, loc_8)
					while true do
						loc_1 = add_i32(loc_1, (if gt_i32(load_i32_i8(memory_at_0, loc_9), 4294967231) then 1 else 0))
						loc_9 = add_i32(loc_9, 1)
						loc_2 = add_i32(loc_2, 1)
						if loc_2 ~= 0 then
							continue
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_8 = add_i32(loc_0, loc_3)
				while true do
					if loc_5 == 0 then
						break
					end
					loc_9 = add_i32(loc_8, band_i32(loc_4, 4294967292))
					loc_6 = (if gt_i32(load_i32_i8(memory_at_0, loc_9), 4294967231) then 1 else 0)
					if loc_5 == 1 then
						break
					end
					loc_6 = add_i32(loc_6, (if gt_i32(load_i32_i8(memory_at_0, loc_9 + 1), 4294967231) then 1 else 0))
					if loc_5 == 2 then
						break
					end
					loc_6 = add_i32(loc_6, (if gt_i32(load_i32_i8(memory_at_0, loc_9 + 2), 4294967231) then 1 else 0))
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_3 = shr_u32(loc_4, 2)
				loc_2 = add_i32(loc_6, loc_1)
				while true do
					loc_6 = loc_8
					if loc_3 == 0 then
						desired = 1
						break
					end
					loc_4 = (if loc_3 < 192 then loc_3 else 192)
					loc_7 = band_i32(loc_4, 3)
					loc_5 = shl_i32(loc_4, 2)
					loc_9 = 0
					while true do
						if loc_4 < 4 then
							break
						end
						loc_0 = add_i32(loc_6, band_i32(loc_5, 1008))
						loc_9 = 0
						loc_1 = loc_6
						while true do
							loc_8 = load_i32(memory_at_0, add_i32(loc_1, 12))
							reg_0 = band_i32(bor_i32(shr_u32(bxor_i32(loc_8, 4294967295), 7), shr_u32(loc_8, 6)), 16843009)
							loc_8 = load_i32(memory_at_0, add_i32(loc_1, 8))
							reg_1 = band_i32(bor_i32(shr_u32(bxor_i32(loc_8, 4294967295), 7), shr_u32(loc_8, 6)), 16843009)
							loc_8 = load_i32(memory_at_0, add_i32(loc_1, 4))
							reg_2 = band_i32(bor_i32(shr_u32(bxor_i32(loc_8, 4294967295), 7), shr_u32(loc_8, 6)), 16843009)
							loc_8 = load_i32(memory_at_0, loc_1)
							loc_9 = add_i32(reg_0, add_i32(reg_1, add_i32(reg_2, add_i32(band_i32(bor_i32(shr_u32(bxor_i32(loc_8, 4294967295), 7), shr_u32(loc_8, 6)), 16843009), loc_9))))
							loc_1 = add_i32(loc_1, 16)
							if loc_1 ~= loc_0 then
								continue
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
							continue
						end
						break
					end
					loc_3 = sub_i32(loc_3, loc_4)
					loc_8 = add_i32(loc_6, loc_5)
					loc_2 = add_i32(shr_u32(mul_i32(add_i32(band_i32(shr_u32(loc_9, 8), 16711935), band_i32(loc_9, 16711935)), 65537), 16), loc_2)
					if loc_7 == 0 then
						continue
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_9 = add_i32(loc_6, shl_i32(band_i32(loc_4, 252), 2))
				loc_1 = load_i32(memory_at_0, loc_9)
				loc_1 = band_i32(bor_i32(shr_u32(bxor_i32(loc_1, 4294967295), 7), shr_u32(loc_1, 6)), 16843009)
				while true do
					if loc_7 == 1 then
						break
					end
					loc_8 = load_i32(memory_at_0, loc_9 + 4)
					loc_1 = add_i32(band_i32(bor_i32(shr_u32(bxor_i32(loc_8, 4294967295), 7), shr_u32(loc_8, 6)), 16843009), loc_1)
					if loc_7 == 2 then
						break
					end
					loc_9 = load_i32(memory_at_0, loc_9 + 8)
					loc_1 = add_i32(band_i32(bor_i32(shr_u32(bxor_i32(loc_9, 4294967295), 7), shr_u32(loc_9, 6)), 16843009), loc_1)
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				reg_0 = add_i32(shr_u32(mul_i32(add_i32(band_i32(shr_u32(loc_1, 8), 459007), band_i32(loc_1, 16711935)), 65537), 16), loc_2)
				desired = 0
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				if loc_1 ~= 0 then
					break
				end
				reg_0 = 0
				desired = 0
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_8 = band_i32(loc_1, 3)
			while true do
				while true do
					if loc_1 >= 4 then
						break
					end
					loc_2 = 0
					loc_9 = 0
					desired = 2
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_3 = band_i32(loc_1, 4294967292)
				loc_2 = 0
				loc_9 = 0
				while true do
					loc_1 = add_i32(loc_0, loc_9)
					loc_2 = add_i32(add_i32(add_i32(add_i32(loc_2, (if gt_i32(load_i32_i8(memory_at_0, loc_1), 4294967231) then 1 else 0)), (if gt_i32(load_i32_i8(memory_at_0, add_i32(loc_1, 1)), 4294967231) then 1 else 0)), (if gt_i32(load_i32_i8(memory_at_0, add_i32(loc_1, 2)), 4294967231) then 1 else 0)), (if gt_i32(load_i32_i8(memory_at_0, add_i32(loc_1, 3)), 4294967231) then 1 else 0))
					loc_9 = add_i32(loc_9, 4)
					if loc_3 ~= loc_9 then
						continue
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			if loc_8 == 0 then
				break
			end
			loc_1 = add_i32(loc_0, loc_9)
			while true do
				loc_2 = add_i32(loc_2, (if gt_i32(load_i32_i8(memory_at_0, loc_1), 4294967231) then 1 else 0))
				loc_1 = add_i32(loc_1, 1)
				loc_8 = add_i32(loc_8, 4294967295)
				if loc_8 ~= 0 then
					continue
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		reg_0 = loc_2
		break
	end
	return reg_0
end
FUNC_LIST[228] = --[[ _ZN4core3fmt9Formatter12pad_integral12write_prefix17hc780479f059212a6E ]] function(loc_0, loc_1, loc_2, loc_3, loc_4)
	local loc_5 = 0
	local reg_0
	local desired
	while true do
		while true do
			while true do
				while true do
					if loc_2 == 1114112 then
						break
					end
					loc_5 = 1
					reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, loc_1 + 16)](loc_0, loc_2)
					if reg_0 ~= 0 then
						desired = 2
						break
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				if loc_3 ~= 0 then
					desired = 1
					break
				end
				loc_5 = 0
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			reg_0 = loc_5
			desired = 0
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, loc_1 + 12)](loc_0, loc_3, loc_4)
		break
	end
	return reg_0
end
FUNC_LIST[229] = --[[ _ZN4core3fmt9Formatter9write_str17h6a826a926e491a0aE ]] function(loc_0, loc_1, loc_2)
	local reg_0
	while true do
		reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, load_i32(memory_at_0, add_i32(loc_0, 24)) + 12)](load_i32(memory_at_0, loc_0 + 20), loc_1, loc_2)
		break
	end
	return reg_0
end
FUNC_LIST[230] = --[[ _ZN4core3fmt9Formatter12debug_struct17h51632fe39345e689E ]] function(loc_0, loc_1, loc_2, loc_3)
	local reg_0
	while true do
		reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, load_i32(memory_at_0, add_i32(loc_1, 24)) + 12)](load_i32(memory_at_0, loc_1 + 20), loc_2, loc_3)
		loc_3 = reg_0
		store_i32_n8(memory_at_0, loc_0 + 5, 0)
		store_i32_n8(memory_at_0, loc_0 + 4, loc_3)
		store_i32(memory_at_0, loc_0, loc_1)
		break
	end
end
FUNC_LIST[231] = --[[ _ZN4core3fmt9Formatter26debug_struct_field1_finish17hd490331c1d1c59f5E ]] function(loc_0, loc_1, loc_2, loc_3, loc_4, loc_5, loc_6)
	local loc_7 = 0
	local reg_0
	local desired
	while true do
		loc_7 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_7
		reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, load_i32(memory_at_0, add_i32(loc_0, 24)) + 12)](load_i32(memory_at_0, loc_0 + 20), loc_1, loc_2)
		loc_2 = reg_0
		store_i32_n8(memory_at_0, loc_7 + 13, 0)
		store_i32_n8(memory_at_0, loc_7 + 12, loc_2)
		store_i32(memory_at_0, loc_7 + 8, loc_0)
		reg_0 = FUNC_LIST[207](add_i32(loc_7, 8), loc_3, loc_4, loc_5, loc_6)
		loc_1 = reg_0
		loc_2 = load_i32_u8(memory_at_0, loc_7 + 12)
		while true do
			while true do
				if load_i32_u8(memory_at_0, loc_7 + 13) ~= 0 then
					break
				end
				loc_0 = (if band_i32(loc_2, 255) ~= 0 then 1 else 0)
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_0 = 1
			if band_i32(loc_2, 255) ~= 0 then
				break
			end
			while true do
				loc_0 = load_i32(memory_at_0, loc_1)
				if band_i32(load_i32_u8(memory_at_0, loc_0 + 28), 4) ~= 0 then
					break
				end
				reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, load_i32(memory_at_0, loc_0 + 24) + 12)](load_i32(memory_at_0, loc_0 + 20), 1073491, 2)
				loc_0 = reg_0
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, load_i32(memory_at_0, loc_0 + 24) + 12)](load_i32(memory_at_0, loc_0 + 20), 1073490, 1)
			loc_0 = reg_0
			break
		end
		GLOBAL_LIST[0].value = add_i32(loc_7, 16)
		reg_0 = loc_0
		break
	end
	return reg_0
end
FUNC_LIST[232] = --[[ _ZN4core3fmt9Formatter26debug_struct_field2_finish17h78895e4334def2f9E ]] function(loc_0, loc_1, loc_2, loc_3, loc_4, loc_5, loc_6, loc_7, loc_8, loc_9, loc_10)
	local loc_11 = 0
	local reg_0
	local desired
	while true do
		loc_11 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_11
		reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, load_i32(memory_at_0, add_i32(loc_0, 24)) + 12)](load_i32(memory_at_0, loc_0 + 20), loc_1, loc_2)
		loc_2 = reg_0
		store_i32_n8(memory_at_0, loc_11 + 13, 0)
		store_i32_n8(memory_at_0, loc_11 + 12, loc_2)
		store_i32(memory_at_0, loc_11 + 8, loc_0)
		reg_0 = FUNC_LIST[207](add_i32(loc_11, 8), loc_3, loc_4, loc_5, loc_6)
		reg_0 = FUNC_LIST[207](reg_0, loc_7, loc_8, loc_9, loc_10)
		loc_1 = reg_0
		loc_2 = load_i32_u8(memory_at_0, loc_11 + 12)
		while true do
			while true do
				if load_i32_u8(memory_at_0, loc_11 + 13) ~= 0 then
					break
				end
				loc_0 = (if band_i32(loc_2, 255) ~= 0 then 1 else 0)
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_0 = 1
			if band_i32(loc_2, 255) ~= 0 then
				break
			end
			while true do
				loc_0 = load_i32(memory_at_0, loc_1)
				if band_i32(load_i32_u8(memory_at_0, loc_0 + 28), 4) ~= 0 then
					break
				end
				reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, load_i32(memory_at_0, loc_0 + 24) + 12)](load_i32(memory_at_0, loc_0 + 20), 1073491, 2)
				loc_0 = reg_0
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, load_i32(memory_at_0, loc_0 + 24) + 12)](load_i32(memory_at_0, loc_0 + 20), 1073490, 1)
			loc_0 = reg_0
			break
		end
		GLOBAL_LIST[0].value = add_i32(loc_11, 16)
		reg_0 = loc_0
		break
	end
	return reg_0
end
FUNC_LIST[233] = --[[ _ZN4core3fmt9Formatter11debug_tuple17hcadb9b3a8ef81c7fE ]] function(loc_0, loc_1, loc_2, loc_3)
	local reg_0
	local reg_1
	while true do
		reg_1 = TABLE_LIST[0].data[load_i32(memory_at_0, load_i32(memory_at_0, add_i32(loc_1, 24)) + 12)](load_i32(memory_at_0, loc_1 + 20), loc_2, loc_3)
		store_i32_n8(memory_at_0, loc_0 + 8, reg_1)
		store_i32(memory_at_0, loc_0 + 4, loc_1)
		store_i32_n8(memory_at_0, loc_0 + 9, (if loc_3 == 0 then 1 else 0))
		store_i32(memory_at_0, loc_0, 0)
		break
	end
end
FUNC_LIST[234] = --[[ _ZN43_$LT$bool$u20$as$u20$core..fmt..Display$GT$3fmt17h78d4f4f96676b832E ]] function(loc_0, loc_1)
	local reg_0
	local desired
	while true do
		while true do
			if load_i32_u8(memory_at_0, loc_0) ~= 0 then
				break
			end
			reg_0 = FUNC_LIST[191](loc_1, 1073788, 5)
			desired = 0
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		reg_0 = FUNC_LIST[191](loc_1, 1073793, 4)
		break
	end
	return reg_0
end
FUNC_LIST[235] = --[[ _ZN40_$LT$str$u20$as$u20$core..fmt..Debug$GT$3fmt17h55e1c76288f8708dE ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = 0
	local loc_8 = 0
	local loc_9 = 0
	local loc_10 = 0
	local loc_11 = 0
	local loc_12 = 0
	local loc_13 = 0
	local loc_14 = 0
	local loc_15 = 0
	local loc_16 = i64_ZERO
	local loc_17 = 0
	local reg_0
	local desired
	while true do
		loc_3 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_3
		loc_4 = 1
		while true do
			while true do
				loc_5 = load_i32(memory_at_0, loc_2 + 20)
				loc_6 = load_i32(memory_at_0, add_i32(loc_2, 24))
				loc_7 = load_i32(memory_at_0, loc_6 + 16)
				reg_0 = TABLE_LIST[0].data[loc_7](loc_5, 34)
				if reg_0 ~= 0 then
					break
				end
				while true do
					while true do
						if loc_1 ~= 0 then
							break
						end
						loc_2 = 0
						loc_1 = 0
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_8 = add_i32(loc_0, loc_1)
					loc_2 = 0
					loc_9 = loc_0
					loc_10 = 0
					while true do
						while true do
							while true do
								while true do
									while true do
										loc_11 = loc_9
										loc_12 = load_i32_i8(memory_at_0, loc_11)
										if le_i32(loc_12, 4294967295) then
											break
										end
										loc_9 = add_i32(loc_11, 1)
										loc_13 = band_i32(loc_12, 255)
										desired = 7
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									loc_14 = band_i32(load_i32_u8(memory_at_0, loc_11 + 1), 63)
									loc_15 = band_i32(loc_12, 31)
									while true do
										if loc_12 > 4294967263 then
											break
										end
										loc_13 = bor_i32(shl_i32(loc_15, 6), loc_14)
										loc_9 = add_i32(loc_11, 2)
										desired = 7
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									loc_14 = bor_i32(shl_i32(loc_14, 6), band_i32(load_i32_u8(memory_at_0, loc_11 + 2), 63))
									loc_9 = add_i32(loc_11, 3)
									while true do
										if loc_12 >= 4294967280 then
											break
										end
										loc_13 = bor_i32(loc_14, shl_i32(loc_15, 12))
										desired = 7
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									loc_13 = bor_i32(bor_i32(shl_i32(loc_14, 6), band_i32(load_i32_u8(memory_at_0, loc_9), 63)), band_i32(shl_i32(loc_15, 18), 1835008))
									if loc_13 == 1114112 then
										desired = 4
										break
									end
									loc_9 = add_i32(loc_11, 4)
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
										continue
									end
									break
								end
								FUNC_LIST[203](add_i32(loc_3, 4), loc_13, 65537)
								while true do
									while true do
										if load_i32_u8(memory_at_0, loc_3 + 4) == 128 then
											break
										end
										if band_i32(sub_i32(load_i32_u8(memory_at_0, loc_3 + 15), load_i32_u8(memory_at_0, loc_3 + 14)), 255) == 1 then
											break
										end
										if loc_10 < loc_2 then
											desired = 5
											break
										end
										while true do
											if loc_2 == 0 then
												break
											end
											while true do
												if loc_2 < loc_1 then
													break
												end
												if loc_2 == loc_1 then
													desired = 9
													break
												end
												desired = 5
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											if lt_i32(load_i32_i8(memory_at_0, add_i32(loc_0, loc_2)), 4294967232) then
												desired = 5
												break
											end
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										while true do
											if loc_10 == 0 then
												break
											end
											while true do
												if loc_10 < loc_1 then
													break
												end
												if loc_10 == loc_1 then
													desired = 9
													break
												end
												desired = 5
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											if le_i32(load_i32_i8(memory_at_0, add_i32(loc_0, loc_10)), 4294967231) then
												desired = 5
												break
											end
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										while true do
											while true do
												reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, loc_6 + 12)](loc_5, add_i32(loc_0, loc_2), sub_i32(loc_10, loc_2))
												if reg_0 ~= 0 then
													break
												end
												loc_15 = add_i32(add_i32(loc_3, 16), 8)
												store_i32(memory_at_0, loc_15, load_i32(memory_at_0, add_i32(add_i32(loc_3, 4), 8)))
												loc_16 = load_i64(memory_at_0, loc_3 + 4)
												store_i64(memory_at_0, loc_3 + 16, loc_16)
												while true do
													if band_i32(wrap_i32_i64(loc_16), 255) ~= 128 then
														break
													end
													loc_14 = 128
													while true do
														while true do
															while true do
																if band_i32(loc_14, 255) == 128 then
																	break
																end
																loc_12 = load_i32_u8(memory_at_0, loc_3 + 26)
																if loc_12 >= load_i32_u8(memory_at_0, loc_3 + 27) then
																	desired = 9
																	break
																end
																store_i32_n8(memory_at_0, loc_3 + 26, add_i32(loc_12, 1))
																if loc_12 >= 10 then
																	desired = 7
																	break
																end
																loc_2 = load_i32_u8(memory_at_0, add_i32(add_i32(loc_3, 16), loc_12))
																desired = 13
																break
															end
															if desired then
																if desired == 13 then
																	desired = nil
																end
																break
															end
															loc_14 = 0
															store_i32(memory_at_0, loc_15, 0)
															loc_2 = load_i32(memory_at_0, loc_3 + 20)
															store_i64(memory_at_0, loc_3 + 16, i64_ZERO)
															break
														end
														if desired then
															if desired == 12 then
																desired = nil
																continue
															end
															break
														end
														reg_0 = TABLE_LIST[0].data[loc_7](loc_5, loc_2)
														if reg_0 == 0 then
															continue
														end
														desired = 10
														break
													end
													if desired then
														if desired == 11 then
															desired = nil
														end
														break
													end
													break
												end
												if desired then
													if desired == 10 then
														desired = nil
													end
													break
												end
												loc_2 = load_i32_u8(memory_at_0, loc_3 + 26)
												loc_12 = (if loc_2 > 10 then loc_2 else 10)
												loc_14 = load_i32_u8(memory_at_0, loc_3 + 27)
												loc_17 = (if loc_14 > loc_2 then loc_14 else loc_2)
												while true do
													if loc_17 == loc_2 then
														desired = 9
														break
													end
													loc_14 = add_i32(loc_2, 1)
													store_i32_n8(memory_at_0, loc_3 + 26, loc_14)
													if loc_12 == loc_2 then
														desired = 7
														break
													end
													loc_15 = add_i32(add_i32(loc_3, 16), loc_2)
													loc_2 = loc_14
													reg_0 = TABLE_LIST[0].data[loc_7](loc_5, load_i32_u8(memory_at_0, loc_15))
													if reg_0 == 0 then
														continue
													end
													break
												end
												if desired then
													if desired == 10 then
														desired = nil
													end
													break
												end
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											loc_4 = 1
											desired = 2
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										loc_2 = 1
										while true do
											if loc_13 < 128 then
												break
											end
											loc_2 = 2
											if loc_13 < 2048 then
												break
											end
											loc_2 = (if loc_13 < 65536 then 3 else 4)
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										loc_2 = add_i32(loc_2, loc_10)
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									loc_10 = add_i32(sub_i32(loc_10, loc_11), loc_9)
									if loc_9 ~= loc_8 then
										desired = 6
										break
									end
									desired = 4
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
										continue
									end
									break
								end
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							FUNC_LIST[189](loc_12, 10, 1076156)
							error("out of code bounds")
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						FUNC_LIST[236](loc_0, loc_1, loc_2, loc_10, 1073816)
						error("out of code bounds")
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					while true do
						if loc_2 ~= 0 then
							break
						end
						loc_2 = 0
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					while true do
						while true do
							if loc_1 > loc_2 then
								break
							end
							if loc_1 == loc_2 then
								desired = 4
								break
							end
							desired = 1
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						if le_i32(load_i32_i8(memory_at_0, add_i32(loc_0, loc_2)), 4294967231) then
							desired = 1
							break
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_1 = sub_i32(loc_1, loc_2)
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, loc_6 + 12)](loc_5, add_i32(loc_0, loc_2), loc_1)
				if reg_0 ~= 0 then
					break
				end
				reg_0 = TABLE_LIST[0].data[loc_7](loc_5, 34)
				loc_4 = reg_0
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			GLOBAL_LIST[0].value = add_i32(loc_3, 32)
			reg_0 = loc_4
			desired = 0
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		FUNC_LIST[236](loc_0, loc_1, loc_2, loc_1, 1073800)
		error("out of code bounds")
	end
	return reg_0
end
FUNC_LIST[236] = --[[ _ZN4core3str16slice_error_fail17h37edf3bde95d9b91E ]] function(loc_0, loc_1, loc_2, loc_3, loc_4)
	while true do
		FUNC_LIST[242](loc_0, loc_1, loc_2, loc_3, loc_4)
		error("out of code bounds")
	end
end
FUNC_LIST[237] = --[[ _ZN42_$LT$str$u20$as$u20$core..fmt..Display$GT$3fmt17h0ae80be026d6a0bcE ]] function(loc_0, loc_1, loc_2)
	local reg_0
	while true do
		reg_0 = FUNC_LIST[191](loc_2, loc_0, loc_1)
		break
	end
	return reg_0
end
FUNC_LIST[238] = --[[ _ZN41_$LT$char$u20$as$u20$core..fmt..Debug$GT$3fmt17h8b6abe23f140dc8bE ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = 0
	local loc_8 = 0
	local reg_0
	local desired
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_2
		loc_3 = 1
		while true do
			while true do
				loc_4 = load_i32(memory_at_0, loc_1 + 20)
				loc_5 = load_i32(memory_at_0, load_i32(memory_at_0, add_i32(loc_1, 24)) + 16)
				reg_0 = TABLE_LIST[0].data[loc_5](loc_4, 39)
				if reg_0 ~= 0 then
					break
				end
				FUNC_LIST[203](loc_2, load_i32(memory_at_0, loc_0), 257)
				while true do
					while true do
						if load_i32_u8(memory_at_0, loc_2) ~= 128 then
							break
						end
						loc_6 = add_i32(loc_2, 8)
						loc_7 = 128
						while true do
							while true do
								while true do
									if band_i32(loc_7, 255) == 128 then
										break
									end
									loc_0 = load_i32_u8(memory_at_0, loc_2 + 10)
									if loc_0 >= load_i32_u8(memory_at_0, loc_2 + 11) then
										desired = 3
										break
									end
									store_i32_n8(memory_at_0, loc_2 + 10, add_i32(loc_0, 1))
									if loc_0 >= 10 then
										desired = 1
										break
									end
									loc_1 = load_i32_u8(memory_at_0, add_i32(loc_2, loc_0))
									desired = 6
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								loc_7 = 0
								store_i32(memory_at_0, loc_6, 0)
								loc_1 = load_i32(memory_at_0, loc_2 + 4)
								store_i64(memory_at_0, loc_2, i64_ZERO)
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
									continue
								end
								break
							end
							reg_0 = TABLE_LIST[0].data[loc_5](loc_4, loc_1)
							if reg_0 == 0 then
								continue
							end
							desired = 2
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_1 = load_i32_u8(memory_at_0, loc_2 + 10)
					loc_0 = (if loc_1 > 10 then loc_1 else 10)
					loc_7 = load_i32_u8(memory_at_0, loc_2 + 11)
					loc_8 = (if loc_7 > loc_1 then loc_7 else loc_1)
					while true do
						if loc_8 == loc_1 then
							desired = 3
							break
						end
						loc_7 = add_i32(loc_1, 1)
						store_i32_n8(memory_at_0, loc_2 + 10, loc_7)
						if loc_0 == loc_1 then
							desired = 1
							break
						end
						loc_6 = add_i32(loc_2, loc_1)
						loc_1 = loc_7
						reg_0 = TABLE_LIST[0].data[loc_5](loc_4, load_i32_u8(memory_at_0, loc_6))
						if reg_0 == 0 then
							continue
						end
						desired = 2
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				reg_0 = TABLE_LIST[0].data[loc_5](loc_4, 39)
				loc_3 = reg_0
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			GLOBAL_LIST[0].value = add_i32(loc_2, 16)
			reg_0 = loc_3
			desired = 0
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		FUNC_LIST[189](loc_0, 10, 1076156)
		error("out of code bounds")
	end
	return reg_0
end
FUNC_LIST[239] = --[[ _ZN43_$LT$char$u20$as$u20$core..fmt..Display$GT$3fmt17h3c047ee9a4159b29E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local reg_0
	local desired
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_2
		loc_0 = load_i32(memory_at_0, loc_0)
		while true do
			while true do
				if bor_i32(load_i32(memory_at_0, loc_1), load_i32(memory_at_0, loc_1 + 8)) == 0 then
					break
				end
				store_i32(memory_at_0, loc_2 + 12, 0)
				while true do
					while true do
						while true do
							while true do
								if loc_0 < 128 then
									break
								end
								if loc_0 < 2048 then
									desired = 5
									break
								end
								if loc_0 >= 65536 then
									desired = 4
									break
								end
								store_i32_n8(memory_at_0, loc_2 + 14, bor_i32(band_i32(loc_0, 63), 128))
								store_i32_n8(memory_at_0, loc_2 + 12, bor_i32(shr_u32(loc_0, 12), 224))
								store_i32_n8(memory_at_0, loc_2 + 13, bor_i32(band_i32(shr_u32(loc_0, 6), 63), 128))
								loc_0 = 3
								desired = 3
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							store_i32_n8(memory_at_0, loc_2 + 12, loc_0)
							loc_0 = 1
							desired = 3
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						store_i32_n8(memory_at_0, loc_2 + 13, bor_i32(band_i32(loc_0, 63), 128))
						store_i32_n8(memory_at_0, loc_2 + 12, bor_i32(shr_u32(loc_0, 6), 192))
						loc_0 = 2
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32_n8(memory_at_0, loc_2 + 15, bor_i32(band_i32(loc_0, 63), 128))
					store_i32_n8(memory_at_0, loc_2 + 12, bor_i32(shr_u32(loc_0, 18), 240))
					store_i32_n8(memory_at_0, loc_2 + 14, bor_i32(band_i32(shr_u32(loc_0, 6), 63), 128))
					store_i32_n8(memory_at_0, loc_2 + 13, bor_i32(band_i32(shr_u32(loc_0, 12), 63), 128))
					loc_0 = 4
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				reg_0 = FUNC_LIST[191](loc_1, add_i32(loc_2, 12), loc_0)
				loc_1 = reg_0
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			reg_0 = TABLE_LIST[0].data[load_i32(memory_at_0, load_i32(memory_at_0, add_i32(loc_1, 24)) + 16)](load_i32(memory_at_0, loc_1 + 20), loc_0)
			loc_1 = reg_0
			break
		end
		GLOBAL_LIST[0].value = add_i32(loc_2, 16)
		reg_0 = loc_1
		break
	end
	return reg_0
end
FUNC_LIST[240] = --[[ _ZN4core5slice6memchr14memchr_aligned17h0fc402833aaf246bE ]] function(loc_0, loc_1, loc_2, loc_3)
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = 0
	local loc_8 = 0
	local desired
	while true do
		while true do
			while true do
				while true do
					while true do
						loc_4 = band_i32(add_i32(loc_2, 3), 4294967292)
						if loc_4 == loc_2 then
							break
						end
						loc_4 = sub_i32(loc_4, loc_2)
						loc_4 = (if loc_4 < loc_3 then loc_4 else loc_3)
						if loc_4 == 0 then
							break
						end
						loc_5 = 0
						loc_6 = band_i32(loc_1, 255)
						loc_7 = 1
						while true do
							if load_i32_u8(memory_at_0, add_i32(loc_2, loc_5)) == loc_6 then
								desired = 1
								break
							end
							loc_5 = add_i32(loc_5, 1)
							if loc_4 ~= loc_5 then
								continue
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_8 = add_i32(loc_3, 4294967288)
						if loc_4 > loc_8 then
							desired = 2
							break
						end
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_8 = add_i32(loc_3, 4294967288)
					loc_4 = 0
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_5 = mul_i32(band_i32(loc_1, 255), 16843009)
				while true do
					loc_6 = add_i32(loc_2, loc_4)
					loc_7 = bxor_i32(load_i32(memory_at_0, add_i32(loc_6, 4)), loc_5)
					loc_6 = bxor_i32(load_i32(memory_at_0, loc_6), loc_5)
					if band_i32(bor_i32(band_i32(add_i32(loc_7, 4278124287), bxor_i32(loc_7, 4294967295)), band_i32(add_i32(loc_6, 4278124287), bxor_i32(loc_6, 4294967295))), 2155905152) ~= 0 then
						desired = 2
						break
					end
					loc_4 = add_i32(loc_4, 8)
					if loc_4 <= loc_8 then
						continue
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_7 = 0
			while true do
				if loc_4 == loc_3 then
					break
				end
				loc_5 = band_i32(loc_1, 255)
				while true do
					while true do
						if load_i32_u8(memory_at_0, add_i32(loc_2, loc_4)) ~= loc_5 then
							break
						end
						loc_5 = loc_4
						loc_7 = 1
						desired = 1
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
							continue
						end
						break
					end
					loc_4 = add_i32(loc_4, 1)
					if loc_3 ~= loc_4 then
						continue
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_5 = loc_3
			break
		end
		store_i32(memory_at_0, loc_0 + 4, loc_5)
		store_i32(memory_at_0, loc_0, loc_7)
		break
	end
end
FUNC_LIST[241] = --[[ _ZN4core5slice5index29slice_end_index_overflow_fail17heca2f6d605df0f60E ]] function(loc_0)
	local loc_1 = 0
	while true do
		loc_1 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_1
		store_i64(memory_at_0, add_i32(loc_1, 20), i64_ZERO)
		store_i32(memory_at_0, loc_1 + 12, 1)
		store_i32(memory_at_0, loc_1 + 8, 1074028)
		store_i32(memory_at_0, loc_1 + 16, 1072984)
		FUNC_LIST[187](add_i32(loc_1, 8), loc_0)
		error("out of code bounds")
	end
end
FUNC_LIST[242] = --[[ _ZN4core3str19slice_error_fail_rt17h91bee75a4bf13f5aE ]] function(loc_0, loc_1, loc_2, loc_3, loc_4)
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = 0
	local loc_8 = 0
	local loc_9 = 0
	local desired
	while true do
		loc_5 = sub_i32(GLOBAL_LIST[0].value, 112)
		GLOBAL_LIST[0].value = loc_5
		store_i32(memory_at_0, loc_5 + 12, loc_3)
		store_i32(memory_at_0, loc_5 + 8, loc_2)
		while true do
			while true do
				while true do
					if loc_1 < 257 then
						break
					end
					loc_6 = 256
					while true do
						if gt_i32(load_i32_i8(memory_at_0, loc_0 + 256), 4294967231) then
							break
						end
						loc_6 = 255
						if gt_i32(load_i32_i8(memory_at_0, loc_0 + 255), 4294967231) then
							break
						end
						loc_6 = 254
						if gt_i32(load_i32_i8(memory_at_0, loc_0 + 254), 4294967231) then
							break
						end
						loc_6 = 253
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					while true do
						while true do
							loc_7 = (if loc_6 < loc_1 then 1 else 0)
							if loc_7 ~= 0 then
								break
							end
							if loc_6 == loc_1 then
								desired = 4
								break
							end
							desired = 1
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						if le_i32(load_i32_i8(memory_at_0, add_i32(loc_0, loc_6)), 4294967231) then
							desired = 1
							break
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i32(memory_at_0, loc_5 + 16, loc_0)
					store_i32(memory_at_0, loc_5 + 20, loc_6)
					loc_6 = (if loc_7 ~= 0 then 5 else 0)
					loc_7 = (if loc_7 ~= 0 then 1074292 else 1072984)
					desired = 2
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				store_i32(memory_at_0, loc_5 + 20, loc_1)
				store_i32(memory_at_0, loc_5 + 16, loc_0)
				loc_6 = 0
				loc_7 = 1072984
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			store_i32(memory_at_0, loc_5 + 28, loc_6)
			store_i32(memory_at_0, loc_5 + 24, loc_7)
			while true do
				while true do
					while true do
						while true do
							while true do
								loc_6 = (if loc_2 > loc_1 then 1 else 0)
								if loc_6 ~= 0 then
									break
								end
								if loc_3 > loc_1 then
									break
								end
								if loc_2 > loc_3 then
									desired = 5
									break
								end
								while true do
									while true do
										if loc_2 == 0 then
											break
										end
										if loc_2 >= loc_1 then
											break
										end
										if lt_i32(load_i32_i8(memory_at_0, add_i32(loc_0, loc_2)), 4294967232) then
											desired = 7
											break
										end
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									loc_2 = loc_3
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								store_i32(memory_at_0, loc_5 + 32, loc_2)
								loc_3 = loc_1
								while true do
									if loc_2 >= loc_1 then
										break
									end
									loc_3 = add_i32(loc_2, 4294967293)
									loc_3 = (if loc_3 > loc_2 then 0 else loc_3)
									loc_6 = add_i32(loc_2, 1)
									if loc_3 > loc_6 then
										desired = 4
										break
									end
									while true do
										if loc_3 == loc_6 then
											break
										end
										loc_8 = add_i32(loc_0, loc_3)
										loc_6 = sub_i32(add_i32(loc_0, loc_6), loc_8)
										while true do
											loc_9 = add_i32(loc_0, loc_2)
											if le_i32(load_i32_i8(memory_at_0, loc_9), 4294967231) then
												break
											end
											loc_7 = add_i32(loc_6, 4294967295)
											desired = 8
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										if loc_3 == loc_2 then
											break
										end
										while true do
											loc_2 = add_i32(loc_9, 4294967295)
											if le_i32(load_i32_i8(memory_at_0, loc_2), 4294967231) then
												break
											end
											loc_7 = add_i32(loc_6, 4294967294)
											desired = 8
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										if loc_8 == loc_2 then
											break
										end
										while true do
											loc_2 = add_i32(loc_9, 4294967294)
											if le_i32(load_i32_i8(memory_at_0, loc_2), 4294967231) then
												break
											end
											loc_7 = add_i32(loc_6, 4294967293)
											desired = 8
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										if loc_8 == loc_2 then
											break
										end
										while true do
											loc_2 = add_i32(loc_9, 4294967293)
											if le_i32(load_i32_i8(memory_at_0, loc_2), 4294967231) then
												break
											end
											loc_7 = add_i32(loc_6, 4294967292)
											desired = 8
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										if loc_8 == loc_2 then
											break
										end
										loc_7 = add_i32(loc_6, 4294967291)
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									loc_3 = add_i32(loc_7, loc_3)
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								while true do
									if loc_3 == 0 then
										break
									end
									while true do
										while true do
											if loc_1 > loc_3 then
												break
											end
											if loc_1 == loc_3 then
												desired = 8
												break
											end
											desired = 2
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										if le_i32(load_i32_i8(memory_at_0, add_i32(loc_0, loc_3)), 4294967231) then
											desired = 2
											break
										end
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									loc_1 = sub_i32(loc_1, loc_3)
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								if loc_1 == 0 then
									desired = 3
									break
								end
								while true do
									while true do
										while true do
											while true do
												loc_2 = add_i32(loc_0, loc_3)
												loc_1 = load_i32_i8(memory_at_0, loc_2)
												if gt_i32(loc_1, 4294967295) then
													break
												end
												loc_0 = band_i32(load_i32_u8(memory_at_0, loc_2 + 1), 63)
												loc_6 = band_i32(loc_1, 31)
												if loc_1 > 4294967263 then
													desired = 9
													break
												end
												loc_2 = bor_i32(shl_i32(loc_6, 6), loc_0)
												desired = 8
												break
											end
											if desired then
												if desired == 9 then
													desired = nil
												end
												break
											end
											store_i32(memory_at_0, loc_5 + 36, band_i32(loc_1, 255))
											loc_1 = 1
											desired = 7
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										loc_0 = bor_i32(shl_i32(loc_0, 6), band_i32(load_i32_u8(memory_at_0, loc_2 + 2), 63))
										while true do
											if loc_1 >= 4294967280 then
												break
											end
											loc_2 = bor_i32(loc_0, shl_i32(loc_6, 12))
											desired = 8
											break
										end
										if desired then
											if desired == 8 then
												desired = nil
											end
											break
										end
										loc_2 = bor_i32(bor_i32(shl_i32(loc_0, 6), band_i32(load_i32_u8(memory_at_0, loc_2 + 3), 63)), band_i32(shl_i32(loc_6, 18), 1835008))
										if loc_2 == 1114112 then
											desired = 3
											break
										end
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									store_i32(memory_at_0, loc_5 + 36, loc_2)
									loc_1 = 1
									if loc_2 < 128 then
										break
									end
									loc_1 = 2
									if loc_2 < 2048 then
										break
									end
									loc_1 = (if loc_2 < 65536 then 3 else 4)
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								store_i32(memory_at_0, loc_5 + 40, loc_3)
								store_i32(memory_at_0, loc_5 + 44, add_i32(loc_1, loc_3))
								store_i64(memory_at_0, add_i32(add_i32(loc_5, 48), 12), i64_from_u32(5, 0))
								store_i32(memory_at_0, add_i32(loc_5, 108), 81)
								store_i32(memory_at_0, add_i32(loc_5, 100), 81)
								store_i32(memory_at_0, add_i32(loc_5, 92), 83)
								store_i32(memory_at_0, add_i32(add_i32(loc_5, 72), 12), 84)
								store_i32(memory_at_0, loc_5 + 52, 5)
								store_i32(memory_at_0, loc_5 + 48, 1074428)
								store_i32(memory_at_0, loc_5 + 76, 18)
								store_i32(memory_at_0, loc_5 + 56, add_i32(loc_5, 72))
								store_i32(memory_at_0, loc_5 + 104, add_i32(loc_5, 24))
								store_i32(memory_at_0, loc_5 + 96, add_i32(loc_5, 16))
								store_i32(memory_at_0, loc_5 + 88, add_i32(loc_5, 40))
								store_i32(memory_at_0, loc_5 + 80, add_i32(loc_5, 36))
								store_i32(memory_at_0, loc_5 + 72, add_i32(loc_5, 32))
								FUNC_LIST[187](add_i32(loc_5, 48), loc_4)
								error("out of code bounds")
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							store_i32(memory_at_0, loc_5 + 40, (if loc_6 ~= 0 then loc_2 else loc_3))
							store_i64(memory_at_0, add_i32(add_i32(loc_5, 48), 12), i64_from_u32(3, 0))
							store_i32(memory_at_0, add_i32(loc_5, 92), 81)
							store_i32(memory_at_0, add_i32(add_i32(loc_5, 72), 12), 81)
							store_i32(memory_at_0, loc_5 + 52, 3)
							store_i32(memory_at_0, loc_5 + 48, 1074492)
							store_i32(memory_at_0, loc_5 + 76, 18)
							store_i32(memory_at_0, loc_5 + 56, add_i32(loc_5, 72))
							store_i32(memory_at_0, loc_5 + 88, add_i32(loc_5, 24))
							store_i32(memory_at_0, loc_5 + 80, add_i32(loc_5, 16))
							store_i32(memory_at_0, loc_5 + 72, add_i32(loc_5, 40))
							FUNC_LIST[187](add_i32(loc_5, 48), loc_4)
							error("out of code bounds")
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						store_i32(memory_at_0, add_i32(loc_5, 100), 81)
						store_i32(memory_at_0, add_i32(loc_5, 92), 81)
						store_i32(memory_at_0, add_i32(add_i32(loc_5, 72), 12), 18)
						store_i64(memory_at_0, add_i32(add_i32(loc_5, 48), 12), i64_from_u32(4, 0))
						store_i32(memory_at_0, loc_5 + 52, 4)
						store_i32(memory_at_0, loc_5 + 48, 1074332)
						store_i32(memory_at_0, loc_5 + 76, 18)
						store_i32(memory_at_0, loc_5 + 56, add_i32(loc_5, 72))
						store_i32(memory_at_0, loc_5 + 96, add_i32(loc_5, 24))
						store_i32(memory_at_0, loc_5 + 88, add_i32(loc_5, 16))
						store_i32(memory_at_0, loc_5 + 80, add_i32(loc_5, 12))
						store_i32(memory_at_0, loc_5 + 72, add_i32(loc_5, 8))
						FUNC_LIST[187](add_i32(loc_5, 48), loc_4)
						error("out of code bounds")
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					FUNC_LIST[198](loc_3, loc_6, 1074544)
					error("out of code bounds")
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				FUNC_LIST[192](1073011, 43, loc_4)
				error("out of code bounds")
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[236](loc_0, loc_1, loc_3, loc_1, loc_4)
			error("out of code bounds")
		end
		FUNC_LIST[236](loc_0, loc_1, 0, loc_6, loc_4)
		error("out of code bounds")
	end
end
FUNC_LIST[243] = --[[ _ZN4core3fmt3num3imp52_$LT$impl$u20$core..fmt..Display$u20$for$u20$u64$GT$3fmt17h957f2a89a5045a65E ]] function(loc_0, loc_1)
	local reg_0
	while true do
		reg_0 = FUNC_LIST[248](load_i64(memory_at_0, loc_0), 1, loc_1)
		break
	end
	return reg_0
end
FUNC_LIST[244] = --[[ _ZN4core7unicode9printable5check17hee828726bd182ff7E ]] function(loc_0, loc_1, loc_2, loc_3, loc_4, loc_5, loc_6)
	local loc_7 = 0
	local loc_8 = 0
	local loc_9 = 0
	local loc_10 = 0
	local loc_11 = 0
	local loc_12 = 0
	local loc_13 = 0
	local reg_0
	local desired
	while true do
		loc_7 = 1
		while true do
			while true do
				if loc_2 == 0 then
					break
				end
				loc_8 = add_i32(loc_1, shl_i32(loc_2, 1))
				loc_9 = shr_u32(band_i32(loc_0, 65280), 8)
				loc_10 = 0
				loc_11 = band_i32(loc_0, 255)
				while true do
					loc_12 = add_i32(loc_1, 2)
					loc_2 = load_i32_u8(memory_at_0, loc_1 + 1)
					loc_13 = add_i32(loc_10, loc_2)
					while true do
						loc_1 = load_i32_u8(memory_at_0, loc_1)
						if loc_1 == loc_9 then
							break
						end
						if loc_1 > loc_9 then
							desired = 2
							break
						end
						loc_10 = loc_13
						loc_1 = loc_12
						if loc_12 == loc_8 then
							desired = 2
							break
						end
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
							continue
						end
						break
					end
					while true do
						while true do
							while true do
								if loc_10 > loc_13 then
									break
								end
								if loc_13 > loc_4 then
									desired = 5
									break
								end
								loc_1 = add_i32(loc_3, loc_10)
								while true do
									if loc_2 == 0 then
										desired = 4
										break
									end
									loc_2 = add_i32(loc_2, 4294967295)
									loc_10 = load_i32_u8(memory_at_0, loc_1)
									loc_1 = add_i32(loc_1, 1)
									if loc_10 ~= loc_11 then
										continue
									end
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								loc_7 = 0
								desired = 1
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							FUNC_LIST[198](loc_10, loc_13, 1074616)
							error("out of code bounds")
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						FUNC_LIST[190](loc_13, loc_4, 1074616)
						error("out of code bounds")
					end
					if desired then
						if desired == 3 then
							desired = nil
							continue
						end
						break
					end
					loc_10 = loc_13
					loc_1 = loc_12
					if loc_12 ~= loc_8 then
						continue
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			if loc_6 == 0 then
				break
			end
			loc_11 = add_i32(loc_5, loc_6)
			loc_1 = band_i32(loc_0, 65535)
			loc_7 = 1
			while true do
				loc_10 = add_i32(loc_5, 1)
				while true do
					while true do
						loc_2 = load_i32_u8(memory_at_0, loc_5)
						loc_13 = extend_i32_n8(loc_2)
						if lt_i32(loc_13, 0) then
							break
						end
						loc_5 = loc_10
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					while true do
						if loc_10 == loc_11 then
							break
						end
						loc_2 = bor_i32(shl_i32(band_i32(loc_13, 127), 8), load_i32_u8(memory_at_0, loc_5 + 1))
						loc_5 = add_i32(loc_5, 2)
						desired = 3
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					FUNC_LIST[192](1073011, 43, 1074600)
					error("out of code bounds")
				end
				if desired then
					if desired == 2 then
						desired = nil
						continue
					end
					break
				end
				loc_1 = sub_i32(loc_1, loc_2)
				if lt_i32(loc_1, 0) then
					desired = 1
					break
				end
				loc_7 = bxor_i32(loc_7, 1)
				if loc_5 ~= loc_11 then
					continue
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			break
		end
		reg_0 = band_i32(loc_7, 1)
		break
	end
	return reg_0
end
FUNC_LIST[245] = --[[ _ZN4core3num60_$LT$impl$u20$core..str..traits..FromStr$u20$for$u20$u16$GT$8from_str17hbe220728a7b10959E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local reg_0
	local desired
	local br_map = {}
	while true do
		while true do
			if loc_1 ~= 0 then
				break
			end
			reg_0 = bor_i32(0, 1)
			desired = 0
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		while true do
			while true do
				while true do
					while true do
						if not br_map[1] then
							br_map[1] = (function()
								return { [0] = 0, 2, 1, }
							end)()
						end
						temp = br_map[1][add_i32(load_i32_u8(memory_at_0, loc_0), 4294967253)] or 2
						if temp < 1 then
							break
						elseif temp > 1 then
							desired = 2
							break
						else
							desired = 3
							break
						end
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					while true do
						loc_1 = add_i32(loc_1, 4294967295)
						if loc_1 ~= 0 then
							break
						end
						reg_0 = bor_i32(256, 1)
						desired = 0
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_0 = add_i32(loc_0, 1)
					desired = 2
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_2 = 1
				loc_3 = 256
				if loc_1 == 1 then
					desired = 1
					break
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				while true do
					while true do
						if loc_1 < 5 then
							break
						end
						loc_2 = 0
						while true do
							if loc_1 == 0 then
								desired = 3
								break
							end
							loc_3 = add_i32(load_i32_u8(memory_at_0, loc_0), 4294967248)
							if loc_3 > 9 then
								desired = 2
								break
							end
							loc_2 = mul_i32(band_i32(loc_2, 65535), 10)
							if shr_u32(loc_2, 16) ~= 0 then
								desired = 2
								break
							end
							loc_1 = add_i32(loc_1, 4294967295)
							loc_0 = add_i32(loc_0, 1)
							loc_2 = add_i32(band_i32(loc_2, 65535), band_i32(loc_3, 65535))
							if band_i32(loc_2, 65535) == loc_2 then
								continue
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						reg_0 = bor_i32(512, 1)
						desired = 0
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_2 = 0
					while true do
						while true do
							loc_3 = add_i32(load_i32_u8(memory_at_0, loc_0), 4294967248)
							if loc_3 <= 9 then
								break
							end
							reg_0 = bor_i32(256, 1)
							desired = 0
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
								continue
							end
							break
						end
						loc_0 = add_i32(loc_0, 1)
						loc_2 = add_i32(mul_i32(loc_2, 10), loc_3)
						loc_1 = add_i32(loc_1, 4294967295)
						if loc_1 ~= 0 then
							continue
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				reg_0 = bor_i32(shl_i32(loc_2, 16), 0)
				desired = 0
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_3 = (if loc_3 > 9 then 256 else 512)
			loc_2 = 1
			break
		end
		if desired then
			if desired == 0 then
				desired = nil
			end
			break
		end
		reg_0 = bor_i32(loc_3, loc_2)
		break
	end
	return reg_0
end
FUNC_LIST[246] = --[[ _ZN4core3num60_$LT$impl$u20$core..str..traits..FromStr$u20$for$u20$u64$GT$8from_str17hef66b1b2f572a7bfE ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	local loc_4 = i64_ZERO
	local loc_5 = 0
	local loc_6 = i64_ZERO
	local desired
	local br_map = {}
	while true do
		loc_3 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_3
		while true do
			while true do
				if loc_2 ~= 0 then
					break
				end
				store_i32_n8(memory_at_0, loc_0 + 1, 0)
				loc_1 = 1
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				while true do
					while true do
						while true do
							while true do
								if not br_map[1] then
									br_map[1] = (function()
										return { [0] = 0, 2, 1, }
									end)()
								end
								temp = br_map[1][add_i32(load_i32_u8(memory_at_0, loc_1), 4294967253)] or 2
								if temp < 1 then
									break
								elseif temp > 1 then
									desired = 4
									break
								else
									desired = 5
									break
								end
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_2 = add_i32(loc_2, 4294967295)
							if loc_2 == 0 then
								desired = 3
								break
							end
							loc_1 = add_i32(loc_1, 1)
							desired = 4
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						if loc_2 == 1 then
							desired = 3
							break
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					while true do
						while true do
							if loc_2 < 17 then
								break
							end
							loc_4 = i64_ZERO
							while true do
								if loc_2 == 0 then
									desired = 4
									break
								end
								FUNC_LIST[258](loc_3, loc_4, i64_ZERO, i64_from_u32(10, 0), i64_ZERO)
								loc_5 = add_i32(load_i32_u8(memory_at_0, loc_1), 4294967248)
								if loc_5 > 9 then
									desired = 3
									break
								end
								if ne_i64(load_i64(memory_at_0, loc_3 + 8), i64_ZERO) then
									desired = 2
									break
								end
								loc_1 = add_i32(loc_1, 1)
								loc_2 = add_i32(loc_2, 4294967295)
								loc_6 = load_i64(memory_at_0, loc_3)
								loc_4 = add_i64(loc_6, extend_i64_u32(loc_5))
								if ge_u64(loc_4, loc_6) then
									continue
								end
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							store_i32_n8(memory_at_0, loc_0 + 1, 2)
							loc_1 = 1
							desired = 1
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_4 = i64_ZERO
						while true do
							loc_5 = add_i32(load_i32_u8(memory_at_0, loc_1), 4294967248)
							if loc_5 > 9 then
								desired = 3
								break
							end
							loc_1 = add_i32(loc_1, 1)
							loc_4 = add_i64(mul_i64(loc_4, i64_from_u32(10, 0)), extend_i64_u32(loc_5))
							loc_2 = add_i32(loc_2, 4294967295)
							if loc_2 ~= 0 then
								continue
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i64(memory_at_0, loc_0 + 8, loc_4)
					loc_1 = 0
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_1 = 1
				store_i32_n8(memory_at_0, loc_0 + 1, 1)
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			store_i32_n8(memory_at_0, loc_0 + 1, 2)
			loc_1 = 1
			break
		end
		store_i32_n8(memory_at_0, loc_0, loc_1)
		GLOBAL_LIST[0].value = add_i32(loc_3, 16)
		break
	end
end
FUNC_LIST[247] = --[[ _ZN4core3num61_$LT$impl$u20$core..str..traits..FromStr$u20$for$u20$u128$GT$8from_str17h910c994f74d22bcdE ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = i64_ZERO
	local loc_6 = i64_ZERO
	local loc_7 = 0
	local loc_8 = i64_ZERO
	local loc_9 = i64_ZERO
	local desired
	local br_map = {}
	while true do
		loc_3 = sub_i32(GLOBAL_LIST[0].value, 48)
		GLOBAL_LIST[0].value = loc_3
		while true do
			while true do
				if loc_2 ~= 0 then
					break
				end
				store_i32_n8(memory_at_0, loc_0 + 1, 0)
				loc_1 = 1
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			while true do
				while true do
					while true do
						while true do
							while true do
								if not br_map[1] then
									br_map[1] = (function()
										return { [0] = 0, 2, 1, }
									end)()
								end
								temp = br_map[1][add_i32(load_i32_u8(memory_at_0, loc_1), 4294967253)] or 2
								if temp < 1 then
									break
								elseif temp > 1 then
									desired = 4
									break
								else
									desired = 5
									break
								end
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_2 = add_i32(loc_2, 4294967295)
							if loc_2 == 0 then
								desired = 3
								break
							end
							loc_1 = add_i32(loc_1, 1)
							desired = 4
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						if loc_2 == 1 then
							desired = 3
							break
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					while true do
						while true do
							if loc_2 < 33 then
								break
							end
							loc_4 = add_i32(loc_3, 40)
							loc_5 = i64_ZERO
							loc_6 = i64_ZERO
							while true do
								if loc_2 == 0 then
									desired = 4
									break
								end
								FUNC_LIST[258](add_i32(loc_3, 16), loc_6, i64_ZERO, i64_from_u32(10, 0), i64_ZERO)
								FUNC_LIST[258](add_i32(loc_3, 32), loc_5, i64_ZERO, i64_from_u32(10, 0), i64_ZERO)
								loc_7 = add_i32(load_i32_u8(memory_at_0, loc_1), 4294967248)
								if loc_7 > 9 then
									desired = 3
									break
								end
								loc_5 = load_i64(memory_at_0, loc_4)
								loc_8 = add_i64(loc_5, load_i64(memory_at_0, loc_3 + 16))
								if bor_i32((if ne_i64(load_i64(memory_at_0, loc_3 + 24), i64_ZERO) then 1 else 0), (if lt_u64(loc_8, loc_5) then 1 else 0)) ~= 0 then
									desired = 2
									break
								end
								loc_1 = add_i32(loc_1, 1)
								loc_2 = add_i32(loc_2, 4294967295)
								loc_9 = load_i64(memory_at_0, loc_3 + 32)
								loc_5 = add_i64(loc_9, extend_i64_u32(loc_7))
								loc_7 = (if lt_u64(loc_5, loc_9) then 1 else 0)
								loc_6 = add_i64(loc_8, extend_i64_u32(loc_7))
								if (if ge_u64(loc_5, loc_9) then loc_7 else (if lt_u64(loc_6, loc_8) then 1 else 0)) == 0 then
									continue
								end
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							store_i32_n8(memory_at_0, loc_0 + 1, 2)
							loc_1 = 1
							desired = 1
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_4 = add_i32(loc_3, 8)
						loc_5 = i64_ZERO
						loc_6 = i64_ZERO
						while true do
							loc_7 = add_i32(load_i32_u8(memory_at_0, loc_1), 4294967248)
							if loc_7 > 9 then
								desired = 3
								break
							end
							FUNC_LIST[258](loc_3, loc_5, loc_6, i64_from_u32(10, 0), i64_ZERO)
							loc_1 = add_i32(loc_1, 1)
							loc_6 = load_i64(memory_at_0, loc_3)
							loc_5 = add_i64(loc_6, extend_i64_u32(loc_7))
							loc_6 = add_i64(load_i64(memory_at_0, loc_4), extend_i64_u32((if lt_u64(loc_5, loc_6) then 1 else 0)))
							loc_2 = add_i32(loc_2, 4294967295)
							if loc_2 ~= 0 then
								continue
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					store_i64(memory_at_0, loc_0 + 8, loc_5)
					store_i64(memory_at_0, add_i32(loc_0, 16), loc_6)
					loc_1 = 0
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_1 = 1
				store_i32_n8(memory_at_0, loc_0 + 1, 1)
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			store_i32_n8(memory_at_0, loc_0 + 1, 2)
			loc_1 = 1
			break
		end
		store_i32_n8(memory_at_0, loc_0, loc_1)
		GLOBAL_LIST[0].value = add_i32(loc_3, 48)
		break
	end
end
FUNC_LIST[248] = --[[ _ZN4core3fmt3num3imp7fmt_u6417hdd2278ea871a5fc5E ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = i64_ZERO
	local loc_6 = 0
	local loc_7 = 0
	local loc_8 = 0
	local reg_0
	local reg_1
	local desired
	while true do
		loc_3 = sub_i32(GLOBAL_LIST[0].value, 48)
		GLOBAL_LIST[0].value = loc_3
		loc_4 = 39
		while true do
			while true do
				if ge_u64(loc_0, i64_from_u32(10000, 0)) then
					break
				end
				loc_5 = loc_0
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_4 = 39
			while true do
				loc_6 = add_i32(add_i32(loc_3, 9), loc_4)
				loc_5 = div_u64(loc_0, i64_from_u32(10000, 0))
				loc_7 = wrap_i32_i64(sub_i64(loc_0, mul_i64(loc_5, i64_from_u32(10000, 0))))
				loc_8 = div_u32(band_i32(loc_7, 65535), 100)
				store_i32_n16(memory_at_0, add_i32(loc_6, 4294967292), load_i32_u16(memory_at_0, add_i32(shl_i32(loc_8, 1), 1073542)))
				store_i32_n16(memory_at_0, add_i32(loc_6, 4294967294), load_i32_u16(memory_at_0, add_i32(shl_i32(band_i32(sub_i32(loc_7, mul_i32(loc_8, 100)), 65535), 1), 1073542)))
				loc_4 = add_i32(loc_4, 4294967292)
				loc_6 = (if gt_u64(loc_0, i64_from_u32(99999999, 0)) then 1 else 0)
				loc_0 = loc_5
				if loc_6 ~= 0 then
					continue
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			break
		end
		while true do
			loc_6 = wrap_i32_i64(loc_5)
			if loc_6 <= 99 then
				break
			end
			loc_4 = add_i32(loc_4, 4294967294)
			loc_6 = wrap_i32_i64(loc_5)
			reg_1 = loc_6
			loc_6 = div_u32(band_i32(loc_6, 65535), 100)
			store_i32_n16(memory_at_0, add_i32(add_i32(loc_3, 9), loc_4), load_i32_u16(memory_at_0, add_i32(shl_i32(band_i32(sub_i32(reg_1, mul_i32(loc_6, 100)), 65535), 1), 1073542)))
			break
		end
		while true do
			while true do
				if loc_6 < 10 then
					break
				end
				loc_4 = add_i32(loc_4, 4294967294)
				store_i32_n16(memory_at_0, add_i32(add_i32(loc_3, 9), loc_4), load_i32_u16(memory_at_0, add_i32(shl_i32(loc_6, 1), 1073542)))
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_4 = add_i32(loc_4, 4294967295)
			store_i32_n8(memory_at_0, add_i32(add_i32(loc_3, 9), loc_4), add_i32(loc_6, 48))
			break
		end
		reg_0 = FUNC_LIST[225](loc_2, loc_1, 1072984, 0, add_i32(add_i32(loc_3, 9), loc_4), sub_i32(39, loc_4))
		loc_4 = reg_0
		GLOBAL_LIST[0].value = add_i32(loc_3, 48)
		reg_0 = loc_4
		break
	end
	return reg_0
end
FUNC_LIST[249] = --[[ _ZN4core3fmt3num53_$LT$impl$u20$core..fmt..UpperHex$u20$for$u20$i32$GT$3fmt17h4222c50385ef17f6E ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = 0
	local loc_4 = 0
	local reg_0
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 128)
		GLOBAL_LIST[0].value = loc_2
		loc_0 = load_i32(memory_at_0, loc_0)
		loc_3 = 0
		while true do
			loc_4 = band_i32(loc_0, 15)
			store_i32_n8(memory_at_0, add_i32(add_i32(loc_2, loc_3), 127), add_i32((if loc_4 < 10 then 48 else 55), loc_4))
			loc_3 = add_i32(loc_3, 4294967295)
			loc_4 = (if loc_0 < 16 then 1 else 0)
			loc_0 = shr_u32(loc_0, 4)
			if loc_4 == 0 then
				continue
			end
			break
		end
		while true do
			loc_0 = add_i32(loc_3, 128)
			if loc_0 <= 128 then
				break
			end
			FUNC_LIST[188](loc_0, 128, 1073524)
			error("out of code bounds")
		end
		reg_0 = FUNC_LIST[225](loc_1, 1, 1073540, 2, add_i32(add_i32(loc_2, loc_3), 128), sub_i32(0, loc_3))
		loc_0 = reg_0
		GLOBAL_LIST[0].value = add_i32(loc_2, 128)
		reg_0 = loc_0
		break
	end
	return reg_0
end
FUNC_LIST[250] = --[[ _ZN4core3fmt3num3imp51_$LT$impl$u20$core..fmt..Display$u20$for$u20$i8$GT$3fmt17h6fce024967a011a2E ]] function(loc_0, loc_1)
	local reg_0
	local reg_1
	while true do
		loc_0 = load_i32_i8(memory_at_0, loc_0)
		reg_0 = band_i64(extend_i64_u32(loc_0), i64_from_u32(255, 0))
		reg_1 = add_i64(extend_i64_i32(bxor_i32(loc_0, 4294967295)), i64_ONE)
		loc_0 = (if gt_i32(loc_0, 4294967295) then 1 else 0)
		reg_0 = FUNC_LIST[248]((if loc_0 ~= 0 then reg_0 else reg_1), loc_0, loc_1)
		break
	end
	return reg_0
end
FUNC_LIST[251] = --[[ _ZN4core3fmt3num3imp52_$LT$impl$u20$core..fmt..Display$u20$for$u20$i32$GT$3fmt17h8680fb77cf49ea37E ]] function(loc_0, loc_1)
	local reg_0
	local reg_1
	while true do
		loc_0 = load_i32(memory_at_0, loc_0)
		reg_0 = extend_i64_u32(loc_0)
		reg_1 = add_i64(extend_i64_i32(bxor_i32(loc_0, 4294967295)), i64_ONE)
		loc_0 = (if gt_i32(loc_0, 4294967295) then 1 else 0)
		reg_0 = FUNC_LIST[248]((if loc_0 ~= 0 then reg_0 else reg_1), loc_0, loc_1)
		break
	end
	return reg_0
end
FUNC_LIST[252] = --[[ __fixunsdfti ]] function(loc_0, loc_1)
	local loc_2 = 0
	local loc_3 = i64_ZERO
	local loc_4 = i64_ZERO
	local loc_5 = i64_ZERO
	local desired
	while true do
		loc_2 = sub_i32(GLOBAL_LIST[0].value, 16)
		GLOBAL_LIST[0].value = loc_2
		loc_3 = i64_ZERO
		loc_4 = i64_ZERO
		while true do
			loc_5 = reinterpret_i64_f64(loc_1)
			if lt_u64(loc_5, i64_from_u32(0, 1072693248)) then
				break
			end
			while true do
				if lt_u64(loc_5, i64_from_u32(0, 1206910976)) then
					break
				end
				loc_3 = (if lt_u64(loc_5, i64_from_u32(1, 2146435072)) then i64_from_u32(4294967295, 4294967295) else i64_ZERO)
				loc_4 = loc_3
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			FUNC_LIST[256](loc_2, i64_ZERO, bor_i64(shl_i64(loc_5, i64_from_u32(11, 0)), i64_from_u32(0, 2147483648)), band_i32(sub_i32(126, wrap_i32_i64(shr_u64(loc_5, i64_from_u32(52, 0)))), 127))
			loc_4 = load_i64(memory_at_0, add_i32(loc_2, 8))
			loc_3 = load_i64(memory_at_0, loc_2)
			break
		end
		store_i64(memory_at_0, loc_0, loc_3)
		store_i64(memory_at_0, loc_0 + 8, loc_4)
		GLOBAL_LIST[0].value = add_i32(loc_2, 16)
		break
	end
end
FUNC_LIST[253] = --[[ _ZN17compiler_builtins3mem6memcpy17h07584e13d26e228bE ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local loc_6 = 0
	local loc_7 = 0
	local loc_8 = 0
	local loc_9 = 0
	local loc_10 = 0
	local reg_0
	local reg_1
	local desired
	while true do
		while true do
			while true do
				if loc_2 >= 16 then
					break
				end
				loc_3 = loc_0
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_4 = band_i32(sub_i32(0, loc_0), 3)
			loc_5 = add_i32(loc_0, loc_4)
			while true do
				if loc_4 == 0 then
					break
				end
				loc_3 = loc_0
				loc_6 = loc_1
				while true do
					store_i32_n8(memory_at_0, loc_3, load_i32_u8(memory_at_0, loc_6))
					loc_6 = add_i32(loc_6, 1)
					loc_3 = add_i32(loc_3, 1)
					if loc_3 < loc_5 then
						continue
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_7 = sub_i32(loc_2, loc_4)
			loc_8 = band_i32(loc_7, 4294967292)
			loc_3 = add_i32(loc_5, loc_8)
			while true do
				while true do
					loc_9 = add_i32(loc_1, loc_4)
					if band_i32(loc_9, 3) == 0 then
						break
					end
					if lt_i32(loc_8, 1) then
						desired = 2
						break
					end
					loc_6 = shl_i32(loc_9, 3)
					loc_2 = band_i32(loc_6, 24)
					loc_10 = band_i32(loc_9, 4294967292)
					loc_1 = add_i32(loc_10, 4)
					loc_4 = band_i32(sub_i32(0, loc_6), 24)
					loc_6 = load_i32(memory_at_0, loc_10)
					while true do
						reg_1 = shr_u32(loc_6, loc_2)
						loc_6 = load_i32(memory_at_0, loc_1)
						store_i32(memory_at_0, loc_5, bor_i32(reg_1, shl_i32(loc_6, loc_4)))
						loc_1 = add_i32(loc_1, 4)
						loc_5 = add_i32(loc_5, 4)
						if loc_5 < loc_3 then
							continue
						end
						desired = 2
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				if lt_i32(loc_8, 1) then
					break
				end
				loc_1 = loc_9
				while true do
					store_i32(memory_at_0, loc_5, load_i32(memory_at_0, loc_1))
					loc_1 = add_i32(loc_1, 4)
					loc_5 = add_i32(loc_5, 4)
					if loc_5 < loc_3 then
						continue
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_2 = band_i32(loc_7, 3)
			loc_1 = add_i32(loc_9, loc_8)
			break
		end
		while true do
			if loc_2 == 0 then
				break
			end
			loc_5 = add_i32(loc_3, loc_2)
			while true do
				store_i32_n8(memory_at_0, loc_3, load_i32_u8(memory_at_0, loc_1))
				loc_1 = add_i32(loc_1, 1)
				loc_3 = add_i32(loc_3, 1)
				if loc_3 < loc_5 then
					continue
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			break
		end
		reg_0 = loc_0
		break
	end
	return reg_0
end
FUNC_LIST[254] = --[[ _ZN17compiler_builtins3mem6memset17hd49c44cbd0862c04E ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local reg_0
	local desired
	while true do
		while true do
			while true do
				if loc_2 >= 16 then
					break
				end
				loc_3 = loc_0
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_4 = band_i32(sub_i32(0, loc_0), 3)
			loc_5 = add_i32(loc_0, loc_4)
			while true do
				if loc_4 == 0 then
					break
				end
				loc_3 = loc_0
				while true do
					store_i32_n8(memory_at_0, loc_3, loc_1)
					loc_3 = add_i32(loc_3, 1)
					if loc_3 < loc_5 then
						continue
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_4 = sub_i32(loc_2, loc_4)
			loc_2 = band_i32(loc_4, 4294967292)
			loc_3 = add_i32(loc_5, loc_2)
			while true do
				if lt_i32(loc_2, 1) then
					break
				end
				loc_2 = mul_i32(band_i32(loc_1, 255), 16843009)
				while true do
					store_i32(memory_at_0, loc_5, loc_2)
					loc_5 = add_i32(loc_5, 4)
					if loc_5 < loc_3 then
						continue
					end
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_2 = band_i32(loc_4, 3)
			break
		end
		while true do
			if loc_2 == 0 then
				break
			end
			loc_5 = add_i32(loc_3, loc_2)
			while true do
				store_i32_n8(memory_at_0, loc_3, loc_1)
				loc_3 = add_i32(loc_3, 1)
				if loc_3 < loc_5 then
					continue
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			break
		end
		reg_0 = loc_0
		break
	end
	return reg_0
end
FUNC_LIST[255] = --[[ _ZN17compiler_builtins3mem6memcmp17h34c54face2c41858E ]] function(loc_0, loc_1, loc_2)
	local loc_3 = 0
	local loc_4 = 0
	local loc_5 = 0
	local reg_0
	local desired
	while true do
		loc_3 = 0
		while true do
			if loc_2 == 0 then
				break
			end
			while true do
				while true do
					loc_4 = load_i32_u8(memory_at_0, loc_0)
					loc_5 = load_i32_u8(memory_at_0, loc_1)
					if loc_4 ~= loc_5 then
						desired = 2
						break
					end
					loc_0 = add_i32(loc_0, 1)
					loc_1 = add_i32(loc_1, 1)
					loc_2 = add_i32(loc_2, 4294967295)
					if loc_2 == 0 then
						desired = 1
						break
					end
					continue
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_3 = sub_i32(loc_4, loc_5)
			break
		end
		reg_0 = loc_3
		break
	end
	return reg_0
end
FUNC_LIST[256] = --[[ __lshrti3 ]] function(loc_0, loc_1, loc_2, loc_3)
	local loc_4 = i64_ZERO
	local desired
	while true do
		while true do
			while true do
				if band_i32(loc_3, 64) ~= 0 then
					break
				end
				if loc_3 == 0 then
					desired = 1
					break
				end
				loc_4 = extend_i64_u32(band_i32(loc_3, 63))
				loc_1 = bor_i64(shl_i64(loc_2, extend_i64_u32(band_i32(sub_i32(0, loc_3), 63))), shr_u64(loc_1, loc_4))
				loc_2 = shr_u64(loc_2, loc_4)
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_1 = shr_u64(loc_2, extend_i64_u32(band_i32(loc_3, 63)))
			loc_2 = i64_ZERO
			break
		end
		store_i64(memory_at_0, loc_0, loc_1)
		store_i64(memory_at_0, loc_0 + 8, loc_2)
		break
	end
end
FUNC_LIST[257] = --[[ _ZN17compiler_builtins3int19specialized_div_rem12u128_div_rem17hf4fd937a212fc2bfE ]] function(loc_0, loc_1, loc_2, loc_3, loc_4)
	local loc_5 = 0
	local loc_6 = i64_ZERO
	local loc_7 = 0
	local loc_8 = i64_ZERO
	local loc_9 = i64_ZERO
	local loc_10 = i64_ZERO
	local loc_11 = i64_ZERO
	local loc_12 = i64_ZERO
	local loc_13 = 0
	local reg_0
	local desired
	while true do
		loc_5 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_5
		while true do
			while true do
				while true do
					while true do
						while true do
							if eq_i64(loc_3, i64_ZERO) then
								break
							end
							if eq_i64(loc_4, i64_ZERO) then
								desired = 4
								break
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_6 = i64_ZERO
						if (if eq_i64(loc_2, loc_4) then (if lt_u64(loc_1, loc_3) then 1 else 0) else (if lt_u64(loc_2, loc_4) then 1 else 0)) ~= 0 then
							desired = 3
							break
						end
						if eq_i64(loc_2, i64_ZERO) then
							desired = 3
							break
						end
						loc_7 = sub_i32(wrap_i32_i64(clz_i64(loc_4)), wrap_i32_i64(clz_i64(loc_2)))
						FUNC_LIST[263](add_i32(loc_5, 16), loc_3, loc_4, band_i32(loc_7, 127))
						loc_8 = shl_i64(i64_ONE, extend_i64_u32(band_i32(loc_7, 63)))
						loc_9 = load_i64(memory_at_0, add_i32(loc_5, 24))
						loc_10 = load_i64(memory_at_0, loc_5 + 16)
						loc_6 = i64_ZERO
						while true do
							while true do
								loc_11 = sub_i64(sub_i64(loc_2, loc_9), extend_i64_u32((if lt_u64(loc_1, loc_10) then 1 else 0)))
								if lt_i64(loc_11, i64_ZERO) then
									break
								end
								loc_6 = bor_i64(loc_8, loc_6)
								loc_1 = sub_i64(loc_1, loc_10)
								if (if eq_i64(loc_11, loc_4) then (if lt_u64(loc_1, loc_3) then 1 else 0) else (if lt_u64(loc_11, loc_4) then 1 else 0)) ~= 0 then
									desired = 2
									break
								end
								loc_2 = loc_11
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
									continue
								end
								break
							end
							loc_10 = bor_i64(shr_u64(loc_10, i64_ONE), shl_i64(loc_9, i64_from_u32(63, 0)))
							loc_8 = shr_u64(loc_8, i64_ONE)
							loc_9 = shr_u64(loc_9, i64_ONE)
							continue
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					while true do
						while true do
							while true do
								while true do
									while true do
										if eq_i64(loc_2, i64_ZERO) then
											break
										end
										if lt_u64(loc_2, loc_3) then
											desired = 5
											break
										end
										if eq_i64(loc_2, loc_3) then
											desired = 7
											break
										end
										loc_12 = div_u64(loc_2, loc_3)
										loc_11 = sub_i64(loc_2, mul_i64(loc_12, loc_3))
										if ge_u64(loc_3, i64_from_u32(0, 1)) then
											desired = 6
											break
										end
										loc_9 = bor_i64(shl_i64(loc_11, i64_from_u32(32, 0)), shr_u64(loc_1, i64_from_u32(32, 0)))
										reg_0 = loc_9
										loc_9 = div_u64(loc_9, loc_3)
										loc_1 = bor_i64(shl_i64(sub_i64(reg_0, mul_i64(loc_9, loc_3)), i64_from_u32(32, 0)), band_i64(loc_1, i64_from_u32(4294967295, 0)))
										loc_10 = div_u64(loc_1, loc_3)
										loc_1 = sub_i64(loc_1, mul_i64(loc_10, loc_3))
										loc_6 = bor_i64(shl_i64(loc_9, i64_from_u32(32, 0)), loc_10)
										loc_12 = bor_i64(shr_u64(loc_9, i64_from_u32(32, 0)), loc_12)
										loc_11 = i64_ZERO
										desired = 1
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
										end
										break
									end
									loc_6 = div_u64(loc_1, loc_3)
									loc_1 = sub_i64(loc_1, mul_i64(loc_6, loc_3))
									loc_11 = i64_ZERO
									desired = 2
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								loc_6 = div_u64(loc_1, loc_2)
								loc_1 = sub_i64(loc_1, mul_i64(loc_6, loc_2))
								loc_11 = i64_ZERO
								loc_12 = i64_ONE
								desired = 1
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							if (if eq_i64(loc_11, loc_4) then (if lt_u64(loc_1, loc_3) then 1 else 0) else (if lt_u64(loc_11, loc_4) then 1 else 0)) ~= 0 then
								desired = 4
								break
							end
							loc_9 = bor_i64(shl_i64(loc_4, i64_from_u32(63, 0)), shr_u64(loc_3, i64_ONE))
							loc_10 = shl_i64(loc_3, i64_from_u32(63, 0))
							loc_2 = i64_from_u32(0, 2147483648)
							loc_4 = i64_ZERO
							while true do
								while true do
									while true do
										loc_8 = sub_i64(sub_i64(loc_11, loc_9), extend_i64_u32((if lt_u64(loc_1, loc_10) then 1 else 0)))
										if lt_i64(loc_8, i64_ZERO) then
											break
										end
										loc_1 = sub_i64(loc_1, loc_10)
										loc_4 = bor_i64(loc_2, loc_4)
										if eq_i64(loc_8, i64_ZERO) then
											desired = 6
											break
										end
										loc_11 = loc_8
										break
									end
									if desired then
										if desired == 7 then
											desired = nil
											continue
										end
										break
									end
									loc_10 = bor_i64(shr_u64(loc_10, i64_ONE), shl_i64(loc_9, i64_from_u32(63, 0)))
									loc_2 = shr_u64(loc_2, i64_ONE)
									loc_9 = shr_u64(loc_9, i64_ONE)
									continue
								end
								if desired then
									if desired == 6 then
										desired = nil
									end
									break
								end
								break
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							loc_9 = div_u64(loc_1, loc_3)
							loc_6 = bor_i64(loc_9, loc_4)
							loc_1 = sub_i64(loc_1, mul_i64(loc_9, loc_3))
							loc_11 = i64_ZERO
							desired = 1
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_7 = wrap_i32_i64(clz_i64(loc_3))
						loc_13 = wrap_i32_i64(clz_i64(loc_2))
						loc_7 = (if loc_7 == loc_13 then 63 else add_i32(sub_i32(loc_7, loc_13), 64))
						FUNC_LIST[263](loc_5, loc_3, loc_4, loc_7)
						loc_11 = shl_i64(i64_ONE, extend_i64_u32(band_i32(loc_7, 63)))
						loc_9 = load_i64(memory_at_0, add_i32(loc_5, 8))
						loc_10 = load_i64(memory_at_0, loc_5)
						loc_4 = i64_ZERO
						while true do
							while true do
								while true do
									loc_8 = sub_i64(sub_i64(loc_2, loc_9), extend_i64_u32((if lt_u64(loc_1, loc_10) then 1 else 0)))
									if lt_i64(loc_8, i64_ZERO) then
										break
									end
									loc_1 = sub_i64(loc_1, loc_10)
									loc_4 = bor_i64(loc_11, loc_4)
									if eq_i64(loc_8, i64_ZERO) then
										desired = 5
										break
									end
									loc_2 = loc_8
									break
								end
								if desired then
									if desired == 6 then
										desired = nil
										continue
									end
									break
								end
								loc_10 = bor_i64(shr_u64(loc_10, i64_ONE), shl_i64(loc_9, i64_from_u32(63, 0)))
								loc_11 = shr_u64(loc_11, i64_ONE)
								loc_9 = shr_u64(loc_9, i64_ONE)
								continue
							end
							if desired then
								if desired == 5 then
									desired = nil
								end
								break
							end
							break
						end
						if desired then
							if desired == 4 then
								desired = nil
							end
							break
						end
						loc_9 = div_u64(loc_1, loc_3)
						loc_6 = bor_i64(loc_9, loc_4)
						loc_1 = sub_i64(loc_1, mul_i64(loc_9, loc_3))
						loc_11 = i64_ZERO
						desired = 2
						break
					end
					if desired then
						if desired == 3 then
							desired = nil
						end
						break
					end
					loc_6 = i64_ZERO
					desired = 1
					break
				end
				if desired then
					if desired == 2 then
						desired = nil
					end
					break
				end
				loc_11 = loc_2
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_12 = i64_ZERO
			break
		end
		store_i64(memory_at_0, loc_0 + 16, loc_1)
		store_i64(memory_at_0, loc_0, loc_6)
		store_i64(memory_at_0, add_i32(loc_0, 24), loc_11)
		store_i64(memory_at_0, loc_0 + 8, loc_12)
		GLOBAL_LIST[0].value = add_i32(loc_5, 32)
		break
	end
end
FUNC_LIST[258] = --[[ __multi3 ]] function(loc_0, loc_1, loc_2, loc_3, loc_4)
	local loc_5 = i64_ZERO
	local loc_6 = i64_ZERO
	local loc_7 = i64_ZERO
	local loc_8 = i64_ZERO
	local loc_9 = i64_ZERO
	local loc_10 = i64_ZERO
	while true do
		loc_5 = band_i64(loc_3, i64_from_u32(4294967295, 0))
		loc_6 = band_i64(loc_1, i64_from_u32(4294967295, 0))
		loc_7 = mul_i64(loc_5, loc_6)
		loc_8 = shr_u64(loc_3, i64_from_u32(32, 0))
		loc_6 = mul_i64(loc_8, loc_6)
		loc_9 = shr_u64(loc_1, i64_from_u32(32, 0))
		loc_5 = add_i64(loc_6, mul_i64(loc_5, loc_9))
		loc_10 = add_i64(loc_7, shl_i64(loc_5, i64_from_u32(32, 0)))
		store_i64(memory_at_0, loc_0, loc_10)
		store_i64(memory_at_0, loc_0 + 8, add_i64(add_i64(add_i64(mul_i64(loc_8, loc_9), bor_i64(shl_i64(extend_i64_u32((if lt_u64(loc_5, loc_6) then 1 else 0)), i64_from_u32(32, 0)), shr_u64(loc_5, i64_from_u32(32, 0)))), extend_i64_u32((if lt_u64(loc_10, loc_7) then 1 else 0))), add_i64(mul_i64(loc_4, loc_1), mul_i64(loc_3, loc_2))))
		break
	end
end
FUNC_LIST[259] = --[[ memset ]] function(loc_0, loc_1, loc_2)
	local reg_0
	while true do
		reg_0 = FUNC_LIST[254](loc_0, loc_1, loc_2)
		break
	end
	return reg_0
end
FUNC_LIST[260] = --[[ memcmp ]] function(loc_0, loc_1, loc_2)
	local reg_0
	while true do
		reg_0 = FUNC_LIST[255](loc_0, loc_1, loc_2)
		break
	end
	return reg_0
end
FUNC_LIST[261] = --[[ __udivti3 ]] function(loc_0, loc_1, loc_2, loc_3, loc_4)
	local loc_5 = 0
	while true do
		loc_5 = sub_i32(GLOBAL_LIST[0].value, 32)
		GLOBAL_LIST[0].value = loc_5
		FUNC_LIST[257](loc_5, loc_1, loc_2, loc_3, loc_4)
		loc_4 = load_i64(memory_at_0, loc_5)
		store_i64(memory_at_0, loc_0 + 8, load_i64(memory_at_0, add_i32(loc_5, 8)))
		store_i64(memory_at_0, loc_0, loc_4)
		GLOBAL_LIST[0].value = add_i32(loc_5, 32)
		break
	end
end
FUNC_LIST[262] = --[[ memcpy ]] function(loc_0, loc_1, loc_2)
	local reg_0
	while true do
		reg_0 = FUNC_LIST[253](loc_0, loc_1, loc_2)
		break
	end
	return reg_0
end
FUNC_LIST[263] = --[[ __ashlti3 ]] function(loc_0, loc_1, loc_2, loc_3)
	local loc_4 = i64_ZERO
	local desired
	while true do
		while true do
			while true do
				if band_i32(loc_3, 64) ~= 0 then
					break
				end
				if loc_3 == 0 then
					desired = 1
					break
				end
				loc_4 = extend_i64_u32(band_i32(loc_3, 63))
				loc_2 = bor_i64(shl_i64(loc_2, loc_4), shr_u64(loc_1, extend_i64_u32(band_i32(sub_i32(0, loc_3), 63))))
				loc_1 = shl_i64(loc_1, loc_4)
				desired = 1
				break
			end
			if desired then
				if desired == 1 then
					desired = nil
				end
				break
			end
			loc_2 = shl_i64(loc_1, extend_i64_u32(band_i32(loc_3, 63)))
			loc_1 = i64_ZERO
			break
		end
		store_i64(memory_at_0, loc_0, loc_1)
		store_i64(memory_at_0, loc_0 + 8, loc_2)
		break
	end
end
local function run_init_code()
	TABLE_LIST[0] = { min = 91, max = 91, data = {} }
	MEMORY_LIST[0] = rt.allocator.new(17, 65535)
	GLOBAL_LIST[0] = { value = 1048576 }
	GLOBAL_LIST[1] = { value = 1085257 }
	GLOBAL_LIST[2] = { value = 1085264 }
	do
		local target = TABLE_LIST[0].data
		local offset = 1
		local data = { FUNC_LIST[5],FUNC_LIST[12],FUNC_LIST[7],FUNC_LIST[4],FUNC_LIST[3],FUNC_LIST[14],FUNC_LIST[13],FUNC_LIST[6],FUNC_LIST[139],FUNC_LIST[20],FUNC_LIST[138],FUNC_LIST[250],FUNC_LIST[239],FUNC_LIST[29],FUNC_LIST[223],FUNC_LIST[251],FUNC_LIST[209],FUNC_LIST[193],FUNC_LIST[27],FUNC_LIST[96],FUNC_LIST[26],FUNC_LIST[30],FUNC_LIST[25],FUNC_LIST[39],FUNC_LIST[42],FUNC_LIST[47],FUNC_LIST[46],FUNC_LIST[71],FUNC_LIST[41],FUNC_LIST[45],FUNC_LIST[40],FUNC_LIST[43],FUNC_LIST[48],FUNC_LIST[95],FUNC_LIST[72],FUNC_LIST[74],FUNC_LIST[73],FUNC_LIST[105],FUNC_LIST[104],FUNC_LIST[101],FUNC_LIST[106],FUNC_LIST[99],FUNC_LIST[100],FUNC_LIST[97],FUNC_LIST[98],FUNC_LIST[102],FUNC_LIST[103],FUNC_LIST[151],FUNC_LIST[117],FUNC_LIST[112],FUNC_LIST[121],FUNC_LIST[128],FUNC_LIST[126],FUNC_LIST[116],FUNC_LIST[114],FUNC_LIST[119],FUNC_LIST[162],FUNC_LIST[125],FUNC_LIST[111],FUNC_LIST[113],FUNC_LIST[110],FUNC_LIST[108],FUNC_LIST[158],FUNC_LIST[159],FUNC_LIST[122],FUNC_LIST[156],FUNC_LIST[157],FUNC_LIST[120],FUNC_LIST[109],FUNC_LIST[168],FUNC_LIST[180],FUNC_LIST[181],FUNC_LIST[166],FUNC_LIST[167],FUNC_LIST[169],FUNC_LIST[170],FUNC_LIST[184],FUNC_LIST[200],FUNC_LIST[199],FUNC_LIST[215],FUNC_LIST[211],FUNC_LIST[216],FUNC_LIST[196],FUNC_LIST[238],FUNC_LIST[186],FUNC_LIST[197],FUNC_LIST[185],FUNC_LIST[217],FUNC_LIST[218],FUNC_LIST[226], }
		table.move(data, 1, #data, offset, target)
	end
	rt.store.string(MEMORY_LIST[0], 1048576,"\x03\x00\x00\x00\x04\x00\x00\x00\x04\x00\x00\x00\x04\x00\x00\x00\x05\x00\x00\x00\x05\x00\x00\x00\x06\x00\x00\x00\x07\x00\x00\x00called `Result::unwrap()` on an `Err` value\x00\x08\x00\x00\x00\x08\x00\x00\x00\x04\x00\x00\x00\t\x00\x00\x00src\\main.rs\x00\\\x00\x10\x00\x0b\x00\x00\x00K\x00\x00\x00%\x00\x00\x00cannot access a Thread Local Storage value during or after destruction\x00\x00\n\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x0b\x00\x00\x00/rustc/07dca489ac2d933c78d3c5158e3f43beefeb02ce/library/std/src/thread/local.rs\x00\xd0\x00\x10\x00O\x00\x00\x00\xf6\x00\x00\x00\x1a\x00\x00\x00src\\main.rs\x000\x01\x10\x00\x0b\x00\x00\x000\x00\x00\x00\x13\x00\x00\x000\x01\x10\x00\x0b\x00\x00\x00/\x00\x00\x00\"\x00\x00\x000\x01\x10\x00\x0b\x00\x00\x003\x00\x00\x00\"\x00\x00\x00called `Option::unwrap()` on a `None` value\x000\x01\x10\x00\x0b\x00\x00\x009\x00\x00\x00:\x00\x00\x00uciisreadyucinewgamenot implemented\x000\x01\x10\x00\x0b\x00\x00\x00B\x00\x00\x00\x0e\x00\x00\x000\x01\x10\x00\x0b\x00\x00\x00A\x00\x00\x00!\x00\x00\x000\x01\x10\x00\x0b\x00\x00\x00@\x00\x00\x00\x1f\x00\x00\x000\x01\x10\x00\x0b\x00\x00\x00?\x00\x00\x00\'\x00\x00\x000\x01\x10\x00\x0b\x00\x00\x00>\x00\x00\x00%\x00\x00\x000\x01\x10\x00\x0b\x00\x00\x00=\x00\x00\x00$\x00\x00\x000\x01\x10\x00\x0b\x00\x00\x00<\x00\x00\x00 \x00\x00\x000\x01\x10\x00\x0b\x00\x00\x00:\x00\x00\x00\x13\x00\x00\x00ParseIntErrorkind\x00\x00\x00\x13\x00\x00\x00\x04\x00\x00\x00\x04\x00\x00\x00\x14\x00\x00\x00\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x04\x04\x04\x04\x04\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00src\\uci\\mod.rs\x00\x00p\x03\x10\x00\x0e\x00\x00\x00\x1a\x00\x00\x00 \x00\x00\x00p\x03\x10\x00\x0e\x00\x00\x00\x1a\x00\x00\x001\x00\x00\x00called `Option::unwrap()` on a `None` value\x00p\x03\x10\x00\x0e\x00\x00\x00\x1c\x00\x00\x00&\x00\x00\x00Invalid promotion notation\x00\x00\xdc\x03\x10\x00\x1a\x00\x00\x00p\x03\x10\x00\x0e\x00\x00\x00+\x00\x00\x00\x15\x00\x00\x00searchmovesponderwtimebtimemovestogodepthnodesmovetimeperftinfinitenot implemented\x00\x00p\x03\x10\x00\x0e\x00\x00\x00}\x00\x00\x00\x16\x00\x00\x00p\x03\x10\x00\x0e\x00\x00\x00x\x00\x00\x003\x00\x00\x00called `Result::unwrap()` on an `Err` value\x00\x15\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x16\x00\x00\x00p\x03\x10\x00\x0e\x00\x00\x00x\x00\x00\x00D\x00\x00\x00p\x03\x10\x00\x0e\x00\x00\x00t\x00\x00\x00=\x00\x00\x00p\x03\x10\x00\x0e\x00\x00\x00t\x00\x00\x00N\x00\x00\x00p\x03\x10\x00\x0e\x00\x00\x00q\x00\x00\x007\x00\x00\x00p\x03\x10\x00\x0e\x00\x00\x00q\x00\x00\x00H\x00\x00\x00p\x03\x10\x00\x0e\x00\x00\x00n\x00\x00\x003\x00\x00\x00p\x03\x10\x00\x0e\x00\x00\x00n\x00\x00\x00D\x00\x00\x00p\x03\x10\x00\x0e\x00\x00\x00k\x00\x00\x003\x00\x00\x00p\x03\x10\x00\x0e\x00\x00\x00k\x00\x00\x00D\x00\x00\x00p\x03\x10\x00\x0e\x00\x00\x00h\x00\x00\x009\x00\x00\x00p\x03\x10\x00\x0e\x00\x00\x00h\x00\x00\x00J\x00\x00\x00p\x03\x10\x00\x0e\x00\x00\x00e\x00\x00\x00=\x00\x00\x00p\x03\x10\x00\x0e\x00\x00\x00e\x00\x00\x00N\x00\x00\x00p\x03\x10\x00\x0e\x00\x00\x00b\x00\x00\x00=\x00\x00\x00p\x03\x10\x00\x0e\x00\x00\x00b\x00\x00\x00N\x00\x00\x00p\x03\x10\x00\x0e\x00\x00\x00_\x00\x00\x008\x00\x00\x00p\x03\x10\x00\x0e\x00\x00\x00_\x00\x00\x00I\x00\x00\x00p\x03\x10\x00\x0e\x00\x00\x00\\\x00\x00\x008\x00\x00\x00p\x03\x10\x00\x0e\x00\x00\x00\\\x00\x00\x00I\x00\x00\x00id name chess\nid author someone\nuciokreadyokmovesfenrnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1p\x03\x10\x00\x0e\x00\x00\x00\xbc\x00\x00\x00<\x00\x00\x00\x13\x00\x00\x00\x08\x00\x00\x00\x04\x00\x00\x00\x17\x00\x00\x00\x18\x00\x00\x00info depth  score cp  time  pv \x00\x80\x06\x10\x00\x0b\x00\x00\x00\x8b\x06\x10\x00\n\x00\x00\x00\x95\x06\x10\x00\x06\x00\x00\x00\x9b\x06\x10\x00\x04\x00\x00\x00bestmove \x00\x00\x00\xc0\x06\x10\x00\t\x00\x00\x00Nodes searched: \xd4\x06\x10\x00\x10\x00\x00\x00p\x03\x10\x00\x0e\x00\x00\x00\xc9\x00\x00\x004\x00\x00\x00p\x03\x10\x00\x0e\x00\x00\x00\xd7\x00\x00\x00\x12\x00\x00\x00\x19\x00\x00\x00\x0c\x00\x00\x00\x04\x00\x00\x00\x1a\x00\x00\x00\x1b\x00\x00\x00\x1c\x00\x00\x00a Display implementation returned an error unexpectedly\x00\x1d\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x1e\x00\x00\x00/rustc/07dca489ac2d933c78d3c5158e3f43beefeb02ce/library/alloc/src/string.rs\x00l\x07\x10\x00K\x00\x00\x003\n\x00\x00\x0e\x00\x00\x00ErrorParseIntErrorkind\x00\x00\x1f\x00\x00\x00\x04\x00\x00\x00\x04\x00\x00\x00\x14\x00\x00\x00{square} {character}src\\board\\fen.rsMissing w/b to move\x00\x04\x08\x10\x00\x10\x00\x00\x00,\x00\x00\x000\x00\x00\x00No w/b to move\x00\x008\x08\x10\x00\x0e\x00\x00\x00\x04\x08\x10\x00\x10\x00\x00\x002\x00\x00\x00\x12\x00\x00\x00Missing castling rights\x00\x04\x08\x10\x00\x10\x00\x00\x006\x00\x00\x00;\x00\x00\x00Missing en passant\x00\x00\x04\x08\x10\x00\x10\x00\x00\x009\x00\x00\x00\'\x00\x00\x00No half move clock\x00\x00\x04\x08\x10\x00\x10\x00\x00\x00C\x00\x00\x00\x0e\x00\x00\x00No full move counter\x04\x08\x10\x00\x10\x00\x00\x00H\x00\x00\x00\x0e\x00\x00\x00 \x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00!\x00\x00\x00\x04\x08\x10\x00\x10\x00\x00\x00J\x00\x00\x00\x0e\x00\x00\x00\x04\x08\x10\x00\x10\x00\x00\x00E\x00\x00\x00\x0e\x00\x00\x00\x1f\x00\x00\x00\x08\x00\x00\x00\x04\x00\x00\x00\"\x00\x00\x00\x04\x08\x10\x00\x10\x00\x00\x00\x1a\x00\x00\x00>\x00\x00\x00 b  w called `Option::unwrap()` on a `None` value\x00\x00\x00\x04\x08\x10\x00\x10\x00\x00\x00s\x00\x00\x006\x00\x00\x00\x04\x08\x10\x00\x10\x00\x00\x00j\x00\x00\x00>\x00\x00\x00Invalid piecesrc\\move_generator\\maker.rs\xa5\t\x10\x00\x1b\x00\x00\x00\x14\x00\x00\x00.\x00\x00\x00\xa5\t\x10\x00\x1b\x00\x00\x00\x1e\x00\x00\x00<\x00\x00\x00\xa5\t\x10\x00\x1b\x00\x00\x00}\x00\x00\x00\x1a\x00\x00\x00\xa5\t\x10\x00\x1b\x00\x00\x00\x9c\x00\x00\x00.\x00\x00\x00\xa5\t\x10\x00\x1b\x00\x00\x00\xa5\x00\x00\x00Q\x00\x00\x00\xa5\t\x10\x00\x1b\x00\x00\x00\xc1\x00\x00\x00P\x00\x00\x00\xa5\t\x10\x00\x1b\x00\x00\x00\xce\x00\x00\x00\x1a\x00\x00\x00\xa5\t\x10\x00\x1b\x00\x00\x00\xd1\x00\x00\x00J\x00\x00\x00PNBRQKpnbrqksrc\\move_generator\\mod.rs\x00\x00\x00L\n\x10\x00\x19\x00\x00\x00H\x00\x00\x00\r\x00\x00\x00L\n\x10\x00\x19\x00\x00\x00F\x00\x00\x00\r\x00\x00\x00L\n\x10\x00\x19\x00\x00\x00\x04\x01\x00\x00\t\x00\x00\x00L\n\x10\x00\x19\x00\x00\x00!\x01\x00\x000\x00\x00\x00L\n\x10\x00\x19\x00\x00\x006\x01\x00\x000\x00\x00\x00L\n\x10\x00\x19\x00\x00\x00X\x01\x00\x004\x00\x00\x00L\n\x10\x00\x19\x00\x00\x00\x81\x01\x00\x006\x00\x00\x00L\n\x10\x00\x19\x00\x00\x00\x9d\x01\x00\x006\x00\x00\x00L\n\x10\x00\x19\x00\x00\x00\xb1\x01\x00\x00\t\x00\x00\x00\x01\x08\xff\xf8\x07\t\xf7\xf9\x07\x07\x00\x00\x00\x07\x00\x00\x06\x07\x01\x00\x01\x06\x00\x00\x05\x07\x02\x00\x02\x05\x00\x00\x04\x07\x03\x00\x03\x04\x00\x00\x03\x07\x04\x00\x04\x03\x00\x00\x02\x07\x05\x00\x05\x02\x00\x00\x01\x07\x06\x00\x06\x01\x00\x00\x00\x07\x07\x00\x07\x00\x00\x00\x07\x06\x00\x01\x00\x06\x00\x01\x06\x06\x01\x01\x01\x06\x01\x01\x05\x06\x02\x01\x02\x05\x01\x01\x04\x06\x03\x01\x03\x04\x01\x01\x03\x06\x04\x01\x04\x03\x01\x01\x02\x06\x05\x01\x05\x02\x01\x01\x01\x06\x06\x01\x06\x01\x01\x01\x00\x06\x07\x01\x06\x00\x01\x00\x07\x05\x00\x02\x00\x05\x00\x02\x06\x05\x01\x02\x01\x05\x01\x02\x05\x05\x02\x02\x02\x05\x02\x02\x04\x05\x03\x02\x03\x04\x02\x02\x03\x05\x04\x02\x04\x03\x02\x02\x02\x05\x05\x02\x05\x02\x02\x02\x01\x05\x06\x02\x05\x01\x02\x01\x00\x05\x07\x02\x05\x00\x02\x00\x07\x04\x00\x03\x00\x04\x00\x03\x06\x04\x01\x03\x01\x04\x01\x03\x05\x04\x02\x03\x02\x04\x02\x03\x04\x04\x03\x03\x03\x04\x03\x03\x03\x04\x04\x03\x04\x03\x03\x03\x02\x04\x05\x03\x04\x02\x03\x02\x01\x04\x06\x03\x04\x01\x03\x01\x00\x04\x07\x03\x04\x00\x03\x00\x07\x03\x00\x04\x00\x03\x00\x04\x06\x03\x01\x04\x01\x03\x01\x04\x05\x03\x02\x04\x02\x03\x02\x04\x04\x03\x03\x04\x03\x03\x03\x04\x03\x03\x04\x04\x03\x03\x04\x03\x02\x03\x05\x04\x03\x02\x04\x02\x01\x03\x06\x04\x03\x01\x04\x01\x00\x03\x07\x04\x03\x00\x04\x00\x07\x02\x00\x05\x00\x02\x00\x05\x06\x02\x01\x05\x01\x02\x01\x05\x05\x02\x02\x05\x02\x02\x02\x05\x04\x02\x03\x05\x02\x02\x03\x04\x03\x02\x04\x05\x02\x02\x04\x03\x02\x02\x05\x05\x02\x02\x05\x02\x01\x02\x06\x05\x02\x01\x05\x01\x00\x02\x07\x05\x02\x00\x05\x00\x07\x01\x00\x06\x00\x01\x00\x06\x06\x01\x01\x06\x01\x01\x01\x06\x05\x01\x02\x06\x01\x01\x02\x05\x04\x01\x03\x06\x01\x01\x03\x04\x03\x01\x04\x06\x01\x01\x04\x03\x02\x01\x05\x06\x01\x01\x05\x02\x01\x01\x06\x06\x01\x01\x06\x01\x00\x01\x07\x06\x01\x00\x06\x00\x07\x00\x00\x07\x00\x00\x00\x07\x06\x00\x01\x07\x00\x00\x01\x06\x05\x00\x02\x07\x00\x00\x02\x05\x04\x00\x03\x07\x00\x00\x03\x04\x03\x00\x04\x07\x00\x00\x04\x03\x02\x00\x05\x07\x00\x00\x05\x02\x01\x00\x06\x07\x00\x00\x06\x01\x00\x00\x07\x07\x00\x00\x07\x00/rustc/07dca489ac2d933c78d3c5158e3f43beefeb02ce/library/alloc/src/vec/mod.rs\x00\r\x10\x00L\x00\x00\x00\xb4\x05\x00\x00\r\x00\x00\x00\x07\x07\x00\x00\x00\x07\x00\x00\x06\x07\x01\x00\x01\x06\x00\x00\x05\x07\x02\x00\x02\x05\x00\x00\x04\x07\x03\x00\x03\x04\x00\x00\x03\x07\x04\x00\x04\x03\x00\x00\x02\x07\x05\x00\x05\x02\x00\x00\x01\x07\x06\x00\x06\x01\x00\x00\x00\x07\x07\x00\x07\x00\x00\x00\x07\x06\x00\x01\x00\x06\x00\x01\x06\x06\x01\x01\x01\x06\x01\x01\x05\x06\x02\x01\x02\x05\x01\x01\x04\x06\x03\x01\x03\x04\x01\x01\x03\x06\x04\x01\x04\x03\x01\x01\x02\x06\x05\x01\x05\x02\x01\x01\x01\x06\x06\x01\x06\x01\x01\x01\x00\x06\x07\x01\x06\x00\x01\x00\x07\x05\x00\x02\x00\x05\x00\x02\x06\x05\x01\x02\x01\x05\x01\x02\x05\x05\x02\x02\x02\x05\x02\x02\x04\x05\x03\x02\x03\x04\x02\x02\x03\x05\x04\x02\x04\x03\x02\x02\x02\x05\x05\x02\x05\x02\x02\x02\x01\x05\x06\x02\x05\x01\x02\x01\x00\x05\x07\x02\x05\x00\x02\x00\x07\x04\x00\x03\x00\x04\x00\x03\x06\x04\x01\x03\x01\x04\x01\x03\x05\x04\x02\x03\x02\x04\x02\x03\x04\x04\x03\x03\x03\x04\x03\x03\x03\x04\x04\x03\x04\x03\x03\x03\x02\x04\x05\x03\x04\x02\x03\x02\x01\x04\x06\x03\x04\x01\x03\x01\x00\x04\x07\x03\x04\x00\x03\x00\x07\x03\x00\x04\x00\x03\x00\x04\x06\x03\x01\x04\x01\x03\x01\x04\x05\x03\x02\x04\x02\x03\x02\x04\x04\x03\x03\x04\x03\x03\x03\x04\x03\x03\x04\x04\x03\x03\x04\x03\x02\x03\x05\x04\x03\x02\x04\x02\x01\x03\x06\x04\x03\x01\x04\x01\x00\x03\x07\x04\x03\x00\x04\x00\x07\x02\x00\x05\x00\x02\x00\x05\x06\x02\x01\x05\x01\x02\x01\x05\x05\x02\x02\x05\x02\x02\x02\x05\x04\x02\x03\x05\x02\x02\x03\x04\x03\x02\x04\x05\x02\x02\x04\x03\x02\x02\x05\x05\x02\x02\x05\x02\x01\x02\x06\x05\x02\x01\x05\x01\x00\x02\x07\x05\x02\x00\x05\x00\x07\x01\x00\x06\x00\x01\x00\x06\x06\x01\x01\x06\x01\x01\x01\x06\x05\x01\x02\x06\x01\x01\x02\x05\x04\x01\x03\x06\x01\x01\x03\x04\x03\x01\x04\x06\x01\x01\x04\x03\x02\x01\x05\x06\x01\x01\x05\x02\x01\x01\x06\x06\x01\x01\x06\x01\x00\x01\x07\x06\x01\x00\x06\x00\x07\x00\x00\x07\x00\x00\x00\x07\x06\x00\x01\x07\x00\x00\x01\x06\x05\x00\x02\x07\x00\x00\x02\x05\x04\x00\x03\x07\x00\x00\x03\x04\x03\x00\x04\x07\x00\x00\x04\x03\x02\x00\x05\x07\x00\x00\x05\x02\x01\x00\x06\x07\x00\x00\x06\x01\x00\x00\x07\x07\x00\x00\x07\x00src\\search\\mod.rs\x00\x00\x00\\\x0f\x10\x00\x11\x00\x00\x00\xab\x00\x00\x00%\x00\x00\x00\\\x0f\x10\x00\x11\x00\x00\x00?\x01\x00\x00!\x00\x00\x00\\\x0f\x10\x00\x11\x00\x00\x00!\x01\x00\x00\x15\x00\x00\x00\\\x0f\x10\x00\x11\x00\x00\x00\'\x01\x00\x00)\x00\x00\x00\x07\x07\x00\x00\x00\x07\x00\x00\x06\x07\x01\x00\x01\x06\x00\x00\x05\x07\x02\x00\x02\x05\x00\x00\x04\x07\x03\x00\x03\x04\x00\x00\x03\x07\x04\x00\x04\x03\x00\x00\x02\x07\x05\x00\x05\x02\x00\x00\x01\x07\x06\x00\x06\x01\x00\x00\x00\x07\x07\x00\x07\x00\x00\x00\x07\x06\x00\x01\x00\x06\x00\x01\x06\x06\x01\x01\x01\x06\x01\x01\x05\x06\x02\x01\x02\x05\x01\x01\x04\x06\x03\x01\x03\x04\x01\x01\x03\x06\x04\x01\x04\x03\x01\x01\x02\x06\x05\x01\x05\x02\x01\x01\x01\x06\x06\x01\x06\x01\x01\x01\x00\x06\x07\x01\x06\x00\x01\x00\x07\x05\x00\x02\x00\x05\x00\x02\x06\x05\x01\x02\x01\x05\x01\x02\x05\x05\x02\x02\x02\x05\x02\x02\x04\x05\x03\x02\x03\x04\x02\x02\x03\x05\x04\x02\x04\x03\x02\x02\x02\x05\x05\x02\x05\x02\x02\x02\x01\x05\x06\x02\x05\x01\x02\x01\x00\x05\x07\x02\x05\x00\x02\x00\x07\x04\x00\x03\x00\x04\x00\x03\x06\x04\x01\x03\x01\x04\x01\x03\x05\x04\x02\x03\x02\x04\x02\x03\x04\x04\x03\x03\x03\x04\x03\x03\x03\x04\x04\x03\x04\x03\x03\x03\x02\x04\x05\x03\x04\x02\x03\x02\x01\x04\x06\x03\x04\x01\x03\x01\x00\x04\x07\x03\x04\x00\x03\x00\x07\x03\x00\x04\x00\x03\x00\x04\x06\x03\x01\x04\x01\x03\x01\x04\x05\x03\x02\x04\x02\x03\x02\x04\x04\x03\x03\x04\x03\x03\x03\x04\x03\x03\x04\x04\x03\x03\x04\x03\x02\x03\x05\x04\x03\x02\x04\x02\x01\x03\x06\x04\x03\x01\x04\x01\x00\x03\x07\x04\x03\x00\x04\x00\x07\x02\x00\x05\x00\x02\x00\x05\x06\x02\x01\x05\x01\x02\x01\x05\x05\x02\x02\x05\x02\x02\x02\x05\x04\x02\x03\x05\x02\x02\x03\x04\x03\x02\x04\x05\x02\x02\x04\x03\x02\x02\x05\x05\x02\x02\x05\x02\x01\x02\x06\x05\x02\x01\x05\x01\x00\x02\x07\x05\x02\x00\x05\x00\x07\x01\x00\x06\x00\x01\x00\x06\x06\x01\x01\x06\x01\x01\x01\x06\x05\x01\x02\x06\x01\x01\x02\x05\x04\x01\x03\x06\x01\x01\x03\x04\x03\x01\x04\x06\x01\x01\x04\x03\x02\x01\x05\x06\x01\x01\x05\x02\x01\x01\x06\x06\x01\x01\x06\x01\x00\x01\x07\x06\x01\x00\x06\x00\x07\x00\x00\x07\x00\x00\x00\x07\x06\x00\x01\x07\x00\x00\x01\x06\x05\x00\x02\x07\x00\x00\x02\x05\x04\x00\x03\x07\x00\x00\x03\x04\x03\x00\x04\x07\x00\x00\x04\x03\x02\x00\x05\x07\x00\x00\x05\x02\x01\x00\x06\x07\x00\x00\x06\x01\x00\x00\x07\x07\x00\x00\x07\x00src\\move_generator\\slider_lookup.rs\x00\xb0\x11\x10\x00#\x00\x00\x005\x00\x00\x00\x1d\x00\x00\x00\xb0\x11\x10\x00#\x00\x00\x00;\x00\x00\x00\x13\x00\x00\x00\xb0\x11\x10\x00#\x00\x00\x00?\x00\x00\x00\x13\x00\x00\x00\xb0\x11\x10\x00#\x00\x00\x00E\x00\x00\x00\x13\x00\x00\x00\xb0\x11\x10\x00#\x00\x00\x00K\x00\x00\x00\x13\x00\x00\x00\xb0\x11\x10\x00#\x00\x00\x00W\x00\x00\x00\x11\x00\x00\x00\xb0\x11\x10\x00#\x00\x00\x00Y\x00\x00\x00\x13\x00\x00\x00\xb0\x11\x10\x00#\x00\x00\x00^\x00\x00\x00\x13\x00\x00\x00\xb0\x11\x10\x00#\x00\x00\x00c\x00\x00\x00\x13\x00\x00\x00\xb0\x11\x10\x00#\x00\x00\x00h\x00\x00\x00\x13\x00\x00\x00\xb0\x11\x10\x00#\x00\x00\x00\x90\x00\x00\x00\x13\x00\x00\x00\x00\x00\x00\x00\xc1 \x00\x01\x80\x10\x00\x014\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x10\x01`@\x00@\x005\x00\x00\x00\x00\x00\x00\x00\x00\x10\x00\x00\x00\x00\x00\x00@\x00 \x10\x00\t\x00\x815\x00\x00\x00\x00\x00\x00\x00\x00\x18\x00\x00\x00\x00\x00\x00\x00\x01\x10DH \x00\x015\x00\x00\x00\x00\x00\x00\x00\x00 \x00\x00\x00\x00\x00\x00\x004\x02\x80\x01\x08\x80\xa05\x00\x00\x00\x00\x00\x00\x00\x00(\x00\x00\x00\x00\x00\x00(\x81\x10\x04\x00\x06\x00\x025\x00\x00\x00\x00\x00\x00\x00\x000\x00\x00\x00\x00\x00\x00\x82\x08\x01D\x10\x08\x00\x045\x00\x00\x00\x00\x00\x00\x00\x008\x00\x00\x00\x00\x00\x00\x00\x03\x80@ \x04\x80\x014\x00\x00\x00\x00\x00\x00\x00\x00@\x00\x00\x00\x00\x00\x00\x80 \x00@\x08\x80\x00\x005\x00\x00\x00\x00\x00\x00\x00\x00P\x00\x00\x00\x00\x00\x00\x00 \x00P\x00@/\x016\x00\x00\x00\x00\x00\x00\x00\x00X\x00\x00\x00\x00\x00\x00\x02 @\x00\x11\x00\x0bD6\x00\x00\x00\x00\x00\x00\x00\x00\\\x00\x00\x00\x00\x00\x00\x80\x00P\x01\x18\x80 \x006\x00\x00\x00\x00\x00\x00\x00\x00`\x00\x00\x00\x00\x00\x00\x00(\x00\x04\x80\x80\x00\x106\x00\x00\x00\x00\x00\x00\x00\x00d\x00\x00\x00\x00\x00\x00\x00\x02\x80\x00\x04\x80\x08\x806\x00\x00\x00\x00\x00\x00\x00\x00h\x00\x00\x00\x00\x00\x00\x002\x98\x0c\x01\x00\x02 6\x00\x00\x00\x00\x00\x00\x00\x00l\x00\x00\x00\x00\x00\x00\x80\x04\x00\xe1\x00\x80\x00\x105\x00\x00\x00\x00\x00\x00\x00\x00p\x00\x00\x00\x00\x00\x00(\x80P\x00\x80\x00@ 5\x00\x00\x00\x00\x00\x00\x00\x00x\x00\x00\x00\x00\x00\x00\x00 \x00\x10@@\x00@6\x00\x00\x00\x00\x00\x00\x00\x00\x80\x00\x00\x00\x00\x00\x00\x81@\x00\"\x00\x12\x00\x086\x00\x00\x00\x00\x00\x00\x00\x00\x84\x00\x00\x00\x00\x00\x00\x82\x10\x00\x08\x80\x00\x10\x006\x00\x00\x00\x00\x00\x00\x00\x00\x88\x00\x00\x00\x00\x00\x00\x00\x04\x00\x08\x80\x80\x00\x106\x00\x00\x00\x00\x00\x00\x00\x00\x8c\x00\x00\x00\x00\x00\x000@ \x04\x01\x08 @6\x00\x00\x00\x00\x00\x00\x00\x00\x90\x00\x00\x00\x00\x00\x00\x01(\n\x10\x00\x04\x00\x106\x00\x00\x00\x00\x00\x00\x00\x00\x94\x00\x00\x00\x00\x00\x00\x01\x84\xc0\x00\x00\"@D5\x00\x00\x00\x00\x00\x00\x00\x00\x98\x00\x00\x00\x00\x00\x00\x00\x80 \x80\x00@h\x005\x00\x00\x00\x00\x00\x00\x00\x00\xa0\x00\x00\x00\x00\x00\x00\x00\x10@@\x00\xe0\x00D6\x00\x00\x00\x00\x00\x00\x00\x00\xa8\x00\x00\x00\x00\x00\x00\x80\x00 \x80\x000\x00\x006\x00\x00\x00\x00\x00\x00\x00\x00\xac\x00\x00\x00\x00\x00\x00\"\x01\t\x00\x01\x10\x00\x006\x00\x00\x00\x00\x00\x00\x00\x00\xb0\x00\x00\x00\x00\x00\x00\x04\x00\x08\x00\x11\x00\x01\x026\x00\x00\x00\x00\x00\x00\x00\x00\xb4\x00\x00\x00\x00\x00\x00\x80\x00\x02\x80\x00DD\x886\x00\x00\x00\x00\x00\x00\x00\x00\xb8\x00\x00\x00\x00\x00\x00\x00\x02\x08\x02\x04\x10\x84\x006\x00\x00\x00\x00\x00\x00\x00\x00\xbc\x00\x00\x00\x00\x00\x00\x01\xa4\x04\x00B\x01\x04\x905\x00\x00\x00\x00\x00\x00\x00\x00\xc0\x00\x00\x00\x00\x00\x00\x80\x00\x80$\x00@\x00\x0c5\x00\x00\x00\x00\x00\x00\x00\x00\xc8\x00\x00\x00\x00\x00\x00\x00 @\x02\x10@\x00\x106\x00\x00\x00\x00\x00\x00\x00\x00\xd0\x00\x00\x00\x00\x00\x00\x000\x80\x01 \x84\x00`6\x00\x00\x00\x00\x00\x00\x00\x00\xd4\x00\x00\x00\x00\x00\x00\x02\x08\x80\x84\x00\x10\x00\x006\x00\x00\x00\x00\x00\x00\x00\x00\xd8\x00\x00\x00\x00\x00\x00\x01\x18\x80\x81\x00\x14\x14\x006\x00\x00\x00\x00\x00\x00\x00\x00\xdc\x00\x00\x00\x00\x00\x00\x00B\x80\x00\x04\x80@\x186\x00\x00\x00\x00\x00\x00\x00\x00\xe0\x00\x00\x00\x00\x00\x00\x02\x08\x00$\x01\x90\xa0\x006\x00\x00\x00\x00\x00\x00\x00\x00\xe4\x00\x00\x00\x00\x00\x00e\x10\x00\x82\x01\x14(\x805\x00\x00\x00\x00\x00\x00\x00\x00\xe8\x00\x00\x00\x00\x00\x00\x10\x80\x00@`\x80\x05\x005\x00\x00\x00\x00\x00\x00\x00\x00\xf0\x00\x00\x00\x00\x00\x00\x02@\x00 \x00P\x10\x026\x00\x00\x00\x00\x00\x00\x00\x00\xf8\x00\x00\x00\x00\x00\x00\x11\x00\x82$\xc0\x00\x06\x106\x00\x00\x00\x00\x00\x00\x00\x00\xfc\x00\x00\x00\x00\x00\x00\x18\x00B\x00\x12 !\x106\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x04\x002 \x88\x00B\x006\x00\x00\x00\x00\x00\x00\x00\x00\x04\x01\x00\x00\x00\x00\x00L\x80\x80\x00\x02\x00\x04D6\x00\x00\x00\x00\x00\x00\x00\x00\x08\x01\x00\x00\x00\x00\x00\x80\x80\x00\x01\x00\"\x00\x086\x00\x00\x00\x00\x00\x00\x00\x00\x0c\x01\x00\x00\x00\x00\x00#\x00\x02D\x80\x02\x80\x805\x00\x00\x00\x00\x00\x00\x00\x00\x10\x01\x00\x00\x00\x00\x00\x80H\x01\x80 \x00@\x025\x00\x00\x00\x00\x00\x00\x00\x00\x18\x01\x00\x00\x00\x00\x00@\x02@\x02\x10 \x00\x006\x00\x00\x00\x00\x00\x00\x00\x00 \x01\x00\x00\x00\x00\x00\x80\x81\x05`\x00\x10@\x886\x00\x00\x00\x00\x00\x00\x00\x00$\x01\x00\x00\x00\x00\x00\x00\x01\x10H\x00\xa1\x00\x006\x00\x00\x00\x00\x00\x00\x00\x00(\x01\x00\x00\x00\x00\x00\x00\x01\x01\x88\x10L\x05\x006\x00\x00\x00\x00\x00\x00\x00\x00,\x01\x00\x00\x00\x00\x00\x80\x00\x04\x00\x02\x81\x00\x006\x00\x00\x00\x00\x00\x00\x00\x000\x01\x00\x00\x00\x00\x00\x00\x02\x08\x04\x05\x00\x02\x086\x00\x00\x00\x00\x00\x00\x00\x004\x01\x00\x00\x00\x00\x00\x80A\x04\x00\x01\x80\x00\x015\x00\x00\x00\x00\x00\x00\x00\x008\x01\x00\x00\x00\x00\x00\"\x80\x18\x00\x01B)\x804\x00\x00\x00\x00\x00\x00\x00\x00@\x01\x00\x00\x00\x00\x00\x05@d\x10\x00\x81@\x015\x00\x00\x00\x00\x00\x00\x00\x00P\x01\x00\x00\x00\x00\x00B\x08\x82\x00\"\x10\x04\x005\x00\x00\x00\x00\x00\x00\x00\x00X\x01\x00\x00\x00\x00\x00\x01%\x00\x10\x88! \x005\x00\x00\x00\x00\x00\x00\x00\x00`\x01\x00\x00\x00\x00\x00B\x0c \x90\x18\x00\x1a\x025\x00\x00\x00\x00\x00\x00\x00\x00h\x01\x00\x00\x00\x00\x00\x82\x11\x08\x10\x04\x00\x02\x885\x00\x00\x00\x00\x00\x00\x00\x00p\x01\x00\x00\x00\x00\x00\x04\xc2\x00\x10\x03\xa8\x00\x005\x00\x00\x00\x00\x00\x00\x00\x00x\x01\x00\x00\x00\x00\x00\x82 \x00A\x00\x04\x00\x884\x00\x00\x00\x00\x00\x00\x00\x00\x80\x01\x00\x00\x00\x00\x00\xb0\x11\x10\x00#\x00\x00\x00\x9e\x00\x00\x00\x12\x00\x00\x00\x02\x82\x00\x84\x84H$\x00:\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00 \xa0\x00\x11\x04\x02 \x02;\x00\x00\x00\x00\x00\x00\x00@\x00\x00\x00\x00\x00\x00\x00\xe8\x00 \x88\x00\x040@;\x00\x00\x00\x00\x00\x00\x00`\x00\x00\x00\x00\x00\x00\x00\x10\x04\x00\x00\x81@\x82 ;\x00\x00\x00\x00\x00\x00\x00\x80\x00\x00\x00\x00\x00\x00\x00\x00\x02P\x00 \x04$X;\x00\x00\x00\x00\x00\x00\x00\xa0\x00\x00\x00\x00\x00\x00\x00\x18\xb0   \x82$\x80;\x00\x00\x00\x00\x00\x00\x00\xc0\x00\x00\x00\x00\x00\x00\x00\x00 < \x0c\x05B\x02;\x00\x00\x00\x00\x00\x00\x00\xe0\x00\x00\x00\x00\x00\x00\x00\x02\x04A\x04\x08B\x00\x08:\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00@\x00\x04\x10\x04\x10\x13@;\x00\x00\x00\x00\x00\x00\x00@\x01\x00\x00\x00\x00\x00\x00\x00\x01\x04\x07\x0c\x02\x19@;\x00\x00\x00\x00\x00\x00\x00`\x01\x00\x00\x00\x00\x00\x00\x04\x00A@A\x10\x02\x10;\x00\x00\x00\x00\x00\x00\x00\x80\x01\x00\x00\x00\x00\x00\x00\x00\x00\x80\x08\x04\x04\x00\x00;\x00\x00\x00\x00\x00\x00\x00\xa0\x01\x00\x00\x00\x00\x00\x00A\x80\x10@\x11\x01 \x00;\x00\x00\x00\x00\x00\x00\x00\xc0\x01\x00\x00\x00\x00\x00\x00\x00\x00\x06 \x04%\x00 ;\x00\x00\x00\x00\x00\x00\x00\xe0\x01\x00\x00\x00\x00\x00\x00\nB\x04\x88\x00\x05\xa0\x02;\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x08\x864\x02\n\x01\x00;\x00\x00\x00\x00\x00\x00\x00 \x02\x00\x00\x00\x00\x00\x00`\x02*\x12@\x00  ;\x00\x00\x00\x00\x00\x00\x00@\x02\x00\x00\x00\x00\x00\x00A$\xa5\x08\xa0\x00\x08\x00;\x00\x00\x00\x00\x00\x00\x00`\x02\x00\x00\x00\x00\x00\x00\x00\"\x02\x02\x08\x04I 9\x00\x00\x00\x00\x00\x00\x00\x80\x02\x00\x00\x00\x00\x00\x00\x00 \x02\"\x0c\x00H\x029\x00\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x00\x00\x00\x00\x00\xa0\x00$\x88\x08\x009\x00\x00\x00\x00\x00\x00\x00\x80\x03\x00\x00\x00\x00\x00\x00\x01 B\x01\x02B \x029\x00\x00\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00\x04\x08\x10\x0b\x82P\x10\x01;\x00\x00\x00\x00\x00\x00\x00\x80\x04\x00\x00\x00\x00\x00\x00\x01\x04\x88\x00Q1\x00\x80;\x00\x00\x00\x00\x00\x00\x00\xa0\x04\x00\x00\x00\x00\x00\x00RA\x08A\x02\x08\x10\x00;\x00\x00\x00\x00\x00\x00\x00\xc0\x04\x00\x00\x00\x00\x00\x00\x01\x03! \x08\x98(\x80;\x00\x00\x00\x00\x00\x00\x00\xe0\x04\x00\x00\x00\x00\x00\x00\x00,\x01\x04\x02\x02\x04\x089\x00\x00\x00\x00\x00\x00\x00\x00\x05\x00\x00\x00\x00\x00\x00\x02\x00\x02(\x80\x80\x02\x107\x00\x00\x00\x00\x00\x00\x00\x80\x05\x00\x00\x00\x00\x00\x00\x00@\x00AP\x00\x01\x017\x00\x00\x00\x00\x00\x00\x00\x80\x07\x00\x00\x00\x00\x00\x00\x00\x10\x10\t\x80\xc0\x00\x009\x00\x00\x00\x00\x00\x00\x00\x80\t\x00\x00\x00\x00\x00\x00\x04\x08\x01\x04P\x00b\x01;\x00\x00\x00\x00\x00\x00\x00\x00\n\x00\x00\x00\x00\x00\x00\x00\x06\x02\x02H@\x00\x89;\x00\x00\x00\x00\x00\x00\x00 \n\x00\x00\x00\x00\x00\x00\x00\x90\x120\x0c \x02B;\x00\x00\x00\x00\x00\x00\x00@\n\x00\x00\x00\x00\x00\x00\x04B\x10\x00*\x04h\x10;\x00\x00\x00\x00\x00\x00\x00`\n\x00\x00\x00\x00\x00\x00\xc0\x00\x10\x04\x88\x11\x00\x009\x00\x00\x00\x00\x00\x00\x00\x80\n\x00\x00\x00\x00\x00\x00\x80\x00(\x80\x02\x02\x18\x007\x00\x00\x00\x00\x00\x00\x00\x00\x0b\x00\x00\x00\x00\x00\x00@\x00\x01\x10\x01\t@\x017\x00\x00\x00\x00\x00\x00\x00\x00\r\x00\x00\x00\x00\x00\x00\x01$\x00@\x04\x08\xa0B9\x00\x00\x00\x00\x00\x00\x00\x00\x0f\x00\x00\x00\x00\x00\x00 \x84\x12@\x11*P\x04;\x00\x00\x00\x00\x00\x00\x00\x80\x0f\x00\x00\x00\x00\x00\x00\x006\x00\x80\x90\x008@;\x00\x00\x00\x00\x00\x00\x00\xa0\x0f\x00\x00\x00\x00\x00\x00@H\x00  \x84$\x80;\x00\x00\x00\x00\x00\x00\x00\xc0\x0f\x00\x00\x00\x00\x00\x00\x04 @\x04\x88\x00\x05\x08;\x00\x00\x00\x00\x00\x00\x00\xe0\x0f\x00\x00\x00\x00\x00\x00\x00\x10\x80(\xc0\x00\x81\x019\x00\x00\x00\x00\x00\x00\x00\x00\x10\x00\x00\x00\x00\x00\x00\x00\x18\x80\x00B\x00P\x109\x00\x00\x00\x00\x00\x00\x00\x80\x10\x00\x00\x00\x00\x00\x00\x00\x04\x02\x92\x08\x04\x00\x129\x00\x00\x00\x00\x00\x00\x00\x00\x11\x00\x00\x00\x00\x00\x00\x01\xe1 \x01\x04\x15@\x809\x00\x00\x00\x00\x00\x00\x00\x80\x11\x00\x00\x00\x00\x00\x00\x00!\x92\x00\x08\x18\n\x00;\x00\x00\x00\x00\x00\x00\x00\x00\x12\x00\x00\x00\x00\x00\x00D\x10\x00\n\x99\x00\x08(;\x00\x00\x00\x00\x00\x00\x00 \x12\x00\x00\x00\x00\x00\x00\x00\x00\x18\x10\x03\x08\x01\x00;\x00\x00\x00\x00\x00\x00\x00@\x12\x00\x00\x00\x00\x00\x00 \x00\x10\x04H\xc1\x01\x02;\x00\x00\x00\x00\x00\x00\x00`\x12\x00\x00\x00\x00\x00\x00\x01\x00\x10\x01\"\x00\x10 ;\x00\x00\x00\x00\x00\x00\x00\x80\x12\x00\x00\x00\x00\x00\x00\x04\x00\x1aB\x04\x00\x88X;\x00\x00\x00\x00\x00\x00\x00\xa0\x12\x00\x00\x00\x00\x00\x00\x00\x00\x06\x02\x10\x010\x00;\x00\x00\x00\x00\x00\x00\x00\xc0\x12\x00\x00\x00\x00\x00\x00!\x01\x1aH\x13\x08\x00\x00;\x00\x00\x00\x00\x00\x00\x00\xe0\x12\x00\x00\x00\x00\x00\x00\x00@\x10\x01\x10\x08 (;\x00\x00\x00\x00\x00\x00\x00\x00\x13\x00\x00\x00\x00\x00\x00 \x80\x00\xa4\x10\x08\x14\x00;\x00\x00\x00\x00\x00\x00\x00 \x13\x00\x00\x00\x00\x00\x00\x00\x02\x04\x84\x00\x04\x05\x00:\x00\x00\x00\x00\x00\x00\x00@\x13\x00\x00\x00\x00\x00\x00\x00\x02\x06\x0c\x84\x10\x8c\x00;\x00\x00\x00\x00\x00\x00\x00\x80\x13\x00\x00\x00\x00\x00\x00\x04\t\x1a\x04\x01\x04@ ;\x00\x00\x00\x00\x00\x00\x00\xa0\x13\x00\x00\x00\x00\x00\x00\x00\x02B(\x02\x00\x00\x00;\x00\x00\x00\x00\x00\x00\x00\xc0\x13\x00\x00\x00\x00\x00\x00\x00\x02\x82\x90\x88\x01\x00\x00;\x00\x00\x00\x00\x00\x00\x00\xe0\x13\x00\x00\x00\x00\x00\x00\x02\x02!\x10H\x00 \x00;\x00\x00\x00\x00\x00\x00\x00\x00\x14\x00\x00\x00\x00\x00\x00@\x00\x01\x88\xa0\x10\x04\xa1;\x00\x00\x00\x00\x00\x00\x00 \x14\x00\x00\x00\x00\x00\x00\x00\x82\x04\x92\x00\x90\x14`:\x00\x00\x00\x00\x00\x00\x00@\x14\x00\x00\x00\x00\x00\x00\xb0\x11\x10\x00#\x00\x00\x00\xaf\x00\x00\x00\x14\x00\x00\x00#\x00\x00\x00\x0c\x00\x00\x00\x04\x00\x00\x00$\x00\x00\x00%\x00\x00\x00\x1c\x00\x00\x00\xc3#\x1c0\xd9\x95\xd1\xb5?\xbfT\x13\x00\'\xb0\x8c@G\xd3\x9e\x03j\x8e\xfe\"\x8b\x8f\xb2x+<\xf0<\xeb\x91\xfar\xdf*\xf6h\x8ea\xaaP\x15+\xa0\xe6\x87O\xed&\xfe\x9dI\xb4(\x86\xf3\xd5\ru\x97S8\x03\x0c\x88\xb1^\x94\xc8\x04\xe7\xfab7V4\xb4\xbc\xd3\xb0{\xbf\x81%\xa7\xc7\'\xed\x90\x11\xd4\xae\x0b\x1b\xe9\xda_\x1af\x97P`\xbe\xef9\xa2N\x7fa\xff\x85\x84\xf4\xc6\x9e~\xba\xd2\xfb\x85\x00m\xed\x8dA\xd6\x9c\xcel\x93\x87wum\xe9D\x0b\xa5\\\xf6\x9c\xf8\xca\xea6\xd8\xdb\xc9\x05\xe9\xf1\xd9\xbaz~\x1de\xd2\xa1b\xee\xbcX\xac\x03\xe6LZ\xc0\xf9\xf5\x99\r\x071\xa4\xfb\x98\xd7AA+r81\xb6 \xdb\xf9yye\x19h\\\xc9\xa0\x8edrLm\xb1\x18\xf7b\n\x0e?\x9d^\xf9\xb3\x01X\r\xf4\x13\x8b\xbfZ\x0eB\x9dh\x96\x9f\xae\x89\x101\xa16\x00\x0c\x1cX\x04\xe1\xd4\x13\xde\xfb\xc1\xb2\xba\xac\x05\x10\xe5}\xf5\xc7\x1fm\xb6,\x0c\xfd\x9f\xf2\x15\x8ce\x04HV$\xe8Z=\x0e\xb4I\x174E\xa5\xb2\xd0^3\x95\xb7\x8c\x11\x1f\xebw\x18\xc3\xd5\xb9\xb0\xc2\xac\xa8\xe8\xcb\x93>\xcc2\x06\xaa\xb9\xe9|\xf9\x80\xa9\xaf\xfe\x13\x0e\x9e>\x94\xf8Z\x0b\x90\xf2\x06b\xaf\xf8v\xfd+\xb4w\xee\xc2J\x91Y\x87W\xda]\xde~s\xaf\xa9s\n\x99\x8c\xd6\xb7\xdb,\x90H\x0e\x12\x97i\xcd\x12h\x05\xe6\xe3{\x93\x95\xf20w\xaccY\x83S\x84I\t\xbc\xcdkk.W\x88\xf8\xb5\x1e\xb6\x7f\xbd\xef\x84\x81.\x9b6\xc7\xb3\x00Uqj\xd9W\xc8\xe6f\x95vd\x9f\xf5>\x8fW\x935\"\x0e\xaaL\xb2\xadN<E.\x0e\xd2\x9b\x00\x01\rEJ\xed\xb6\xb6\x9eC%\x9e\"\xaa\xea\x1aOh\'\x10k\xf4\xc1x\xb6\xdd\x9f[Q\xd9\xcen;\xb4:\xc9o\x9b\x89\x18\xc3r\x16\xc7f\x9a\xb0\x9b\rah\xf5lP\xafbWvD\xfb{t\x0f\xbbq\xf2\xf2\xb0\xaa\x07>x\xb0\x9f1\xb9\xcb\x1f\xe0\x10\x0fc\xaf\xec\x1c=\xbb\xcc\xe3\xfd4\xf0\x83\x10x_m S\x08\n\x9d\xc1\xaa\xac\xe9\x19n\x86.\xed>\x0b\x9e\xfc2\x1b\x0f\x1c\xed9\x0f\xcfa>\x87\xa9\xea\x1b\xbc\x9dk\x94\xa4\xed\x82=P\"\xb2\xcd\xb7\x16\xef\x15\x9a\xe1B\xfd\xe0S\xa9\xedJ\x82\x08P\x88(%\x19m\x115\xe7\xa1&\xd2\xe3\xc4\xca\xd8#\xac{DU\xc9Z\x93\x0c\xe2\x01\x089\x8d;\x89\x1cm;\x15\xee\x97:\x81\x93\xfe\xf2f\xd5BNsD?\xb1 PR\xe6\xf0Y\xa7\x15)\xbdl\xb1 \xf0r7E\xfaR\xd6|R\xa0t4\xd8\xb9\x1c\x931}\xe0Z*=q\xb0\x15\xaf\x87\xdaFL\x03\xc3\x1d<K\xf5l^KdoM\x9bDn+\xadhh\xdd\x87\t\xf5>%%x\x06\xa1\xaf\x12o\xb6u8\x83\x0c.\x05\xa0M6\'\xdaM\x14\x8dRj!t\xab\x04\xdf\xd5\x1a\xe8\t\xaf\xb4k{\x9f\x8a\x98\xeb\xad`+\xf9\xc4s\xf5(\x98\xe6\x7f\xc0w\xf4Z\xc4\x88\xd4w+\x0f7x\x0c\xdb\xd4\xbf\xd0\x1e0\xa2\xfe\x8b\xf6F~\x0c\x0eK\x0c~JX5\x03vUs\xe7\x9f\xcbx\xf2*\x03\xf3\xb2\xd2\x02\xe0?\xefC\x92l\x1d\xd0E|Z\x93j>\x96\xd7\t\xbc{\x89C\x91\xba0\x9d\x1bi{v8G\xf5\x0b\x9d\x88\xb2\xab5\"\xd7\x1d\xe3rS_D\xe9\xdc\xc4\xa6{{\xeb\xf2J\xd4sA\\#\x96e\xf5\x9fO\x17\xdcR0\xc81B\xb5<\xa2r\x97\xf5\xf1\xd7\xb2\x98\x15\xa94\x13}\xf3\xce%`y\x0e\xda\xf7\x80\xe2\xd5\xf6}\xd5\xd4\xf8p~S`t\xa9\xd5\tz\x81\x95\x95\xf1\xb5\xd6\x06\xd6\x88o~\xa2\x8cvD\xe9-\xad]\xaa\xb8\'A\x16\xa9>6$.\xc1\x0bO\xa8\xa5\x96\xd5H,\"\xd4Q\xa4\x14P\xfe\xe7`\xb6\xb5Y\t\x17\xf4\x81\x83\xeb*\x7f\xb7\xcef\x1c\xf1\xfc\xbbt\xa6C\x1a\xc8\xde\x99\xac\xdfk\x90\x87\xf7=\xda\x9c\'\xfa\xf3\xdc\xf7\x17\xf7\x8d\xf8\x00\n\xf9\x15$bO\xa6x6\xac\x86\xca\x04\x8c\xe4 ln\xa8\xf9\xf0\x006\xb8h\xf4{\xc5\xa5]\xe8=\x03\x1f1\xed1\x9d|(|\x08F\x92\x1fZ\xab\xc5\xba\xabU\xf2\x13s\xb2\xdf\x91\x15:\xf692Z5\xa8\x17\xbcO\xad\x94\xed\x1cG\xa06|\x944\x8b7\xf8\xc2o\xac\xd58\xaa;\xae\xc6\xc7\xe7[y&\x95\x99\xb2\xd8\x00u\x13m\xcf\xab\x12\x06\xc9\xbcB^1\x1c\xd9\xb3y\x87\xcc\xa4\x95\xa57F\x84\'5\xb1\xb0\xf8\xff\xdf\x94\xd2\xa5\x15\x0b]\x08\xc59G`\xceGA\"Y`\xd6\xb7\x86\xd8\xec\xdaR\xfew\xfe\xa5\x01R\xa7b\xf9\xbav\x92\xfb\xfd\x0eWq,\x881,\xa54_\xd0\x15\xbd\xa0\xe9\xc1$\xa5z\x95x/\xdfrm\xaf-I\xfc\xec\x97B\xfehg\xe9B\x9c?\x18\xde9\xce\x8d-\xfaz%\xe9\xe42\x832\x8c\xe3\x81_\x182\x83\xa2\n\xbe\x95<f\x9b\x15|\xd6E\x9f\xc1\xdd\xbd\x85\xcck\x9b\xca\xd3t#y\x04\x19\xc0U\xb5F\x8c\xfc\xf7\xdd\x0cv1\x8eX:6\xb0\x8c9?\x1f\xbc\x9c4\xa2v\xc9<\xea\x1fF\x8b\xef3\x19\xbe(,\x01\xfc\xea\x97|\xf6Vuh\x04\xba\x92\x03\xeb\xbeN\xbd\xb0|\xd8z\xb9H\x04\xa7\xd3\xe3\x81\x1e%\xaf]\x19\xdd{\xe2\x8c\x18\x19\xc9\n\x86h\xbe\x84\x87\xa2L\x0f$\x13\r\xff\x80\xfe`Q\xf6!\xf5Mnt\x19\xdcG\xd0\x94\xa3z\xfc\xdb\xd4\t\xb7\x14^\xdd\xf4\xa8\x02\xe6>\x0fD\xac%+\xc7|mS.\xd7\xbcB!\xb5\x86>+\x8b5Wf\xd2Z\x80\xb7\xad+\x1bI\"\x89Y\x93\xdf:\xa2\x12\xf0@\xeb|\x9f\xc0\xd4\x04\xc2\x8d\x19\x80\xf6Ym\xea\xe8&+\x15q\x07(]\xee\xdc9\xac\x8a\x02\xbfj\xa6-v\x9br\xb6\x8f\x1a\xf4lthwT6Y\x17\xc9\xd8\xcb\x84\xf6\xa5<\xe2\xbcp\x13\xc6\xa9\xcd\xe22ZP\xe6\xdb\x85\xa8Q>\xaew\\,\xf5\'b\x87!:Th\xba\xbb\xa9\x8c\x12\xb6!\xa84\xae4n2?\x93S\x13O\xe1\xa5w\xe0\xc1.\xb7\xda\x1d\x8f\xe2w\xbdTt\xbe(R\xa6\xaaA-z\xe6\tv\xdc\x8b\xc7/\x14\x91\xed\x83\x7f\x0f\x1a\x16\xbe\xe7p(\xc3\xce:P\xe1B\xc7@\x86\"\x0eR\x0b\x01\x10\x04\xcfe\x86\xa3\xc2\xbb*1\x92\x82\x16/\x8e\xf3O\x82\xa0#\xb8\x9d\x89gDO\x8d\x83\x0bO\xc3\x13Vd\xc3\x1dJg\xd8O:\xdaxy\x87<Pv\xa7\x92\xe4#\xf8c\xef\x13\xd4\xec\xec6\xb1\xae\x1eO0]\xd5\xa5z\x90\xee4\xd6=\xf5\xce\xe9Qu\xebg\x1d\xb2\xb8no\x11\xcb\'\xe2\xff\xa2^\xa0\x12\x14+\x16\\\xfc-\x0f\xf9\x95\x0c\x1d\xa2[\xb9\xe4\xa3\xd6\'\xbd\xf9\xaf\xda\x92\x07\xf2>Y\xa0\r\x03\xd1Q\xef\xaf\x8d\xe3\r\x05\xe9$\x03&\xac\x7f[:\xf5\xda2\xea\xd1\x00\xd8I\x9a\x7f%^\x1b>ld\x17\xfb]qV\x81\xf4 SP#\xafg\xe0\x14\xa4({R\x16$\x0b\x88\xc9\xa9\x0cGiiMk`\xd7K\x9b8\x89\xe3\xb5\x8e\x03\xda\xa1\xbb\xe05|W\x95\x7f\xea6\xdbxA\xe1^\x006\x952\xae\xa5\xa1w\x8f\xad\xa5\x7f\xcf\x85&q^\x07\xda\x991\xef\xf1\x01\xd8_.\xbd\x1c\xad\x9b:K\xf0\x83XM\xc1\xf7\x12\xb9Z\x89_\\\x1e\xaaud\x82.\xecK\xe9e\x0b\x8f_\xe9\xf8Q\x8dV\x18#\xa7\xd1\x96\xa8LKa\xb5\x1e\xbb_\x14l\x9d\x8a\xa6\xa3\xcei\x06\xd9W\x96\x904W\x04e\xcf\xda\xd4l\xcc\x04k\xf39f\x13\xbe\xc1e\x19\xb3\x81\x14\xd8\xa0\x06\x8e\x8a\xe0O>\x8d\x8a\xc9\xbd=7wm\xd34\xfd\x87\xa5\xea\xc0\x98&l\x01/\xd6\xb9\xcf3Nu\x0c\r\xb9\x98^~\xc2\xc9\xa0\xef9\'`Yo\x0bk\xf6\xb0\xd9/\x18\xb2\x9e\x99\xd2M\xa2\xc6\x9a{\x14\x90\xd3]\t\xda\xee\xb1\x9a\xa3\x19\x19\x8b\x1f\xdd\xa9\xcd\xca)\xd2d\x0e@\xdb\xe6\x10\x8bf\xc2\x19\x81\x1c h\xa4\xda\x07\xb2i\xa5cAU\xfd\x93\xb4\x82:\xc2>=\xb9\xf7$\x16\xbc\x95\t\x1a\x8c\x91_\x16 W\xa1t/\xdb\xa0\xaf\xb0\xad\xb6\xda\xf6\x9e\xb2\x057\xaf\x00\xb2Z\x8b\xe7\x17\x12\xa6\x9e\xaa\xedK\xa0_(\t;\xa0$\x07K\xbd\xf4\xa7\xe7\x85\x1b\xb0\xf4\x89.\xf6\xab\xe6\xee\xed\xa8\x10a\xad\x8b,\x87\x1eQ1\xd2\x82\xaa\xc0\x031\x00\x89\xe7\xfc\xd4du\"x\xf8\\9\xa2\x91X\xc9\xab\'8\xf8\xe4\xcb\x19\x13\xc6>n\xb8\x05;\x8e\x92\xd2[\x03{\x80\\(\x9b\xc6)\x07\xb2Q\xa3\xa1\xabf\xadE\xfb\xc9W\xe8|\xdd\x98s-ob\x83\xf4\\\xb4\x972J\x98p\xe2\xcf\xbeA80\x13T\xa1\x82\xc0\xf8\xbb\xa9C\x97\xa26\x7fTJq\x9b\x80d\x9d_\x17\x8a1\xe6\xac\x10G\xea\xb9q\x99E/\xf5dN#\x19m\xc0\x95\xe1|\xc1f\xf6\xbd\x9e\xea\x1a\xc5\xc2\x99^\x980~\xa5t\xa8\xaa\x1b\x0c\xa3\xfdU\xb2\xcf\xa9\x8b`!\x94\xd4\xfa\xae\xc3\x90\xb1\x19\x0c)\xe1\x15\xfd\xbae\x1c\xaew(\xe9\x1f8\r\xb7\xe5\xbb\xc3\xb9\x0f\x96Q\xfd\xff\xaeH\xcb2\xee\x87\xe0\xbd\x8e\xae\xc3\x02\xa5sa\xb9fe\x89*\xeb\x85F\xb9\'@_\x81l\x8a\xccV\xe8\t\xc6Q\xc7e~E\x83\xe0\xde\x1d4\x99\xc8\x83*\x0c\x03\xf9a\xadU\x83\xfa\xd3\x14\x97q\xc6\x194\x83G\x9f\x88\x89\xd7u\xd8b\xf2/\xf6]\x18\x8b\xb9\xe0@\xfd\x95E;WZ\xe5\xd4vjN\xe3\xc0\x9d\xbd[\xdb\xca\xfe\xe1b?Q!x\xe3R\xf1\xdd\xb3\x01/6<\xa2!\xd3\x8b\xc2\xda\t\xae\xb7T\xe6Z\xdf\x06H`g\xa5\x91\xef\xda\xf5Q\xa1=c\xd2*\x1b\xb3\xc5Z\x95/6L)\xe4\xea\xdf\"}\xaf\xd2\x11\xd7.y\xb1\n\xb08\xa1\x0e\x18|VQV?&=\xd7\xa5\xe24\x07\xf7d\xb9\xba(\xd4:\xbe\x02\x99\xc3\xe9?=L^\xb8\xa6\xe5\x17qc\xb9\x8c\xaa\x9e>dV\xd8TY@\xb4\xffd\x848)&\xa5\xe8\xf2Rt_x\x12d\xfe\x0c\x16\xa6Z6\xe1@\xea\xd0\t\xba[\xec\xa7\x8c\xa3F\x8d\x96\x0bD\xf8\xe9@\xdd]_\xba\xf2\x1c\x86\xd3\xa0ieqE&\x1f\xb3\xf4k\xa1\x15\x93)mh;\xc0\xa5 }=\xd8G\xe0\xdd\rs\x01w7\xec\xb3\xca \xf7\xe5XF#\x9f\xba\xd1\xde%\x82\x9c\xaf\xaf\xaf\n\x0fa\x8cu\xab\xc8\xf9\xa1\xfc\xcf\x94\x1fh;B\x84\x97\x92\xc2N\xdd\x94@\xb9n\xf2P\xca5\xba\xd0\x90\xac\xcf\xde\xd2\xe7d\x04\xe4\xaf\xe1\xd7Y \r\xd1\xa3\xd1\xb7\xb2\xe9g\x04\xb0\xb5xw\xb7x\x89\xaa%\xde\xa0\xa2lVu\xcb/\t9\xf0\xc0\x95\x07\xc3\xa9\xb2\x96\x1a\x86\xf5\xc8\xad\xd5se\xea,\x13Q\xe7\x1b\xd9\x8c\xdc\xd6\xd3\x89{5\xa5,b\xd1\xf8O\x16\xce\xe7\\\xb4d|\x14v~\xc9r!\x9a\x07\xd9\xe3\x87^\xffG;oy\trz\xe3\x99\xda\xa5\x041\xab\xa7H\xbff\x9c\xf7\n\x03Y\xb4\xf0\xeep;\xbe\xf0\x1bx\xdd\xe3\xd6\xa8\x11V\xb6\xef\x9a\x03\xd1w\xb0\xaf5F3+\x94\xf9l\xf4Q\xack\\\x18?\x86z\x81G\xa1u\xb8lfW\x0fBI\x1e\x17\xa9|\xf8\xf3.X\xba\x18\x96cO\xd1\x06M[~\x1e2\'?\xdf\x92\xf1\x03\xa9\x0c\xda\x1e\xcaE\xba\x9b\x92\x9aR\x0b\x81\xcac\xc6_\xb8MKv7\xefY+\x01[O\x999N\xbe`\xbaV\xc1{\x92xat|\x86\xb2|}\xd0\xd3\n\x9a\xb4Pm\xe5\xea\x94\x05x]\xd7;s\x00\xbf\xff\x82\x15\xb8D\x9f\x93\xfe\xb8$*y\x0bO\x84\x9a\n\xbc\xf0&\xa6s\xc1\xec\xf3;\x1b\xa2\x0cS\n\x08\xafX\x1c\xe4\x04\x95A|AN\xb8\x048\x91\x1d.\x88d\x176\x0f\xf4JE\xd7\xe8 W\xafJ\xca\xd8\x0b\x181\x0e\xeakA\xcb=\x9cR\xc6X\x14\x00\x1d\x10\x1f\n\x92u\xae\x9dO\xe2\x81\xd5\xcfv\xa1\x9b\xb3\x86$\x8a\x93\x93T\x1aeG\x85.\xc7\xf3\xf5J\xc62\x0e\xd9\x07\x19\xffb\x83\xe9T\x91\x85\xe9\xfbM\x8e\x11dl\x16a\xd3\x03\x9aG\x1f\xf9e\x8c\x00h}t\xcfG\xb4\xdd\xa9%\xa8\xcf!K\xbb\xb6e\xcc\xebc\x9d\xc0\x06W479H\xe0y\xa1_\x00q\x81\xb24\xfd\x192\xd1d\xe9\xc2\x00\xb7\x95\xaa3\xe4{K\xe9\x08\xcf\xad\xdf\xce\'\xf2\xfc\x11\x11\xc4D\x1b\x95\x17\x1a\xf4\xb7\xbf\x13\xf2-F\x8e\xc9(c\xa435\xf0\x95\x9b\x90v\xf7\x96\x02\xd9x0\xdb\xa0\xf6\xa9\x1d\x08T\xbfS[\x17%\xf7q\nj\xcc\x0b\xf7p\xc0$!\xad\xcf\x14<\xe6\xbdT}\x0f\xf0Z\xb0O\xad\xdb\xba\xafU\x8eBC\x076>\x85\xbeU\x96\xec\xb0\x0b4\x81\xf0&\xf4z\x10\x83\xad\xf1^i\xb7E\x8f$\x82\xcf\x85;6\x04p\x9e\x81~}\x14\x0e\xa0\x81\xcd\xc5\xbe\xc8\xec]\xc4h\x8de\x8b\x1d\x93G\xf6\xea>-\xeaw\x0e\x81\xe5*(\xd8\x06\x82\xbeI\x9d\x06\x95\x81:\xb6\xf2\xc4\xaf\xda\xaeI\xe7\r\x0fx\xc6G)\x10#[\xe3\xf1\x18}\x1a\x8e\xc4|\x8967\xc1v\x96\xc0YbFVC\xc5\xdc\x8d\x0e\xb6p\x9a]\x803]\xc2\x0e \x9f\xe4\x9ei)\x8a\xa7\x96-g2*\xe6\xcb\x18\xe4c!\x05\xf9*\x8f2\xb1\xac\xf7%xc,\xb0\x87p\xfd\x9b\xd4]/\x82\x9c\x16\x9f\xd9\xa6\x00:/CKHK\xf4\x10\xc6\x84<[|\xdc\'&8\x97\x12\xa6C\\\xa54np\x12>s*A\x89\xc64\xef{\x86\xa9\x11\xfd\xad\xf0s\x99i\x0bh?\x17\xecG\xc1\xb7m\x8a}\x04\x93\x7f\'\xd6\xaf\x030\x8eK7\xb9\xe7u+]\xa1\x16\x04\xbe\x90\xaa\xcd\xfaK^\xd6\xab6\xfb\xa9W~6(\xb9\xfa\"\xab]Y%\xe0\xf9O\xc1\x9e\x1bTH)\xb9\xcbU\xd3i\x80\x0f\\\xd1@`\x031pdR\x18\xa4\x08\x9f\xfb\xae\xe4\xbb/\xf0D\xc8o:j\xd8\xfaO&\x126\xd6UiD\xd8`k\xc6\xaf\x9b;\x98|\x1b\xf8\xa6\xd2J\xec\xc0\rt{r\x9b\x07\x96\xb3@zz\x96G}\x95\xce\x0c\xc8\x8cP@\xf2q\xca\x85.Z\x94\x8e\xa9\x04\xba|\t\xf4\x8b\xdc\x89\xbd\xd6\x98\xb4\x1d\xe3w\xcc)\xdc\xe7s\x8b\xf9\"y\x00\xf9.\x14H\xdf,\xd1\xc7\xcd\x8a\xea\xc2O\xa3\x1d\xb3\xcc\xd5\xe0*\x83sg\x04\xd4\xf1\xf8;o\xda5\x971Bb\xd51\x0e\xafe\xa1C\x15\xa0\x19\x1fc\x00\'$\xe9j<R!v\xeb\x14\xf9T\x11\xbf\xe1$\xdda\x15n\xe3\xafE\x15:h7\xe4\x92\x8b\x1b\xb6kI\x00\xd4c)\xf9a\xc5\xdd\xab\xa3\x9bJFt\xa1\xdeo\xac\x03\\s5\xa8\x98\x064,w\xe6\xf8\xcf\xd4\xec\rn\x12*2 ,\xb5\x0e\x1a\xff\xe8\x8e\x88`\xfe\x10%\xdf\x02%W1\xc7<fM\xcd\xad\x900y\xfaWP\xa5\xafz\xda\x12\x06`\x8b\xa7\xe4\x1c|MQ\tg\xe1\x9a\x8d\xb7\x0e\x8a\xaa\xee\x9f2\xd3\xd2\xefh\xa9\x1bhB\xc6\x1e@\x7f]j\xd8\x91\xf5\xb9\xf9\xaa\xe2Q\x83^3\n\x04\xa8\xbc\x98A\xa2D\xc9f&\xfd\x81\r:/\x0e\x1d\x80 \xf3\xfau\xe9\x87N\x9e!\x07j\x05\xcf1\xa8S\xf7\xff\xcbV5\x1a~\x91\x97\xcbq\xcd\xc5\x16i\xf0c\xb6\n\xbd\x84\x1e\xbcT\xa9\xad1\x98\x1e\xb0\xf3W\xe3\x87ESy\x9a \xbe\xe8\xa9\xf2\x94\x8d=,\xd2\xe8\xcf\xeb\xce-1\xef\xa4\"L\tX8\x1a\x18\x84[In9\xfba`mK\xaf\xc6\xda\xaa\xee8\xbeC\x9a\xd3\x94Ks\x16J\xef\xa2! \x0cY\x9cC\xa5\xa2\x11.\xf7/t\x95\xa2\xa3G\xc3Dj\xec3\xb6z\x00\xeb\xb8\x1f\xa9#\xc95\xd6TW\xc1P\xa5\xe3\x86\xce\x80\xd93\xea\xceO\x8c\xf5\x03\x01\xbd@\x13\x04R:\x8a\x86\x83\x01\xe83\xf8\xdd<v\x10\x9b\xb1\xaeJ\x93\x8b\xac\x8dk\x9cWz\x83`UI\xa3\xe2X7\xe8=\xc1<?\x93\xce\x1c\xdd\xcf\x9el\xc2\x96\x9c\xafM\x80\xa5\xb3\xb0\x8d\xda#4\xc2\xd8G\xc4\x866v\xb4Em\xc64RD\x88J2\xf9\xce8xe\x94,\xcb\x83Gfy\x92\xa3\nhb\xb3x\xf7_F\x8a{+M\x94c\xa0\x0b\xd5\xe99>]Y\xe1\xf0\x16\x9bf\xf2\x03\x7f\xda2\x1f\xc7L-\xa9\xd2NK\xda\xdb\x08\x80\\Z\xe3\xb3\xd6\xe9\xdb\xf7\x1akA\xf3C\xd9\nk\x95;\xee\xc4e\x8a\xa2\xa7m\x81\xc9\x9e\xc1\x1e\x1c\xee\x82k\x14l\xb0\xee\x94\n\x1c\xe2\x1f\x10\x16\x13\xc2?\x9d\xb1\xe9O\x9a\xefJ+\"\xce\x1f\xae\xc8=?f\xf2\x90\t\x11\x10\x9e\xd4\xee0h\r\xfd\t\xc6x\x9d/\xa7\xf2)\x83\xa4F\xc3A\xb8}\x8a\x1c\xb6\xc55E\x06\x0c \xfdP\xd6\xb6hO,(\xf0\xd3\x1a\xb8\xae*\x0f\xba\xa3&\xb4\xdd\xb3\x95#\x15\xac\x1f3\x9e\'-~\x94\xa4\x924_\xd7\x01\xa8\xb6\xea\xe0R\x87\xc4S:\x1f~\xf3\xf9Hx\x9d_\xbc\xe9\xe4\x8be\x93\x8b\xeb\xe3\x9e\xb56\x13\x95\xd7k\x0e]\x040\xa2=0\xbezx\"\xef\xfai/&6\xa6.\"4\x1dj\xa9\x82L%\xf6\x8ce\xa6\xf5\x15rP\x07\xf3\xef\x89\xddS\xdc\xf8\x89A\x19\x0e\xfd\x98\xebQ\xe4\xce\xd0\x89*\xf1Tg&\xf1\x1d\x96jyJ%IC\x1fYl\xb5\x07\x96\x1d|\x07\xc8\xdfF\xd3 \xfa&z\xe4\x1d\xf8\xac55O!#g\x1f*\xdc;\xe6\xb4\xc7\xf2\x0c\x91n\xe2\x13$^\xed!\xd8Z\xa2\xce\xed\xcf\x84\x0f\x80\x04%\xa0\xb4[\xbcx>\xa8@\x03\x93p`]\x83a\x05\xb2\x91\x8a({\x8e\xe4\x80\xf8\x99\x1c\xba\xba\x98\xa2\xf7|G\xb8}\xc7\xd2\x97fmW\xdb)\xed7#\xc1\xbb\x8e\xba\x9b\xd3q\x84q\xe5w3\xc47$\xe9;\xcb\x8f\xe6-\x15\x8f\xa4\x13+\x80HF\xee\xd9\xcc\x0f$0\xeaTz\x0e\xf5\xe8\xd9\xf8&\xc4Bs\x86\x84K8\x06\xa7{\x05\xb4\x08g\t\x11\xda\x11\xa14\xbf\xc0\xaf\xa0\x1a\xe6\xc2\xd4\xcf\xff\xb9mH\xc3\x98W\tX-\x9ao\x17\xd7\x12\x86\xd2\x1bQ\xe3hth\x1fJ\xb0\xaf,\t\xc2)\xba\xb4\xe2\xdf\xfc\t\xcc\xf1\xc9\xc7\xe7F\x06\t\x18$\xce\xfe>\xaa\xf2<\xf5\xb9\xdf!E\\\x7f\x14=\xd1\xde\xce\xdahD\xablB\xe3\x1d\xb5\x8d\x87\x82E\x9e\xa3\xdc\x19-\x06\xd6\xbd3^\xcd\xdf\xdd\xe5\x99\x03^`\x1c\xa1Q\xe6\xc0\xe0\xdao\x11Dlyy\xa9$1\xd6\x846M\xf4\x98\x9a(T\x82`Jk\xce\xeej}nCn=\"\xcf\xfb\xcf\xb0\xb5\x14\xb3\x19\xb1nx\x84s\x06\xe7\x11\xc4!\xd5\xca\x02\xa8\xe8\xf6\xac[\xc4\xd2\x87\xc9\x8f\xba[\xceU\x1f\xe51(d\xa2g\xa8{\xb7\xc1\xe6\x0b\xab\x8a\xc6\xcc&\xc28\xdc\xc5o_\xe0\xc9\xe6z\x890g\xb6\x9b\xdc\x0f\xbc\xb6\x94\x97\xd24\xf1L@\x10\x8e\xa7\xf89<\xb5\xff|\nsEO:\x04\xf8\xbf>\x1f\x88\xbd\x1dci \x94\xccn\xafLLRy=\xdfM\xe9\xc5\xea\x9a\xa3\x17\x1acF\xf8^\xac:N\xa2\xe4\x88L\xca\x8c\xf3\x92\xdde\xc4\x94\xe5\xbc\xdc<Y\xd1\'\x9fN\xff\x11\xab&\x05CAf*F\"\xe3\x97\x08I\xafz\xd25\x1aWB\xabs\x96\t\xc8)t\xb5\xc6H(\xdf2\x14) \xfat~\xe7\x0c?t\xd4?ha\xe2j\x89X\x9en\xbc\xb8\xfc5wT6\xc9\xe5\x81\xb6\xfc\xadc\x02\x11\xec^\xee\x80\xe3\xce\x8c\x97\xa5\x8b\xcd\x81X\xb8Q\xda:\xff&\xf0\x9c\"\xdf6\xdb\x04\xcc\xc2\x1b\xdf\xe5\x91]\xbb\x1d\x1b\xdc\x01\xf7\x05\x98s\xf4;\xde)\xc3\xf7=\xfa\x12\xde\x8e\xf8\xb9O\xf7\xe2\xe3H\x9e5\x11t\xc9D\x8cx*\x90\xf3\xd8\x86E\x04\xe2\x02:\x94\xd9\xf5s\x1bu\xc1\xcf4\xad\x84\x1cf<\x8f\x04W&\xf8\x94=\xe12s\xb15\".\xf95?\x0c\xb1\xfd\xad2\xc07f\x14x\xaa\x8e\xb3\xe5\xd7\x8ac\xfa\x90\xa8\xd7\xe1\xd2\x9e\xbex\xcc&\x01\xc5\x9e\x93\xa0\xdf\xef\xbf\xdb\x00\xf7v\x1c\xadf<\x08\x85\x90Zi=\x84`\xc8\re`\xacW\xdfnl\xc7\xe0\xe5|\xd12cv\xd2\x89xe\xe2V\xae>=\x03\xd9\xd7\x06\xe8K\xd8#\xd5\x17H\r\x13\x91\xced\xa4G\xe0\xe1~\xec$\xc7\xeb\xd5p}\x07E\xf9\x97\x16\xc9v\x8bAj\x91\xf7\x95z;}\xac-\xe2\x02%\x0b\xae]\x90\xd3\xad\t\xa5\xa7O\xb4\xeay\xcdF4W=\xbe\xbb\xcf\xe5\xdb\x10\xfe:W,^\xf4\x1a6\xa6\xa1r\xa6\xa9\x8c\tDXA|\xcb\x95[\xc1&\xe4\xfc{`%\xf3 \xc1\xb1 \r\xb4\x8a\xf2\x8cG\r\xe6\xe5L\x7f\xbd\x15\x92\nK\xea\x14\x17\xd9\xc74e>g\x17\xf5i\xad\x01\xf9I*R\x9d\x0b}\x17\xd2\x1cw\x96kj\xde\xe1\xce\xb5\xd2\x9bL_\xb80\x1d\xb8k!Q\xbdk\x91\x97\x8c_\xaa\x99i49\xb2p\xec\xe9s\xa9\\\xdb\xd9\x1a\xe2\xc4!\x00b\x8f\xceF\x88\x81\xe5\x1e\xbaU\x9b\x8e\xd8\x9a\xfa#\xcd]$\xd7\x11:-\xff\x9c\x9bv\xa4\x03\x8b\xa1\xb5__\xf0`\x8bWz\x16\x1dF\xfd\x90\x07\xf3\x13\xdft\xd2)\x9bXt$$\xd6u\xaf\xbf\x1ef;7\xc5\x99\x12\xa8\xa0K\xce\xa1\xfdfF\x01\xb6\x83_\xac\x96\xf9b\x88F\x01q]\x9f\x98^+\x01!\xe1\x1c\x0f\x14|%X\x84\xa5\'\xf3\xfb\x8e\x87F\rA\xc8H\xdc<\xc7|\xe2\xfd\x10i\x13X@\x8a\x9e\xf5\xd7\xc8\x1ao&eq\xd6\xed\x04e\xd1\r+\xa4n\xc4\xa4\n\x96\x08,P\xbc\xb3\n~w\xb8\x14\xbf\xb9EPO\x99\x82K\xa0&\xbf\x1d\xdd\r\x89c\x8a\x16\x06~\xd4\xe2\xb3\xc9\xf3\x85T C\xa5#\x98k\x11\x9ec\r\xf3/S`\x0fs?L\xf6R\xc5\xba\xf2\n\xf15\x0bz\x0b\x9bEC\x9b\x8c\x19{\xc35M\xd5y8\x8f\x88\xb8\n\xe8\x99\x8c\n\xa2\x15J\xfc\xc0\xc1\'\xf9\xfe\xd5\xe5\x92o\xf7\xf4\x1a\x0fi\xf3\x0cUO\x8a\xc2r\xc1\x1c\x99wl_:\xaa\x88\xdaa\xd4\xd30\xe9\xf7\xc2\x18\xb1\x7f\x90\xa9}\x1ewXD\xfd\x10\xaf\x13\xb6o\x1a\xb9\tL\x17\x0b0\xf9\xf6\xbf\x11\xe8\x1er\x84\xc1\xa5\xde\x80y\x05r\xa1\x91\xbf \x93\xea\x088q\x03\xa9\x01L\x14\x18\xb6]\x8c\xbe/\xb6!*Q\x10\xea=)\xfc\xe2\xf7\xb4\x8d\xaf.%X\x8a^\xed\x99\x03\xaa\xb7V\xeb\xab\xf4\xc17\x8c\x8fX\xb1\r\xda\x1bh\xb2>b\x94@\xabv\x8d\x04p\x96K>\x82\xc3\xfb\xd5t\x82\x98#\x84\x9d7\x16\xba\xeaca\x8cs{2w\x06\xca\xdc\xc6\xec\xefrr/;\n\x9b\xd8\xc0\x8e0\xd9$I\xa3u\xcd\xea\xbb*\x9aor\xe9\xc3\xf5-\xe7\x85\r\xed \x92\x93xn\xa7\xe2\xcf\xa34\x9f.\xfe\x7f\x92\xf67VT\'t\x86\xc1\xbd\xe2\xd8\t\xbd\xdb\x88\xf2s\x14F\x13\x943\x1bb\xe6\x95\xfc\x00\xe8\xfe;\x07\xd75c\x14Gy\xe6\xb6c\xf6\xff.\xe0\x02Y\x1a\xc81\xa7\xe2\x9c\xd0O\xff\xa4\x9d\x9bc\x07I\x14\xbe\xd4B#x\xe0\xe9\xa1\xd1nVs\xaeH#L*9\x99\xf7\xcc\xd1~\x1a{&H\xa6\xc57\x06\x08\x0f\xe3\xb7\x15ow\xe3\x1e\xa9\xf6j\xaf\xd9\xeen\xe5>\x07t\xc5\xbb8CR*\xd8\x06`\xfc\x98\xc5\xba\xf4\nF\xe7\xe2\xe0P\xdc\x1c\x15\xff\x04\x9e\x83\xbf6\x1de%\xdb\xc2\xff\x14\x1f8\xd4:/\x1d^,\xf9\xb8\x80T\xd1\x86I\x1f\n,\x9aU\xafa-\x00W~\x08\x03q\'+\xec2\x17\xfeg\x87\x16Vr\x05\x18\x8c(\xd2\xcb\x97\xec\x8d\xc4\xb4\x17\x02\x99~\xb2\xbc\x17\xa0\xa9\xe6\x1f\n\xcbR($eP\xab`R@L\x15\x8d\r.\xf9D/P\xf7\x0bO\x9f7\xb68|\xf0\x7f8\x84\x86[7\\\x12\xd0\x0b\xdfA\x98\xe7r\xd3\x0b\x109wK$\x0c}\x0e\xd9s}\x08\x8e\xd2\xdc*\x89\x9b)\x17\x81i`\xf2\xd2\xe9\x85B\xa8\x1e\x0b5\xea\xb8$>uy\x18I\xef\xf4\xb4\xe4\"\x97\x0c\x86\x1f\xb5VN$\n\xb8\xa2\xd6\xd9\x99\xa4\xe9\xb2\xa6Tr\x18\x0c\xf96\xe8\xd6\x83\xc8V\x16\x05\x81\xd2\xcd_\xb7(\xca\xfc\xa9k\xba\x009\xb2\xa6\xcf\xbe\x06\xfe\xa5\x1es\xa6\x89\x88t\x84Dk\xa5ho\xc6\xf9\xeeJ\xe8\x83\xc0\x90\xb4\x84g\xd3\x0e\xba,\x95\x00px\x90\x80\xe2\xb6N\xa4bE\x08\xef\xa0k\x98\x89\x06\x87\'h\xc3,\x1a\x7f\xf1\xcd2>\xae\xac\xe4e\xe5\xed,\xaaL\x05l\xab\xf1\xbc\xd4D\xc7S\xa9Z.\xa7\x07Xp{\xcd\xc6\xa2\x02\x0b\x8c\xcb0G2\x83`5\xc1{7\x86\xed\xdb\r?\xe8I\x02\x17\xad\xca\xfbq \x1eBNye\x84\x1f]\xf0\xedd\xc2#\x0c\x99\x80\xe2\xa5\xa4\xa3(Y\x03\xd6\x90\xc1\x9a\xacx\xaa\x92#]a\xaf\xbd$\xfa_\xf3\xe9\x11\x9d\xa3\xc2#\x96\xd9\x94\xef\xbbDl\xc1\x81\xd7\xb4\xba\xd4\x9dYc\x14\x08\xabh\x07\xeb\xc1=}\xfc\xe8UFg\xddn#\x0f5\xf0\x0f\xb4\xb9\x1a\xf4\xa4\xcc\x8e \xac\x02q\xfe\x95\x8f\xfdE\xa1\xe7\x89\xde\x90\xd3\x9d\x1b\xba\x87\x8a\xf7K\xd6\x0b>+t\xc5\xd3p,4m\x1e\x8d\xeb\xce&\x8a)\x98\x10\xfc{\xd4\x83\xb2\x14\xf7A\x85j\xd2_\xa8\x10>\xa5\x97ZG3\xcf\xd7\xfaR\xb9!^/\"\xf4g\xfeU\x00 \xeco46,-d\x8a\x17\xf2\xa6\x1a\xf5~\x18\xf4\xdd\x9dQ\x19src\\board\\zobrist.rs\x887\x10\x00\x14\x00\x00\x00\x1d\x00\x00\x00\x13\x00\x00\x00\x887\x10\x00\x14\x00\x00\x00!\x00\x00\x00\x13\x00\x00\x00\x887\x10\x00\x14\x00\x00\x00F\x00\x00\x00\t\x00\x00\x00\x00\x00\x00\x00attempt to calculate the remainder with a divisor of zero\x00\x00\x00\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x04\x04\x04\x04\x04\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x0c8\x10\x00\x00\x00\x00\x00\x0c8\x10\x00\x00\x00\x00\x00Invalid notationsrc\\board\\square.rs\x00,9\x10\x00\x13\x00\x00\x00W\x00\x00\x000\x00\x00\x00,9\x10\x00\x13\x00\x00\x00[\x00\x00\x00\x0e\x00\x00\x00,9\x10\x00\x13\x00\x00\x00]\x00\x00\x00\x0e\x00\x00\x00Once instance has previously been poisoned\x00\x00p9\x10\x00*\x00\x00\x00one-time initialization may not be performed recursively\xa49\x10\x008\x00\x00\x00called `Option::unwrap()` on a `None` value/rustc/07dca489ac2d933c78d3c5158e3f43beefeb02ce/library/std/src/sync/once.rs\x00\x0f:\x10\x00L\x00\x00\x00\xd0\x00\x00\x001\x00\x00\x00\x00\x00\x00\x00\xc1 \x00\x01\x80\x10\x00\x014\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x10\x01`@\x00@\x005\x00\x00\x00\x00\x00\x00\x00\x00\x10\x00\x00\x00\x00\x00\x00@\x00 \x10\x00\t\x00\x815\x00\x00\x00\x00\x00\x00\x00\x00\x18\x00\x00\x00\x00\x00\x00\x00\x01\x10DH \x00\x015\x00\x00\x00\x00\x00\x00\x00\x00 \x00\x00\x00\x00\x00\x00\x004\x02\x80\x01\x08\x80\xa05\x00\x00\x00\x00\x00\x00\x00\x00(\x00\x00\x00\x00\x00\x00(\x81\x10\x04\x00\x06\x00\x025\x00\x00\x00\x00\x00\x00\x00\x000\x00\x00\x00\x00\x00\x00\x82\x08\x01D\x10\x08\x00\x045\x00\x00\x00\x00\x00\x00\x00\x008\x00\x00\x00\x00\x00\x00\x00\x03\x80@ \x04\x80\x014\x00\x00\x00\x00\x00\x00\x00\x00@\x00\x00\x00\x00\x00\x00\x80 \x00@\x08\x80\x00\x005\x00\x00\x00\x00\x00\x00\x00\x00P\x00\x00\x00\x00\x00\x00\x00 \x00P\x00@/\x016\x00\x00\x00\x00\x00\x00\x00\x00X\x00\x00\x00\x00\x00\x00\x02 @\x00\x11\x00\x0bD6\x00\x00\x00\x00\x00\x00\x00\x00\\\x00\x00\x00\x00\x00\x00\x80\x00P\x01\x18\x80 \x006\x00\x00\x00\x00\x00\x00\x00\x00`\x00\x00\x00\x00\x00\x00\x00(\x00\x04\x80\x80\x00\x106\x00\x00\x00\x00\x00\x00\x00\x00d\x00\x00\x00\x00\x00\x00\x00\x02\x80\x00\x04\x80\x08\x806\x00\x00\x00\x00\x00\x00\x00\x00h\x00\x00\x00\x00\x00\x00\x002\x98\x0c\x01\x00\x02 6\x00\x00\x00\x00\x00\x00\x00\x00l\x00\x00\x00\x00\x00\x00\x80\x04\x00\xe1\x00\x80\x00\x105\x00\x00\x00\x00\x00\x00\x00\x00p\x00\x00\x00\x00\x00\x00(\x80P\x00\x80\x00@ 5\x00\x00\x00\x00\x00\x00\x00\x00x\x00\x00\x00\x00\x00\x00\x00 \x00\x10@@\x00@6\x00\x00\x00\x00\x00\x00\x00\x00\x80\x00\x00\x00\x00\x00\x00\x81@\x00\"\x00\x12\x00\x086\x00\x00\x00\x00\x00\x00\x00\x00\x84\x00\x00\x00\x00\x00\x00\x82\x10\x00\x08\x80\x00\x10\x006\x00\x00\x00\x00\x00\x00\x00\x00\x88\x00\x00\x00\x00\x00\x00\x00\x04\x00\x08\x80\x80\x00\x106\x00\x00\x00\x00\x00\x00\x00\x00\x8c\x00\x00\x00\x00\x00\x000@ \x04\x01\x08 @6\x00\x00\x00\x00\x00\x00\x00\x00\x90\x00\x00\x00\x00\x00\x00\x01(\n\x10\x00\x04\x00\x106\x00\x00\x00\x00\x00\x00\x00\x00\x94\x00\x00\x00\x00\x00\x00\x01\x84\xc0\x00\x00\"@D5\x00\x00\x00\x00\x00\x00\x00\x00\x98\x00\x00\x00\x00\x00\x00\x00\x80 \x80\x00@h\x005\x00\x00\x00\x00\x00\x00\x00\x00\xa0\x00\x00\x00\x00\x00\x00\x00\x10@@\x00\xe0\x00D6\x00\x00\x00\x00\x00\x00\x00\x00\xa8\x00\x00\x00\x00\x00\x00\x80\x00 \x80\x000\x00\x006\x00\x00\x00\x00\x00\x00\x00\x00\xac\x00\x00\x00\x00\x00\x00\"\x01\t\x00\x01\x10\x00\x006\x00\x00\x00\x00\x00\x00\x00\x00\xb0\x00\x00\x00\x00\x00\x00\x04\x00\x08\x00\x11\x00\x01\x026\x00\x00\x00\x00\x00\x00\x00\x00\xb4\x00\x00\x00\x00\x00\x00\x80\x00\x02\x80\x00DD\x886\x00\x00\x00\x00\x00\x00\x00\x00\xb8\x00\x00\x00\x00\x00\x00\x00\x02\x08\x02\x04\x10\x84\x006\x00\x00\x00\x00\x00\x00\x00\x00\xbc\x00\x00\x00\x00\x00\x00\x01\xa4\x04\x00B\x01\x04\x905\x00\x00\x00\x00\x00\x00\x00\x00\xc0\x00\x00\x00\x00\x00\x00\x80\x00\x80$\x00@\x00\x0c5\x00\x00\x00\x00\x00\x00\x00\x00\xc8\x00\x00\x00\x00\x00\x00\x00 @\x02\x10@\x00\x106\x00\x00\x00\x00\x00\x00\x00\x00\xd0\x00\x00\x00\x00\x00\x00\x000\x80\x01 \x84\x00`6\x00\x00\x00\x00\x00\x00\x00\x00\xd4\x00\x00\x00\x00\x00\x00\x02\x08\x80\x84\x00\x10\x00\x006\x00\x00\x00\x00\x00\x00\x00\x00\xd8\x00\x00\x00\x00\x00\x00\x01\x18\x80\x81\x00\x14\x14\x006\x00\x00\x00\x00\x00\x00\x00\x00\xdc\x00\x00\x00\x00\x00\x00\x00B\x80\x00\x04\x80@\x186\x00\x00\x00\x00\x00\x00\x00\x00\xe0\x00\x00\x00\x00\x00\x00\x02\x08\x00$\x01\x90\xa0\x006\x00\x00\x00\x00\x00\x00\x00\x00\xe4\x00\x00\x00\x00\x00\x00e\x10\x00\x82\x01\x14(\x805\x00\x00\x00\x00\x00\x00\x00\x00\xe8\x00\x00\x00\x00\x00\x00\x10\x80\x00@`\x80\x05\x005\x00\x00\x00\x00\x00\x00\x00\x00\xf0\x00\x00\x00\x00\x00\x00\x02@\x00 \x00P\x10\x026\x00\x00\x00\x00\x00\x00\x00\x00\xf8\x00\x00\x00\x00\x00\x00\x11\x00\x82$\xc0\x00\x06\x106\x00\x00\x00\x00\x00\x00\x00\x00\xfc\x00\x00\x00\x00\x00\x00\x18\x00B\x00\x12 !\x106\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x04\x002 \x88\x00B\x006\x00\x00\x00\x00\x00\x00\x00\x00\x04\x01\x00\x00\x00\x00\x00L\x80\x80\x00\x02\x00\x04D6\x00\x00\x00\x00\x00\x00\x00\x00\x08\x01\x00\x00\x00\x00\x00\x80\x80\x00\x01\x00\"\x00\x086\x00\x00\x00\x00\x00\x00\x00\x00\x0c\x01\x00\x00\x00\x00\x00#\x00\x02D\x80\x02\x80\x805\x00\x00\x00\x00\x00\x00\x00\x00\x10\x01\x00\x00\x00\x00\x00\x80H\x01\x80 \x00@\x025\x00\x00\x00\x00\x00\x00\x00\x00\x18\x01\x00\x00\x00\x00\x00@\x02@\x02\x10 \x00\x006\x00\x00\x00\x00\x00\x00\x00\x00 \x01\x00\x00\x00\x00\x00\x80\x81\x05`\x00\x10@\x886\x00\x00\x00\x00\x00\x00\x00\x00$\x01\x00\x00\x00\x00\x00\x00\x01\x10H\x00\xa1\x00\x006\x00\x00\x00\x00\x00\x00\x00\x00(\x01\x00\x00\x00\x00\x00\x00\x01\x01\x88\x10L\x05\x006\x00\x00\x00\x00\x00\x00\x00\x00,\x01\x00\x00\x00\x00\x00\x80\x00\x04\x00\x02\x81\x00\x006\x00\x00\x00\x00\x00\x00\x00\x000\x01\x00\x00\x00\x00\x00\x00\x02\x08\x04\x05\x00\x02\x086\x00\x00\x00\x00\x00\x00\x00\x004\x01\x00\x00\x00\x00\x00\x80A\x04\x00\x01\x80\x00\x015\x00\x00\x00\x00\x00\x00\x00\x008\x01\x00\x00\x00\x00\x00\"\x80\x18\x00\x01B)\x804\x00\x00\x00\x00\x00\x00\x00\x00@\x01\x00\x00\x00\x00\x00\x05@d\x10\x00\x81@\x015\x00\x00\x00\x00\x00\x00\x00\x00P\x01\x00\x00\x00\x00\x00B\x08\x82\x00\"\x10\x04\x005\x00\x00\x00\x00\x00\x00\x00\x00X\x01\x00\x00\x00\x00\x00\x01%\x00\x10\x88! \x005\x00\x00\x00\x00\x00\x00\x00\x00`\x01\x00\x00\x00\x00\x00B\x0c \x90\x18\x00\x1a\x025\x00\x00\x00\x00\x00\x00\x00\x00h\x01\x00\x00\x00\x00\x00\x82\x11\x08\x10\x04\x00\x02\x885\x00\x00\x00\x00\x00\x00\x00\x00p\x01\x00\x00\x00\x00\x00\x04\xc2\x00\x10\x03\xa8\x00\x005\x00\x00\x00\x00\x00\x00\x00\x00x\x01\x00\x00\x00\x00\x00\x82 \x00A\x00\x04\x00\x884\x00\x00\x00\x00\x00\x00\x00\x00\x80\x01\x00\x00\x00\x00\x00\x02\x82\x00\x84\x84H$\x00:\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00 \xa0\x00\x11\x04\x02 \x02;\x00\x00\x00\x00\x00\x00\x00@\x00\x00\x00\x00\x00\x00\x00\xe8\x00 \x88\x00\x040@;\x00\x00\x00\x00\x00\x00\x00`\x00\x00\x00\x00\x00\x00\x00\x10\x04\x00\x00\x81@\x82 ;\x00\x00\x00\x00\x00\x00\x00\x80\x00\x00\x00\x00\x00\x00\x00\x00\x02P\x00 \x04$X;\x00\x00\x00\x00\x00\x00\x00\xa0\x00\x00\x00\x00\x00\x00\x00\x18\xb0   \x82$\x80;\x00\x00\x00\x00\x00\x00\x00\xc0\x00\x00\x00\x00\x00\x00\x00\x00 < \x0c\x05B\x02;\x00\x00\x00\x00\x00\x00\x00\xe0\x00\x00\x00\x00\x00\x00\x00\x02\x04A\x04\x08B\x00\x08:\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00@\x00\x04\x10\x04\x10\x13@;\x00\x00\x00\x00\x00\x00\x00@\x01\x00\x00\x00\x00\x00\x00\x00\x01\x04\x07\x0c\x02\x19@;\x00\x00\x00\x00\x00\x00\x00`\x01\x00\x00\x00\x00\x00\x00\x04\x00A@A\x10\x02\x10;\x00\x00\x00\x00\x00\x00\x00\x80\x01\x00\x00\x00\x00\x00\x00\x00\x00\x80\x08\x04\x04\x00\x00;\x00\x00\x00\x00\x00\x00\x00\xa0\x01\x00\x00\x00\x00\x00\x00A\x80\x10@\x11\x01 \x00;\x00\x00\x00\x00\x00\x00\x00\xc0\x01\x00\x00\x00\x00\x00\x00\x00\x00\x06 \x04%\x00 ;\x00\x00\x00\x00\x00\x00\x00\xe0\x01\x00\x00\x00\x00\x00\x00\nB\x04\x88\x00\x05\xa0\x02;\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x08\x864\x02\n\x01\x00;\x00\x00\x00\x00\x00\x00\x00 \x02\x00\x00\x00\x00\x00\x00`\x02*\x12@\x00  ;\x00\x00\x00\x00\x00\x00\x00@\x02\x00\x00\x00\x00\x00\x00A$\xa5\x08\xa0\x00\x08\x00;\x00\x00\x00\x00\x00\x00\x00`\x02\x00\x00\x00\x00\x00\x00\x00\"\x02\x02\x08\x04I 9\x00\x00\x00\x00\x00\x00\x00\x80\x02\x00\x00\x00\x00\x00\x00\x00 \x02\"\x0c\x00H\x029\x00\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x00\x00\x00\x00\x00\xa0\x00$\x88\x08\x009\x00\x00\x00\x00\x00\x00\x00\x80\x03\x00\x00\x00\x00\x00\x00\x01 B\x01\x02B \x029\x00\x00\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00\x04\x08\x10\x0b\x82P\x10\x01;\x00\x00\x00\x00\x00\x00\x00\x80\x04\x00\x00\x00\x00\x00\x00\x01\x04\x88\x00Q1\x00\x80;\x00\x00\x00\x00\x00\x00\x00\xa0\x04\x00\x00\x00\x00\x00\x00RA\x08A\x02\x08\x10\x00;\x00\x00\x00\x00\x00\x00\x00\xc0\x04\x00\x00\x00\x00\x00\x00\x01\x03! \x08\x98(\x80;\x00\x00\x00\x00\x00\x00\x00\xe0\x04\x00\x00\x00\x00\x00\x00\x00,\x01\x04\x02\x02\x04\x089\x00\x00\x00\x00\x00\x00\x00\x00\x05\x00\x00\x00\x00\x00\x00\x02\x00\x02(\x80\x80\x02\x107\x00\x00\x00\x00\x00\x00\x00\x80\x05\x00\x00\x00\x00\x00\x00\x00@\x00AP\x00\x01\x017\x00\x00\x00\x00\x00\x00\x00\x80\x07\x00\x00\x00\x00\x00\x00\x00\x10\x10\t\x80\xc0\x00\x009\x00\x00\x00\x00\x00\x00\x00\x80\t\x00\x00\x00\x00\x00\x00\x04\x08\x01\x04P\x00b\x01;\x00\x00\x00\x00\x00\x00\x00\x00\n\x00\x00\x00\x00\x00\x00\x00\x06\x02\x02H@\x00\x89;\x00\x00\x00\x00\x00\x00\x00 \n\x00\x00\x00\x00\x00\x00\x00\x90\x120\x0c \x02B;\x00\x00\x00\x00\x00\x00\x00@\n\x00\x00\x00\x00\x00\x00\x04B\x10\x00*\x04h\x10;\x00\x00\x00\x00\x00\x00\x00`\n\x00\x00\x00\x00\x00\x00\xc0\x00\x10\x04\x88\x11\x00\x009\x00\x00\x00\x00\x00\x00\x00\x80\n\x00\x00\x00\x00\x00\x00\x80\x00(\x80\x02\x02\x18\x007\x00\x00\x00\x00\x00\x00\x00\x00\x0b\x00\x00\x00\x00\x00\x00@\x00\x01\x10\x01\t@\x017\x00\x00\x00\x00\x00\x00\x00\x00\r\x00\x00\x00\x00\x00\x00\x01$\x00@\x04\x08\xa0B9\x00\x00\x00\x00\x00\x00\x00\x00\x0f\x00\x00\x00\x00\x00\x00 \x84\x12@\x11*P\x04;\x00\x00\x00\x00\x00\x00\x00\x80\x0f\x00\x00\x00\x00\x00\x00\x006\x00\x80\x90\x008@;\x00\x00\x00\x00\x00\x00\x00\xa0\x0f\x00\x00\x00\x00\x00\x00@H\x00  \x84$\x80;\x00\x00\x00\x00\x00\x00\x00\xc0\x0f\x00\x00\x00\x00\x00\x00\x04 @\x04\x88\x00\x05\x08;\x00\x00\x00\x00\x00\x00\x00\xe0\x0f\x00\x00\x00\x00\x00\x00\x00\x10\x80(\xc0\x00\x81\x019\x00\x00\x00\x00\x00\x00\x00\x00\x10\x00\x00\x00\x00\x00\x00\x00\x18\x80\x00B\x00P\x109\x00\x00\x00\x00\x00\x00\x00\x80\x10\x00\x00\x00\x00\x00\x00\x00\x04\x02\x92\x08\x04\x00\x129\x00\x00\x00\x00\x00\x00\x00\x00\x11\x00\x00\x00\x00\x00\x00\x01\xe1 \x01\x04\x15@\x809\x00\x00\x00\x00\x00\x00\x00\x80\x11\x00\x00\x00\x00\x00\x00\x00!\x92\x00\x08\x18\n\x00;\x00\x00\x00\x00\x00\x00\x00\x00\x12\x00\x00\x00\x00\x00\x00D\x10\x00\n\x99\x00\x08(;\x00\x00\x00\x00\x00\x00\x00 \x12\x00\x00\x00\x00\x00\x00\x00\x00\x18\x10\x03\x08\x01\x00;\x00\x00\x00\x00\x00\x00\x00@\x12\x00\x00\x00\x00\x00\x00 \x00\x10\x04H\xc1\x01\x02;\x00\x00\x00\x00\x00\x00\x00`\x12\x00\x00\x00\x00\x00\x00\x01\x00\x10\x01\"\x00\x10 ;\x00\x00\x00\x00\x00\x00\x00\x80\x12\x00\x00\x00\x00\x00\x00\x04\x00\x1aB\x04\x00\x88X;\x00\x00\x00\x00\x00\x00\x00\xa0\x12\x00\x00\x00\x00\x00\x00\x00\x00\x06\x02\x10\x010\x00;\x00\x00\x00\x00\x00\x00\x00\xc0\x12\x00\x00\x00\x00\x00\x00!\x01\x1aH\x13\x08\x00\x00;\x00\x00\x00\x00\x00\x00\x00\xe0\x12\x00\x00\x00\x00\x00\x00\x00@\x10\x01\x10\x08 (;\x00\x00\x00\x00\x00\x00\x00\x00\x13\x00\x00\x00\x00\x00\x00 \x80\x00\xa4\x10\x08\x14\x00;\x00\x00\x00\x00\x00\x00\x00 \x13\x00\x00\x00\x00\x00\x00\x00\x02\x04\x84\x00\x04\x05\x00:\x00\x00\x00\x00\x00\x00\x00@\x13\x00\x00\x00\x00\x00\x00\x00\x02\x06\x0c\x84\x10\x8c\x00;\x00\x00\x00\x00\x00\x00\x00\x80\x13\x00\x00\x00\x00\x00\x00\x04\t\x1a\x04\x01\x04@ ;\x00\x00\x00\x00\x00\x00\x00\xa0\x13\x00\x00\x00\x00\x00\x00\x00\x02B(\x02\x00\x00\x00;\x00\x00\x00\x00\x00\x00\x00\xc0\x13\x00\x00\x00\x00\x00\x00\x00\x02\x82\x90\x88\x01\x00\x00;\x00\x00\x00\x00\x00\x00\x00\xe0\x13\x00\x00\x00\x00\x00\x00\x02\x02!\x10H\x00 \x00;\x00\x00\x00\x00\x00\x00\x00\x00\x14\x00\x00\x00\x00\x00\x00@\x00\x01\x88\xa0\x10\x04\xa1;\x00\x00\x00\x00\x00\x00\x00 \x14\x00\x00\x00\x00\x00\x00\x00\x82\x04\x92\x00\x90\x14`:\x00\x00\x00\x00\x00\x00\x00@\x14\x00\x00\x00\x00\x00\x00/rustc/07dca489ac2d933c78d3c5158e3f43beefeb02ce/library/std/src/sync/once.rspF\x10\x00L\x00\x00\x00\xd0\x00\x00\x00\x14\x00\x00\x00R\x00\x00\x00R\x00\x00\x00R\x00\x00\x00R\x00\x00\x00R\x00\x00\x00R\x00\x00\x00R\x00\x00\x00R\x00\x00\x00\xb4\x00\x00\x00\xd8\x00\x00\x00\x8f\x00\x00\x00\xb1\x00\x00\x00\x96\x00\x00\x00\xd0\x00\x00\x00t\x00\x00\x00G\x00\x00\x00L\x00\x00\x00Y\x00\x00\x00l\x00\x00\x00q\x00\x00\x00\x93\x00\x00\x00\x8a\x00\x00\x00k\x00\x00\x00>\x00\x00\x00D\x00\x00\x00_\x00\x00\x00X\x00\x00\x00g\x00\x00\x00i\x00\x00\x00^\x00\x00\x00c\x00\x00\x00;\x00\x00\x007\x00\x00\x00P\x00\x00\x00M\x00\x00\x00^\x00\x00\x00c\x00\x00\x00X\x00\x00\x00\\\x00\x00\x009\x00\x00\x008\x00\x00\x00N\x00\x00\x00N\x00\x00\x00H\x00\x00\x00U\x00\x00\x00U\x00\x00\x00s\x00\x00\x00F\x00\x00\x00/\x00\x00\x00Q\x00\x00\x00>\x00\x00\x00;\x00\x00\x00C\x00\x00\x00j\x00\x00\x00x\x00\x00\x00<\x00\x00\x00R\x00\x00\x00R\x00\x00\x00R\x00\x00\x00R\x00\x00\x00R\x00\x00\x00R\x00\x00\x00R\x00\x00\x00R\x00\x00\x00\xaa\x00\x00\x00\xf8\x00\x00\x00/\x01\x00\x00 \x01\x00\x00\x8e\x01\x00\x00\xf0\x00\x00\x00B\x01\x00\x00\xe6\x00\x00\x00\x08\x01\x00\x00(\x01\x00\x00\x99\x01\x00\x00u\x01\x00\x00h\x01\x00\x00\x8f\x01\x00\x00X\x01\x00\x00@\x01\x00\x00\"\x01\x00\x00\x8d\x01\x00\x00v\x01\x00\x00\x92\x01\x00\x00\xa5\x01\x00\x00\xd2\x01\x00\x00\x9a\x01\x00\x00}\x01\x00\x00H\x01\x00\x00b\x01\x00\x00d\x01\x00\x00\x86\x01\x00\x00v\x01\x00\x00\x96\x01\x00\x00c\x01\x00\x00g\x01\x00\x00D\x01\x00\x00U\x01\x00\x00a\x01\x00\x00^\x01\x00\x00m\x01\x00\x00d\x01\x00\x00f\x01\x00\x00I\x01\x00\x00:\x01\x00\x00H\x01\x00\x00]\x01\x00\x00[\x01\x00\x00d\x01\x00\x00b\x01\x00\x00j\x01\x00\x00A\x01\x00\x004\x01\x00\x00\x1c\x01\x00\x00E\x01\x00\x00N\x01\x00\x00P\x01\x00\x00c\x01\x00\x00C\x01\x00\x00>\x01\x00\x00\xe8\x00\x00\x00<\x01\x00\x00\x17\x01\x00\x000\x01\x00\x00@\x01\x00\x005\x01\x00\x00>\x01\x00\x00:\x01\x00\x00P\x01\x00\x00q\x01\x00\x00\x1b\x01\x00\x00H\x01\x00\x00T\x01\x00\x00C\x01\x00\x00t\x01\x00\x00e\x01\x00\x00S\x01\x00\x00}\x01\x00\x00[\x01\x00\x00`\x01\x00\x00\x8b\x01\x00\x00\xa8\x01\x00\x00\x7f\x01\x00\x00>\x01\x00\x00]\x01\x00\x00\x92\x01\x00\x00\x98\x01\x00\x00\x95\x01\x00\x00\x90\x01\x00\x00\x9f\x01\x00\x00\x92\x01\x00\x00k\x01\x00\x00i\x01\x00\x00r\x01\x00\x00\x80\x01\x00\x00\x9f\x01\x00\x00\x92\x01\x00\x00\x92\x01\x00\x00t\x01\x00\x00k\x01\x00\x00g\x01\x00\x00z\x01\x00\x00z\x01\x00\x00\x87\x01\x00\x00\x8f\x01\x00\x00y\x01\x00\x00w\x01\x00\x00q\x01\x00\x00m\x01\x00\x00|\x01\x00\x00|\x01\x00\x00|\x01\x00\x00{\x01\x00\x00\x88\x01\x00\x00\x7f\x01\x00\x00w\x01\x00\x00q\x01\x00\x00|\x01\x00\x00}\x01\x00\x00m\x01\x00\x00t\x01\x00\x00\x82\x01\x00\x00\x8e\x01\x00\x00n\x01\x00\x00L\x01\x00\x00j\x01\x00\x00_\x01\x00\x00X\x01\x00\x00`\x01\x00\x00a\x01\x00\x00F\x01\x00\x00X\x01\x00\x00\xfd\x01\x00\x00\x07\x02\x00\x00\xfd\x01\x00\x00\x10\x02\x00\x00\x1c\x02\x00\x00\xe6\x01\x00\x00\xfc\x01\x00\x00\x08\x02\x00\x00\xf8\x01\x00\x00\xfd\x01\x00\x00\x17\x02\x00\x00\x1b\x02\x00\x00-\x02\x00\x00 \x02\x00\x00\xf7\x01\x00\x00\t\x02\x00\x00\xd8\x01\x00\x00\xf0\x01\x00\x00\xf7\x01\x00\x00\x01\x02\x00\x00\xee\x01\x00\x00\n\x02\x00\x00\x1a\x02\x00\x00\xed\x01\x00\x00\xc5\x01\x00\x00\xd2\x01\x00\x00\xe4\x01\x00\x00\xf7\x01\x00\x00\xf5\x01\x00\x00\x00\x02\x00\x00\xd5\x01\x00\x00\xc9\x01\x00\x00\xb9\x01\x00\x00\xc3\x01\x00\x00\xd1\x01\x00\x00\xdc\x01\x00\x00\xe6\x01\x00\x00\xd6\x01\x00\x00\xe3\x01\x00\x00\xc6\x01\x00\x00\xb0\x01\x00\x00\xc4\x01\x00\x00\xcd\x01\x00\x00\xcc\x01\x00\x00\xe0\x01\x00\x00\xdd\x01\x00\x00\xd8\x01\x00\x00\xbc\x01\x00\x00\xb1\x01\x00\x00\xcd\x01\x00\x00\xc9\x01\x00\x00\xd4\x01\x00\x00\xdc\x01\x00\x00\xe8\x01\x00\x00\xd7\x01\x00\x00\x96\x01\x00\x00\xca\x01\x00\x00\xd0\x01\x00\x00\xde\x01\x00\x00\xee\x01\x00\x00\xed\x01\x00\x00\xe4\x01\x00\x00\xb8\x01\x00\x00\xc3\x01\x00\x00\xe5\x03\x00\x00\x01\x04\x00\x00\x1e\x04\x00\x00\r\x04\x00\x00<\x04\x00\x00-\x04\x00\x00,\x04\x00\x00.\x04\x00\x00\xe9\x03\x00\x00\xda\x03\x00\x00\xfc\x03\x00\x00\x02\x04\x00\x00\xf1\x03\x00\x00:\x04\x00\x00\x1d\x04\x00\x007\x04\x00\x00\xf4\x03\x00\x00\xf0\x03\x00\x00\x08\x04\x00\x00\t\x04\x00\x00\x1e\x04\x00\x009\x04\x00\x000\x04\x00\x00:\x04\x00\x00\xe6\x03\x00\x00\xe6\x03\x00\x00\xf1\x03\x00\x00\xf1\x03\x00\x00\x00\x04\x00\x00\x12\x04\x00\x00\xff\x03\x00\x00\x02\x04\x00\x00\xf8\x03\x00\x00\xe7\x03\x00\x00\xf8\x03\x00\x00\xf7\x03\x00\x00\xff\x03\x00\x00\xfd\x03\x00\x00\x04\x04\x00\x00\xfe\x03\x00\x00\xf3\x03\x00\x00\x03\x04\x00\x00\xf6\x03\x00\x00\xff\x03\x00\x00\xfc\x03\x00\x00\x03\x04\x00\x00\x0f\x04\x00\x00\x06\x04\x00\x00\xde\x03\x00\x00\xf9\x03\x00\x00\x0c\x04\x00\x00\x03\x04\x00\x00\t\x04\x00\x00\x10\x04\x00\x00\xfe\x03\x00\x00\x02\x04\x00\x00\x00\x04\x00\x00\xef\x03\x00\x00\xf8\x03\x00\x00\x0b\x04\x00\x00\xf2\x03\x00\x00\xe8\x03\x00\x00\xe2\x03\x00\x00\xcf\x03\x00\x00\xbf\xff\xff\xff\x17\x00\x00\x00\x10\x00\x00\x00\xf1\xff\xff\xff\xc8\xff\xff\xff\xde\xff\xff\xff\x02\x00\x00\x00\r\x00\x00\x00\x1d\x00\x00\x00\xff\xff\xff\xff\xec\xff\xff\xff\xf9\xff\xff\xff\xf8\xff\xff\xff\xfc\xff\xff\xff\xda\xff\xff\xff\xe3\xff\xff\xff\xf7\xff\xff\xff\x18\x00\x00\x00\x02\x00\x00\x00\xf0\xff\xff\xff\xec\xff\xff\xff\x06\x00\x00\x00\x16\x00\x00\x00\xea\xff\xff\xff\xef\xff\xff\xff\xec\xff\xff\xff\xf4\xff\xff\xff\xe5\xff\xff\xff\xe2\xff\xff\xff\xe7\xff\xff\xff\xf2\xff\xff\xff\xdc\xff\xff\xff\xcf\xff\xff\xff\xff\xff\xff\xff\xe5\xff\xff\xff\xd9\xff\xff\xff\xd2\xff\xff\xff\xd4\xff\xff\xff\xdf\xff\xff\xff\xcd\xff\xff\xff\xf2\xff\xff\xff\xf2\xff\xff\xff\xea\xff\xff\xff\xd2\xff\xff\xff\xd4\xff\xff\xff\xe2\xff\xff\xff\xf1\xff\xff\xff\xe5\xff\xff\xff\x01\x00\x00\x00\x07\x00\x00\x00\xf8\xff\xff\xff\xc0\xff\xff\xff\xd5\xff\xff\xff\xf0\xff\xff\xff\t\x00\x00\x00\x08\x00\x00\x00\xf1\xff\xff\xff$\x00\x00\x00\x0c\x00\x00\x00\xca\xff\xff\xff\x08\x00\x00\x00\xe4\xff\xff\xff\x18\x00\x00\x00\x0e\x00\x00\x00^\x00\x00\x00^\x00\x00\x00^\x00\x00\x00^\x00\x00\x00^\x00\x00\x00^\x00\x00\x00^\x00\x00\x00^\x00\x00\x00\x10\x01\x00\x00\x0b\x01\x00\x00\xfc\x00\x00\x00\xe4\x00\x00\x00\xf1\x00\x00\x00\xe2\x00\x00\x00\x03\x01\x00\x00\x19\x01\x00\x00\xbc\x00\x00\x00\xc2\x00\x00\x00\xb3\x00\x00\x00\xa1\x00\x00\x00\x96\x00\x00\x00\x93\x00\x00\x00\xb0\x00\x00\x00\xb2\x00\x00\x00~\x00\x00\x00v\x00\x00\x00k\x00\x00\x00c\x00\x00\x00\\\x00\x00\x00b\x00\x00\x00o\x00\x00\x00o\x00\x00\x00k\x00\x00\x00g\x00\x00\x00[\x00\x00\x00W\x00\x00\x00W\x00\x00\x00V\x00\x00\x00a\x00\x00\x00]\x00\x00\x00b\x00\x00\x00e\x00\x00\x00X\x00\x00\x00_\x00\x00\x00^\x00\x00\x00Y\x00\x00\x00]\x00\x00\x00V\x00\x00\x00k\x00\x00\x00f\x00\x00\x00f\x00\x00\x00h\x00\x00\x00k\x00\x00\x00^\x00\x00\x00`\x00\x00\x00W\x00\x00\x00^\x00\x00\x00^\x00\x00\x00^\x00\x00\x00^\x00\x00\x00^\x00\x00\x00^\x00\x00\x00^\x00\x00\x00^\x00\x00\x00\xdf\x00\x00\x00\xf3\x00\x00\x00\x0c\x01\x00\x00\xfd\x00\x00\x00\xfa\x00\x00\x00\xfe\x00\x00\x00\xda\x00\x00\x00\xb6\x00\x00\x00\x00\x01\x00\x00\x11\x01\x00\x00\x00\x01\x00\x00\x17\x01\x00\x00\x10\x01\x00\x00\x00\x01\x00\x00\x01\x01\x00\x00\xe5\x00\x00\x00\x01\x01\x00\x00\x05\x01\x00\x00#\x01\x00\x00\"\x01\x00\x00\x18\x01\x00\x00\x10\x01\x00\x00\x06\x01\x00\x00\xf0\x00\x00\x00\x08\x01\x00\x00\x1c\x01\x00\x00/\x01\x00\x00/\x01\x00\x00/\x01\x00\x00$\x01\x00\x00!\x01\x00\x00\x07\x01\x00\x00\x07\x01\x00\x00\x13\x01\x00\x00)\x01\x00\x002\x01\x00\x00)\x01\x00\x00*\x01\x00\x00\x1d\x01\x00\x00\x07\x01\x00\x00\x02\x01\x00\x00\x16\x01\x00\x00\x18\x01\x00\x00(\x01\x00\x00#\x01\x00\x00\x16\x01\x00\x00\x05\x01\x00\x00\x03\x01\x00\x00\xef\x00\x00\x00\x05\x01\x00\x00\x0f\x01\x00\x00\x14\x01\x00\x00\x17\x01\x00\x00\x05\x01\x00\x00\x02\x01\x00\x00\xed\x00\x00\x00\xfc\x00\x00\x00\xe6\x00\x00\x00\x02\x01\x00\x00\n\x01\x00\x00\x03\x01\x00\x00\x07\x01\x00\x00\xe7\x00\x00\x00\xd9\x00\x00\x00\x1b\x01\x00\x00\x14\x01\x00\x00\x1e\x01\x00\x00!\x01\x00\x00\"\x01\x00\x00 \x01\x00\x00\x18\x01\x00\x00\x11\x01\x00\x00!\x01\x00\x00%\x01\x00\x000\x01\x00\x00\x1d\x01\x00\x00&\x01\x00\x00\x1c\x01\x00\x00%\x01\x00\x00\x1b\x01\x00\x00+\x01\x00\x00!\x01\x00\x00)\x01\x00\x00(\x01\x00\x00\'\x01\x00\x00/\x01\x00\x00)\x01\x00\x00-\x01\x00\x00&\x01\x00\x002\x01\x00\x005\x01\x00\x002\x01\x00\x007\x01\x00\x003\x01\x00\x00,\x01\x00\x00+\x01\x00\x00#\x01\x00\x00,\x01\x00\x006\x01\x00\x00<\x01\x00\x000\x01\x00\x003\x01\x00\x00&\x01\x00\x00 \x01\x00\x00\x1d\x01\x00\x00&\x01\x00\x001\x01\x00\x003\x01\x00\x006\x01\x00\x00,\x01\x00\x00\"\x01\x00\x00\x1a\x01\x00\x00\x1b\x01\x00\x00\x17\x01\x00\x00\"\x01\x00\x00(\x01\x00\x00-\x01\x00\x00 \x01\x00\x00\x1a\x01\x00\x00\x0e\x01\x00\x00\x12\x01\x00\x00 \x01\x00\x00\x12\x01\x00\x00$\x01\x00\x00 \x01\x00\x00\x19\x01\x00\x00$\x01\x00\x00\x18\x01\x00\x00\r\x02\x00\x00\n\x02\x00\x00\x12\x02\x00\x00\x0f\x02\x00\x00\x0c\x02\x00\x00\x0c\x02\x00\x00\x08\x02\x00\x00\x05\x02\x00\x00\x0b\x02\x00\x00\r\x02\x00\x00\r\x02\x00\x00\x0b\x02\x00\x00\xfd\x01\x00\x00\x03\x02\x00\x00\x08\x02\x00\x00\x03\x02\x00\x00\x07\x02\x00\x00\x07\x02\x00\x00\x07\x02\x00\x00\x05\x02\x00\x00\x04\x02\x00\x00\xfd\x01\x00\x00\xfb\x01\x00\x00\xfd\x01\x00\x00\x04\x02\x00\x00\x03\x02\x00\x00\r\x02\x00\x00\x01\x02\x00\x00\x02\x02\x00\x00\x01\x02\x00\x00\xff\x01\x00\x00\x02\x02\x00\x00\x03\x02\x00\x00\x05\x02\x00\x00\x08\x02\x00\x00\x04\x02\x00\x00\xfb\x01\x00\x00\xfa\x01\x00\x00\xf8\x01\x00\x00\xf5\x01\x00\x00\xfc\x01\x00\x00\x00\x02\x00\x00\xfb\x01\x00\x00\xff\x01\x00\x00\xf9\x01\x00\x00\xf4\x01\x00\x00\xf8\x01\x00\x00\xf0\x01\x00\x00\xfa\x01\x00\x00\xfa\x01\x00\x00\x00\x02\x00\x00\x02\x02\x00\x00\xf7\x01\x00\x00\xf7\x01\x00\x00\xf5\x01\x00\x00\xfd\x01\x00\x00\xf7\x01\x00\x00\x02\x02\x00\x00\x03\x02\x00\x00\xff\x01\x00\x00\xfb\x01\x00\x00\xf3\x01\x00\x00\x04\x02\x00\x00\xec\x01\x00\x00\x9f\x03\x00\x00\xbe\x03\x00\x00\xbe\x03\x00\x00\xc3\x03\x00\x00\xc3\x03\x00\x00\xbb\x03\x00\x00\xb2\x03\x00\x00\xbc\x03\x00\x00\x97\x03\x00\x00\xbc\x03\x00\x00\xc8\x03\x00\x00\xd1\x03\x00\x00\xe2\x03\x00\x00\xc1\x03\x00\x00\xc6\x03\x00\x00\xa8\x03\x00\x00\x94\x03\x00\x00\xae\x03\x00\x00\xb1\x03\x00\x00\xd9\x03\x00\x00\xd7\x03\x00\x00\xcb\x03\x00\x00\xbb\x03\x00\x00\xb1\x03\x00\x00\xab\x03\x00\x00\xbe\x03\x00\x00\xc0\x03\x00\x00\xd5\x03\x00\x00\xe1\x03\x00\x00\xd0\x03\x00\x00\xe1\x03\x00\x00\xcc\x03\x00\x00\x96\x03\x00\x00\xc4\x03\x00\x00\xbb\x03\x00\x00\xd7\x03\x00\x00\xc7\x03\x00\x00\xca\x03\x00\x00\xcf\x03\x00\x00\xbf\x03\x00\x00\x98\x03\x00\x00\x8d\x03\x00\x00\xb7\x03\x00\x00\xae\x03\x00\x00\xb1\x03\x00\x00\xb9\x03\x00\x00\xb2\x03\x00\x00\xad\x03\x00\x00\x92\x03\x00\x00\x91\x03\x00\x00\x8a\x03\x00\x00\x98\x03\x00\x00\x98\x03\x00\x00\x91\x03\x00\x00\x84\x03\x00\x00\x88\x03\x00\x00\x87\x03\x00\x00\x8c\x03\x00\x00\x92\x03\x00\x00}\x03\x00\x00\xa3\x03\x00\x00\x88\x03\x00\x00\x94\x03\x00\x00\x7f\x03\x00\x00\xb6\xff\xff\xff\xdd\xff\xff\xff\xee\xff\xff\xff\xee\xff\xff\xff\xf5\xff\xff\xff\x0f\x00\x00\x00\x04\x00\x00\x00\xef\xff\xff\xff\xf4\xff\xff\xff\x11\x00\x00\x00\x0e\x00\x00\x00\x11\x00\x00\x00\x11\x00\x00\x00&\x00\x00\x00\x17\x00\x00\x00\x0b\x00\x00\x00\n\x00\x00\x00\x11\x00\x00\x00\x17\x00\x00\x00\x0f\x00\x00\x00\x14\x00\x00\x00-\x00\x00\x00,\x00\x00\x00\r\x00\x00\x00\xf8\xff\xff\xff\x16\x00\x00\x00\x18\x00\x00\x00\x1b\x00\x00\x00\x1a\x00\x00\x00!\x00\x00\x00\x1a\x00\x00\x00\x03\x00\x00\x00\xee\xff\xff\xff\xfc\xff\xff\xff\x15\x00\x00\x00\x18\x00\x00\x00\x1b\x00\x00\x00\x17\x00\x00\x00\t\x00\x00\x00\xf5\xff\xff\xff\xed\xff\xff\xff\xfd\xff\xff\xff\x0b\x00\x00\x00\x15\x00\x00\x00\x17\x00\x00\x00\x10\x00\x00\x00\x07\x00\x00\x00\xf7\xff\xff\xff\xe5\xff\xff\xff\xf5\xff\xff\xff\x04\x00\x00\x00\r\x00\x00\x00\x0e\x00\x00\x00\x04\x00\x00\x00\xfb\xff\xff\xff\xef\xff\xff\xff\xcb\xff\xff\xff\xde\xff\xff\xff\xeb\xff\xff\xff\xf5\xff\xff\xff\xe4\xff\xff\xff\xf2\xff\xff\xff\xe8\xff\xff\xff\xd5\xff\xff\xffEmptyInvalidDigitPosOverflowNegOverflowZero\x00\'\x00\x00\x00\x0c\x00\x00\x00\x04\x00\x00\x00(\x00\x00\x00)\x00\x00\x00\'\x00\x00\x00\x10\x00\x00\x00\x04\x00\x00\x00*\x00\x00\x00+\x00\x00\x00: 1\x00\xccR\x10\x00\x00\x00\x00\x00 S\x10\x00\x03\x00\x00\x00: \x00\x00\xccR\x10\x00\x00\x00\x00\x004S\x10\x00\x02\x00\x00\x00src\\search\\encoded_move.rs\x00\x00HS\x10\x00\x1a\x00\x00\x00,\x00\x00\x00\n\x00\x00\x00\x00\x01\x02\x03\x04\x05\x06\x07src\\search\\move_ordering.rs\x00|S\x10\x00\x1b\x00\x00\x00/\x00\x00\x00\x18\x00\x00\x00called `Option::unwrap()` on a `None` value\x00|S\x10\x00\x1b\x00\x00\x00@\x00\x00\x00H\x00\x00\x00d\x00\x00\x00,\x01\x00\x00@\x01\x00\x00\xf4\x01\x00\x00\x84\x03\x00\x00\x00\x00\x00\x00d\x00\x00\x00,\x01\x00\x00@\x01\x00\x00\xf4\x01\x00\x00\x84\x03\x00\x00\x00\x00\x00\x00|S\x10\x00\x1b\x00\x00\x00R\x00\x00\x00\x16\x00\x00\x00|S\x10\x00\x1b\x00\x00\x004\x00\x00\x00\x18\x00\x00\x00|S\x10\x00\x1b\x00\x00\x00a\x00\x00\x00#\x00\x00\x00|S\x10\x00\x1b\x00\x00\x00j\x00\x00\x00\x1a\x00\x00\x00|S\x10\x00\x1b\x00\x00\x00\x80\x00\x00\x00H\x00\x00\x00|S\x10\x00\x1b\x00\x00\x00\x81\x00\x00\x00@\x00\x00\x00internal error: entered unreachable code|S\x10\x00\x1b\x00\x00\x00z\x00\x00\x00\x12\x00\x00\x00\'\x00\x00\x00\x0c\x00\x00\x00\x04\x00\x00\x00,\x00\x00\x00-\x00\x00\x00|S\x10\x00\x1b\x00\x00\x00\x94\x00\x00\x00\x11\x00\x00\x00\'\x00\x00\x00\x18\x00\x00\x00\x04\x00\x00\x00.\x00\x00\x00/\x00\x00\x00|S\x10\x00\x1b\x00\x00\x00\xae\x00\x00\x00\x11\x00\x00\x00\x05\x00\x00\x00\x0c\x00\x00\x00\x0b\x00\x00\x00\x0b\x00\x00\x00\x04\x00\x00\x00\xccR\x10\x00\xd1R\x10\x00\xddR\x10\x00\xe8R\x10\x00\xf3R\x10\x00/rustc/07dca489ac2d933c78d3c5158e3f43beefeb02ce/library/core/src/io/borrowed_buf.rs\x00\x00\x00\x00\x001\x00\x00\x00\x04\x00\x00\x00\x04\x00\x00\x002\x00\x00\x00called `Option::unwrap()` on a `None` value\x003\x00\x00\x00\x0c\x00\x00\x00\x04\x00\x00\x004\x00\x00\x005\x00\x00\x006\x00\x00\x00mainlibrary/std/src/rt.rs\x00\x00\x00\xccU\x10\x00\x15\x00\x00\x00r\x00\x00\x00\r\x00\x00\x00AccessErrorlibrary/std/src/thread/mod.rsfailed to generate unique thread ID: bitspace exhausted\x00\x1cV\x10\x007\x00\x00\x00\xffU\x10\x00\x1d\x00\x00\x00\x98\x04\x00\x00\r\x00\x00\x00stream did not contain valid UTF-8\x00\x00lV\x10\x00\"\x00\x00\x00\x15\x00\x00\x00Oscode\x00\x001\x00\x00\x00\x04\x00\x00\x00\x04\x00\x00\x007\x00\x00\x00kind8\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x009\x00\x00\x00message\x003\x00\x00\x00\x0c\x00\x00\x00\x04\x00\x00\x00:\x00\x00\x00KindError\x00\x00\x001\x00\x00\x00\x08\x00\x00\x00\x04\x00\x00\x00;\x00\x00\x00Customerror\x001\x00\x00\x00\x04\x00\x00\x00\x04\x00\x00\x00<\x00\x00\x00library/std/src/io/stdio.rs\x00\x18W\x10\x00\x1b\x00\x00\x00~\x02\x00\x00\x13\x00\x00\x00library/std/src/io/mod.rs\x00\x00\x00DW\x10\x00\x19\x00\x00\x00\x83\x01\x00\x00\x1d\x00\x00\x00\x1cU\x10\x00S\x00\x00\x00\xdf\x00\x00\x00\x1a\x00\x00\x00DW\x10\x00\x19\x00\x00\x00\x1e\x08\x00\x005\x00\x00\x00cannot recursively acquire mutex\x90W\x10\x00 \x00\x00\x00library/std/src/sys/wasm/../unsupported/locks/mutex.rs\x00\x00\xb8W\x10\x006\x00\x00\x00\x14\x00\x00\x00\t\x00\x00\x00library/std/src/sync/once.rs\x00X\x10\x00\x1c\x00\x00\x00\x95\x00\x00\x002\x00\x00\x00\x00X\x10\x00\x1c\x00\x00\x00\xd0\x00\x00\x00\x14\x00\x00\x00\x00X\x10\x00\x1c\x00\x00\x00\xd0\x00\x00\x001\x00\x00\x00lock count overflow in reentrant mutexlibrary/std/src/sync/remutex.rs\x00\x00\x00rX\x10\x00\x1f\x00\x00\x00\x91\x00\x00\x00\x0e\x00\x00\x00memory allocation of  bytes failed\x00\x00\xa4X\x10\x00\x15\x00\x00\x00\xb9X\x10\x00\r\x00\x00\x00library/std/src/alloc.rs\xd8X\x10\x00\x18\x00\x00\x00b\x01\x00\x00\t\x00\x00\x00library/std/src/panicking.rs\x00Y\x10\x00\x1c\x00\x00\x00\x84\x02\x00\x00\x1e\x00\x00\x003\x00\x00\x00\x0c\x00\x00\x00\x04\x00\x00\x00=\x00\x00\x001\x00\x00\x00\x08\x00\x00\x00\x04\x00\x00\x00>\x00\x00\x001\x00\x00\x00\x08\x00\x00\x00\x04\x00\x00\x00?\x00\x00\x00@\x00\x00\x00A\x00\x00\x00\x10\x00\x00\x00\x04\x00\x00\x00B\x00\x00\x00C\x00\x00\x00D\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00E\x00\x00\x00NotFoundPermissionDeniedConnectionRefusedConnectionResetHostUnreachableNetworkUnreachableConnectionAbortedNotConnectedAddrInUseAddrNotAvailableNetworkDownBrokenPipeAlreadyExistsWouldBlockNotADirectoryIsADirectoryDirectoryNotEmptyReadOnlyFilesystemFilesystemLoopStaleNetworkFileHandleInvalidInputInvalidDataTimedOutWriteZeroStorageFullNotSeekableFilesystemQuotaExceededFileTooLargeResourceBusyExecutableFileBusyDeadlockCrossesDevicesTooManyLinksInvalidFilenameArgumentListTooLongInterruptedUnsupportedUnexpectedEofOutOfMemoryOtherUncategorizedoperation successfulOnce instance has previously been poisoned\xb6[\x10\x00*\x00\x00\x00one-time initialization may not be performed recursively\xe8[\x10\x008\x00\x00\x00\x08\x00\x00\x00\x10\x00\x00\x00\x11\x00\x00\x00\x0f\x00\x00\x00\x0f\x00\x00\x00\x12\x00\x00\x00\x11\x00\x00\x00\x0c\x00\x00\x00\t\x00\x00\x00\x10\x00\x00\x00\x0b\x00\x00\x00\n\x00\x00\x00\r\x00\x00\x00\n\x00\x00\x00\r\x00\x00\x00\x0c\x00\x00\x00\x11\x00\x00\x00\x12\x00\x00\x00\x0e\x00\x00\x00\x16\x00\x00\x00\x0c\x00\x00\x00\x0b\x00\x00\x00\x08\x00\x00\x00\t\x00\x00\x00\x0b\x00\x00\x00\x0b\x00\x00\x00\x17\x00\x00\x00\x0c\x00\x00\x00\x0c\x00\x00\x00\x12\x00\x00\x00\x08\x00\x00\x00\x0e\x00\x00\x00\x0c\x00\x00\x00\x0f\x00\x00\x00\x13\x00\x00\x00\x0b\x00\x00\x00\x0b\x00\x00\x00\r\x00\x00\x00\x0b\x00\x00\x00\x05\x00\x00\x00\r\x00\x00\x00\x84Y\x10\x00\x8cY\x10\x00\x9cY\x10\x00\xadY\x10\x00\xbcY\x10\x00\xcbY\x10\x00\xddY\x10\x00\xeeY\x10\x00\xfaY\x10\x00\x03Z\x10\x00\x13Z\x10\x00\x1eZ\x10\x00(Z\x10\x005Z\x10\x00?Z\x10\x00LZ\x10\x00XZ\x10\x00iZ\x10\x00{Z\x10\x00\x89Z\x10\x00\x9fZ\x10\x00\xabZ\x10\x00\xb6Z\x10\x00\xbeZ\x10\x00\xc7Z\x10\x00\xd2Z\x10\x00\xddZ\x10\x00\xf4Z\x10\x00\x00[\x10\x00\x0c[\x10\x00\x1e[\x10\x00&[\x10\x004[\x10\x00@[\x10\x00O[\x10\x00b[\x10\x00m[\x10\x00x[\x10\x00\x85[\x10\x00\x90[\x10\x00\x95[\x10\x00ErrorLayoutErrorF\x00\x00\x00\x0c\x00\x00\x00\x04\x00\x00\x00G\x00\x00\x00H\x00\x00\x00I\x00\x00\x00library/alloc/src/raw_vec.rscapacity overflow\x00\x00\x00\xb4]\x10\x00\x11\x00\x00\x00\x98]\x10\x00\x1c\x00\x00\x00;\x02\x00\x00\x05\x00\x00\x00called `Option::unwrap()` on a `None` valuelibrary/alloc/src/ffi/c_str.rs\x00\x00\x00\x0b^\x10\x00\x1e\x00\x00\x00\x1b\x01\x00\x007\x00\x00\x00a formatting trait implementation returned an error\x00J\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00K\x00\x00\x00library/alloc/src/fmt.rs\x80^\x10\x00\x18\x00\x00\x00d\x02\x00\x00 \x00\x00\x00called `Result::unwrap()` on an `Err` value\x00J\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00L\x00\x00\x00library/alloc/src/sync.rs\x00\x00\x00\xe4^\x10\x00\x19\x00\x00\x00o\x01\x00\x002\x00\x00\x00swap_remove index (is ) should be < len (is )\x00\x00\x00\x10_\x10\x00\x16\x00\x00\x00&_\x10\x00\x16\x00\x00\x00<_\x10\x00\x01\x00\x00\x00library/core/src/fmt/mod.rscalled `Option::unwrap()` on a `None` value)..\x00\x00\x00\x9f_\x10\x00\x02\x00\x00\x000123456789abcdefBorrowErrorBorrowMutErroralready borrowed: \x00\xd5_\x10\x00\x12\x00\x00\x00already mutably borrowed: \x00\x00\xf0_\x10\x00\x1a\x00\x00\x00X_\x10\x00\x00\x00\x00\x00U\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00V\x00\x00\x00explicit panic\x00\x00,`\x10\x00\x0e\x00\x00\x00index out of bounds: the len is  but the index is \x00\x00D`\x10\x00 \x00\x00\x00d`\x10\x00\x12\x00\x00\x00==!=matchesassertion `left  right` failed\n  left: \n right: \x00\x93`\x10\x00\x10\x00\x00\x00\xa3`\x10\x00\x17\x00\x00\x00\xba`\x10\x00\t\x00\x00\x00 right` failed: \n  left: \x00\x00\x00\x93`\x10\x00\x10\x00\x00\x00\xdc`\x10\x00\x10\x00\x00\x00\xec`\x10\x00\t\x00\x00\x00\xba`\x10\x00\t\x00\x00\x00: \x00\x00X_\x10\x00\x00\x00\x00\x00\x18a\x10\x00\x02\x00\x00\x00W\x00\x00\x00\x0c\x00\x00\x00\x04\x00\x00\x00X\x00\x00\x00Y\x00\x00\x00Z\x00\x00\x00     { ,  {\n,\n} }((\n,library/core/src/fmt/num.rsYa\x10\x00\x1b\x00\x00\x00i\x00\x00\x00\x17\x00\x00\x000x00010203040506070809101112131415161718192021222324252627282930313233343536373839404142434445464748495051525354555657585960616263646566676869707172737475767778798081828384858687888990919293949596979899assertion failed: *curr > 19\x00\x00Ya\x10\x00\x1b\x00\x00\x00\xef\x01\x00\x00\x05\x00\x00\x00falsetrue\x00\x00\x00X_\x10\x00\x1b\x00\x00\x005\t\x00\x00\x1a\x00\x00\x00X_\x10\x00\x1b\x00\x00\x00.\t\x00\x00\"\x00\x00\x00range start index  out of range for slice of length \xa8b\x10\x00\x12\x00\x00\x00\xbab\x10\x00\"\x00\x00\x00range end index \xecb\x10\x00\x10\x00\x00\x00\xbab\x10\x00\"\x00\x00\x00slice index starts at  but ends at \x00\x0cc\x10\x00\x16\x00\x00\x00\"c\x10\x00\r\x00\x00\x00attempted to index slice up to maximum usize@c\x10\x00,\x00\x00\x00\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x04\x04\x04\x04\x04\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00[...]begin <= end ( <= ) when slicing ``yd\x10\x00\x0e\x00\x00\x00\x87d\x10\x00\x04\x00\x00\x00\x8bd\x10\x00\x10\x00\x00\x00\x9bd\x10\x00\x01\x00\x00\x00byte index  is not a char boundary; it is inside  (bytes ) of `\x00\xbcd\x10\x00\x0b\x00\x00\x00\xc7d\x10\x00&\x00\x00\x00\xedd\x10\x00\x08\x00\x00\x00\xf5d\x10\x00\x06\x00\x00\x00\x9bd\x10\x00\x01\x00\x00\x00 is out of bounds of `\x00\x00\xbcd\x10\x00\x0b\x00\x00\x00$e\x10\x00\x16\x00\x00\x00\x9bd\x10\x00\x01\x00\x00\x00library/core/src/str/mod.rs\x00Te\x10\x00\x1b\x00\x00\x00\t\x01\x00\x00,\x00\x00\x00library/core/src/unicode/printable.rs\x00\x00\x00\x80e\x10\x00%\x00\x00\x00\x1a\x00\x00\x006\x00\x00\x00\x80e\x10\x00%\x00\x00\x00\n\x00\x00\x00+\x00\x00\x00\x00\x06\x01\x01\x03\x01\x04\x02\x05\x07\x07\x02\x08\x08\t\x02\n\x05\x0b\x02\x0e\x04\x10\x01\x11\x02\x12\x05\x13\x11\x14\x01\x15\x02\x17\x02\x19\r\x1c\x05\x1d\x08\x1f\x01$\x01j\x04k\x02\xaf\x03\xb1\x02\xbc\x02\xcf\x02\xd1\x02\xd4\x0c\xd5\t\xd6\x02\xd7\x02\xda\x01\xe0\x05\xe1\x02\xe7\x04\xe8\x02\xee \xf0\x04\xf8\x02\xfa\x03\xfb\x01\x0c\';>NO\x8f\x9e\x9e\x9f{\x8b\x93\x96\xa2\xb2\xba\x86\xb1\x06\x07\t6=>V\xf3\xd0\xd1\x04\x14\x1867VW\x7f\xaa\xae\xaf\xbd5\xe0\x12\x87\x89\x8e\x9e\x04\r\x0e\x11\x12)14:EFIJNOde\\\xb6\xb7\x1b\x1c\x07\x08\n\x0b\x14\x1769:\xa8\xa9\xd8\xd9\t7\x90\x91\xa8\x07\n;>fi\x8f\x92\x11o_\xbf\xee\xefZb\xf4\xfc\xffST\x9a\x9b./\'(U\x9d\xa0\xa1\xa3\xa4\xa7\xa8\xad\xba\xbc\xc4\x06\x0b\x0c\x15\x1d:?EQ\xa6\xa7\xcc\xcd\xa0\x07\x19\x1a\"%>?\xe7\xec\xef\xff\xc5\xc6\x04 #%&(38:HJLPSUVXZ\\^`cefksx}\x7f\x8a\xa4\xaa\xaf\xb0\xc0\xd0\xae\xafno\xbe\x93^\"{\x05\x03\x04-\x03f\x03\x01/.\x80\x82\x1d\x031\x0f\x1c\x04$\t\x1e\x05+\x05D\x04\x0e*\x80\xaa\x06$\x04$\x04(\x084\x0bNC\x817\t\x16\n\x08\x18;E9\x03c\x08\t0\x16\x05!\x03\x1b\x05\x01@8\x04K\x05/\x04\n\x07\t\x07@ \'\x04\x0c\t6\x03:\x05\x1a\x07\x04\x0c\x07PI73\r3\x07.\x08\n\x81&RK+\x08*\x16\x1a&\x1c\x14\x17\tN\x04$\tD\r\x19\x07\n\x06H\x08\'\tu\x0bB>*\x06;\x05\n\x06Q\x06\x01\x05\x10\x03\x05\x80\x8bb\x1eH\x08\n\x80\xa6^\"E\x0b\n\x06\r\x13:\x06\n6,\x04\x17\x80\xb9<dS\x0cH\t\nFE\x1bH\x08S\rI\x07\n\x80\xf6F\n\x1d\x03GI7\x03\x0e\x08\n\x069\x07\n\x816\x19\x07;\x03\x1cV\x01\x0f2\r\x83\x9bfu\x0b\x80\xc4\x8aLc\r\x840\x10\x16\x8f\xaa\x82G\xa1\xb9\x829\x07*\x04\\\x06&\nF\n(\x05\x13\x82\xb0[eK\x049\x07\x11@\x05\x0b\x02\x0e\x97\xf8\x08\x84\xd6*\t\xa2\xe7\x813\x0f\x01\x1d\x06\x0e\x04\x08\x81\x8c\x89\x04k\x05\r\x03\t\x07\x10\x92`G\tt<\x80\xf6\ns\x08p\x15Fz\x14\x0c\x14\x0cW\t\x19\x80\x87\x81G\x03\x85B\x0f\x15\x84P\x1f\x06\x06\x80\xd5+\x05>!\x01p-\x03\x1a\x04\x02\x81@\x1f\x11:\x05\x01\x81\xd0*\x82\xe6\x80\xf7)L\x04\n\x04\x02\x83\x11DL=\x80\xc2<\x06\x01\x04U\x05\x1b4\x02\x81\x0e,\x04d\x0cV\n\x80\xae8\x1d\r,\x04\t\x07\x02\x0e\x06\x80\x9a\x83\xd8\x04\x11\x03\r\x03w\x04_\x06\x0c\x04\x01\x0f\x0c\x048\x08\n\x06(\x08\"N\x81T\x0c\x1d\x03\t\x076\x08\x0e\x04\t\x07\t\x07\x80\xcb%\n\x84\x06\x00\x01\x03\x05\x05\x06\x06\x02\x07\x06\x08\x07\t\x11\n\x1c\x0b\x19\x0c\x1a\r\x10\x0e\x0c\x0f\x04\x10\x03\x12\x12\x13\t\x16\x01\x17\x04\x18\x01\x19\x03\x1a\x07\x1b\x01\x1c\x02\x1f\x16 \x03+\x03-\x0b.\x010\x031\x022\x01\xa7\x02\xa9\x02\xaa\x04\xab\x08\xfa\x02\xfb\x05\xfd\x02\xfe\x03\xff\t\xadxy\x8b\x8d\xa20WX\x8b\x8c\x90\x1c\xdd\x0e\x0fKL\xfb\xfc./?\\]_\xe2\x84\x8d\x8e\x91\x92\xa9\xb1\xba\xbb\xc5\xc6\xc9\xca\xde\xe4\xe5\xff\x00\x04\x11\x12)147:;=IJ]\x84\x8e\x92\xa9\xb1\xb4\xba\xbb\xc6\xca\xce\xcf\xe4\xe5\x00\x04\r\x0e\x11\x12)14:;EFIJ^de\x84\x91\x9b\x9d\xc9\xce\xcf\r\x11):;EIW[\\^_de\x8d\x91\xa9\xb4\xba\xbb\xc5\xc9\xdf\xe4\xe5\xf0\r\x11EIde\x80\x84\xb2\xbc\xbe\xbf\xd5\xd7\xf0\xf1\x83\x85\x8b\xa4\xa6\xbe\xbf\xc5\xc7\xcf\xda\xdbH\x98\xbd\xcd\xc6\xce\xcfINOWY^_\x89\x8e\x8f\xb1\xb6\xb7\xbf\xc1\xc6\xc7\xd7\x11\x16\x17[\\\xf6\xf7\xfe\xff\x80mq\xde\xdf\x0e\x1fno\x1c\x1d_}~\xae\xaf\x7f\xbb\xbc\x16\x17\x1e\x1fFGNOXZ\\^~\x7f\xb5\xc5\xd4\xd5\xdc\xf0\xf1\xf5rs\x8ftu\x96&./\xa7\xaf\xb7\xbf\xc7\xcf\xd7\xdf\x9a@\x97\x980\x8f\x1f\xd2\xd4\xce\xffNOZ[\x07\x08\x0f\x10\'/\xee\xefno7=?BE\x90\x91Sgu\xc8\xc9\xd0\xd1\xd8\xd9\xe7\xfe\xff\x00 _\"\x82\xdf\x04\x82D\x08\x1b\x04\x06\x11\x81\xac\x0e\x80\xab\x05\x1f\t\x81\x1b\x03\x19\x08\x01\x04/\x044\x04\x07\x03\x01\x07\x06\x07\x11\nP\x0f\x12\x07U\x07\x03\x04\x1c\n\t\x03\x08\x03\x07\x03\x02\x03\x03\x03\x0c\x04\x05\x03\x0b\x06\x01\x0e\x15\x05N\x07\x1b\x07W\x07\x02\x06\x17\x0cP\x04C\x03-\x03\x01\x04\x11\x06\x0f\x0c:\x04\x1d%_ m\x04j%\x80\xc8\x05\x82\xb0\x03\x1a\x06\x82\xfd\x03Y\x07\x16\t\x18\t\x14\x0c\x14\x0cj\x06\n\x06\x1a\x06Y\x07+\x05F\n,\x04\x0c\x04\x01\x031\x0b,\x04\x1a\x06\x0b\x03\x80\xac\x06\n\x06/1M\x03\x80\xa4\x08<\x03\x0f\x03<\x078\x08+\x05\x82\xff\x11\x18\x08/\x11-\x03!\x0f!\x0f\x80\x8c\x04\x82\x97\x19\x0b\x15\x88\x94\x05/\x05;\x07\x02\x0e\x18\t\x80\xbe\"t\x0c\x80\xd6\x1a\x0c\x05\x80\xff\x05\x80\xdf\x0c\xf2\x9d\x037\t\x81\\\x14\x80\xb8\x08\x80\xcb\x05\n\x18;\x03\n\x068\x08F\x08\x0c\x06t\x0b\x1e\x03Z\x04Y\t\x80\x83\x18\x1c\n\x16\tL\x04\x80\x8a\x06\xab\xa4\x0c\x17\x041\xa1\x04\x81\xda&\x07\x0c\x05\x05\x80\xa6\x10\x81\xf5\x07\x01 *\x06L\x04\x80\x8d\x04\x80\xbe\x03\x1b\x03\x0f\rlibrary/core/src/unicode/unicode_data.rsDk\x10\x00(\x00\x00\x00P\x00\x00\x00(\x00\x00\x00Dk\x10\x00(\x00\x00\x00\\\x00\x00\x00\x16\x00\x00\x00library/core/src/escape.rs\x00\x00\x8ck\x10\x00\x1a\x00\x00\x008\x00\x00\x00\x0b\x00\x00\x00\\u{\x00\x8ck\x10\x00\x1a\x00\x00\x00f\x00\x00\x00#\x00\x00\x00\x00\x03\x00\x00\x83\x04 \x00\x91\x05`\x00]\x13\xa0\x00\x12\x17 \x1f\x0c `\x1f\xef,\xa0+*0 ,o\xa6\xe0,\x02\xa8`-\x1e\xfb`.\x00\xfe 6\x9e\xff`6\xfd\x01\xe16\x01\n!7$\r\xe17\xab\x0ea9/\x18\xa190\x1caH\xf3\x1e\xa1L@4aP\xf0j\xa1QOo!R\x9d\xbc\xa1R\x00\xcfaSe\xd1\xa1S\x00\xda!T\x00\xe0\xe1U\xae\xe2aW\xec\xe4!Y\xd0\xe8\xa1Y \x00\xeeY\xf0\x01\x7fZ\x00p\x00\x07\x00-\x01\x01\x01\x02\x01\x02\x01\x01H\x0b0\x15\x10\x01e\x07\x02\x06\x02\x02\x01\x04#\x01\x1e\x1b[\x0b:\t\t\x01\x18\x04\x01\t\x01\x03\x01\x05+\x03<\x08*\x18\x01 7\x01\x01\x01\x04\x08\x04\x01\x03\x07\n\x02\x1d\x01:\x01\x01\x01\x02\x04\x08\x01\t\x01\n\x02\x1a\x01\x02\x029\x01\x04\x02\x04\x02\x02\x03\x03\x01\x1e\x02\x03\x01\x0b\x029\x01\x04\x05\x01\x02\x04\x01\x14\x02\x16\x06\x01\x01:\x01\x01\x02\x01\x04\x08\x01\x07\x03\n\x02\x1e\x01;\x01\x01\x01\x0c\x01\t\x01(\x01\x03\x017\x01\x01\x03\x05\x03\x01\x04\x07\x02\x0b\x02\x1d\x01:\x01\x02\x01\x02\x01\x03\x01\x05\x02\x07\x02\x0b\x02\x1c\x029\x02\x01\x01\x02\x04\x08\x01\t\x01\n\x02\x1d\x01H\x01\x04\x01\x02\x03\x01\x01\x08\x01Q\x01\x02\x07\x0c\x08b\x01\x02\t\x0b\x07I\x02\x1b\x01\x01\x01\x01\x017\x0e\x01\x05\x01\x02\x05\x0b\x01$\t\x01f\x04\x01\x06\x01\x02\x02\x02\x19\x02\x04\x03\x10\x04\r\x01\x02\x02\x06\x01\x0f\x01\x00\x03\x00\x03\x1d\x02\x1e\x02\x1e\x02@\x02\x01\x07\x08\x01\x02\x0b\t\x01-\x03\x01\x01u\x02\"\x01v\x03\x04\x02\t\x01\x06\x03\xdb\x02\x02\x01:\x01\x01\x07\x01\x01\x01\x01\x02\x08\x06\n\x02\x010\x1f1\x040\x07\x01\x01\x05\x01(\t\x0c\x02 \x04\x02\x02\x01\x038\x01\x01\x02\x03\x01\x01\x03:\x08\x02\x02\x98\x03\x01\r\x01\x07\x04\x01\x06\x01\x03\x02\xc6@\x00\x01\xc3!\x00\x03\x8d\x01` \x00\x06i\x02\x00\x04\x01\n \x02P\x02\x00\x01\x03\x01\x04\x01\x19\x02\x05\x01\x97\x02\x1a\x12\r\x01&\x08\x19\x0b.\x030\x01\x02\x04\x02\x02\'\x01C\x06\x02\x02\x02\x02\x0c\x01\x08\x01/\x013\x01\x01\x03\x02\x02\x05\x02\x01\x01*\x02\x08\x01\xee\x01\x02\x01\x04\x01\x00\x01\x00\x10\x10\x10\x00\x02\x00\x01\xe2\x01\x95\x05\x00\x03\x01\x02\x05\x04(\x03\x04\x01\xa5\x02\x00\x04\x00\x02P\x03F\x0b1\x04{\x016\x0f)\x01\x02\x02\n\x031\x04\x02\x02\x07\x01=\x03$\x05\x01\x08>\x01\x0c\x024\t\n\x04\x02\x01_\x03\x02\x01\x01\x02\x06\x01\x02\x01\x9d\x01\x03\x08\x15\x029\x02\x01\x01\x01\x01\x16\x01\x0e\x07\x03\x05\xc3\x08\x02\x03\x01\x01\x17\x01Q\x01\x02\x06\x01\x01\x02\x01\x01\x02\x01\x02\xeb\x01\x02\x04\x06\x02\x01\x02\x1b\x02U\x08\x02\x01\x01\x02j\x01\x01\x01\x02\x06\x01\x01e\x03\x02\x04\x01\x05\x00\t\x01\x02\xf5\x01\n\x02\x01\x01\x04\x01\x90\x04\x02\x02\x04\x01 \n(\x06\x02\x04\x08\x01\t\x06\x02\x03.\r\x01\x02\x00\x07\x01\x06\x01\x01R\x16\x02\x07\x01\x02\x01\x02z\x06\x03\x01\x01\x02\x01\x07\x01\x01H\x02\x03\x01\x01\x01\x00\x02\x0b\x024\x05\x05\x01\x01\x01\x00\x01\x06\x0f\x00\x05;\x07\x00\x01?\x04Q\x01\x00\x02\x00.\x02\x17\x00\x01\x01\x03\x04\x05\x08\x08\x02\x07\x1e\x04\x94\x03\x007\x042\x08\x01\x0e\x01\x16\x05\x01\x0f\x00\x07\x01\x11\x02\x07\x01\x02\x01\x05d\x01\xa0\x07\x00\x01=\x04\x00\x04\x00\x07m\x07\x00`\x80\xf0\x00\x02\x02\x02\x02\x02\x02\x02\x02\x02\x03\x03\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x02\x02\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00")
end
return function(wasm)
	FUNC_LIST[0] = wasm["env"].func_list["print_char"]
	FUNC_LIST[1] = wasm["env"].func_list["time"]
	run_init_code()
	memory_at_0 = MEMORY_LIST[0]
	return {
		rt = rt,
		func_list = {
			["send_input"] = FUNC_LIST[11],
			["main"] = FUNC_LIST[16],
		},
		table_list = {
		},
		memory_list = {
			["memory"] = MEMORY_LIST[0],
		},
		global_list = {
			["__data_end"] = GLOBAL_LIST[1],
			["__heap_base"] = GLOBAL_LIST[2],
		},
	}
end
