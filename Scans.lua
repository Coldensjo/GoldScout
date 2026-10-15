-- Gold Scout auction house scans: a copy of every Auctionator full scan, summarized per item.
-- GoldScoutDB.scans (oldest first): { t, realm, faction, n, data = "itemID:min:qty:auctions:median,..." }
-- Hooks Auctionator's own database (addon code, not Blizzard's, so nothing is tainted).
-- On first use the full scans AuctionhouseSync already captured are copied in.

local MAX_SCANS = 40
local FULL_SCAN_MIN_ITEMS = 1000 -- a search covers a few items, a full scan thousands

local hooked = {}

local function Summarize(itemIndexes)
	local parts = {}
	for key, entries in pairs(itemIndexes) do
		local id = tonumber(key)
		if id and #entries > 0 then
			local sorted, qty = {}, 0
			for i, e in ipairs(entries) do
				sorted[i] = e
				qty = qty + (e.available or 0)
			end
			table.sort(sorted, function(a, b) return a.price < b.price end)
			local median, seen = sorted[1].price, 0
			for _, e in ipairs(sorted) do
				seen = seen + (e.available or 0)
				if seen * 2 >= qty then
					median = e.price
					break
				end
			end
			parts[#parts + 1] = id .. ":" .. sorted[1].price .. ":" .. qty .. ":" .. #entries .. ":" .. median
		end
	end
	return table.concat(parts, ","), #parts
end

local function Add(scan)
	local scans = GoldScoutDB.scans
	-- the same scan can come from both sources
	for _, s in ipairs(scans) do
		if math.abs(s.t - scan.t) < 60 and s.n == scan.n then return end
	end
	scans[#scans + 1] = scan
	table.sort(scans, function(a, b) return a.t < b.t end)
	while #scans > MAX_SCANS do table.remove(scans, 1) end
end

local function OnProcessScan(_, itemIndexes)
	if type(itemIndexes) ~= "table" then return end
	local data, count = Summarize(itemIndexes)
	if count < FULL_SCAN_MIN_ITEMS then return end
	Add({ t = time(), realm = GetRealmName(), faction = UnitFactionGroup("player"), n = count, data = data })
	print("|cffffd200Gold Scout|r saved the auction house scan (" .. count .. " items). /gs scans")
end

local function HookDatabase()
	local database = Auctionator and Auctionator.Database
	if database and not hooked[database] and database.ProcessScan then
		hooksecurefunc(database, "ProcessScan", OnProcessScan)
		hooked[database] = true
	end
end

local function ImportSync()
	if GoldScoutDB.scansImported or type(AuctionhouseSyncDB) ~= "table" then return end
	for _, s in ipairs(AuctionhouseSyncDB.scans or {}) do
		if type(s.data) == "string" and (s.n or 0) >= FULL_SCAN_MIN_ITEMS then
			Add({ t = s.t, realm = s.realm, faction = s.faction, n = s.n, data = s.data })
		end
	end
	GoldScoutDB.scansImported = true
end

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(_, e, name)
	if e == "ADDON_LOADED" and name == "GoldScout" then
		GoldScoutDB = GoldScoutDB or {}
		GoldScoutDB.scans = GoldScoutDB.scans or {}
		-- Auctionator (re)creates its database in InitializeDatabase: hook every instance it makes
		if Auctionator and Auctionator.Variables and Auctionator.Variables.InitializeDatabase then
			hooksecurefunc(Auctionator.Variables, "InitializeDatabase", HookDatabase)
		end
		HookDatabase()
	elseif e == "PLAYER_LOGIN" then
		HookDatabase()
		ImportSync()
	end
end)
