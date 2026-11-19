-- Keeps each player's deal record in the save and sends the notification that a deal
-- finished. Only this context can do either; only the interface can see the deals
-- (DealManager.GetPlayerDeals returns nothing here), so the interface decides what
-- to store and announce and hands it over:
--   single player: directly, through ExposedMembers.UIExt;
--   network game: as a player operation (EXECUTE_SCRIPT), which runs on every machine,
--   the way the game's own scenarios set a property from the interface.
include("DealRecord");

local function CurrentTurn()
	if Game == nil or Game.GetCurrentGameTurn == nil then return 0 end
	local ok, turn = pcall(function() return Game.GetCurrentGameTurn() end);
	if ok and type(turn) == "number" then return turn end
	return 0;
end

-- ---------------------------------------------------------------------------
-- Journal (see DealRecord.AppendLog). The counter is shared with the interface,
-- so lines from both contexts read in one order.
-- ---------------------------------------------------------------------------
local m_Seq = 0;

local function NextSeq()
	if ExposedMembers ~= nil then
		ExposedMembers.UIExt = ExposedMembers.UIExt or {};
		ExposedMembers.UIExt.LogSeq = (ExposedMembers.UIExt.LogSeq or 0) + 1;
		return ExposedMembers.UIExt.LogSeq;
	end
	m_Seq = m_Seq + 1;
	return m_Seq;
end

local function AppendJournal(line)
	pcall(function()
		local old = Game:GetProperty(DealRecord.LOG_GAMEPLAY);
		Game:SetProperty(DealRecord.LOG_GAMEPLAY, DealRecord.AppendLog(old, line));
	end);
end

local function Journal(text)
	local line = tostring(NextSeq()) .. " t" .. tostring(CurrentTurn()) .. " GP " .. text;
	print("UIExt: " .. line);
	AppendJournal(line);
end

-- ---------------------------------------------------------------------------
-- Record
-- ---------------------------------------------------------------------------
local function ReadArchive(player)
	if player == nil then return nil end
	local ok, text = pcall(Game.GetProperty, Game, DealRecord.ArchiveKey(player));
	if ok and type(text) == "string" then return text end
	return nil;
end

local function PutRecord(player, line)
	if player == nil or DealRecord.DecodeRecord(line) == nil then return end
	local key = DealRecord.ArchiveKey(player);
	local text = DealRecord.PutLine(ReadArchive(player), line);
	pcall(Game.SetProperty, Game, key, text);
end

-- ---------------------------------------------------------------------------
-- Notification. params: uiextType (a NotificationTypes name), uiextMessage, uiextSummary,
-- uiextPartner, uiextDealID, uiextTurn.
-- ---------------------------------------------------------------------------
local function Notify(player, params)
	if player == nil or type(params) ~= "table" then return false end
	if NotificationManager == nil or NotificationManager.SendNotification == nil
		or NotificationTypes == nil or ParameterTypes == nil then return false end
	local notifyType = NotificationTypes[params.uiextType];
	if notifyType == nil then return false end
	local sent = {
		[DealRecord.NOTIFY_MARK] = 1,
		UIExtPartner = params.uiextPartner,
		UIExtDealID = params.uiextDealID,
		UIExtTurn = params.uiextTurn,
	};
	sent[ParameterTypes.MESSAGE] = params.uiextMessage;
	sent[ParameterTypes.SUMMARY] = params.uiextSummary;
	return pcall(NotificationManager.SendNotification, player, notifyType, sent) == true;
end

local function OnPutOperation(player, params)
	local ok, err = pcall(PutRecord, player, type(params) == "table" and params.uiextLine or nil);
	if not ok then Journal("put error " .. tostring(err)) end
end

local function OnNotifyOperation(player, params)
	local ok, err = pcall(Notify, player, params);
	if not ok then Journal("notify error " .. tostring(err)) end
end

local function Initialize()
	if DealRecord == nil then
		error("DealRecord.lua is not loaded: it must be listed in ImportFiles in the modinfo");
	end
	GameEvents[DealRecord.OP_PUT].Add(OnPutOperation);
	GameEvents[DealRecord.OP_NOTIFY].Add(OnNotifyOperation);
	if ExposedMembers ~= nil then
		ExposedMembers.UIExt = ExposedMembers.UIExt or {};
		ExposedMembers.UIExt.ReadArchive = ReadArchive;
		ExposedMembers.UIExt.PutRecord = PutRecord;
		ExposedMembers.UIExt.Notify = Notify;
		ExposedMembers.UIExt.AppendJournal = AppendJournal;
	end
	Journal("ready");
end

local ok, err = pcall(Initialize);
if not ok then Journal("init error " .. tostring(err)) end
