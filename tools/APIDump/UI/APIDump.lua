-- UI context dumper: Events, LuaEvents, UI, DealManager and the rest of what InGame UI sees.
include("APIDumpCore");

ContextPtr:SetHide(true);

APIDump.SpyEvents("UI", Events, "Events");
APIDump.SpyEvents("UI", LuaEvents, "LuaEvents");

Events.LoadGameViewStateDone.Add(function()
	APIDump.Run("UI");
end);
