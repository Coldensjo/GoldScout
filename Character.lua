-- Gold Scout character progress: levels, experience, kills, quests, skills, reputation, dungeons,
-- duels, honor, time played and where the time goes. The Progress tab (Progress.lua) reads it.
--
-- Journal lines added here (see Journal.lua for the format and the lines it writes itself):
--   kill     |npcID|name|zone|mobLevel      a monster you or your pet fought that died tagged to you, or a
--                                           corpse you looted; once per corpse. In a group only looted corpses.
--   xp       |source|amount|detail          source = kill (detail: the mob), quest (quest id), explore (area), other
--   skill    |name|rank|max                 a profession or weapon skill went up (one line per point)
--   rep      |faction|delta|standing        reputation gained or lost; standing is the standing id (4 = neutral)
--   instance |enter|name|type               type = party, raid, pvp, arena
--   instance |leave|name|type|seconds
--   duel     |won/lost|opponent|how         how = knockout, retreat
--   hk       |victim|honor                  an honorable kill
--   accept   |questID|title                 a quest accepted
--   abandon  |questID                       a quest abandoned
--   zone     |name                          entered a zone
-- GoldScoutDB.chars[key]:
--   played = { total, level, at }           seconds played in total and at this level, as the server reported
--   levels = { [level] = { played, from, to } }   seconds played at each level, and when it was reached and left
--   days   = { [YYYY-MM-DD] = { played, combat, zones = { [name] = seconds }, casts = { [spellID] = n } } }
--   gear   = { [slot] = itemID }, xp, xpMax, rested, rep = { [faction] = { standing, value } }
-- GoldScoutDB.quests[questID] = title

local _, ns = ...

local TICK = 30 -- seconds between bookkeeping ticks
local ENGAGED_MEMORY = 600 -- seconds a fought monster is remembered after leaving combat

local key, char
local function Log(...)
	if ns.Log then ns.Log(...) end
end

-- A global string ("%s has defeated %s in a duel", or with positional "%1$s ... %2$s") as a Lua pattern.
-- Returns the pattern and, for each capture, which argument of the format it is.
local function Pattern(fmt, prefix)
	if not fmt then return nil end
	if prefix then
		-- only up to and including the first number, so suffixes like "(+5 group bonus)" do not matter
		local cut = fmt:find("%%%d?%$?d")
		if cut then fmt = fmt:sub(1, (fmt:find("d", cut, true))) end
	end
	local order, n = {}, 0
	local p = fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
	p = p:gsub("%%(%d?)%%?%$?([sd])", function(pos, kind)
		n = n + 1
		order[n] = tonumber(pos) or n
		return kind == "s" and (prefix and "(.-)" or "(.+)") or "(%d+)"
	end)
	return "^" .. p .. (prefix and "" or "$"), order
end

