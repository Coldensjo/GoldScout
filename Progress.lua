-- Gold Scout progress tab: levels, experience, kills, quests, skills, reputation, dungeons, PvP and
-- where the time goes, per character or for all of them. Reads the journal lines and the per
-- character records that Character.lua keeps; draws with the tools from Stats.lua.

local _, ns = ...

local C = ns.Canvas
local Money, ItemName, Ago, ClassName, Price, VendorPrice = ns.Money, ns.ItemName, ns.Ago, ns.ClassName, ns.Price, ns.VendorPrice

local GREEN, RED, GOLD, BLUE, PURPLE, GREY = { 0.25, 0.8, 0.35 }, { 0.9, 0.3, 0.25 }, { 1, 0.82, 0 }, { 0.3, 0.6, 1 }, { 0.65, 0.45, 0.95 }, { 0.55, 0.55, 0.55 }
local XP_PARTS = {
	{ "kill", "Kills", BLUE },
	{ "quest", "Quests", GOLD },
	{ "explore", "Exploration", GREEN },
	{ "other", "Other", GREY },
}
local ROLL_PARTS = {
	{ "need", "Need", RED },
	{ "greed", "Greed", GOLD },
	{ "disenchant", "Disenchant", PURPLE },
	{ "pass", "Pass", GREY },
}
local KIND = { party = "Dungeon", raid = "Raid", pvp = "Battleground", arena = "Arena" }
local MERGE_RUNS = 15 * 60 -- a leave and an enter of the same instance this close are one run (a wipe, a disconnect)

------------------------------------------------------------------------------------------------
-- Helpers

local function N(n)
	n = math.floor((n or 0) + 0.5)
	if n >= 1000000 then return string.format("%.1fm", n / 1000000) end
	if n >= 10000 then return string.format("%.1fk", n / 1000) end
	return tostring(n)
end

local function Exact(n)
	n = math.floor((n or 0) + 0.5)
	local s = tostring(n)
	while true do
		local k
		s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
		if k == 0 then break end
	end
	return s
end

local function Signed(n)
	if n < 0 then return "|cffff4040" .. Exact(n) .. "|r" end
	return "+" .. Exact(n)
end

-- "45m", "3.2h", "27h"
local function Hours(s)
	s = s or 0
	if s < 3600 then return math.max(0, math.floor(s / 60)) .. "m" end
	if s < 36000 then return string.format("%.1fh", s / 3600) end
	return math.floor(s / 3600 + 0.5) .. "h"
end

-- "2d 5h 12m"
local function Long(s)
	s = math.floor(s or 0)
	local d, h, m = math.floor(s / 86400), math.floor(s % 86400 / 3600), math.floor(s % 3600 / 60)
	if d > 0 then return string.format("%dd %dh %dm", d, h, m) end
	if h > 0 then return string.format("%dh %dm", h, m) end
	return m .. "m"
end

local function Rate(n, secs)
	if not secs or secs < 60 then return nil end
	return n / secs * 3600
end

local function SpellName(id)
	local name
	if C_Spell and C_Spell.GetSpellName then name = C_Spell.GetSpellName(id)
	elseif GetSpellInfo then name = GetSpellInfo(id) end
	return name or ("spell " .. id)
end

local function QuestName(id)
	local q = GoldScoutDB.quests and GoldScoutDB.quests[tonumber(id) or 0]
	return q or ("quest " .. tostring(id))
end

local function Noon()
	local t = date("*t")
	t.hour, t.min, t.sec = 12, 0, 0
	return time(t)
end

------------------------------------------------------------------------------------------------
-- Everything about one character (or all of them), in one pass over the journal

