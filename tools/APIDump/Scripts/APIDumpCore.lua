-- Shared by the UI and gameplay dumpers: walks what the engine exposes to Lua in the
-- current context and prints it to Lua.log as tab-separated "APIDUMP" lines, which
-- tools/extract_api.py turns into docs/api/*.md.
APIDump = APIDump or {};

local NAMESPACE_DEPTH = 2;
local SPY_LIMIT = 3;
local VALUE_WIDTH = 80;
local ARG_KEYS = 12;

-- Lua's own libraries, the database (see DebugGameplay.sqlite instead), and our own tables.
local SKIP_GLOBALS = {
	_G = true, package = true, string = true, table = true, math = true, os = true,
	io = true, debug = true, coroutine = true, GameInfo = true, Controls = true,
	APIDump = true, ExposedMembers = true,
};
-- Their members are events: the names are listed, the event objects are not walked.
local EVENT_TABLES = { Events = true, GameEvents = true, LuaEvents = true };

local function Emit(context, kind, path, detail)
	print("APIDUMP\t" .. context .. "\t" .. kind .. "\t" .. path .. "\t" .. (detail or ""));
end

local function Clip(text)
	text = string.gsub(tostring(text), "[\t\r\n]", " ");
	if string.len(text) > VALUE_WIDTH then
		text = string.sub(text, 1, VALUE_WIDTH) .. "...";
	end
	return text;
end

local function Describe(value)
	local t = type(value);
	if t == "number" or t == "string" or t == "boolean" then
		return t .. " " .. Clip(value);
	end
	return t;
end

local function SortedKeys(map)
	local keys = {};
	for k in pairs(map) do
		if type(k) == "string" then table.insert(keys, k); end
	end
	table.sort(keys);
	return keys;
end

-- String keys of the object itself and of its metatable __index chain, where engine
-- objects keep their methods.
local function CollectMembers(obj)
	local members = {};
	local seen = {};
	local current = obj;
	for _ = 1, 8 do
		if type(current) == "table" then
			for k, v in pairs(current) do
				if type(k) == "string" and members[k] == nil then
					members[k] = v;
				end
			end
		end
		local ok, mt = pcall(getmetatable, current);
		if not ok or type(mt) ~= "table" or seen[mt] then break end
		seen[mt] = true;
		current = rawget(mt, "__index");
		if type(current) ~= "table" then break end
	end
	return members;
end

local function DumpObject(context, path, obj, depth, visited, membersOnly)
	if visited[obj] then
		Emit(context, "SEE", path, visited[obj]);
		return;
	end
	visited[obj] = path;
	local ok, members = pcall(CollectMembers, obj);
	if not ok then
		Emit(context, "ERROR", path, Clip(members));
		return;
	end
	for _, name in ipairs(SortedKeys(members)) do
		local value = members[name];
		local child = path .. "." .. name;
		Emit(context, "MEMBER", child, Describe(value));
		if depth > 1 and not membersOnly and (type(value) == "table" or type(value) == "userdata") then
			DumpObject(context, child, value, depth - 1, visited, false);
		end
	end
end

local function FormatValue(value)
	if type(value) ~= "table" then
		return Describe(value);
	end
	local parts = {};
	local count = 0;
	for k, v in pairs(value) do
		count = count + 1;
		if count <= ARG_KEYS then
			table.insert(parts, Clip(k) .. "=" .. Describe(v));
		end
	end
	if count > ARG_KEYS then
		table.insert(parts, "... " .. count .. " keys");
	end
	return "table {" .. table.concat(parts, ", ") .. "}";
end

local function FormatArgs(...)
	local parts = {};
	for i = 1, select("#", ...) do
		table.insert(parts, "#" .. i .. " " .. FormatValue((select(i, ...))));
	end
	return table.concat(parts, " | ");
end

function APIDump.Globals(context)
	Emit(context, "BEGIN", "globals", "");
	for _, name in ipairs(SortedKeys(_G)) do
		if type(name) == "string" then
			Emit(context, "GLOBAL", name, Describe(_G[name]));
		end
	end
	for _, name in ipairs(SortedKeys(_G)) do
		local value = _G[name];
		if type(name) == "string" and not SKIP_GLOBALS[name]
			and (type(value) == "table" or type(value) == "userdata") then
			DumpObject(context, name, value, NAMESPACE_DEPTH, {}, EVENT_TABLES[name]);
		end
	end
end

local function Call(obj, name, ...)
	local ok, fn = pcall(function() return obj[name]; end);
	if not ok or type(fn) ~= "function" then return nil end
	local done, result = pcall(fn, ...);
	if done then return result end
	return nil;
end

local function First(collection)
	local ok, found = pcall(function()
		for _, item in collection:Members() do
			return item;
		end
	end);
	if ok then return found end
	return nil;
end

local PLAYER_GETTERS = {
	"GetCities", "GetUnits", "GetDistricts", "GetTreasury", "GetTechs", "GetCulture",
	"GetReligion", "GetDiplomacy", "GetResources", "GetStats", "GetTrade", "GetInfluence",
	"GetGovernors", "GetGreatPeoplePoints", "GetEras", "GetAi_Diplomacy", "GetAi_Military",
	"GetIdentity", "GetCongress",
};
local CITY_GETTERS = {
	"GetBuildQueue", "GetBuildings", "GetDistricts", "GetGrowth", "GetCulturalIdentity",
	"GetGold", "GetReligion", "GetTrade", "GetCityTrade", "GetCityTradeManager",
	"GetYields", "GetOwner",
};
local UNIT_GETTERS = { "GetExperience", "GetAbility", "GetGreatPerson", "GetReligion" };
local GAME_GETTERS = {
	"GetReligion", "GetGreatPeople", "GetEras", "GetTradeManager", "GetQuestsManager",
	"GetEmergencyManager", "GetCombatManager", "GetDiplomacyManager", "GetWorldCongress",
	"GetCulture", "GetVictoryManager", "GetRandomEvents",
};

local function DumpGetters(context, prefix, obj, getters, isStatic)
	for _, name in ipairs(getters) do
		local result;
		if isStatic then
			result = Call(obj, name);
		else
			result = Call(obj, name, obj);
		end
		if type(result) == "table" or type(result) == "userdata" then
			DumpObject(context, prefix .. name .. "()", result, 1, {}, true);
		end
	end
end

local function LocalPlayerID()
	local id = Call(Game, "GetLocalPlayer");
	if type(id) == "number" and id >= 0 then return id end
	local alive = Call(PlayerManager, "GetAliveMajorIDs");
	if type(alive) == "table" and alive[1] ~= nil then return alive[1] end
	return 0;
end

function APIDump.Instances(context)
	Emit(context, "BEGIN", "instances", "");
	if Game ~= nil then
		DumpGetters(context, "Game.", Game, GAME_GETTERS, true);
	end
	if Players == nil then return end
	local playerID = LocalPlayerID();
	local player = Players[playerID];
	if player == nil then
		Emit(context, "ERROR", "Player", "no player " .. tostring(playerID));
		return;
	end
	DumpObject(context, "Player", player, 1, {}, true);
	DumpGetters(context, "Player:", player, PLAYER_GETTERS, false);

	local cities = Call(player, "GetCities", player);
	local city = cities and (Call(cities, "GetCapitalCity", cities) or First(cities));
	if city ~= nil then
		DumpObject(context, "City", city, 1, {}, true);
		DumpGetters(context, "City:", city, CITY_GETTERS, false);
		local districts = Call(city, "GetDistricts", city);
		local district = districts and First(districts);
		if district ~= nil then
			DumpObject(context, "District", district, 1, {}, true);
		end
		local x, y = Call(city, "GetX", city), Call(city, "GetY", city);
		local plot = (x and y and Map ~= nil) and Call(Map, "GetPlot", x, y) or nil;
		if plot ~= nil then
			DumpObject(context, "Plot", plot, 1, {}, true);
		end
	end

	local units = Call(player, "GetUnits", player);
	local unit = units and First(units);
	if unit ~= nil then
		DumpObject(context, "Unit", unit, 1, {}, true);
		DumpGetters(context, "Unit:", unit, UNIT_GETTERS, false);
	end
end

-- Logs the first SPY_LIMIT firings of every event with its arguments: the engine
-- publishes no signatures, so this is how argument order and types are learned.
function APIDump.SpyEvents(context, events, prefix)
	if events == nil then return end
	local ok, members = pcall(CollectMembers, events);
	if not ok then return end
	local hooked = 0;
	for _, name in ipairs(SortedKeys(members)) do
		local count = 0;
		local path = prefix .. "." .. name;
		local added = pcall(function()
			events[name].Add(function(...)
				if count >= SPY_LIMIT then return end
				count = count + 1;
				Emit(context, "FIRED", path, FormatArgs(...));
			end);
		end);
		if added then hooked = hooked + 1; end
	end
	Emit(context, "SPY", prefix, tostring(hooked) .. " events hooked");
end

function APIDump.Run(context)
	local ok, err = pcall(APIDump.Globals, context);
	if not ok then Emit(context, "ERROR", "globals", Clip(err)); end
	ok, err = pcall(APIDump.Instances, context);
	if not ok then Emit(context, "ERROR", "instances", Clip(err)); end
	Emit(context, "END", "dump", "");
end