-- Captures of msg against a global string, in the order of the format's arguments
local compiled = {}
local function Match(msg, fmt, prefix)
	if not fmt then return nil end
	local c = compiled[fmt]
	if not c then
		local p, order = Pattern(fmt, prefix)
		c = { p, order }
		compiled[fmt] = c
	end
	local caps = { msg:match(c[1]) }
	if #caps == 0 then return nil end
	local out = {}
	for i, v in ipairs(caps) do out[c[2][i] or i] = v end
	return unpack(out, 1, #caps)
end

local function Today() return date("%Y-%m-%d") end

local function DayRecord()
	char.days = char.days or {}
	local k = Today()
	local d = char.days[k]
	if not d then
		d = { played = 0, combat = 0, zones = {}, casts = {} }
		char.days[k] = d
	end
	return d
end

local function LevelRecord(level)
	char.levels = char.levels or {}
	local l = char.levels[level]
	if not l then
		l = { played = 0, from = time() }
		char.levels[level] = l
	end
	return l
end

------------------------------------------------------------------------------------------------
-- Time: played in total, at this level, today, in this zone, in combat

local level, zone, inside
local tickedAt, combatAt
local session = { start = time(), xp = 0, kills = 0, quests = 0, deaths = 0 }

local function Tick()
	if not char then return end
	local now = GetTime()
	local dt = now - (tickedAt or now)
	tickedAt = now
	if dt <= 0 then return end
	local d = DayRecord()
	d.played = d.played + dt
	if zone then d.zones[zone] = (d.zones[zone] or 0) + dt end
	if combatAt then
		d.combat = d.combat + (now - combatAt)
		combatAt = now
	end
	LevelRecord(level).played = LevelRecord(level).played + dt
	if char.played then char.played.total = char.played.total + dt end
end

local function RequestPlayed()
	if not RequestTimePlayed then return end
	-- the Blizzard UI prints "Total time played" for every answer; keep ours quiet
	local shown = ChatFrame_DisplayTimePlayed
	if shown then ChatFrame_DisplayTimePlayed = function() end end
	pcall(RequestTimePlayed)
	C_Timer.After(5, function()
		if shown and ChatFrame_DisplayTimePlayed ~= shown then ChatFrame_DisplayTimePlayed = shown end
	end)
end

local function PlayedReported(total, atLevel)
	Tick()
	char.played = { total = total, level = atLevel, at = time() }
	-- the server's number for this level is the truth; our ticks continue from it
	LevelRecord(level).played = atLevel
end

------------------------------------------------------------------------------------------------
-- Kills: a monster on your threat list that dies while its tag is yours, or a corpse you loot

local engaged = {}
local corpses, corpseOrder = {}, {}

local function NpcID(guid)
	if not guid then return nil end
	local kind, _, _, _, _, id = strsplit("-", guid)
	if kind == "Creature" or kind == "Vehicle" then return tonumber(id) end
end

local function Counted(guid)
	if corpses[guid] then return true end
	corpses[guid] = true
	corpseOrder[#corpseOrder + 1] = guid
	if #corpseOrder > 1500 then corpses[table.remove(corpseOrder, 1)] = nil end
	return false
end

local function Kill(guid, name, mobLevel)
	local id = NpcID(guid)
	if not id or not char or Counted(guid) then return end
	session.kills = session.kills + 1
	Log("kill", id, name or "?", GetZoneText(), mobLevel or 0)
end

-- Journal.lua calls this for every corpse it reads a loot window from
function ns.LootedCorpse(guid, name)
	Kill(guid, name, nil)
end

local Threat = UnitThreatSituation or function() return nil end
local function TapDenied(unit)
	if UnitIsTapDenied then return UnitIsTapDenied(unit) end
	if UnitIsTapped then return UnitIsTapped(unit) and not UnitIsTappedByPlayer(unit) end
	return false
end

local function OnThreat(unit)
	local guid = UnitGUID(unit)
	if not NpcID(guid) then return end
	if Threat("player", unit) or (UnitExists("pet") and Threat("pet", unit)) then engaged[guid] = GetTime() end
end

local function OnHealth(unit)
	local guid = UnitGUID(unit)
	if not guid or not engaged[guid] or not UnitIsDead(unit) then return end
	engaged[guid] = nil
	if IsInGroup() or TapDenied(unit) then return end
	Kill(guid, UnitName(unit), UnitLevel(unit))
end

local function ForgetOld()
	local now = GetTime()
	for guid, t in pairs(engaged) do
		if now - t > ENGAGED_MEMORY then engaged[guid] = nil end
	end
end

------------------------------------------------------------------------------------------------
-- Experience: every change of the XP bar, attributed to the kill, quest or discovery just reported

local xp, xpMax, xpLevel -- the bar as last read; the level is kept apart from PLAYER_LEVEL_UP, which can fire first or last
local xpSource, xpDetail, xpAt

local function Attribute(source, detail)
	xpSource, xpDetail, xpAt = source, detail, GetTime()
end

local XP_KILL = { COMBATLOG_XPGAIN_FIRSTPERSON, COMBATLOG_XPGAIN_EXHAUSTION1, COMBATLOG_XPGAIN_EXHAUSTION2,
	COMBATLOG_XPGAIN_FIRSTPERSON_GROUP, COMBATLOG_XPGAIN_EXHAUSTION4, COMBATLOG_XPGAIN_EXHAUSTION5 }

local function OnXPMessage(msg)
	for _, fmt in ipairs(XP_KILL) do
		local name = Match(msg, fmt, true)
		if name then return Attribute("kill", name) end
	end
	-- "You gain 120 experience." (no name): still a kill, from the group
	if Match(msg, COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED, true) then Attribute("kill", "") end
end

local function OnXP()
	local now, max, lvl = UnitXP("player"), UnitXPMax("player"), UnitLevel("player")
	if xp then
		local delta
		if lvl > xpLevel then delta = (xpMax - xp) + now else delta = now - xp end
		if delta > 0 then
			-- the chat line that explains it can arrive just after the bar moved
			C_Timer.After(0.2, function()
				local src, detail = "other", ""
				if xpAt and GetTime() - xpAt < 2 then src, detail = xpSource, xpDetail or "" end
				xpAt = nil
				session.xp = session.xp + delta
				Log("xp", src, delta, detail)
			end)
		end
	end
	xp, xpMax, xpLevel = now, max, lvl
	char.xp, char.xpMax = now, max
	char.rested = GetXPExhaustion and GetXPExhaustion() or nil
end

------------------------------------------------------------------------------------------------
-- Skills and reputation

local skills = {}

local function ReadSkills()
	local out = {}
	if GetNumSkillLines then
		for i = 1, GetNumSkillLines() do
			local name, header, _, rank, _, _, max = GetSkillLineInfo(i)
			if name and not header then out[name] = { rank, max } end
		end
	elseif GetProfessions then
		for _, idx in pairs({ GetProfessions() }) do
			local name, _, rank, max = GetProfessionInfo(idx)
			if name then out[name] = { rank, max } end
		end
	end
	return out
end

local function OnSkills(baseline)
	local now = ReadSkills()
	if not baseline then
		for name, s in pairs(now) do
			local old = skills[name]
			if old and s[1] > old[1] then
				for r = old[1] + 1, s[1] do Log("skill", name, r, s[2]) end
			end
		end
	end
	skills = now
end

local function Standing(faction)
	if not GetNumFactions then return "" end
	for i = 1, GetNumFactions() do
		local name, _, standing, _, _, value, _, _, header = GetFactionInfo(i)
		if name == faction and not header then return standing or "", value end
	end
	return ""
end

local function OnReputation(msg)
	local faction, n = Match(msg, FACTION_STANDING_INCREASED)
	local sign = 1
	if not faction then
		faction, n = Match(msg, FACTION_STANDING_DECREASED)
		sign = -1
	end
	if not faction then return end
	Log("rep", faction, sign * (tonumber(n) or 0), (Standing(faction)))
end

local function SaveReputation()
	if not GetNumFactions then return end
	local rep = {}
	for i = 1, GetNumFactions() do
		local name, _, standing, _, _, value, _, _, header = GetFactionInfo(i)
		if name and not header then rep[name] = { standing, value } end
	end
	char.rep = rep
end

------------------------------------------------------------------------------------------------
-- Instances, zones, duels, honor, quests, gear

local function Place()
	local inInstance, kind = IsInInstance()
	local name = GetInstanceInfo and GetInstanceInfo() or GetRealZoneText()
	if inInstance and (not inside or inside.name ~= name) then
		if inside then Log("instance", "leave", inside.name, inside.kind, math.floor(GetTime() - inside.t)) end
		inside = { name = name, kind = kind or "?", t = GetTime() }
		Log("instance", "enter", name, inside.kind)
	elseif not inInstance and inside then
		Log("instance", "leave", inside.name, inside.kind, math.floor(GetTime() - inside.t))
		inside = nil
	end
	local z = GetRealZoneText()
	if z and z ~= "" and z ~= zone then
		Tick()
		zone = z
		Log("zone", z)
	end
end

local function OnSystem(msg)
	local area = Match(msg, ERR_ZONE_EXPLORED_XP, true)
	if area then return Attribute("explore", area) end
	local me = UnitName("player")
	-- both formats name the winner first in their arguments, whatever the word order
	local winner, loser = Match(msg, DUEL_WINNER_KNOCKOUT)
	local how = "knockout"
	if not winner then
		winner, loser = Match(msg, DUEL_WINNER_RETREAT)
		how = "retreat"
	end
	if not winner then return end
	if winner == me then Log("duel", "won", loser, how)
	elseif loser == me then Log("duel", "lost", winner, how) end
end

local hkAt
local function OnHonor(msg)
	local victim = msg:match("^(.-) dies")
	if not victim then return end
	local honor = tonumber(msg:match("(%d+)%)?%.?$")) or 0
	hkAt = GetTime()
	Log("hk", victim, honor)
end

local function OnPvpKills()
	C_Timer.After(0.5, function()
		if hkAt and GetTime() - hkAt < 2 then return end
		Log("hk", "?", 0)
	end)
end

local removed = {}
local function QuestTitle(questID, index)
	if C_QuestLog and C_QuestLog.GetTitleForQuestID then
		local t = C_QuestLog.GetTitleForQuestID(questID)
		if t then return t end
	end
	if index and GetQuestLogTitle then
		local t = GetQuestLogTitle(index)
		if t then return t end
	end
	return ""
end

local function OnAccepted(a, b)
	local questID, index = b or a, b and a or nil
	questID = tonumber(questID)
	if not questID then return end
	local title = QuestTitle(questID, index)
	GoldScoutDB.quests = GoldScoutDB.quests or {}
	if title ~= "" then GoldScoutDB.quests[questID] = title end
	Log("accept", questID, title)
end

local function OnRemoved(questID)
	questID = tonumber(questID)
	if not questID then return end
	removed[questID] = GetTime()
	C_Timer.After(2, function()
		if removed[questID] then
			removed[questID] = nil
			Log("abandon", questID)
		end
	end)
end

local function OnTurnedIn(questID)
	questID = tonumber(questID)
	if questID then removed[questID] = nil end
	session.quests = session.quests + 1
	Attribute("quest", questID or "")
	-- the turn-in can be removed from the log before the event arrives
	C_Timer.After(2.5, function() if questID then removed[questID] = nil end end)
end

local function Gear()
	local gear = {}
	for slot = 1, 19 do
		local id = GetInventoryItemID("player", slot)
		if id then gear[slot] = id end
	end
	char.gear = gear
end

------------------------------------------------------------------------------------------------

function ns.ProgressSession()
	return session, key
end

local f = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "PLAYER_LOGOUT", "TIME_PLAYED_MSG", "PLAYER_LEVEL_UP", "PLAYER_XP_UPDATE",
	"CHAT_MSG_COMBAT_XP_GAIN", "CHAT_MSG_SYSTEM", "CHAT_MSG_COMBAT_FACTION_CHANGE", "CHAT_MSG_COMBAT_HONOR_GAIN",
	"PLAYER_PVP_KILLS_CHANGED", "SKILL_LINES_CHANGED", "CHAT_MSG_SKILL", "UNIT_THREAT_LIST_UPDATE", "UNIT_HEALTH",
	"NAME_PLATE_UNIT_ADDED", "PLAYER_TARGET_CHANGED", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
	"PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "UNIT_SPELLCAST_SUCCEEDED",
	"QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN", "PLAYER_EQUIPMENT_CHANGED", "PLAYER_DEAD", "UPDATE_EXHAUSTION" }) do
	pcall(f.RegisterEvent, f, e)
