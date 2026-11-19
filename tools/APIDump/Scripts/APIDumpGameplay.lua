-- Gameplay context dumper: GameEvents and the gameplay-side Players, Game and Map, whose
-- methods differ from the UI ones.
include("APIDumpCore");

APIDump.SpyEvents("Gameplay", GameEvents, "GameEvents");

Events.LoadScreenClose.Add(function()
	APIDump.Run("Gameplay");
end);
