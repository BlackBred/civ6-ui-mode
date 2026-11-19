-- Behaviour tests for UI/DealOverview.lua against the mocked Civ6 API. Run with: luajit tests/test_deal_overview.lua
local TESTS_DIR = arg[0]:match("^(.*)/[^/]*$") or ".";
local MOD_DIR = TESTS_DIR .. "/../UI_Extender";
package.path = TESTS_DIR .. "/?.lua;" .. package.path;
local Mock = require("mock_civ6");

local tests = {};
local function test(name, fn) table.insert(tests, { name = name, fn = fn }) end

local function Items(w, name, parent)
	local list = {};
	local im = w:Manager(name);
	if im == nil then return list end
	for _, inst in ipairs(im.items) do
		if inst.Top.parent == parent then table.insert(list, inst) end
	end
	return list;
end

-- What the deals tab shows: { header, sides = { { title, items = { text, ... } } } } per deal.
local function TabDeals(w, panel)
	local deals = {};
	for _, deal in ipairs(Items(w, "DealsTabDeal", panel.TabCards)) do
		local entry = { header = deal.Header.text, sides = {} };
		for _, side in ipairs(Items(w, "DealsTabSide", deal.Sides)) do
			local title, anchor = nil, nil;
			for _, id in ipairs({ "SharedTitle", "OursTitle", "TheirsTitle" }) do
				if not side[id].hidden then
					assert(title == nil, "two titles shown on one side");
					title = side[id].text;
					anchor = side[id].anchor;
				end
			end
			local texts = {};
			for _, item in ipairs(Items(w, "DealsTabItem", side.Items)) do
				table.insert(texts, item.Text.text);
			end
			table.insert(entry.sides, { title = title, items = texts, width = side.Top.w, anchor = anchor });
		end
		table.insert(deals, entry);
	end
	return deals;
end

local function eq(actual, expected, what)
	if actual ~= expected then
		error(string.format("%s\n    expected: %s\n    actual:   %s", what or "values differ", tostring(expected), tostring(actual)), 2);
	end
end

local function check(value, what)
	if not value then error(what or "check failed", 2) end
end

local function NewWorld(opts)
	opts = opts or {};
	opts.modDir = MOD_DIR;
	opts.turn = opts.turn or 20;
	local w = Mock.new(opts);
	w:AddResource(1, "RESOURCE_SILK", "Silk");
	w:AddResource(2, "RESOURCE_IRON", "Iron", "RESOURCECLASS_STRATEGIC");
	w:AddResource(3, "RESOURCE_SPICES", "Spices");
	w.gameText["LOC_DIPLOACTION_ALLIANCE_NAME"] = "Alliance";
	return w;
end

local function Gold(from, amount, duration, enacted)
	return { type = "GOLD", from = from, amount = amount, duration = duration, enacted = enacted };
end

local function Silk(from, duration, enacted)
	return { type = "RESOURCES", from = from, amount = 1, duration = duration, enacted = enacted, valueType = 1 };
end

local function Spice(from, duration, enacted)
	return { type = "RESOURCES", from = from, amount = 1, duration = duration, enacted = enacted, valueType = 3 };
end

local function Iron(from, duration, enacted)
	return { type = "RESOURCES", from = from, amount = 2, duration = duration, enacted = enacted, valueType = 2 };
end

local function Alliance(from)
	return { type = "AGREEMENTS", subType = "ALLIANCE", from = from, duration = 0, subTypeName = "LOC_DIPLOACTION_ALLIANCE_NAME" };
end

local function Visible(c) return not c.hidden end

local function BlocksOn(w, parent)
	local list = {};
	for _, block in ipairs(w:FlowBlocks()) do
		if block.Top.parent == parent then table.insert(list, block) end
	end
	return list;
end

local function TintChannels(block)
	local r, g, b, a = (block.Tint.color or ""):match("^([%d%.]+),([%d%.]+),([%d%.]+),([%d%.]+)$");
	return tonumber(r), tonumber(g), tonumber(b), tonumber(a);
end

local function IsLightGreen(block, what)
	local r, g, b, a = TintChannels(block);
	check(r ~= nil and g > r and g > b and a > 0 and a < 0.35, (what or "import") .. " tint " .. tostring(block.Tint.color));
end

local function IsLightRed(block, what)
	local r, g, b, a = TintChannels(block);
	check(r ~= nil and r > g and r > b and a > 0 and a < 0.35, (what or "export") .. " tint " .. tostring(block.Tint.color));
end

-- ---------------------------------------------------------------------------
test("loads without errors and stays hidden on the map", function(w)
	w:Load();
	w:Tick(30);
	check(Visible(w.Controls.DebugBox) == false, "debug box is shown");
	check(w.Controls.Root.hidden, "panel visible without diplomacy");
	check(w.Controls.ExpandButton.hidden, "expand button visible without diplomacy");
	local found = false;
	for _, l in ipairs(w.logs) do if l:find("initialized", 1, true) then found = true end end
	check(found, "no 'initialized' log line");
end);