end

f:SetScript("OnEvent", function(_, e, ...)
	if e == "PLAYER_LOGIN" then
		local name, realm = UnitFullName("player")
		key = name .. "-" .. (realm or GetRealmName() or "")
		GoldScoutDB = GoldScoutDB or {}
		GoldScoutDB.chars = GoldScoutDB.chars or {}
		GoldScoutDB.chars[key] = GoldScoutDB.chars[key] or {}
		char = GoldScoutDB.chars[key]
		level = UnitLevel("player")
		LevelRecord(level)
		xp, xpMax, xpLevel = UnitXP("player"), UnitXPMax("player"), level
		char.xp, char.xpMax = xp, xpMax
		char.rested = GetXPExhaustion and GetXPExhaustion() or nil
		tickedAt = GetTime()
		OnSkills(true)
		Gear()
		C_Timer.After(2, Place)
		C_Timer.After(4, RequestPlayed)
		C_Timer.NewTicker(TICK, Tick)
		return
	end
	if not char then return end

	if e == "PLAYER_LOGOUT" then
		Tick()
		SaveReputation()
		if inside then Log("instance", "leave", inside.name, inside.kind, math.floor(GetTime() - inside.t)) end
	elseif e == "TIME_PLAYED_MSG" then
		local total, atLevel = ...
		PlayedReported(total or 0, atLevel or 0)
	elseif e == "PLAYER_LEVEL_UP" then
		local new = tonumber((...)) or UnitLevel("player")
		Tick()
		LevelRecord(level).to = time()
		level = new
		LevelRecord(level)
		C_Timer.After(3, RequestPlayed)
	elseif e == "PLAYER_XP_UPDATE" then
		OnXP()
	elseif e == "UPDATE_EXHAUSTION" then
		char.rested = GetXPExhaustion and GetXPExhaustion() or nil
	elseif e == "CHAT_MSG_COMBAT_XP_GAIN" then
		OnXPMessage((...))
	elseif e == "CHAT_MSG_SYSTEM" then
		OnSystem((...))
	elseif e == "CHAT_MSG_COMBAT_FACTION_CHANGE" then
		OnReputation((...))
	elseif e == "CHAT_MSG_COMBAT_HONOR_GAIN" then
		OnHonor((...))
	elseif e == "PLAYER_PVP_KILLS_CHANGED" then
		OnPvpKills()
	elseif e == "SKILL_LINES_CHANGED" or e == "CHAT_MSG_SKILL" then
		OnSkills()
	elseif e == "UNIT_THREAT_LIST_UPDATE" then
		local unit = ...
		if unit then OnThreat(unit) end
	elseif e == "NAME_PLATE_UNIT_ADDED" then
		local unit = ...
		if unit then OnThreat(unit) end
	elseif e == "PLAYER_TARGET_CHANGED" then
		if UnitExists("target") then
			OnThreat("target")
			OnHealth("target")
		end
	elseif e == "UNIT_HEALTH" then
		local unit = ...
		if unit then OnHealth(unit) end
	elseif e == "PLAYER_REGEN_DISABLED" then
		combatAt = GetTime()
	elseif e == "PLAYER_REGEN_ENABLED" then
		if combatAt then
			DayRecord().combat = DayRecord().combat + (GetTime() - combatAt)
			combatAt = nil
		end
		ForgetOld()
	elseif e == "PLAYER_ENTERING_WORLD" or e == "ZONE_CHANGED_NEW_AREA" or e == "ZONE_CHANGED" then
		Place()
	elseif e == "UNIT_SPELLCAST_SUCCEEDED" then
		local unit, _, spellID = ...
		if unit == "player" and spellID then
			local casts = DayRecord().casts
			casts[spellID] = (casts[spellID] or 0) + 1
		end
	elseif e == "QUEST_ACCEPTED" then
		OnAccepted(...)
	elseif e == "QUEST_REMOVED" then
		OnRemoved((...))
	elseif e == "QUEST_TURNED_IN" then
		OnTurnedIn((...))
	elseif e == "PLAYER_EQUIPMENT_CHANGED" then
		Gear()
	elseif e == "PLAYER_DEAD" then
		session.deaths = session.deaths + 1
	end
end)