local function Collect(who)
	local now = time()
	local chars = GoldScoutDB.chars or {}
	local function Mine(k) return not who or k == who end

	local P = {
		kills = 0, xp = {}, xpTotal = 0, quests = 0, accepted = 0, abandoned = 0, deaths = 0, loots = 0, crafts = 0, nodes = 0,
		levelUps = 0, hks = 0, honor = 0, duels = { won = 0, lost = 0, by = {} }, rolls = {}, rollItems = {},
		mobs = {}, zones = {}, skills = {}, rep = {}, days = {}, levels = {}, runs = {}, casts = {}, played = 0, combat = 0,
		questList = {}, first = now,
	}
	for _, p in ipairs(XP_PARTS) do P.xp[p[1]] = 0 end
	for _, p in ipairs(ROLL_PARTS) do P.rolls[p[1]] = 0 end
	P.rolls.won = 0

	local function Day(t)
		local k = date("%Y-%m-%d", t)
		local d = P.days[k]
		if not d then
			d = { key = k, t = t, xp = {}, xpTotal = 0, kills = 0, quests = 0, deaths = 0, skillUps = 0, skills = {}, played = 0, combat = 0 }
			P.days[k] = d
		end
		return d
	end
	local function Level(l)
		local v = P.levels[l]
		if not v then
			v = { level = l, kills = 0, quests = 0, xp = 0, deaths = 0, played = 0 }
			P.levels[l] = v
		end
		return v
	end
	local function Zone(z)
		local v = P.zones[z]
		if not v then
			v = { name = z, secs = 0, kills = 0, deaths = 0 }
			P.zones[z] = v
		end
		return v
	end

	-- the records Character.lua keeps per character
	for k, c in pairs(chars) do
		if Mine(k) then
			if c.played then P.played = P.played + (c.played.total or 0) end
			for l, v in pairs(c.levels or {}) do
				local lv = Level(tonumber(l) or 0)
				lv.played = lv.played + (v.played or 0)
				if not c.played then P.played = P.played + (v.played or 0) end
				lv.from = lv.from and math.min(lv.from, v.from or lv.from) or v.from
				lv.to = v.to and math.max(lv.to or 0, v.to) or lv.to
			end
			for dk, d in pairs(c.days or {}) do
				local y, m, dd = dk:match("(%d+)-(%d+)-(%d+)")
				local t = y and time({ year = tonumber(y), month = tonumber(m), day = tonumber(dd), hour = 12 }) or now
				local day = Day(t)
				day.played = day.played + (d.played or 0)
				day.combat = day.combat + (d.combat or 0)
				P.combat = P.combat + (d.combat or 0)
				for z, s in pairs(d.zones or {}) do Zone(z).secs = Zone(z).secs + s end
				for id, n in pairs(d.casts or {}) do P.casts[id] = (P.casts[id] or 0) + n end
			end
		end
	end

	-- the level each character was at, walked along the journal (level lines say the new level)
	local journal = GoldScoutDB.journal or {}
	local levelLines = {}
	for _, line in ipairs(journal) do
		local t, k, kind, a = strsplit("|", line)
		if kind == "level" and Mine(k) then
			local list = levelLines[k] or {}
			levelLines[k] = list
			list[#list + 1] = { tonumber(t) or 0, tonumber(a) or 0 }
		end
	end
	local pointer = {}
	local function LevelAt(k, t)
		local list = levelLines[k]
		local c = chars[k]
		if not list then return c and c.level or 0 end
		if t < list[1][1] then return list[1][2] - 1 end
		local i = pointer[k] or 1
		while list[i + 1] and list[i + 1][1] <= t do i = i + 1 end
		pointer[k] = i
		return list[i][2]
	end

	local active = {} -- char -> the instance run going on
	local pendingRoll = {} -- itemID -> true while a need or greed roll waits for its result
	local function EndRun(k, run, t, secs)
		run.secs = secs or (t - run.start)
		run.stop = t
		local last = P.runs[#P.runs]
		if last and last.name == run.name and last.who == k and run.start - last.stop < MERGE_RUNS then
			for _, f in ipairs({ "secs", "kills", "deaths", "xp", "quests", "loot" }) do last[f] = last[f] + run[f] end
			last.stop = run.stop
		else
			P.runs[#P.runs + 1] = run
		end
		active[k] = nil
	end

	for _, line in ipairs(journal) do
		local t, k, kind, a, b, c, d, e, items = strsplit("|", line)
		t = tonumber(t)
		if t and Mine(k) then
			if t < P.first then P.first = t end
			local run = active[k]
			if kind == "kill" then
				P.kills = P.kills + 1
				Day(t).kills = Day(t).kills + 1
				Level(LevelAt(k, t)).kills = Level(LevelAt(k, t)).kills + 1
				if c and c ~= "" then Zone(c).kills = Zone(c).kills + 1 end
				local m = P.mobs[b] or { name = b, n = 0, xp = 0, xpN = 0, zone = c, level = tonumber(d) or 0 }
				P.mobs[b] = m
				m.n = m.n + 1
				if (tonumber(d) or 0) > 0 then m.level = tonumber(d) end
				if run then run.kills = run.kills + 1 end
			elseif kind == "xp" then
				local n = tonumber(b) or 0
				local src = P.xp[a] and a or "other"
				P.xp[src] = P.xp[src] + n
				P.xpTotal = P.xpTotal + n
				local day = Day(t)
				day.xp[src] = (day.xp[src] or 0) + n
				day.xpTotal = day.xpTotal + n
				Level(LevelAt(k, t)).xp = Level(LevelAt(k, t)).xp + n
				if src == "kill" and c and c ~= "" then
					local m = P.mobs[c]
					if m then m.xp, m.xpN = m.xp + n, m.xpN + 1 end
				end
				if run then run.xp = run.xp + n end
			elseif kind == "quest" then
				P.quests = P.quests + 1
				Day(t).quests = Day(t).quests + 1
				Level(LevelAt(k, t)).quests = Level(LevelAt(k, t)).quests + 1
				P.questList[#P.questList + 1] = { t = t, id = a, xp = tonumber(b) or 0, money = tonumber(c) or 0, who = k }
				if run then run.quests = run.quests + 1 end
			elseif kind == "accept" then
				P.accepted = P.accepted + 1
			elseif kind == "abandon" then
				P.abandoned = P.abandoned + 1
			elseif kind == "death" then
				P.deaths = P.deaths + 1
				Day(t).deaths = Day(t).deaths + 1
				Level(LevelAt(k, t)).deaths = Level(LevelAt(k, t)).deaths + 1
				if a and a ~= "" then Zone(a).deaths = Zone(a).deaths + 1 end
				if run then run.deaths = run.deaths + 1 end
			elseif kind == "level" then
				P.levelUps = P.levelUps + 1
				LevelAt(k, t)
			elseif kind == "skill" then
				local s = P.skills[a] or { name = a, ups = 0, today = 0, week = 0, rank = 0, max = 0, first = t, last = t, perHour = {} }
				P.skills[a] = s
				s.ups = s.ups + 1
				s.rank, s.max = math.max(s.rank, tonumber(b) or 0), tonumber(c) or s.max
				s.last = t
				if now - t < 86400 then s.today = s.today + 1 end
				if now - t < 7 * 86400 then s.week = s.week + 1 end
				local day = Day(t)
				day.skillUps = day.skillUps + 1
				day.skills[a] = (day.skills[a] or 0) + 1
			elseif kind == "rep" then
				local r = P.rep[a] or { name = a, gained = 0, lost = 0, n = 0, standing = tonumber(c) }
				P.rep[a] = r
				local n = tonumber(b) or 0
				if n >= 0 then r.gained = r.gained + n else r.lost = r.lost - n end
				r.n = r.n + 1
				r.standing = tonumber(c) or r.standing
			elseif kind == "instance" then
				if a == "enter" then
					if run then EndRun(k, run, t) end
					active[k] = { name = b, kind = c or "?", start = t, kills = 0, deaths = 0, xp = 0, quests = 0, loot = 0, who = k }
				elseif run then
					EndRun(k, run, t, tonumber(d))
				end
			elseif kind == "duel" then
				if a == "won" then P.duels.won = P.duels.won + 1 else P.duels.lost = P.duels.lost + 1 end
				local o = P.duels.by[b or "?"] or { name = b or "?", won = 0, lost = 0 }
				P.duels.by[b or "?"] = o
				if a == "won" then o.won = o.won + 1 else o.lost = o.lost + 1 end
			elseif kind == "hk" then
				P.hks = P.hks + 1
				P.honor = P.honor + (tonumber(b) or 0)
			elseif kind == "roll" then
				local id = tonumber(b) or 0
				local it = P.rollItems[id] or { id = id, rolled = 0, won = 0, need = 0, greed = 0 }
				P.rollItems[id] = it
				if a == "won" then
					P.rolls.won = P.rolls.won + 1
					it.won = it.won + 1
					pendingRoll[id] = nil
				elseif P.rolls[a] then
					P.rolls[a] = P.rolls[a] + 1
					if a == "need" or a == "greed" then
						it.rolled = it.rolled + 1
						it[a] = it[a] + 1
						pendingRoll[id] = true
					end
				end
			elseif kind == "loot" then
				P.loots = P.loots + 1
				if run then
					for part in (items or ""):gmatch("[^,]+") do
						local id, q = part:match("(%d+):(%d+)")
						if id then run.loot = run.loot + (Price(tonumber(id)) or VendorPrice(tonumber(id)) or 0) * tonumber(q) end
					end
					run.loot = run.loot + (tonumber(e) or 0)
				end
			elseif kind == "craft" then
				P.crafts = P.crafts + (tonumber(b) or 1)
			end
		end
	end
	for k, run in pairs(active) do EndRun(k, run, now) end
	for _, line in ipairs(GoldScoutDB.gather or {}) do
		local _, k = strsplit("|", line)
		if Mine(k) then P.nodes = P.nodes + 1 end
	end

	-- the skills as they are now, from the character records (ranks logged only go up when seen)
	for k, c in pairs(chars) do
		if Mine(k) then
			for name, s in pairs(c.skills or {}) do
				local sk = P.skills[name]
				if sk and (s[1] or 0) >= sk.rank then sk.rank, sk.max = s[1], s[2] or sk.max end
			end
		end
	end
	P.daysTracked = math.max(1, (now - P.first) / 86400)
	return P
end

------------------------------------------------------------------------------------------------
-- Charts of its own

local function LastDays(P, n)
	local noon = Noon()
	local list = {}
	for i = n - 1, 0, -1 do
		local t = noon - i * 86400
		local k = date("%Y-%m-%d", t)
		list[#list + 1] = P.days[k] or { key = k, t = t, xp = {}, xpTotal = 0, kills = 0, quests = 0, deaths = 0, skillUps = 0, skills = {}, played = 0, combat = 0 }
	end
	return list
end

-- XP per day, kills / quests / exploration / other stacked
local function XPChart(x, y, w, h, days)
	local max = 0
	for _, d in ipairs(days) do max = math.max(max, d.xpTotal) end
	if max == 0 then return C.Empty(x, y, w, h, "No experience recorded yet") end
	local gx, gw = C.Grid(x, y, w, h, max, N)
	local slot = gw / #days
	local bw = math.max(3, math.min(26, slot - 8))
	for i, d in ipairs(days) do
		local cx = gx + (i - 1) * slot + slot / 2
		local top = y + h
		for _, p in ipairs(XP_PARTS) do
			local v = d.xp[p[1]] or 0
			if v > 0 then
				local bh = v / max * h
				top = top - bh
				C.Tex(cx - bw / 2, top, bw, bh, p[3], 0.9)
			end
		end
		C.Text(cx - slot / 2, y + h + 4, date("%a\n%d", d.t), "GameFontDisableSmall", slot, "CENTER"):SetWordWrap(true)
		C.Hit(cx - slot / 2, y, slot, h, function(tt)
			tt:AddLine(date("%A %d %B", d.t))
			tt:AddDoubleLine("Experience", Exact(d.xpTotal), 1, 0.82, 0, 1, 1, 1)
			for _, p in ipairs(XP_PARTS) do
				local v = d.xp[p[1]] or 0
				if v > 0 then tt:AddDoubleLine("  " .. p[2], Exact(v) .. string.format(" |cff9a9a9a%d%%|r", math.floor(v / d.xpTotal * 100 + 0.5)), 1, 1, 1, 1, 1, 1) end
			end
			if d.played > 60 then
				tt:AddDoubleLine("Played", Long(d.played) .. (d.combat > 0 and string.format(" |cff9a9a9a%d%% in combat|r", math.floor(d.combat / d.played * 100 + 0.5)) or ""), 1, 1, 1, 1, 1, 1)
				tt:AddDoubleLine("Experience per hour", Exact(Rate(d.xpTotal, d.played) or 0), 1, 1, 1, 1, 1, 1)
			end
			tt:AddDoubleLine("Kills / quests / deaths", d.kills .. " / " .. d.quests .. " / " .. d.deaths, 1, 1, 1, 1, 1, 1)
		end)
	end
end

-- Time played at each level
local function LevelChart(x, y, w, h, P, current)
	local levels = {}
	for _, v in pairs(P.levels) do
		if v.level > 0 and (v.played > 0 or v.kills > 0 or v.xp > 0) then levels[#levels + 1] = v end
	end
	table.sort(levels, function(a, b) return a.level < b.level end)
	if #levels == 0 then return C.Empty(x, y, w, h, "Time per level is counted from now on") end
	local max = 0
	for _, v in ipairs(levels) do max = math.max(max, v.played) end
	if max == 0 then max = 1 end
	local gx, gw = C.Grid(x, y, w, h, max, Hours)
	local slot = gw / #levels
	local bw = math.max(3, math.min(30, slot - 6))
	for i, v in ipairs(levels) do
		local cx = gx + (i - 1) * slot + slot / 2
		local bh = v.played / max * h
		C.Tex(cx - bw / 2, y + h - bh, bw, bh, v.level == current and GOLD or PURPLE, 0.85)
		if slot >= 16 or i % 2 == 1 then C.Text(cx - slot / 2, y + h + 4, "|cff9a9a9a" .. v.level .. "|r", "GameFontDisableSmall", slot, "CENTER") end
		C.Hit(cx - slot / 2, y, slot, h, function(tt)
			tt:AddLine("Level " .. v.level .. (v.level == current and " (now)" or ""))
			tt:AddDoubleLine("Played at this level", Long(v.played), 1, 1, 1, 1, 1, 1)
			if v.from then tt:AddDoubleLine("Reached", date("%a %d %b %H:%M", v.from), 1, 1, 1, 1, 1, 1) end
			if v.to then tt:AddDoubleLine("Left", date("%a %d %b %H:%M", v.to) .. " |cff9a9a9a" .. Long(v.to - (v.from or v.to)) .. " of real time|r", 1, 1, 1, 1, 1, 1) end
			tt:AddDoubleLine("Experience", Exact(v.xp) .. (Rate(v.xp, v.played) and (" |cff9a9a9a" .. Exact(Rate(v.xp, v.played)) .. " / hour|r") or ""), 1, 1, 1, 1, 1, 1)
			tt:AddDoubleLine("Kills", v.kills .. (Rate(v.kills, v.played) and string.format(" |cff9a9a9a%.0f / hour|r", Rate(v.kills, v.played)) or ""), 1, 1, 1, 1, 1, 1)
			tt:AddDoubleLine("Quests", v.quests, 1, 1, 1, 1, 1, 1)
			tt:AddDoubleLine("Deaths", v.deaths, 1, 1, 1, 1, 1, 1)
		end)
	end
end

-- Kills, quests and deaths per day: three bars a day
local function ActivityChart(x, y, w, h, days)
	local max = 0
	for _, d in ipairs(days) do max = math.max(max, d.kills, d.quests * 5, d.deaths * 5) end
	if max == 0 then return C.Empty(x, y, w, h) end
	local gx, gw = C.Grid(x, y, w, h, max, N)
	local slot = gw / #days
	local bw = math.max(2, math.min(10, (slot - 8) / 3))
	for i, d in ipairs(days) do
		local cx = gx + (i - 1) * slot + slot / 2
		local kh, qh, dh = d.kills / max * h, d.quests * 5 / max * h, d.deaths * 5 / max * h
		C.Tex(cx - bw * 1.5 - 1, y + h - kh, bw, kh, BLUE, 0.9)
		C.Tex(cx - bw / 2, y + h - qh, bw, qh, GOLD, 0.9)
		C.Tex(cx + bw / 2 + 1, y + h - dh, bw, dh, RED, 0.9)
		C.Text(cx - slot / 2, y + h + 4, date("%a\n%d", d.t), "GameFontDisableSmall", slot, "CENTER"):SetWordWrap(true)
		C.Hit(cx - slot / 2, y, slot, h, function(tt)
			tt:AddLine(date("%A %d %B", d.t))
			tt:AddDoubleLine("Kills", d.kills .. (Rate(d.kills, d.played) and string.format(" |cff9a9a9a%.0f / hour|r", Rate(d.kills, d.played)) or ""), 0.3, 0.6, 1, 1, 1, 1)
			tt:AddDoubleLine("Quests turned in", d.quests, 1, 0.82, 0, 1, 1, 1)
			tt:AddDoubleLine("Deaths", d.deaths, 0.9, 0.3, 0.25, 1, 1, 1)
			if d.played > 60 then tt:AddDoubleLine("Played", Long(d.played), 1, 1, 1, 1, 1, 1) end
			tt:AddLine("Quests and deaths are drawn 5x taller than kills", 0.6, 0.6, 0.6)
		end)
	end
end

-- Skill points gained per day
local function SkillChart(x, y, w, h, days)
	local max = 0
	for _, d in ipairs(days) do max = math.max(max, d.skillUps) end
	if max == 0 then return C.Empty(x, y, w, h, "No skill-ups recorded yet") end
	local gx, gw = C.Grid(x, y, w, h, max, N)
	local slot = gw / #days
	local bw = math.max(3, math.min(26, slot - 8))
	for i, d in ipairs(days) do
		local cx = gx + (i - 1) * slot + slot / 2
		local bh = d.skillUps / max * h
		C.Tex(cx - bw / 2, y + h - bh, bw, bh, GREEN, 0.85)
		if d.skillUps > 0 then C.Text(cx - slot / 2, y + h - bh - 12, d.skillUps, "GameFontHighlightSmall", slot, "CENTER") end
		C.Text(cx - slot / 2, y + h + 4, date("%a\n%d", d.t), "GameFontDisableSmall", slot, "CENTER"):SetWordWrap(true)
		C.Hit(cx - slot / 2, y, slot, h, function(tt)
			tt:AddLine(date("%A %d %B", d.t))
			local list = {}
			for name, n in pairs(d.skills) do list[#list + 1] = { name, n } end
			table.sort(list, function(a, b) return a[2] > b[2] end)
			for _, s in ipairs(list) do tt:AddDoubleLine(s[1], "+" .. s[2], 1, 1, 1, 1, 1, 1) end
			if #list == 0 then tt:AddLine("No skill-ups", 0.6, 0.6, 0.6) end
		end)
	end
end

-- Every skill with its rank bar and the points gained
local function SkillRows(x, y, w, P, n)
	local list = {}
	for _, s in pairs(P.skills) do list[#list + 1] = s end
	table.sort(list, function(a, b)
		if a.week ~= b.week then return a.week > b.week end
		return a.ups > b.ups
	end)
	if #list == 0 then return C.Empty(x, y, w, 100, "Skill-ups are recorded from now on") end
	local labelW, valueW = 100, 95
	for i = 1, math.min(n, #list) do
		local s = list[i]
		local ry = y + (i - 1) * 22
		C.Text(x, ry + 4, s.name, "GameFontHighlightSmall", labelW)
		local barW = w - labelW - valueW
		C.Tex(x + labelW, ry + 2, barW, 14, { 1, 1, 1 }, 0.04, "BACKGROUND")
		if s.max > 0 then C.Tex(x + labelW, ry + 2, barW * math.min(1, s.rank / s.max), 14, s.rank >= s.max and RED or GREEN, 0.8) end
		C.Text(x + w - valueW, ry + 4, s.rank .. "/" .. s.max .. " |cff40ff40+" .. s.ups .. "|r", "GameFontHighlightSmall", valueW, "RIGHT")
		C.Hit(x, ry, w, 20, function(tt)
			tt:AddLine(s.name)
			tt:AddDoubleLine("Rank", s.rank .. " of " .. s.max, 1, 1, 1, 1, 1, 1)
			tt:AddDoubleLine("Points gained", s.ups .. " recorded", 1, 1, 1, 1, 1, 1)
			tt:AddDoubleLine("Last 24 hours / 7 days", s.today .. " / " .. s.week, 1, 1, 1, 1, 1, 1)
			if s.ups >= 2 and s.last > s.first then tt:AddDoubleLine("One point every", Long((s.last - s.first) / (s.ups - 1)) .. " of real time", 1, 1, 1, 1, 1, 1) end
			tt:AddDoubleLine("Last point", Ago(s.last), 1, 1, 1, 1, 1, 1)
			if s.max > 0 and s.rank >= s.max then tt:AddLine("At the cap: visit a trainer", 1, 0.5, 0.25) end
		end)
	end
end

-- Dungeons, raids and battlegrounds, one row per instance
local function RunRows(x, y, w, P, n)
	local by = {}
	for _, r in ipairs(P.runs) do
		local g = by[r.name] or { name = r.name, kind = r.kind, runs = 0, secs = 0, kills = 0, deaths = 0, xp = 0, quests = 0, loot = 0, last = 0, longest = 0 }
		by[r.name] = g
		g.runs = g.runs + 1
		for _, f in ipairs({ "secs", "kills", "deaths", "xp", "quests", "loot" }) do g[f] = g[f] + r[f] end
		g.last = math.max(g.last, r.stop or r.start)
		g.longest = math.max(g.longest, r.secs)
	end
	local list = {}
	for _, g in pairs(by) do list[#list + 1] = g end
	table.sort(list, function(a, b) return a.secs > b.secs end)
	if #list == 0 then return C.Empty(x, y, w, 80, "No dungeon, raid or battleground recorded yet") end
	local cols = { { "Instance", 170 }, { "Runs", 40 }, { "Time / run", 70 }, { "Kills", 45 }, { "Deaths", 50 }, { "XP / run", 65 }, { "Loot / run", 90 } }
	local cx = x
	for _, c in ipairs(cols) do
		C.Text(cx, y, "|cff9a9a9a" .. c[1] .. "|r", "GameFontDisableSmall", c[2])
		cx = cx + c[2]
	end
	for i = 1, math.min(n, #list) do
		local g = list[i]
		local ry = y + 14 + (i - 1) * 19
		C.Tex(x, ry, w, 18, { 1, 1, 1 }, i % 2 == 0 and 0.04 or 0, "BACKGROUND")
		local vals = { g.name .. " |cff9a9a9a" .. (KIND[g.kind] or g.kind) .. "|r", g.runs, Hours(g.secs / g.runs), string.format("%.0f", g.kills / g.runs),
			string.format("%.1f", g.deaths / g.runs), N(g.xp / g.runs), Money(g.loot / g.runs) }
		cx = x
		for j, c in ipairs(cols) do
			C.Text(cx + 2, ry + 3, tostring(vals[j]), "GameFontHighlightSmall", c[2] - 4)
			cx = cx + c[2]
		end
		C.Hit(x, ry, w, 18, function(tt)
			tt:AddLine(g.name)
			tt:AddDoubleLine("Runs", g.runs .. " |cff9a9a9a" .. Long(g.secs) .. " inside in total|r", 1, 1, 1, 1, 1, 1)
			tt:AddDoubleLine("Longest run", Long(g.longest), 1, 1, 1, 1, 1, 1)
			tt:AddDoubleLine("Kills / deaths", g.kills .. " / " .. g.deaths, 1, 1, 1, 1, 1, 1)
			tt:AddDoubleLine("Experience", Exact(g.xp) .. (Rate(g.xp, g.secs) and (" |cff9a9a9a" .. Exact(Rate(g.xp, g.secs)) .. " / hour|r") or ""), 1, 1, 1, 1, 1, 1)
			tt:AddDoubleLine("Quests turned in inside", g.quests, 1, 1, 1, 1, 1, 1)
			tt:AddDoubleLine("Loot (today's prices)", Money(g.loot) .. (Rate(g.loot, g.secs) and (" |cff9a9a9a" .. Money(Rate(g.loot, g.secs)) .. " / hour|r") or ""), 1, 1, 1, 1, 1, 1)
			tt:AddDoubleLine("Last run", Ago(g.last), 1, 1, 1, 1, 1, 1)
		end)
	end
	return 14 + math.min(n, #list) * 19
end

------------------------------------------------------------------------------------------------
-- The page

local page, selected
local W = C.W

local function CurrentKey()
	local name, realm = UnitFullName("player")
	return (name or "?") .. "-" .. (realm or GetRealmName() or "")
end

local function Draw()
	local chars = {}
	for k, c in pairs(GoldScoutDB.chars or {}) do chars[#chars + 1] = { key = k, c = c } end
	table.sort(chars, function(a, b) return (a.c.name or a.key) < (b.c.name or b.key) end)
	local me = CurrentKey()
	if not selected or (selected ~= "all" and not GoldScoutDB.chars[selected]) then selected = me end
	local who = selected ~= "all" and selected or nil
	local one = who and GoldScoutDB.chars[who] or nil
	local P = Collect(who)
	local now = time()
	local today = P.days[date("%Y-%m-%d")] or { xpTotal = 0, played = 0, kills = 0, quests = 0, deaths = 0 }

	C.Begin(page)
	local y = 4

	-- Who
	local x = 0
	local list = { { key = "all", label = "All characters" } }
	for _, e in ipairs(chars) do list[#list + 1] = { key = e.key, label = ClassName(e.c), c = e.c } end
	for _, e in ipairs(list) do
		local label = e.key == selected and ("|cffffd200[|r " .. e.label .. " |cffffd200]|r") or e.label
		local fs = C.Text(x, y, label, "GameFontNormal", 240)
		local w = fs:GetStringWidth() + 6
		C.Hit(x - 3, y - 3, w, 20, function(tt)
			if e.c then
				tt:AddLine(e.c.name or e.key)
				tt:AddDoubleLine("Level", e.c.level or "?", 1, 1, 1, 1, 1, 1)
				if e.c.played then tt:AddDoubleLine("Played", Long(e.c.played.total), 1, 1, 1, 1, 1, 1) end
				tt:AddDoubleLine("Seen", Ago(e.c.seen), 1, 1, 1, 1, 1, 1)
			else
				tt:AddLine("Everything, added up over all characters")
			end
		end, nil, function()
			selected = e.key
			ns.Toggle("progress")
		end)
		x = x + w + 18
	end
	y = y + 26

	-- Headline numbers
	local level = one and one.level or 0
	local lv = one and P.levels[level] or nil
	local levelRate = lv and Rate(lv.xp, lv.played)
	local todayRate = Rate(today.xpTotal, today.played)
	local weekXP, weekPlayed = 0, 0
	for _, d in ipairs(LastDays(P, 7)) do weekXP, weekPlayed = weekXP + d.xpTotal, weekPlayed + d.played end
	local weekRate = Rate(weekXP, weekPlayed)
	local best = levelRate or todayRate or weekRate
	local toGo = one and one.xpMax and one.xp and (one.xpMax - one.xp) or nil
	local eta = toGo and best and best > 0 and toGo / best * 3600 or nil
	local runSecs, runDeaths = 0, 0
	for _, r in ipairs(P.runs) do runSecs, runDeaths = runSecs + r.secs, runDeaths + r.deaths end
	local levelsPlayed = 0
	for _, v in pairs(P.levels) do if v.played > 0 then levelsPlayed = levelsPlayed + 1 end end
	local tw = (W - 7 * 8) / 8
	local tiles = {
		one and { "Level", tostring(level), one.xpMax and one.xpMax > 0 and string.format("%d%% to %d%s", math.floor((one.xp or 0) / one.xpMax * 100), level + 1,
			one.rested and one.rested > 0 and (", rested " .. N(one.rested)) or "") or "", function(tt)
			tt:AddLine(one.name or who)
			tt:AddDoubleLine("Experience", Exact(one.xp or 0) .. " of " .. Exact(one.xpMax or 0), 1, 1, 1, 1, 1, 1)
			if toGo then tt:AddDoubleLine("To the next level", Exact(toGo), 1, 1, 1, 1, 1, 1) end
			if one.rested then tt:AddDoubleLine("Rested experience", Exact(one.rested), 1, 1, 1, 1, 1, 1) end
			tt:AddDoubleLine("Levels gained since tracking", P.levelUps, 1, 1, 1, 1, 1, 1)
		end } or { "Characters", tostring(#chars), P.levelUps .. " levels gained", function(tt)
			tt:AddLine("All characters")
			for _, e in ipairs(chars) do tt:AddDoubleLine(ClassName(e.c), "level " .. (e.c.level or "?"), 1, 1, 1, 1, 1, 1) end
		end },
		{ "Time played", Hours(P.played), lv and ("this level " .. Hours(lv.played)) or (levelsPlayed .. " levels timed"), function(tt)
			tt:AddLine("Time played")
			tt:AddDoubleLine("In total (server's count)", Long(P.played), 1, 1, 1, 1, 1, 1)
			if lv then tt:AddDoubleLine("At level " .. level, Long(lv.played), 1, 1, 1, 1, 1, 1) end
			tt:AddDoubleLine("Today", Long(today.played), 1, 1, 1, 1, 1, 1)
			tt:AddDoubleLine("Last 7 days", Long(weekPlayed), 1, 1, 1, 1, 1, 1)
			if P.played > 0 then tt:AddDoubleLine("In combat (while tracked)", Long(P.combat), 1, 1, 1, 1, 1, 1) end
		end },
		{ "XP per hour", best and Exact(best) or "-", levelRate and ("at this level; today " .. (todayRate and N(todayRate) or "-")) or ("today; 7 days " .. (weekRate and N(weekRate) or "-")), function(tt)
			tt:AddLine("Experience per hour played")
			if levelRate then tt:AddDoubleLine("At level " .. level, Exact(levelRate), 1, 1, 1, 1, 1, 1) end
			tt:AddDoubleLine("Today", todayRate and Exact(todayRate) or "-", 1, 1, 1, 1, 1, 1)
			tt:AddDoubleLine("Last 7 days", weekRate and Exact(weekRate) or "-", 1, 1, 1, 1, 1, 1)
			tt:AddDoubleLine("Experience per day (7 days)", Exact(weekXP / 7), 1, 1, 1, 1, 1, 1)
			tt:AddDoubleLine("All recorded", Exact(P.xpTotal), 1, 1, 1, 1, 1, 1)
		end },
		{ "Next level in", eta and Hours(eta) or "-", toGo and (Exact(toGo) .. " xp to go") or (one and "needs an hour of play" or "pick a character"), function(tt)
			tt:AddLine("Time to the next level")
			tt:AddLine("Experience still needed, at the pace of this level (or today, or the last 7 days).", 1, 1, 1, true)
		end },
		{ "Kills", Exact(P.kills), (Rate(P.kills, weekPlayed) and string.format("%.0f an hour, ", Rate(P.kills, weekPlayed)) or "") .. (P.levelUps > 0 and string.format("%.0f a level", P.kills / P.levelUps) or ""), function(tt)
			tt:AddLine("Kills")
			tt:AddLine("Monsters you or your pet fought that died tagged to you, and corpses you looted. In a group, only what you loot.", 1, 1, 1, true)
			tt:AddDoubleLine("Today", today.kills, 1, 1, 1, 1, 1, 1)
			if P.levelUps > 0 then tt:AddDoubleLine("Per level gained", string.format("%.0f", P.kills / P.levelUps), 1, 1, 1, 1, 1, 1) end
			if P.xp.kill > 0 and P.kills > 0 then tt:AddDoubleLine("Experience per kill", string.format("%.0f", P.xp.kill / P.kills), 1, 1, 1, 1, 1, 1) end
		end },
		{ "Quests done", Exact(P.quests), P.accepted .. " accepted, " .. P.abandoned .. " abandoned", function(tt)
			tt:AddLine("Quests")
			tt:AddDoubleLine("Turned in", P.quests, 1, 1, 1, 1, 1, 1)
			tt:AddDoubleLine("Today", today.quests, 1, 1, 1, 1, 1, 1)
			if P.levelUps > 0 then tt:AddDoubleLine("Per level gained", string.format("%.1f", P.quests / P.levelUps), 1, 1, 1, 1, 1, 1) end
			if P.quests > 0 then tt:AddDoubleLine("Experience per quest", string.format("%.0f", P.xp.quest / P.quests), 1, 1, 1, 1, 1, 1) end
			local money = 0
			for _, q in ipairs(P.questList) do money = money + q.money end
			tt:AddDoubleLine("Quest gold", Money(money), 1, 1, 1, 1, 1, 1)
		end },
		{ "Deaths", Exact(P.deaths), Rate(P.deaths, P.played) and (P.deaths > 0 and ("one every " .. Hours(P.played / P.deaths)) or "none while played") or (today.deaths .. " today"), function(tt)
			tt:AddLine("Deaths")
			tt:AddDoubleLine("Today", today.deaths, 1, 1, 1, 1, 1, 1)
			if P.levelUps > 0 then tt:AddDoubleLine("Per level gained", string.format("%.1f", P.deaths / P.levelUps), 1, 1, 1, 1, 1, 1) end
			tt:AddDoubleLine("In dungeons and battlegrounds", runDeaths, 1, 1, 1, 1, 1, 1)
		end },
		{ "Instance runs", tostring(#P.runs), Hours(runSecs) .. " inside, " .. runDeaths .. " deaths", function(tt)
			tt:AddLine("Dungeons, raids and battlegrounds")
			tt:AddLine("A run is from entering to leaving; leaving and coming back within 15 minutes counts as the same run.", 1, 1, 1, true)
		end },
	}
	for i, t in ipairs(tiles) do
		C.Tile((i - 1) * (tw + 8), y, tw, t[1], tostring(t[2]), t[3], t[4])
	end
	y = y + 70

	-- Experience per day, and time per level
	local days = LastDays(P, 14)
	local half = (W - 30) / 2
	C.Title(0, y, "Experience per day: kills |cff4d99ff|||r quests |cffffd100|||r exploration |cff40cc59|||r other |cff8c8c8c|||r", half)
	C.Title(half + 30, y, "Time played at each level", half)
	XPChart(0, y + 28, half, 140, days)
	LevelChart(half + 30, y + 28, half, 140, P, level)
	y = y + 28 + 140 + 40

	-- Where the experience comes from, skills, reputation
	local third = (W - 2 * 30) / 3
	C.Title(0, y, "Where the experience comes from", third)
	C.Title(third + 30, y, "Professions and weapon skills", third)
	C.Title(2 * (third + 30), y, "Reputation gained", third)
	C.Bars(0, y + 26, third, XP_PARTS, P.xp, P.xpTotal, BLUE, Exact)
	SkillRows(third + 30, y + 26, third, P, 8)
	local repParts, repValues = {}, {}
	for _, r in pairs(P.rep) do
		if r.gained > 0 then
			repParts[#repParts + 1] = { r.name, r.name, GREEN, note = r.lost > 0 and ("Lost " .. Exact(r.lost) .. " along the way") or nil }
			repValues[r.name] = r.gained
		end
	end
	table.sort(repParts, function(a, b) return repValues[a[1]] > repValues[b[1]] end)
	while #repParts > 8 do table.remove(repParts) end
	local repTotal = 0
	for _, v in pairs(repValues) do repTotal = repTotal + v end
	if #repParts == 0 then C.Empty(2 * (third + 30), y + 26, third, 100, "No reputation gained yet") end
	C.Bars(2 * (third + 30), y + 26, third, repParts, repValues, repTotal, GREEN, Exact)
	y = y + 26 + 8 * 22 + 14

	-- Most killed, time by zone, spells, loot rolls
	local quarter = (W - 3 * 24) / 4
	local mobs, zones, spells, rollList = {}, {}, {}, {}
	for _, m in pairs(P.mobs) do
		mobs[#mobs + 1] = { name = m.name, value = m.n, text = m.n .. " kills", tip = function(tt)
			tt:AddLine(m.name .. (m.level > 0 and (" |cff9a9a9alevel " .. m.level .. "|r") or ""))
			tt:AddDoubleLine("Kills", m.n, 1, 1, 1, 1, 1, 1)
			if m.xpN > 0 then tt:AddDoubleLine("Experience per kill", string.format("%.0f", m.xp / m.xpN), 1, 1, 1, 1, 1, 1) end
			if m.zone and m.zone ~= "" then tt:AddDoubleLine("Zone", m.zone, 1, 1, 1, 1, 1, 1) end
			local kv = KillValueDB and KillValueDB.learned
			if kv then
				for _, r in pairs(kv) do
					if r.name == m.name and r.kills and r.kills > 0 then
						tt:AddDoubleLine("Looted coin per kill (Kill Value)", Money((r.money or 0) / r.kills), 1, 1, 1, 1, 1, 1)
						break
					end
				end
			end
		end }
	end
	for _, z in pairs(P.zones) do
		if z.secs > 0 or z.kills > 0 or z.deaths > 0 then
			zones[#zones + 1] = { name = z.name, value = z.secs, text = Hours(z.secs), tip = function(tt)
				tt:AddLine(z.name)
				tt:AddDoubleLine("Time spent", Long(z.secs), 1, 1, 1, 1, 1, 1)
				tt:AddDoubleLine("Kills", z.kills .. (Rate(z.kills, z.secs) and string.format(" |cff9a9a9a%.0f / hour|r", Rate(z.kills, z.secs)) or ""), 1, 1, 1, 1, 1, 1)
				tt:AddDoubleLine("Deaths", z.deaths, 1, 1, 1, 1, 1, 1)
			end }
		end
	end
	local castTotal = 0
	for id, n in pairs(P.casts) do
		castTotal = castTotal + n
		spells[#spells + 1] = { name = SpellName(id), value = n, text = Exact(n), tip = function(tt)
			tt:AddLine(SpellName(id))
			tt:AddDoubleLine("Casts", Exact(n), 1, 1, 1, 1, 1, 1)
			if Rate(n, P.played) then tt:AddDoubleLine("Per hour played", string.format("%.1f", Rate(n, P.played)), 1, 1, 1, 1, 1, 1) end
		end }
	end
	for _, it in pairs(P.rollItems) do
		if it.rolled > 0 or it.won > 0 then
			rollList[#rollList + 1] = { id = it.id, name = "item " .. it.id, value = it.won * 10 + it.rolled, text = it.won .. " won / " .. it.rolled .. " rolled",
				tip = function(tt)
					tt:AddLine("Gold Scout", 1, 0.82, 0)
					tt:AddDoubleLine("Rolled need / greed", it.need .. " / " .. it.greed, 1, 1, 1, 1, 1, 1)
					tt:AddDoubleLine("Won", it.won, 1, 1, 1, 1, 1, 1)
				end }
		end
	end
	for _, l in ipairs({ mobs, zones, spells, rollList }) do table.sort(l, function(a, b) return a.value > b.value end) end
	C.Title(0, y, "Killed the most", quarter)
	C.Title(quarter + 24, y, "Time by zone", quarter)
	C.Title(2 * (quarter + 24), y, "Cast the most" .. (castTotal > 0 and ("  |cff9a9a9a" .. Exact(castTotal) .. " casts|r") or ""), quarter)
	C.Title(3 * (quarter + 24), y, "Loot rolls", quarter)
	if #mobs == 0 then C.Empty(0, y + 24, quarter, 100, "Kills are recorded from now on") end
	C.TopList(0, y + 24, quarter, mobs, BLUE, 10)
	if #zones == 0 then C.Empty(quarter + 24, y + 24, quarter, 100, "Zone time is recorded from now on") end
	C.TopList(quarter + 24, y + 24, quarter, zones, PURPLE, 10)
	if #spells == 0 then C.Empty(2 * (quarter + 24), y + 24, quarter, 100, "Casts are recorded from now on") end
	C.TopList(2 * (quarter + 24), y + 24, quarter, spells, GOLD, 10)
	local rolled = P.rolls.need + P.rolls.greed
	local rx = 3 * (quarter + 24)
	local rollText = string.format("%d need, %d greed, %d pass", P.rolls.need, P.rolls.greed, P.rolls.pass)
	C.Text(rx, y + 26, rollText, "GameFontHighlightSmall", quarter)
	C.Text(rx, y + 42, rolled > 0 and string.format("won %d of %d rolled |cff9a9a9a(%d%%)|r, lost %d", P.rolls.won, rolled, math.floor(P.rolls.won / rolled * 100 + 0.5), math.max(0, rolled - P.rolls.won))
		or "|cff808080No need or greed rolls yet|r", "GameFontHighlightSmall", quarter)
	C.Hit(rx, y + 24, quarter, 34, function(tt)
		tt:AddLine("Loot rolls")
		tt:AddLine("Lost = need and greed rolls without a win. Rolls on items that are still being rolled count as lost until the result shows.", 1, 1, 1, true)
		if P.rolls.disenchant > 0 then tt:AddDoubleLine("Disenchant rolls", P.rolls.disenchant, 1, 1, 1, 1, 1, 1) end
	end)
	C.TopList(rx, y + 62, quarter, rollList, GOLD, 8)
	y = y + 24 + 10 * 19 + 14

	-- Kills, quests and deaths per day; skill-ups per day
	C.Title(0, y, "Kills |cff4d99ff|||r quests |cffffd100|||r deaths |cffe64d40|||r per day", half)
	C.Title(half + 30, y, "Skill points per day", half)
	ActivityChart(0, y + 28, half, 120, days)
	SkillChart(half + 30, y + 28, half, 120, days)
	y = y + 28 + 120 + 40

	-- Dungeons and PvP
	C.Title(0, y, "Dungeons, raids and battlegrounds", half)
	C.Title(half + 30, y, "PvP: duels and honorable kills", half)
	local rowsH = RunRows(0, y + 26, half, P, 8) or 80
	local px = half + 30
	local duels = P.duels.won + P.duels.lost
	C.Text(px, y + 26, duels > 0 and string.format("Duels: |cff40ff40%d won|r, |cffff4040%d lost|r |cff9a9a9a(%d%% won)|r", P.duels.won, P.duels.lost, math.floor(P.duels.won / duels * 100 + 0.5))
		or "|cff808080No duels recorded yet|r", "GameFontHighlightSmall", half)
	C.Text(px, y + 42, P.hks > 0 and string.format("Honorable kills: %d |cff9a9a9a(%s honor points estimated)|r", P.hks, Exact(P.honor))
		or "|cff808080No honorable kills recorded yet|r", "GameFontHighlightSmall", half)
	local opponents = {}
	for _, o in pairs(P.duels.by) do
		opponents[#opponents + 1] = { name = o.name, value = o.won + o.lost, text = o.won .. " - " .. o.lost, tip = function(tt)
			tt:AddLine(o.name)
			tt:AddDoubleLine("Won / lost against them", o.won .. " / " .. o.lost, 1, 1, 1, 1, 1, 1)
		end }
	end
	table.sort(opponents, function(a, b) return a.value > b.value end)
	C.TopList(px, y + 62, half, opponents, RED, 6)
	y = y + 26 + math.max(rowsH, 62 + math.min(6, #opponents) * 19) + 16

	-- Everything counted
	local counts = {
		{ "kills", "Kills", BLUE }, { "quests", "Quests turned in", GOLD }, { "accepted", "Quests accepted", GOLD }, { "loots", "Loot windows", GREEN },
		{ "nodes", "Nodes gathered", GREEN }, { "crafts", "Items crafted", PURPLE }, { "deaths", "Deaths", RED }, { "levelUps", "Levels gained", GOLD },
	}
	local values = {}
	for _, c in ipairs(counts) do values[c[1]] = P[c[1]] end
	C.Title(0, y, "Everything counted" .. string.format("  |cff9a9a9asince %s, %.1f days|r", date("%a %d %b", P.first), P.daysTracked), half)
	C.Bars(0, y + 26, half, counts, values, 0, GREY, Exact)
	-- this session, for the character logged in
	local s = ns.ProgressSession and ns.ProgressSession()
	C.Title(half + 30, y, "This session (" .. (GoldScoutDB.chars[me] and GoldScoutDB.chars[me].name or "you") .. ")", half)
	if s then
		local secs = now - s.start
		local lines = {
			{ "Playing for", Long(secs) },
			{ "Experience", Exact(s.xp) .. (Rate(s.xp, secs) and (" |cff9a9a9a" .. Exact(Rate(s.xp, secs)) .. " / hour|r") or "") },
			{ "Kills", s.kills .. (Rate(s.kills, secs) and string.format(" |cff9a9a9a%.0f / hour|r", Rate(s.kills, secs)) or "") },
			{ "Quests turned in", tostring(s.quests) },
			{ "Deaths", tostring(s.deaths) },
		}
		for i, l in ipairs(lines) do
			C.Text(half + 30, y + 26 + (i - 1) * 18, "|cff9a9a9a" .. l[1] .. "|r", "GameFontHighlightSmall", 130)
			C.Text(half + 30 + 130, y + 26 + (i - 1) * 18, l[2], "GameFontHighlightSmall", half - 130)
		end
	end
	y = y + 26 + 8 * 22 + 10

	C.Finish()
	page:SetHeight(y)
	return "Kills, experience, skill-ups, reputation, zones, instances, duels and honor are recorded from the moment this version was installed. Hover anything for details."
end

ns.TABS.progress = {
	title = "Progress",
	panel = function(parent)
		local scroll = CreateFrame("ScrollFrame", "GoldScoutProgressScroll", parent, "UIPanelScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", 18, -62)
		scroll:SetPoint("BOTTOMRIGHT", -40, 34)
		page = CreateFrame("Frame", nil, scroll)
		page:SetSize(W, 800)
		scroll:SetScrollChild(page)
		return scroll
	end,
	refresh = Draw,
}