test("timed gold and resource deal", function(w)
	w:AddDeal(0, 1, { Gold(0, 5, 30, 10), Silk(1, 30, 10) });
	w:Load();
	w:OpenDiplomacy(1);

	local root = w.Controls.Root;
	check(root.hidden, "diplomacy panel is shown");
	check(w.Controls.ExpandButton.hidden, "expand button is shown");
	check(w.Controls.Title.text:find("India", 1, true), "title has no civ: " .. w.Controls.Title.text);
	local cards = w:Cards();
	eq(#cards, 1, "card count");
	eq(cards[1].Header.text, "Turns left: 20 · since turn 10", "header");
	eq(cards[1].OursBody.text, "5 [ICON_GOLD] per turn", "ours");
	eq(cards[1].TheirsTitle.text, "Gandhi gives", "theirs title");
	eq(cards[1].TheirsBody.text, "1 [ICON_RESOURCE_SILK] Silk", "theirs");
	check(cards[1].SharedBody.hidden, "shared block shown for a one-sided deal");
end);

test("a table saved by an earlier version still shows the lump sum", function(w)
	w:AddDeal(0, 1, { Silk(1, 30, 10) });
	w.properties["UIEXT_DEAL_ARCHIVE"] = {
		deals = { ["1"] = {
			id = "-1", turn = "10", a = "0", b = "1",
			items = {
				["1"] = {
					kind = "GOLD", amount = "100", duration = "0", from = "0",
					valueType = "-1", subType = "-1", name = "", alliance = false, mutual = false,
				},
				["2"] = {
					kind = "RESOURCES", amount = "1", duration = "30", from = "1",
					valueType = "1", subType = "-1", name = "", alliance = false, mutual = false,
				},
			},
		} },
	};
	w:LoadGameplay();
	w:Load();
	w:OpenDiplomacy(1);
	local card = w:Cards()[1];
	eq(card.OursOnceBody.text, "100 [ICON_GOLD]", "lump gold restored from the old table");
	eq(card.TheirsBody.text, "1 [ICON_RESOURCE_SILK] Silk", "silk");
end);

test("one-time gold still on the deal is shown", function(w)
	w:AddDeal(0, 1, { Gold(0, 100, 0) });
	w:Load();
	w:OpenDiplomacy(1);
	local cards = w:Cards();
	eq(#cards, 1, "card count");
	eq(cards[1].Header.text, "One-time deal", "header");
	eq(cards[1].OursOnceBody.text, "100 [ICON_GOLD]", "ours one-time");
	eq(cards[1].OursOnceTitle.text, "One-time", "one-time heading");
	check(cards[1].OursTitle.y < cards[1].OursOnceTitle.y, "one-time heading is below you give");
	check(cards[1].OursTermTitle.hidden, "per-turn heading without a term");
	check(cards[1].OursBody.hidden, "no lasting items on our side");
	check(cards[1].TheirsBody.hidden, "their side shown");
end);

test("one-time items sit in a second column beside a divider", function(w)
	w:AddDeal(0, 1, { Gold(0, 100, 0), Gold(0, 5, 30, 10), Silk(1, 30, 10) });
	w:Load();
	w:OpenDiplomacy(1);
	local card = w:Cards()[1];
	check(not card.OursDivider.hidden, "divider shown beside one-time items");
	eq(card.OursBody.text, "5 [ICON_GOLD] per turn", "lasting column");
	eq(card.OursOnceBody.text, "100 [ICON_GOLD]", "one-time column");
	eq(card.OursOnceTitle.text, "One-time", "one-time title");
	eq(card.OursTermTitle.text, "Per turn", "per-turn title");
	eq(card.OursTermTitle.y, card.OursOnceTitle.y, "the two headings share a line");
	check(card.OursTitle.y < card.OursTermTitle.y, "headings are below you give");
	check(card.OursBody.y > card.OursTermTitle.y, "items are below the headings");
	check(card.OursOnceBody.x > card.OursBody.x, "one-time column is to the right");
	check(card.OursDivider.x > card.OursBody.x and card.OursDivider.x < card.OursOnceBody.x, "divider between the columns");
	check(card.TheirsDivider.hidden, "their side has no one-time items");
	check(card.TheirsOnceBody.hidden, "their one-time column hidden");
end);

test("no divider when a side has no one-time items", function(w)
	w:AddDeal(0, 1, { Gold(0, 5, 30, 10), Silk(1, 30, 10) });
	w:Load();
	w:OpenDiplomacy(1);
	local card = w:Cards()[1];
	check(card.OursDivider.hidden, "our divider hidden");
	check(card.TheirsDivider.hidden, "their divider hidden");
	check(card.OursOnceBody.hidden and card.TheirsOnceBody.hidden, "one-time columns hidden");
	check(card.OursTermTitle.hidden and card.TheirsTermTitle.hidden, "per-turn headings hidden");
	eq(card.OursBody.text, "5 [ICON_GOLD] per turn", "ours");
end);

test("alliance is open-ended and shown once as shared", function(w)
	w:AddDeal(0, 1, { Alliance(0), Alliance(1) });
	w:Load();
	w:OpenDiplomacy(1);
	local cards = w:Cards();
	eq(#cards, 1, "card count");
	eq(cards[1].Header.text, "Until ended", "header");
	eq(cards[1].SharedBody.text, "Alliance", "shared");
	check(cards[1].OursBody.hidden and cards[1].TheirsBody.hidden, "alliance also listed per side");
end);

test("different durations show turns per line", function(w)
	w:AddDeal(0, 1, { Gold(0, 5, 30, 10), Silk(1, 10, 15) });
	w:Load();
	w:OpenDiplomacy(1);
	local card = w:Cards()[1];
	eq(card.Header.text, "Items end at different times · since turn 10", "header");
	eq(card.OursBody.text, "5 [ICON_GOLD] per turn · 20", "ours");
	eq(card.TheirsBody.text, "1 [ICON_RESOURCE_SILK] Silk · 5", "theirs");
end);

test("cards are sorted by soonest expiry", function(w)
	w:AddDeal(0, 1, { Gold(0, 5, 30, 10) });
	w:AddDeal(0, 1, { Gold(1, 2, 10, 13) });
	w:Load();
	w:OpenDiplomacy(1);
	local cards = w:Cards();
	eq(#cards, 2, "card count");
	eq(cards[1].Header.text, "Turns left: 3 · since turn 13", "first card");
	eq(cards[2].Header.text, "Turns left: 20 · since turn 10", "second card");
end);

test("partner found from the open session when no event names it", function(w)
	w:AddDeal(0, 1, { Gold(0, 5, 30, 10) });
	w.sessions[1] = 7;
	w:Load();
	w:OpenDiplomacy(nil);
	check(w.Controls.Root.hidden, "diplomacy panel is shown");
	check(w.Controls.Title.text:find("India", 1, true), "title has no civ: " .. w.Controls.Title.text);
end);

test("the diplomacy panel stays hidden when its buttons are clicked", function(w)
	w:AddDeal(0, 1, { Gold(0, 5, 30, 10) });
	w:Load();
	w:OpenDiplomacy(1);
	w.Controls.CollapseButton:Click();
	w.Controls.ExpandButton:Click();
	check(w.Controls.Root.hidden, "panel shown from the diplomacy screen");
	check(w.Controls.ExpandButton.hidden, "expand button shown from the diplomacy screen");
end);

test("the deal list shows on the deal screen and hides when it closes", function(w)
	w:AddDeal(0, 1, { Gold(0, 5, 30, 10) });
	w:Load();
	w:OpenDiplomacy(1);
	check(w.Controls.Root.hidden, "panel shown before the deal screen");
	w:OpenDeal();
	check(Visible(w.Controls.Root), "panel hidden on the deal screen");
	eq(w.Controls.Root.x, 540, "panel placed right next to the trade banner (534 + 6)");
	check(w.Controls.Root.x + w.Controls.Root.w <= w.screenW, "panel runs off the right edge");
	w:CloseDeal();
	w:OpenDeal();
	check(Visible(w.Controls.Root), "panel hidden on the second deal screen");
	eq(w.Controls.Root.x, 540, "second opening keeps the position");
	w:CloseDeal();
	check(w.Controls.Root.hidden, "panel left after the deal screen closed");
end);

test("closing diplomacy hides everything", function(w)
	w:AddDeal(0, 1, { Gold(0, 5, 30, 10) });
	w:Load();
	w:OpenDiplomacy(1);
	w:CloseDiplomacy();
	check(w.Controls.Root.hidden, "panel left on the map");
	check(w.Controls.ExpandButton.hidden, "expand button left on the map");
end);

test("failing deal API does not break the panel", function(w)
	w.failDeals = true;
	w:Load();
	w:OpenDiplomacy(1);
	check(Visible(w.Controls.EmptyLabel), "empty label hidden");
end);

test("luxury export to the open leader shows the turns and a gold frame", function(w)
	w:AddDeal(0, 1, { Silk(0, 30, 10) });
	w:Load();
	w:OpenDiplomacy(1);
	eq(#w:FlowBlocks(), 0, "flows shown before the deal screen");
	w:OpenDeal();

	local mine = BlocksOn(w, w.luxuryList);
	local theirs = BlocksOn(w, w.theirLuxuryList);
	eq(#mine, 1, "our block count");
	eq(mine[1].Title.text, "Export", "block title");
	IsLightRed(mine[1], "export");
	eq(#theirs, 1, "their block count");
	eq(theirs[1].Title.text, "Import", "their import of the same silk");
	IsLightGreen(theirs[1], "their import");
	local icons = w:FlowIcons();
	eq(#icons, 2, "icon count");
	eq(icons[1].Turns.text, "20", "turns");
	eq(icons[1].Amount.text, "1", "amount");
	check(icons[1].Highlight.hidden == false, "current leader not highlighted");
	local tip = icons[1].Top.tooltip;
	check(tip:find("Silk", 1, true) ~= nil, "tooltip resource: " .. tostring(tip));
	check(tip:find("Gandhi · 1 · 20", 1, true) ~= nil, "tooltip partner: " .. tostring(tip));
	check(tip:find("*", 1, true) == nil, "star on a single deal");
	eq(icons[2].Turns.text, "20", "their turns");
	check(icons[2].Highlight.hidden == false, "they already buy it from us");
	check(icons[2].Top.tooltip:find("Peter · 1 · 20", 1, true) ~= nil, "their tooltip: " .. tostring(icons[2].Top.tooltip));
end);

test("several partners show the soonest turn and a star", function(w)
	w.players[2] = { leader = "Cleopatra", civ = "Egypt" };
	w:AddDeal(0, 1, { Silk(0, 30, 15) });
	w:AddDeal(0, 2, { Silk(0, 30, 5) });
	w:Load();
	w:OpenDiplomacy(1);
	w:OpenDeal();

	local mine = BlocksOn(w, w.luxuryList);
	eq(#mine, 1, "our block count");
	local icons = {};
	for _, icon in ipairs(w:FlowIcons()) do
		if icon.Top.parent == mine[1].Icons then table.insert(icons, icon) end
	end
	eq(#icons, 1, "icon count");
	eq(icons[1].Turns.text, "15*", "soonest turns");
	eq(icons[1].Amount.text, "2", "summed amount");
	check(icons[1].Highlight.hidden == false, "open leader not highlighted");
	local tip = icons[1].Top.tooltip;
	check(tip:find("Cleopatra · 1 · 15", 1, true) ~= nil, "soonest partner: " .. tostring(tip));
	check(tip:find("[COLOR_Gold]Gandhi · 1 · 25 turns left[ENDCOLOR]", 1, true) ~= nil, "open leader: " .. tostring(tip));
	check(tip:find("[COLOR_Gold]Cleopatra", 1, true) == nil, "other leader colored");

	local theirs = BlocksOn(w, w.theirLuxuryList);
	eq(#theirs, 1, "their import of the silk they buy from us");
	local theirIcons = {};
	for _, icon in ipairs(w:FlowIcons()) do
		if icon.Top.parent == theirs[1].Icons then table.insert(theirIcons, icon) end
	end
	eq(#theirIcons, 1, "their icon count");
	eq(theirIcons[1].Turns.text, "25", "one deal, no star");
	check(theirIcons[1].Highlight.hidden == false, "bought from us");
end);

test("import and export are separate blocks", function(w)
	w.players[2] = { leader = "Cleopatra", civ = "Egypt" };
	w:AddDeal(0, 1, { Silk(1, 30, 18) });
	w:AddDeal(0, 2, { Spice(0, 30, 16) });
	w:Load();
	w:OpenDiplomacy(1);
	w:OpenDeal();

	local mine = BlocksOn(w, w.luxuryList);
	eq(#mine, 2, "block count");
	eq(#BlocksOn(w, w.theirLuxuryList), 0, "their import of nothing");
	eq(mine[1].Title.text, "Import", "first block");
	eq(mine[2].Title.text, "Export", "second block");
	IsLightGreen(mine[1], "import");
	IsLightRed(mine[2], "export");
	local icons = w:FlowIcons();
	eq(icons[1].Turns.text, "28", "import turns");
	eq(icons[1].Amount.text, "1", "import amount");
	check(icons[1].Highlight.hidden == false, "import from the open leader");
	check(icons[1].Top.tooltip:find("Import", 1, true) ~= nil, "import heading");
	eq(icons[2].Turns.text, "26", "export turns");
	eq(icons[2].Amount.text, "1", "export amount");
	check(icons[2].Highlight.hidden, "export to someone else is highlighted");
	check(icons[2].Top.tooltip:find("Cleopatra · 1 · 26", 1, true) ~= nil, "export tooltip: " .. tostring(icons[2].Top.tooltip));
end);

test("strategic and one-time resources are not listed as flows", function(w)
	w:AddDeal(0, 1, { Iron(0, 30, 10), Silk(1, 0, 10) });
	w:Load();
	w:OpenDiplomacy(1);
	w:OpenDeal();
	eq(#w:FlowBlocks(), 0, "block count");
	eq(#w:FlowIcons(), 0, "icon count");
end);

test("the open leader's own imports show what they already buy", function(w)
	w.players[2] = { leader = "Cleopatra", civ = "Egypt" };
	w:AddDeal(1, 2, { Spice(2, 30, 10) });
	w:AddDeal(0, 1, { Silk(0, 30, 12) });
	w:Load();
	w:OpenDiplomacy(1);
	w:OpenDeal();

	local theirs = BlocksOn(w, w.theirLuxuryList);
	eq(#theirs, 1, "their block count");
	eq(theirs[1].Title.text, "Import", "their heading");
	IsLightGreen(theirs[1], "their import");
	local icons = {};
	for _, icon in ipairs(w:FlowIcons()) do
		if icon.Top.parent == theirs[1].Icons then table.insert(icons, icon) end
	end
	eq(#icons, 2, "their icon count");
	eq(icons[1].Turns.text, "20", "spices end sooner");
	check(icons[1].Highlight.hidden, "a third-party import is framed as ours");
	check(icons[1].Top.tooltip:find("Cleopatra · 1 · 20", 1, true) ~= nil, "spices seller: " .. tostring(icons[1].Top.tooltip));
	eq(icons[2].Turns.text, "22", "silk turns");
	check(icons[2].Highlight.hidden == false, "silk bought from us is not framed");
	check(icons[2].Top.tooltip:find("[COLOR_Gold]Peter · 1 · 22 turns left[ENDCOLOR]", 1, true) ~= nil, "silk seller: " .. tostring(icons[2].Top.tooltip));
	eq(#BlocksOn(w, w.luxuryList), 1, "our export of that silk");
	eq(BlocksOn(w, w.luxuryList)[1].Title.text, "Export", "our heading");
end);

test("closing the deal screen removes import and export", function(w)
	w:AddDeal(0, 1, { Silk(0, 30, 10) });
	w:Load();
	w:OpenDiplomacy(1);
	w:OpenDeal();
	eq(#w:FlowIcons(), 2, "icon count");
	w:CloseDeal();
	eq(#w:FlowBlocks(), 0, "blocks left after close");
	eq(#w:FlowIcons(), 0, "icons left after close");
	eq(#w.luxuryList.children, 2, "luxury list children");
	eq(#w.theirLuxuryList.children, 2, "their luxury list children");
end);

test("deals tab appears in the intel report when the game rebuilds the tabs", function(w)
	w:AddDeal(0, 1, { Gold(0, 5, 30, 10), Silk(1, 30, 10) });
	w:Load();
	local report = w:IntelReport();
	w.LuaEvents.DiploScene_RefreshTabs(1);

	local button, panel = w:DealsTab();
	eq(button.Button.parent, report.stack, "button parent");
	eq(button.ButtonIcon.icon, "ICON_UNIT_TRADER_WHITE", "button icon");
	check(panel.Top.hidden, "panel shown before click");
	eq(panel.Top.parent, report.container, "panel parent");
	local deals = TabDeals(w, panel);
	eq(#deals, 1, "deal count");
	eq(deals[1].header, "Turns left: 20 · since turn 10", "header");
	eq(#deals[1].sides, 2, "side count");
	eq(deals[1].sides[1].title, "You give", "ours title");
	eq(table.concat(deals[1].sides[1].items, "|"), "5 [ICON_GOLD] per turn", "ours");
	eq(deals[1].sides[2].title, "Gandhi gives", "theirs title");
	eq(table.concat(deals[1].sides[2].items, "|"), "1 [ICON_RESOURCE_SILK] Silk", "theirs");
	eq(deals[1].sides[1].width, 470, "side fits the report width");
	eq(panel.Top.w, 470, "panel fits the report width");
	check(panel.TabEmpty.hidden, "empty label shown with a deal");
end);

test("deals tab button returns to the end when the game reattaches its tabs", function(w)
	w:Load();
	local report = w:IntelReport();
	w.LuaEvents.DiploScene_RefreshTabs(1);
	local button = w:DealsTab();
	local gameButton = Mock.NewControl({ id = "GameTab" });
	table.insert(report.stack.children, 1, gameButton);
	gameButton.parent = report.stack;
	gameButton:ChangeParent(report.stack);
	eq(report.stack.children[#report.stack.children], gameButton, "game button moved last");
	w.LuaEvents.DiploScene_RefreshTabs(1);
	eq(report.stack.children[#report.stack.children], button.Button, "deals button is last again");
end);

test("a wrapped title does not separate the bullets or drop a single bullet", function(w)
	w.players[1].leader = "Cleopatra of Egypt";
	w:AddDeal(0, 1, { Gold(1, 4, 30, 10), Silk(1, 30, 10) });
	w:Load();
	w:IntelReport();
	w.LuaEvents.DiploScene_RefreshTabs(1);
	local _, panel = w:DealsTab();
	local deal = Items(w, "DealsTabDeal", panel.TabCards)[1];
	local side = Items(w, "DealsTabSide", deal.Sides)[1];
	local rows = Items(w, "DealsTabItem", side.Items);
	eq(#rows, 2, "item count");
	eq(rows[1].Top.h, 22, "first row");
	eq(rows[2].Top.h, 22, "second row");
	eq(side.Items.y, 0, "bullets start at the top");
	eq(side.Items.h, 46, "no blank row between bullets");
	eq(side.Top.h, 46, "side is no taller than its bullets");
	eq(side.TheirsTitle.y, 0, "title starts on the first bullet");
	eq(side.TheirsTitle.anchor, "L,T", "title anchor");

	w.deals = {};
	w:AddDeal(0, 1, { Gold(1, 1, 30, 10) });
	w.Events.DiplomacyDealEnacted();
	deal = Items(w, "DealsTabDeal", panel.TabCards)[1];
	side = Items(w, "DealsTabSide", deal.Sides)[1];
	eq(side.Items.y, 0, "single bullet stays at the top");
	eq(side.Items.h, 22, "single bullet row");
	eq(side.TheirsTitle.y, 0, "title stays on that bullet");
	check(side.Top.h > side.Items.h, "the wrapped second line has room under the bullet");
end);

test("a two-line side title stays pinned to the top of its row", function(w)
	w:AddDeal(0, 1, { Gold(1, 3, 30, 10) });
	w:Load();
	w:IntelReport();
	w.LuaEvents.DiploScene_RefreshTabs(1);
	local _, panel = w:DealsTab();
	local deal = TabDeals(w, panel)[1];
	eq(deal.sides[1].title, "Gandhi gives", "title");
	eq(deal.sides[1].anchor, "L,T", "title anchor");
end);

test("deals tab is added once per rebuild, not twice", function(w)
	w:Load();
	local report = w:IntelReport();
	w.LuaEvents.DiploScene_RefreshTabs(1);
	w.LuaEvents.DiploScene_RefreshTabs(1);
	eq(#report.stack.children, 1, "buttons in the same report");

	-- The game destroys the old report when it rebuilds, so it is gone from the tree.
	w.view.children = {};
	local newer = w:IntelReport();
	w.LuaEvents.DiploScene_RefreshTabs(1);
	eq(#newer.stack.children, 1, "buttons in the rebuilt report");
	eq(#report.stack.children, 0, "old report no longer holds the button");
end);

test("deals tab is added from the update tick when no event arrives", function(w)
	w:AddDeal(0, 1, { Gold(0, 5, 30, 10) });
	w:Load();
	local report = w:IntelReport();
	w:OpenDiplomacy(1);
	local button, panel = w:DealsTab();
	eq(button.Button.parent, report.stack, "button parent");
	eq(#panel.TabCards.children, 1, "card count");
end);

test("clicking the deals tab shows its panel and hides the game's panel", function(w)
	w:AddDeal(0, 1, { Gold(0, 5, 30, 10) });
	w:Load();
	local report = w:IntelReport();
	local other = Mock.NewControl({ id = "OtherTab" });
	other.selected = true;
	table.insert(report.stack.children, other);
	w.LuaEvents.DiploScene_RefreshTabs(1);
	local button, panel = w:DealsTab();

	button.Button:Click();
	check(not panel.Top.hidden, "deals panel still hidden after click");
	check(report.gamePanel.hidden, "game panel still shown after click");
	eq(report.header.text, "INTEL REPORT: DEALS", "header");
	check(button.Button:IsSelected(), "deals button not selected");
	check(not other.selected, "other tab button still selected");
end);

test("deals button highlight follows the panel", function(w)
	w:Load();
	local report = w:IntelReport();
	w.LuaEvents.DiploScene_RefreshTabs(1);
	local button, panel = w:DealsTab();
	w:OpenDiplomacy(1);

	button.Button:Click();
	w:Tick(10);
	check(button.Button:IsSelected(), "highlight off while the panel is open");

	-- The game's own tab takes over: it hides every other panel, including ours.
	for _, child in ipairs(report.container.children) do
		child:SetHide(child ~= report.gamePanel);
	end
	report.gamePanel:SetHide(false);
	w:Tick(10);
	check(not button.Button:IsSelected(), "highlight stays on after another tab is clicked");
end);

test("deals tab updates when a deal is enacted", function(w)
	w:Load();
	local report = w:IntelReport();
	w.LuaEvents.DiploScene_RefreshTabs(1);
	local _, panel = w:DealsTab();
	eq(#panel.TabCards.children, 0, "card count before");
	check(not panel.TabEmpty.hidden, "empty label hidden without deals");

	w:AddDeal(0, 1, { Gold(0, 5, 30, 10) });
	w.Events.DiplomacyDealEnacted();
	eq(#panel.TabCards.children, 1, "card count after");
	check(panel.TabEmpty.hidden, "empty label shown with a deal");
	eq(TabDeals(w, panel)[1].header, "Turns left: 20 · since turn 10", "header");
end);

test("deals tab shows a shared alliance and per-line turns", function(w)
	w:AddDeal(0, 1, { Alliance(0), Alliance(1), Gold(0, 5, 30, 10), Silk(1, 10, 15) });
	w:Load();
	w:IntelReport();
	w.LuaEvents.DiploScene_RefreshTabs(1);
	local _, panel = w:DealsTab();
	local deal = TabDeals(w, panel)[1];
	eq(deal.header, "Items end at different times · since turn 10", "header");
	eq(deal.sides[1].title, "Shared", "shared title");
	eq(table.concat(deal.sides[1].items, "|"), "Alliance · Until ended", "shared");
	eq(table.concat(deal.sides[2].items, "|"), "5 [ICON_GOLD] per turn · 20", "ours");
	eq(table.concat(deal.sides[3].items, "|"), "1 [ICON_RESOURCE_SILK] Silk · 5", "theirs");
end);

test("reused side blocks show only their own title", function(w)
	w:AddDeal(0, 1, { Gold(0, 5, 30, 10) });
	w:Load();
	w:IntelReport();
	w.LuaEvents.DiploScene_RefreshTabs(1);
	w.deals = {};
	w:AddDeal(0, 1, { Gold(1, 3, 30, 10) });
	w.Events.DiplomacyDealEnacted();
	local _, panel = w:DealsTab();
	local deal = TabDeals(w, panel)[1];
	eq(#deal.sides, 1, "side count");
	eq(deal.sides[1].title, "Gandhi gives", "title");
end);

test("deals tab lists trade routes both ways under the deals", function(w)
	w.players[2] = { leader = "Cleopatra", civ = "Egypt" };
	w:AddCity(0, 1, "Moscow");
	w:AddCity(0, 2, "Novgorod");
	w:AddCity(1, 7, "Delhi");
	w:AddCity(2, 9, "Thebes");
	w:AddRoute(0, 1, 1, 7, { [2] = 4, [3] = 1.5 }, { [2] = 2 });
	w:AddRoute(1, 7, 0, 2, { [0] = 1, [1] = 1 }, {});
	w:AddRoute(0, 2, 2, 9, { [2] = 9 }, { [2] = 9 });
	w:AddDeal(0, 1, { Gold(0, 5, 30, 10) });
	w:Load();
	w:IntelReport();
	w.LuaEvents.DiploScene_RefreshTabs(1);
	local _, panel = w:DealsTab();

	eq(#TabDeals(w, panel), 1, "deals stay apart from routes");
	check(not panel.RoutesRule.hidden, "rule between deals and routes");
	check(not panel.RoutesHeader.hidden, "routes heading");
	check(panel.RoutesEmpty.hidden, "no-routes line shown with routes");
	local routes = Items(w, "DealsTabRoute", panel.TabRoutes);
	eq(#routes, 2, "only routes with this leader");

	local ours = routes[1];
	check(Visible(ours.LeftCityOurs) and ours.LeftCityTheirs.hidden, "our origin on the left, in our color");
	eq(ours.LeftCityOurs.text, "Moscow", "our route first, origin");
	check(Visible(ours.RightCityTheirs) and ours.RightCityOurs.hidden, "their destination on the right, in their color");
	eq(ours.RightCityTheirs.text, "Delhi", "destination");
	eq(ours.LeftYields.text, "+4 [ICON_Gold]  +1.5 [ICON_Science]", "origin yield");
	eq(ours.RightYields.text, "+2 [ICON_Gold]", "destination yield");
	check(not ours.ArrowOurs.hidden and ours.ArrowTheirs.hidden, "our route has the blue arrow");

	local theirs = routes[2];
	check(Visible(theirs.LeftCityTheirs) and theirs.LeftCityOurs.hidden, "their origin on the left, in their color");
	eq(theirs.LeftCityTheirs.text, "Delhi", "their route, origin");
	check(Visible(theirs.RightCityOurs) and theirs.RightCityTheirs.hidden, "our destination on the right, in our color");
	eq(theirs.RightCityOurs.text, "Novgorod", "destination");
	eq(theirs.LeftYields.text, "+1 [ICON_Food]  +1 [ICON_Production]", "their origin yield");
	eq(theirs.RightYields.text, "No yield", "our city earns nothing");
	check(theirs.ArrowOurs.hidden and not theirs.ArrowTheirs.hidden, "their route has the orange arrow");
end);

test("short Cyrillic city names keep both yields on one line", function(w)
	w:AddCity(0, 1, "Абу-Симбел");
	w:AddCity(1, 7, "Смоленск");
	w:AddRoute(0, 1, 1, 7, { [2] = 3, [3] = 1 }, {});
	w:Load();
	w:IntelReport();
	w.LuaEvents.DiploScene_RefreshTabs(1);
	local _, panel = w:DealsTab();
	local route = Items(w, "DealsTabRoute", panel.TabRoutes)[1];
	eq(route.LeftYields.y, route.RightYields.y, "yields of both cities on one line");
	eq(route.LeftYields.y, 32, "right under a one-row name");
end);

test("many yields of a route city go on several lines", function(w)
	w:AddCity(0, 1, "Moscow");
	w:AddCity(1, 7, "Delhi");
	w:AddRoute(0, 1, 1, 7, { [0] = 1, [1] = 2, [2] = 3, [3] = 4 }, {});
	w:Load();
	w:IntelReport();
	w.LuaEvents.DiploScene_RefreshTabs(1);
	local _, panel = w:DealsTab();
	local route = Items(w, "DealsTabRoute", panel.TabRoutes)[1];
	eq(route.LeftYields.text, "+1 [ICON_Food]  +2 [ICON_Production]  +3 [ICON_Gold][NEWLINE]+4 [ICON_Science]", "yield lines");
	check(route.Row.h > route.LeftYields.y + 22, "row is tall enough for both lines");
end);

test("deals tab says when there are no trade routes", function(w)
	w:AddCity(0, 1, "Moscow");
	w:Load();
	w:IntelReport();
	w.LuaEvents.DiploScene_RefreshTabs(1);
	local _, panel = w:DealsTab();
	eq(#Items(w, "DealsTabRoute", panel.TabRoutes), 0, "route count");
	check(not panel.RoutesEmpty.hidden, "no-routes line hidden");
	check(not panel.TabEmpty.hidden, "no-deals line hidden");
end);

test("deals tab lists a one-time gold gift", function(w)
	w:AddDeal(0, 1, { Gold(0, 100, 0) });
	w:Load();
	w:IntelReport();
	w.LuaEvents.DiploScene_RefreshTabs(1);
	local _, panel = w:DealsTab();
	local deal = TabDeals(w, panel)[1];
	eq(deal.header, "One-time deal", "header");
	eq(table.concat(deal.sides[1].items, "|"), "100 [ICON_GOLD] · one-time", "ours");
	check(panel.TabEmpty.hidden, "empty label shown");
end);

test("stripped lump gold is restored from the save", function(w)
	w:AddDeal(0, 1, { Silk(1, 30, 10) });
	w.properties["UIEXT_DEALS_P0"] = table.concat({
		"D\t-1\t10\t0\t1\tGOLD/100/0/0/-1/-1//;RESOURCES/1/30/1/1/-1//\t",
		"D\t-2\t4\t0\t1\tGOLD/7/0/0/-1/-1//\t",
		"N\t-2",
	}, "~");
	w:LoadGameplay();
	w:Load();
	w:OpenDiplomacy(1);
	local card = w:Cards()[1];
	eq(#w:Cards(), 1, "expired archive deal is not a card");
	eq(card.Header.text, "Turns left: 20 · since turn 10", "one-time gold does not change the countdown");
	eq(card.OursOnceBody.text, "100 [ICON_GOLD]", "lump gold");
	eq(card.TheirsBody.text, "1 [ICON_RESOURCE_SILK] Silk", "silk");
end);

test("city, favor and a great work are shown", function(w)
	w.greatWorks[4] = { Name = "LOC_MONA_LISA", GreatWorkType = "GREATWORK_MONA_LISA" };
	w.gameText["LOC_MONA_LISA"] = "Mona Lisa";
	w:AddDeal(0, 1, {
		{ type = "DIPLOMATIC_FAVOR", from = 0, amount = 25, duration = 0 },
		{ type = "GREATWORK", from = 0, duration = 0, valueType = 4 },
		{ type = "CITIES", from = 1, duration = 0, name = "Delhi" },
	});
	w:Load();
	w:OpenDiplomacy(1);
	local card = w:Cards()[1];
	eq(card.Header.text, "One-time deal", "header");
	eq(card.OursOnceBody.text, "25 [ICON_FAVOR][NEWLINE]Great Work: Mona Lisa", "ours");
	eq(card.TheirsOnceBody.text, "City: Delhi", "theirs");
	check(card.OursBody.hidden and card.TheirsBody.hidden, "no lasting items");
end);

-- As in DiplomacyDeals.log: the game enacts the deal, drops the one-time gold,
-- and only then reports it. The deal table is read while the deal screen is open.
local function AcceptGoldForSilk(w)
	w.turn = 35;
	w:OpenDiplomacy(1);
	w.working = { a = 0, b = 1, items = { Gold(0, 100, 0), Gold(0, 10, 30), Silk(1, 30) } };
	w:OpenDeal();
	w.working = nil;
	w:AddDeal(0, 1, { Gold(0, 10, 30, 35), Silk(1, 30, 35) });
	w.Events.DiplomacyDealEnacted(0, 1);
end

-- The local player's record as the save holds it.
local function Saved(w)
	local raw = w.properties["UIEXT_DEALS_P0"];
	check(type(raw) == "string", "record is stored as text");
	return w.env.DealRecord.Normalize(raw);
end

local function StoredKinds(w)
	local saved = Saved(w);
	local kinds = {};
	for _, item in ipairs(saved.deals[1].items) do
		table.insert(kinds, item.kind .. ":" .. tostring(item.amount) .. ":" .. tostring(item.duration));
	end
	table.sort(kinds);
	return #saved.deals, table.concat(kinds, ",");
end

test("accepting a deal keeps the lump sum that the game strips", function(w)
	w:LoadGameplay();
	w:Load();
	AcceptGoldForSilk(w);
	local count, kinds = StoredKinds(w);
	eq(count, 1, "stored deals");
	eq(kinds, "GOLD:100:0,GOLD:10:30,RESOURCES:1:30", "stored items");
	local card = w:Cards()[1];
	eq(card.Header.text, "Turns left: 30 · since turn 35", "header");
	eq(card.OursBody.text, "10 [ICON_GOLD] per turn", "ours lasting");
	eq(card.OursOnceBody.text, "100 [ICON_GOLD]", "ours one-time");
	eq(card.TheirsBody.text, "1 [ICON_RESOURCE_SILK] Silk", "theirs");
end);

test("the lump sum is stored when the interface loads before the gameplay script", function(w)
	w:Load();
	w:Tick(10);
	w:LoadGameplay();
	AcceptGoldForSilk(w);
	local count, kinds = StoredKinds(w);
	eq(count, 1, "stored deals");
	eq(kinds, "GOLD:100:0,GOLD:10:30,RESOURCES:1:30", "stored items");
end);

test("after loading the save both views still show the lump sum", function(w)
	w:LoadGameplay();
	w:Load();
	AcceptGoldForSilk(w);
	w:CloseDeal();
	w:CloseDiplomacy();
	w.turn = 40;
	w:Reload();
	w:OpenDiplomacy(1);
	w:OpenDeal();
	local card = w:Cards()[1];
	eq(card.Header.text, "Turns left: 25 · since turn 35", "panel header");
	eq(card.OursBody.text, "10 [ICON_GOLD] per turn", "panel ours lasting");
	eq(card.OursOnceBody.text, "100 [ICON_GOLD]", "panel ours one-time");
	w:IntelReport();
	w.LuaEvents.DiploScene_RefreshTabs(1);
	local _, panel = w:DealsTab();
	local deal = TabDeals(w, panel)[1];
	eq(deal.header, "Turns left: 25 · since turn 35", "tab header");
	eq(deal.sides[1].title, "You give", "tab ours title");
	eq(table.concat(deal.sides[1].items, "|"), "100 [ICON_GOLD] · one-time|10 [ICON_GOLD] per turn", "tab ours");
	eq(table.concat(deal.sides[2].items, "|"), "1 [ICON_RESOURCE_SILK] Silk", "tab theirs");
end);

-- Earlier versions kept the record in one property for every player, with the
-- one-time items of a lasting deal as a separate accepted deal table, and a copy in
-- the configuration.
test("the record of an earlier version is carried over once", function(w)
	w.turn = 40;
	w:AddDeal(0, 1, { Gold(0, 10, 30, 35), Silk(1, 30, 35) });
	w.config["UIEXT_DEAL_ARCHIVE"] = table.concat({
		"D\t1006\t35\t0\t1\tGOLD/10/30/0/-1/-1//;RESOURCES/1/30/1/1/-1//\t",
		"D\t-1\t30\t1\t2\tGOLD/5/0/2/-1/-1//\t",
		"A\t35\t0\t1\tGOLD/100/0/0/-1/-1//;GOLD/10/30/0/-1/-1//;RESOURCES/1/30/1/1/-1//\tp0t35n1",
		"N\t-1",
	}, "~");
	w:LoadGameplay();
	w:Load();
	w:Tick(10);
	local saved = Saved(w);
	eq(#saved.deals, 1, "only the local player's deal");
	w.config["UIEXT_DEAL_ARCHIVE"] = "D\t-5\t20\t0\t1\tGOLD/9/0/0/-1/-1//\t~N\t-5";
	w:Reload();
	w:Tick(10);
	eq(#Saved(w).deals, 1, "not carried over again");
	w:OpenDiplomacy(1);
	w:OpenDeal();
	local card = w:Cards()[1];
	eq(card.OursOnceBody.text, "100 [ICON_GOLD]", "panel ours one-time");
	w:IntelReport();
	w.LuaEvents.DiploScene_RefreshTabs(1);
	local _, panel = w:DealsTab();
	local deal = TabDeals(w, panel)[1];
	eq(table.concat(deal.sides[1].items, "|"), "100 [ICON_GOLD] · one-time|10 [ICON_GOLD] per turn", "tab ours");
end);

-- As in the turn 98 save: the game listed the deal only after its event.
test("one-time gold survives a load when the deal is listed only after the event", function(w)
	w:LoadGameplay();
	w:Load();
	w.turn = 98;
	w:OpenDiplomacy(1);
	w.working = { a = 0, b = 1, items = { Gold(0, 100, 0), Gold(0, 10, 30) } };
	w:OpenDeal();
	w.working = nil;
	w.Events.DiplomacyDealEnacted(0, 1);
	w:AddDeal(0, 1, { Gold(0, 10, 30, 98) });
	w:Tick(5 * 60);
	w:CloseDeal();
	w:CloseDiplomacy();
	eq(#Saved(w).deals, 1, "one record for the deal");
	w.turn = 99;
	w:Reload();
	w.managers = {};
	w:Load();
	w:OpenDiplomacy(1);
	w:OpenDeal();
	local card = w:Cards()[1];
	eq(card.OursOnceBody.text, "100 [ICON_GOLD]", "panel ours one-time");
	eq(card.OursBody.text, "10 [ICON_GOLD] per turn", "panel ours lasting");
	w:IntelReport();
	w.LuaEvents.DiploScene_RefreshTabs(1);
	local _, panel = w:DealsTab();
	local deal = TabDeals(w, panel)[1];
	eq(table.concat(deal.sides[1].items, "|"), "100 [ICON_GOLD] · one-time|10 [ICON_GOLD] per turn", "tab ours");
end);

test("two deals with one leader in one turn keep their own one-time items after a load", function(w)
	w:LoadGameplay();
	w:Load();
	w.turn = 99;
	w:OpenDiplomacy(1);
	w.working = { a = 0, b = 1, items = { Gold(0, 100, 0), Gold(0, 10, 30) } };
	w:OpenDeal();
	w.working = nil;
	w.Events.DiplomacyDealEnacted(0, 1);
	w:AddDeal(0, 1, { Gold(0, 10, 30, 99) });
	w:CloseDeal();
	w.working = { a = 0, b = 1, items = { { type = "DIPLOMATIC_FAVOR", from = 0, amount = 1, duration = 0 }, Gold(0, 1, 30) } };
	w:OpenDeal();
	w.working = nil;
	w.Events.DiplomacyDealEnacted(0, 1);
	w:AddDeal(0, 1, { Gold(0, 1, 30, 99) });
	w:CloseDeal();
	w:CloseDiplomacy();
	w:Reload();
	w.managers = {};
	w:Load();
	w:OpenDiplomacy(1);
	w:OpenDeal();
	local byLasting = {};
	for _, card in ipairs(w:Cards()) do
		byLasting[card.OursBody.text] = card.OursOnceBody.text;
	end
	eq(byLasting["10 [ICON_GOLD] per turn"], "100 [ICON_GOLD]", "first deal");
	eq(byLasting["1 [ICON_GOLD] per turn"], "1 [ICON_FAVOR]", "second deal");
end);

test("a deal table left without a deal is not attached to a later one", function(w)
	w:LoadGameplay();
	w:Load();
	w.turn = 35;
	w:OpenDiplomacy(1);
	w.working = { a = 0, b = 1, items = { Gold(0, 500, 0) } };
	w:OpenDeal();
	w.working = nil;
	w:CloseDeal();
	w:OpenDeal();
	w:AddDeal(0, 1, { Silk(1, 30, 35) });
	w.Events.DiplomacyDealEnacted(0, 1);
	local _, kinds = StoredKinds(w);
	eq(kinds, "RESOURCES:1:30", "stored items");
	eq(w:Cards()[1].TheirsBody.text, "1 [ICON_RESOURCE_SILK] Silk", "card");
end);

test("the panel opens on current deals and the history tab switches", function(w)
	w:AddDeal(0, 1, { Gold(0, 5, 30, 10) });
	w:Load();
	w:OpenDiplomacy(1);
	w:OpenDeal();
	check(w.Controls.CurrentTab:IsSelected(), "current tab not selected");
	check(not w.Controls.CurrentTabSelected.hidden, "current tab face");
	check(w.Controls.HistoryTabSelected.hidden, "history tab face");
	eq(#w:Cards(), 1, "current card count");
	w.Controls.HistoryTab:Click();
	check(w.Controls.HistoryTab:IsSelected(), "history tab not selected");
	check(not w.Controls.CurrentTab:IsSelected(), "current tab still selected");
	eq(#w:Cards(), 0, "history card count");
	check(Visible(w.Controls.EmptyLabel), "empty label hidden");
	eq(w.Controls.EmptyLabel.text, "No finished deals.", "empty history text");
	eq(w.Controls.ExpandButton.text, "Deals: 1", "expand button still counts current deals");
	local historyH, historyY = w.Controls.Root.h, w.Controls.Root.y;
	w.Controls.CurrentTab:Click();
	eq(#w:Cards(), 1, "back on current deals");
	eq(w.Controls.Root.h, historyH, "panel height does not change with the tab");
	eq(w.Controls.Root.y, historyY, "panel top does not move with the tab");
	eq(w.Controls.EmptyLabel.text, "No active deals.", "empty current text");
end);

test("history shows finished deals with their turns and years", function(w)
	w.turn = 50;
	w:AddDeal(0, 1, { Gold(0, 5, 30, 45) });
	w.properties["UIEXT_DEALS_P0"] = table.concat({
		"D\t-1\t10\t0\t1\tGOLD/100/0/0/-1/-1//;RESOURCES/1/30/1/1/-1//\t",
		"D\t-2\t20\t0\t1\tGOLD/40/0/1/-1/-1//\t",
		"D\t-4\t12\t0\t1\tGOLD/3/30/0/-1/-1//;RESOURCES/1/10/1/1/-1//\t30",
		"N\t-4",
	}, "~");
	w:LoadGameplay();
	w:Load();
	w:OpenDiplomacy(1);
	w:OpenDeal();
	w.Controls.HistoryTab:Click();
	local cards = w:Cards();
	eq(#cards, 3, "history card count");
	eq(cards[1].Header.text, "From turn 10 (3600 BC) to turn 40 (2400 BC)", "term ran out");
	eq(cards[1].OursOnceBody.text, "100 [ICON_GOLD]", "one-time part of a lasting deal");
	eq(cards[1].TheirsBody.text, "1 [ICON_RESOURCE_SILK] Silk", "lasting part");
	eq(cards[2].Header.text, "From turn 12 (3520 BC) to turn 30 (2800 BC)", "cut short");
	eq(cards[2].OursBody.text, "3 [ICON_GOLD] per turn · until turn 30", "line that ran to the end");
	eq(cards[2].TheirsBody.text, "1 [ICON_RESOURCE_SILK] Silk · until turn 22", "line that ended earlier");
	eq(cards[3].Header.text, "One-time, on turn 20 (3200 BC)", "one-time exchange");
	eq(cards[3].TheirsOnceBody.text, "40 [ICON_GOLD]", "one-time gold");
	local saved = Saved(w);
	eq(w.env.DealRecord.FindID(saved, -1).ended, 40, "end turn written to the save");
	eq(#saved.deals, 4, "the running deal is recorded too");
end);

-- As in DiplomacyDeals.log, turn 92: a trade and two gifts with one leader in one turn.
-- The game deletes each of them as soon as it is enacted.
local function TradeAndTwoGifts(w)
	w.turn = 92;
	w:OpenDiplomacy(1);
	for _, items in ipairs({
		{ Gold(0, 100, 0), { type = "DIPLOMATIC_FAVOR", from = 1, amount = 20, duration = 0 } },
		{ Gold(0, 100, 0) },
		{ Gold(0, 60, 0) },
	}) do
		w.working = { a = 0, b = 1, items = items };
		w:OpenDeal();
		w.working = nil;
		w.Events.DiplomacyDealEnacted(0, 1);
		w:CloseDeal();
	end
	w:OpenDeal();
	w.Controls.HistoryTab:Click();
	local bodies = {};
	for _, card in ipairs(w:Cards()) do
		eq(card.Header.text, "One-time, on turn 92 (320 BC)", "header");
		table.insert(bodies, card.OursOnceBody.text .. "|" .. card.TheirsOnceBody.text);
	end
	table.sort(bodies);
	return table.concat(bodies, " ; ");
end

test("gifts made after a trade in the same turn reach the history", function(w)
	w:LoadGameplay();
	w:Load();
	eq(TradeAndTwoGifts(w), "100 [ICON_GOLD]| ; 100 [ICON_GOLD]|20 [ICON_FAVOR] ; 60 [ICON_GOLD]|", "history");
end);

test("gifts reach the history when the interface loads before the gameplay script", function(w)
	w:Load();
	w:Tick(10);
	w:LoadGameplay();
	eq(TradeAndTwoGifts(w), "100 [ICON_GOLD]| ; 100 [ICON_GOLD]|20 [ICON_FAVOR] ; 60 [ICON_GOLD]|", "history");
end);

local function TwoEqualGifts(w)
	w.turn = 92;
	w:OpenDiplomacy(1);
	for _ = 1, 2 do
		w.working = { a = 0, b = 1, items = { Gold(0, 60, 0) } };
		w:OpenDeal();
		w.working = nil;
		w.Events.DiplomacyDealEnacted(0, 1);
		w:CloseDeal();
	end
	w:CloseDiplomacy();
end

local function HistoryAfterReload(w)
	w:Reload();
	w:OpenDiplomacy(1);
	w:OpenDeal();
	w.Controls.HistoryTab:Click();
	local bodies = {};
	for _, card in ipairs(w:Cards()) do table.insert(bodies, card.OursOnceBody.text) end
	return table.concat(bodies, " ; ");
end

test("two equal gifts in one turn are two history cards, also after a load", function(w)
	w:LoadGameplay();
	w:Load();
	TwoEqualGifts(w);
	w.turn = 93;
	eq(HistoryAfterReload(w), "60 [ICON_GOLD] ; 60 [ICON_GOLD]", "history");
end);

test("the journal in the save says what the record took from the game", function(w)
	w:LoadGameplay();
	w:Load();
	w.turn = 90;
	w:OpenDiplomacy(1);
	w.working = { a = 0, b = 1, items = { Silk(0, 30), Gold(1, 50, 0) } };
	w:OpenDeal();
	w.working = nil;
	w.Events.DiplomacyDealEnacted(0, 1);
	w:AddDeal(0, 1, { Silk(0, 30, 90) });
	w:Tick(5 * 60);
	w.deals = {};
	w.turn = 95;
	w.Events.LocalPlayerTurnBegin();
	local journal = w.properties[w.env.DealRecord.LOG_GAMEPLAY];
	check(journal:find("t90 UI accepted -1(0,1)t90[RESOURCES1/30<0,GOLD50/0<1]", 1, true), "deal table: " .. journal);
	check(journal:find("t95 UI turn end -1(0,1)t90[RESOURCES1/30<0,GOLD50/0<1] ended=95 notified", 1, true), "end: " .. journal);
	eq(#Saved(w).deals, 1, "the listed deal is the accepted one");
end);

test("interface diagnostics land in the gameplay journal", function(w)
	w:LoadGameplay();
	w:Load();
	w:Tick(10);
	local function journal() return w.properties[w.env.DealRecord.LOG_GAMEPLAY] end
	w:OpenDiplomacy(1);
	check(journal():find("UI diag screen av=1- dv=0- conv=- over=- fade=- with=1 session=nil from=nil open=1", 1, true),
		"diplomacy opened: " .. journal());
	w.Events.DiplomacyStatement(0, 1, { StatementType = 5, SessionID = 7 });
	check(journal():find("UI diag statement 0->1 5/nil response=nil session=7", 1, true), "statement: " .. journal());
end);

test("nothing ends when the game cannot be asked", function(w)
	w.properties["UIEXT_DEALS_P0"] = "D\t-1\t10\t0\t1\tRESOURCES/1/30/1/1/-1//\t~N\t-1";
	w.failDeals = true;
	w:LoadGameplay();
	w:Load();
	w:OpenDiplomacy(1);
	w:OpenDeal();
	w.Controls.HistoryTab:Click();
	w.Events.LocalPlayerTurnBegin();
	eq(#w:Cards(), 0, "history card count");
	eq(Saved(w).deals[1].ended, nil, "still running");
end);

test("an item the game marks expired no longer keeps the deal running", function(w)
	w.turn = 30;
	w:AddDeal(0, 1, { Silk(1, 30, 10) });
	w:LoadGameplay();
	w:Load();
	w:Tick(10);
	w.deals[1].items[1].expired = true;
	w.turn = 40;
	w.Events.LocalPlayerTurnBegin();
	eq(Saved(w).deals[1].ended, 40, "ended");
	eq(#w.notifications, 1, "announced");
end);

test("failing deal API leaves the luxury list untouched", function(w)
	w.failDeals = true;
	w:Load();
	w:OpenDiplomacy(1);
	w:OpenDeal();
	eq(#w:FlowBlocks(), 0, "block count");
	eq(#w:Errors(), 0, "error count");
end);

-- ---------------------------------------------------------------------------
-- A finished deal put back on the table
-- ---------------------------------------------------------------------------
-- Silk for spices, 103 gold and 1 gold per turn, finished on turn 40.
local SILK_FOR_SPICES = "RESOURCES/1/30/0/1/-1//;RESOURCES/1/30/1/3/-1//;GOLD/103/0/1/-1/-1//;GOLD/1/30/1/-1/-1//";

local function TableText(w)
	local parts = {};
	for _, item in ipairs(w.working.items) do
		table.insert(parts, string.format("%s:%s:%s:%s:%s", item.type, tostring(item.from), tostring(item.amount),
			tostring(item.duration), tostring(item.valueType or -1)));
	end
	return table.concat(parts, ",");
end

local function HistoryReady(w)
	w.turn = 50;
	w.properties["UIEXT_DEALS_P0"] = "D\t-1\t10\t0\t1\t" .. SILK_FOR_SPICES .. "\t40~N\t-1";
	w:Wallet(0).resources[1] = 1;
	w:Wallet(0).gold = 10;
	w:Wallet(1).resources[3] = 2;
	w:Wallet(1).gold = 150;
	w:Wallet(1).perTurn = 4;
	w:LoadGameplay();
	w:Load();
	w:OpenDiplomacy(1);
	w.working = { a = 0, b = 1, items = { Gold(0, 7, 0) } };
	w:OpenDeal();
	w.Controls.HistoryTab:Click();
	eq(#w:Cards(), 1, "history card count");
	return w:Cards()[1];
end

local function Logged(w, text)
	for _, line in ipairs(w.logs) do
		if line:find(text, 1, true) then return true end
	end
	return false;
end

test("clicking a finished deal puts the same terms on the table", function(w)
	local card = HistoryReady(w);
	check(Visible(card.Pick), "history card is not clickable");
	check(card.Pick.tooltip:find("same terms", 1, true), "tooltip " .. tostring(card.Pick.tooltip));
	card.Pick:Click();
	eq(TableText(w), "RESOURCES:0:1:30:1,RESOURCES:1:1:30:3,GOLD:1:103:0:-1,GOLD:1:1:30:-1", "deal table");
	eq(w.dealViewShows, 1, "the deal screen reads the table again");
	eq(w.sounds[1], "UI_GreatWorks_Put_Down", "sound");
end);

test("nothing changes when the treasury no longer holds the lump sum", function(w)
	local card = HistoryReady(w);
	w:Wallet(1).gold = 88;
	card.Pick:Click();
	eq(TableText(w), "GOLD:0:7:0:-1", "deal table");
	eq(w.dealViewShows, 0, "deal screen shown again");
	check(Logged(w, "not available [GOLD103/0<1]"), "reason not logged");
end);

test("gold per turn over the limit leaves the table as it was", function(w)
	local card = HistoryReady(w);
	w:Wallet(1).perTurn = 0;
	card.Pick:Click();
	eq(TableText(w), "GOLD:0:7:0:-1", "deal table restored");
	eq(w.dealViewShows, 0, "deal screen shown again");
end);

test("nothing changes when a resource is gone or a deal is pending", function(w)
	local card = HistoryReady(w);
	w:Wallet(0).resources[1] = 0;
	card.Pick:Click();
	eq(TableText(w), "GOLD:0:7:0:-1", "without silk");
	w:Wallet(0).resources[1] = 1;
	w.pending = true;
	card.Pick:Click();
	eq(TableText(w), "GOLD:0:7:0:-1", "with a pending deal");
end);

test("agreements go back on the table, a shared one once", function(w)
	w.turn = 50;
	w.gameText["LOC_OPEN_BORDERS"] = "Open Borders";
	w.gameText["LOC_DEFENSIVE_PACT"] = "Defensive Pact";
	w.properties["UIEXT_DEALS_P0"] = "D\t-1\t10\t0\t1\t"
		.. "AGREEMENTS/0/30/0/-1/1//LOC_OPEN_BORDERS;AGREEMENTS/0/30/1/-1/1//LOC_OPEN_BORDERS;"
		.. "AGREEMENTS/0/30/0/-1/3/m/LOC_DEFENSIVE_PACT;AGREEMENTS/0/30/1/-1/3/m/LOC_DEFENSIVE_PACT\t40~N\t-1";
	for _, from in ipairs({ 0, 1 }) do
		table.insert(w.possible, { from = from, type = "AGREEMENTS", SubType = 1 });
		table.insert(w.possible, { from = from, type = "AGREEMENTS", SubType = 3 });
	end
	w:LoadGameplay();
	w:Load();
	w:OpenDiplomacy(1);
	w.working = { a = 0, b = 1, items = {} };
	w:OpenDeal();
	w.Controls.HistoryTab:Click();
	w:Cards()[1].Pick:Click();
	local parts = {};
	for _, item in ipairs(w.working.items) do
		table.insert(parts, item.type .. ":" .. tostring(item.from) .. ":" .. tostring(item.subTypeValue) .. ":" .. tostring(item.duration));
	end
	eq(table.concat(parts, ","), "AGREEMENTS:0:1:30,AGREEMENTS:1:1:30,AGREEMENTS:0:3:30", "deal table");
	w.possible = {};
	w.working = { a = 0, b = 1, items = {} };
	w:Cards()[1].Pick:Click();
	eq(#w.working.items, 0, "an agreement the game no longer offers");
end);

test("a current deal card is not clickable", function(w)
	w:AddDeal(0, 1, { Gold(0, 5, 30, 10) });
	w:Load();
	w:OpenDiplomacy(1);
	w:OpenDeal();
	check(w:Cards()[1].Pick.hidden, "current deal card is clickable");
end);

-- ---------------------------------------------------------------------------
-- Notification that a deal finished
-- ---------------------------------------------------------------------------
local function RunningSilkForSpices(w)
	w.turn = 39;
	w.properties["UIEXT_DEALS_P0"] = "D\t-1\t10\t0\t1\t" .. SILK_FOR_SPICES .. "\t~N\t-1";
	w:AddDeal(0, 1, { Silk(0, 30, 10), Spice(1, 30, 10), Gold(1, 1, 30, 10) });
	w:LoadGameplay();
	w:Load();
	w:Tick(10);
end

-- Between turns the game drops the deal; the next turn begins for the local player.
local function EndTurn(w, turn)
	w.deals = {};
	w.turn = turn;
	w.Events.LocalPlayerTurnBegin();
end

test("a deal that ran out is announced with what changed hands", function(w)
	RunningSilkForSpices(w);
	eq(#w.notifications, 0, "nothing while it runs");
	EndTurn(w, 40);
	eq(#w.notifications, 1, "notifications");
	local sent = w.notifications[1];
	eq(sent.player, 0, "player");
	eq(sent.type, 509, "user-defined type");
	eq(sent.params.Message, "Deal with Gandhi expired", "title");
	eq(sent.params.Summary, "You gave: 1 [ICON_RESOURCE_SILK] Silk[NEWLINE]"
		.. "You received: 1 [ICON_RESOURCE_SPICES] Spices, 103 [ICON_GOLD] · one-time, 1 [ICON_GOLD] per turn[NEWLINE]"
		.. "Click to open the deal history with this leader.", "text");
	eq(sent.params.UIExtPartner, 1, "partner");
	eq(sent.params.UIExtDealID, -1, "deal");
	EndTurn(w, 41);
	eq(#w.notifications, 1, "announced once");
	w:Reload();
	w:Tick(10);
	eq(#w.notifications, 1, "not again after a load");
end);

test("a deal cut short by war says it ended, as soon as the game drops it", function(w)
	RunningSilkForSpices(w);
	w.turn = 25;
	w.deals = {};
	w.Events.DiplomacyDeclareWar(0, 1);
	eq(#w.notifications, 1, "notifications");
	eq(w.notifications[1].type, 508, "broken-deal type");
	eq(w.notifications[1].params.Message, "Deal with Gandhi ended", "title");
	eq(Saved(w).deals[1].ended, 25, "end turn in the save");
end);

test("a deal the game drops a moment after the war event is still caught", function(w)
	RunningSilkForSpices(w);
	w.turn = 25;
	w.Events.DiplomacyDeclareWar(0, 1);
	w.deals = {};
	w:Tick(5 * 60);
	eq(#w.notifications, 1, "notifications");
end);

test("a deal found gone long after its term is not announced", function(w)
	RunningSilkForSpices(w);
	EndTurn(w, 60);
	eq(#w.notifications, 0, "notifications");
	eq(Saved(w).deals[1].ended, 40, "it still ends with its term");
end);

test("in a network game the record and the notification go through player operations", function(w)
	w.network = true;
	RunningSilkForSpices(w);
	EndTurn(w, 40);
	eq(#w.notifications, 1, "notifications");
	eq(Saved(w).deals[1].ended, 40, "end turn in the save");
	local kinds = {};
	for _, op in ipairs(w.operations) do kinds[op.params.OnStart] = true end
	check(kinds.UIExt_PutDealRecord and kinds.UIExt_NotifyDealEnded, "operations");
end);

test("clicking the notification opens the deal screen on the history at that deal", function(w)
	w.turn = 39;
	w.properties["UIEXT_DEALS_P0"] = table.concat({
		"D\t-1\t5\t0\t1\tGOLD/3/20/0/-1/-1//\t25",
		"D\t-2\t10\t0\t1\t" .. SILK_FOR_SPICES .. "\t",
		"N\t-2",
	}, "~");
	w:AddDeal(0, 1, { Silk(0, 30, 10), Spice(1, 30, 10), Gold(1, 1, 30, 10) });
	w:LoadGameplay();
	w:Load();
	w:Tick(10);
	EndTurn(w, 40);
	eq(#w.notifications, 1, "notifications");
	w.working = { a = 0, b = 1, items = { Gold(0, 7, 0) } };
	w.LuaEvents.NotificationPanel_UserNotificationActivate(0, 1);
	eq(#w.requests, 1, "session requests");
	eq(w.requests[1].b, 1, "with the partner");
	eq(w.requests[1].kind, "MAKE_DEAL", "a deal session");
	eq(#w.working.items, 0, "the table starts empty");
	w:OpenDiplomacy(1);
	w:OpenDeal();
	check(w.Controls.HistoryTab:IsSelected(), "history tab not selected");
	local cards = w:Cards();
	eq(#cards, 2, "history card count");
	check(Visible(cards[1].Focus), "the finished deal is not highlighted");
	check(cards[2].Focus.hidden, "another deal is highlighted");
	eq(w.Controls.Scroll.scroll, 0, "scrolled to the deal");
	w:CloseDiplomacy();
	w:OpenDiplomacy(1);
	w:OpenDeal();
	check(w:Cards()[1].Focus.hidden, "highlight kept after closing");
end);

test("other notifications are left to the game", function(w)
	w:Load();
	w.notifications[1] = { player = 0, type = 509, params = { Message = "Pirates" } };
	w.LuaEvents.NotificationPanel_UserNotificationActivate(0, 1);
	eq(#w.requests, 0, "session requests");
end);

-- ---------------------------------------------------------------------------
-- Static checks
-- ---------------------------------------------------------------------------
local function StaticTests()
	local failures = {};
	local english, russian = Mock.ParseText(Mock.ReadFile(MOD_DIR .. "/Text/DealOverview_Text.xml"));
	for tag in pairs(english) do
		if russian[tag] == nil then table.insert(failures, "no ru_RU text for " .. tag) end
	end
	for _, file in ipairs({
		"/UI/DealOverview.lua", "/UI/DealOverview.xml",
		"/Scripts/DealArchive.lua", "/Scripts/DealRecord.lua",
	}) do
		for tag in Mock.ReadFile(MOD_DIR .. file):gmatch("LOC_UIEXT_[%w_]+") do
			if english[tag] == nil then table.insert(failures, file .. " uses undefined " .. tag) end
		end
	end
	-- The tab is added next to the game's report tabs, not by replacing the diplomacy script.
	local overlay = Mock.ReadFile(MOD_DIR .. "/UI/DealOverview.lua");
	for _, needle in ipairs({ "DiploScene_RefreshTabs", "IntelTabButtonStack", "IntelPanelContainer", "DealsTabButton" }) do
		if overlay:find(needle, 1, true) == nil then
			table.insert(failures, "deals tab missing " .. needle);
		end
	end
	local modinfo = Mock.ReadFile(MOD_DIR .. "/UI_Extender.modinfo");
	if modinfo:find("ReplaceUIScript", 1, true) ~= nil then
		table.insert(failures, "modinfo replaces the diplomacy script again");
	end
	if modinfo:find("AddGameplayScripts", 1, true) == nil or modinfo:find("Scripts/DealArchive.lua", 1, true) == nil then
		table.insert(failures, "modinfo does not load the deal archive");
	end
	for path in Mock.ReadFile(MOD_DIR .. "/UI_Extender.modinfo"):gmatch("<File>(.-)</File>") do
		local f = io.open(MOD_DIR .. "/" .. path, "r");
		if f == nil then table.insert(failures, "modinfo lists missing file " .. path) else f:close() end
	end
	return failures;
end

-- ---------------------------------------------------------------------------
local failed = 0;
for _, t in ipairs(tests) do
	local w = NewWorld();
	local ok, err = pcall(t.fn, w);
	if ok then
		local problems = w:Errors();
		for _, line in ipairs(w:AllTexts()) do
			if line:find("LOC_", 1, true) then table.insert(problems, "unresolved text " .. line) end
		end
		if #problems > 0 then
			ok, err = false, table.concat(problems, "\n    ");
		end
	end
	if ok then
		print("ok    " .. t.name);
	else
		failed = failed + 1;
		print("FAIL  " .. t.name .. "\n    " .. tostring(err));
		if #w.logs > 0 then print("    mod log:\n      " .. table.concat(w.logs, "\n      ")) end
	end
end

local static = StaticTests();
if #static == 0 then
	print("ok    static: texts, LOC keys, modinfo files");
else
	failed = failed + 1;
	print("FAIL  static\n    " .. table.concat(static, "\n    "));
end

print(string.format("\n%d of %d failed", failed, #tests + 1));
os.exit(failed == 0 and 0 or 1);
