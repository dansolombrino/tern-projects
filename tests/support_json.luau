--!strict
-- Test support: a small JSON decoder (the luau CLI has none) for the fixtures,
-- which are real `tern.json.encode` captures wrapped in Luau modules.

local json = {}

function json.decode(text: string): any
	local pos = 1

	local function fail(msg: string): never
		error(string.format("json: %s at byte %d", msg, pos))
	end

	local function skip()
		pos = string.find(text, "[^ \t\r\n]", pos) or #text + 1
	end

	local value: () -> any

	local function str(): string
		pos += 1 -- opening quote
		local parts = {}
		while true do
			local c = string.sub(text, pos, pos)
			if c == "" then
				fail("unterminated string")
			elseif c == '"' then
				pos += 1
				return table.concat(parts)
			elseif c == "\\" then
				local e = string.sub(text, pos + 1, pos + 1)
				if e == "u" then
					local cp = tonumber(string.sub(text, pos + 2, pos + 5), 16) or fail("bad \\u")
					pos += 6
					-- Surrogate pair.
					if cp >= 0xD800 and cp <= 0xDBFF and string.sub(text, pos, pos + 1) == "\\u" then
						local lo = tonumber(string.sub(text, pos + 2, pos + 5), 16) or fail("bad \\u")
						cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
						pos += 6
					end
					table.insert(parts, utf8.char(cp))
				else
					local map: { [string]: string } = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
					parts[#parts + 1] = map[e] or e
					pos += 2
				end
			else
				local stop = string.find(text, '["\\]', pos) or fail("unterminated string")
				table.insert(parts, string.sub(text, pos, stop - 1))
				pos = stop
			end
		end
	end

	function value(): any
		skip()
		local c = string.sub(text, pos, pos)
		if c == "{" then
			pos += 1
			local obj = {}
			skip()
			if string.sub(text, pos, pos) == "}" then
				pos += 1
				return obj
			end
			while true do
				skip()
				if string.sub(text, pos, pos) ~= '"' then
					fail("expected key")
				end
				local k = str()
				skip()
				if string.sub(text, pos, pos) ~= ":" then
					fail("expected :")
				end
				pos += 1
				obj[k] = value()
				skip()
				local d = string.sub(text, pos, pos)
				pos += 1
				if d == "}" then
					return obj
				elseif d ~= "," then
					fail("expected , or }")
				end
			end
		elseif c == "[" then
			pos += 1
			local arr = {}
			skip()
			if string.sub(text, pos, pos) == "]" then
				pos += 1
				return arr
			end
			while true do
				table.insert(arr, value())
				skip()
				local d = string.sub(text, pos, pos)
				pos += 1
				if d == "]" then
					return arr
				elseif d ~= "," then
					fail("expected , or ]")
				end
			end
		elseif c == '"' then
			return str()
		elseif string.sub(text, pos, pos + 3) == "true" then
			pos += 4
			return true
		elseif string.sub(text, pos, pos + 4) == "false" then
			pos += 5
			return false
		elseif string.sub(text, pos, pos + 3) == "null" then
			pos += 4
			return nil -- dropped, as tern.json.decode drops null members
		else
			local num: string = string.match(text, "^-?%d+%.?%d*[eE]?[-+]?%d*", pos) or ""
			if num == "" then
				fail("unexpected character")
			end
			pos += #num
			return tonumber(num)
		end
	end

	local result = value()
	skip()
	if pos <= #text then
		fail("trailing data")
	end
	return result
end

return json
