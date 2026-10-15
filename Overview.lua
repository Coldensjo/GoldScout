-- Gold Scout overview: a window over everything GoldScoutDB has gathered.
-- Tabs: Characters, Items (all characters, valued at auction price), Crafting (recipe profit), Vendors (flips).

local _, ns = ...

local ROWS, ROW_H = 18, 20
local TOP = 98 -- where the rows start: title, tab row, sub-tab row, header
local AH_CUT = 0.95

local frame, rows, tabs, subTabs, search, footer, header, scrollbar
local current, data, offset = "chars", {}, 0
local Select

------------------------------------------------------------------------------------------------
-- Helpers

local function Money(c)
	if not c then return "|cff808080-|r" end
	local neg = c < 0
	c = math.floor(math.abs(c) + 0.5)
	local g, s, cc = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
	local str
	if g > 0 then
		str = string.format("|cffffd700%dg|r |cffc7c7cf%02ds|r", g, s)
	elseif s > 0 then
		str = string.format("|cffc7c7cf%ds|r |cffeda55f%02dc|r", s, cc)
	else
		str = string.format("|cffeda55f%dc|r", cc)
	end
	return neg and ("|cffff4040-|r" .. str) or str
end

local function Price(id)
	if not id or not Auctionator or not Auctionator.API or not Auctionator.API.v1 then return nil end
	local ok, p = pcall(Auctionator.API.v1.GetAuctionPriceByItemID, "GoldScout", id)
	return ok and p or nil
end

local function VendorPrice(id)
	if not Auctionator or not Auctionator.API or not Auctionator.API.v1.GetVendorPriceByItemID then return nil end
	local ok, p = pcall(Auctionator.API.v1.GetVendorPriceByItemID, "GoldScout", id)
	return ok and p or nil
end

-- Reagents bought from vendors (vials, thread) are often missing from the auction house
local function ReagentPrice(id)
	local ah, v = Price(id), VendorPrice(id)
	if ah and v then return math.min(ah, v) end
	return ah or v
end

local pending = {}
local function ItemName(id)
	local name, _, quality = C_Item.GetItemInfo(id)
	if name then
		local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
		return color and (color.hex .. name .. "|r") or name, name
	end
	if not pending[id] then
		pending[id] = true
		C_Item.RequestLoadItemDataByID(id)
	end
	return "|cff808080item " .. id .. "|r", "item " .. id
end

local function ClassName(c)
	local color = c.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[c.class]
	local name = c.name or "?"
	return color and ("|c" .. color.colorStr .. name .. "|r") or name
end

local function Ago(t)
	if not t then return "|cff808080never|r" end
	local d = time() - t
	if d < 3600 then return math.floor(d / 60) .. "m ago" end
	if d < 86400 then return math.floor(d / 3600) .. "h ago" end
	return math.floor(d / 86400) .. "d ago"
end

local function Chars()
	local list = {}
	for _, c in pairs(GoldScoutDB and GoldScoutDB.chars or {}) do
		list[#list + 1] = c
	end
	table.sort(list, function(a, b) return (a.money or 0) > (b.money or 0) end)
	return list
end

local function Values(t)
	if type(t) ~= "table" then return {} end
	local out = {}
	for _, v in pairs(t) do out[#out + 1] = v end
	return out
end

------------------------------------------------------------------------------------------------
-- Records shared by the tabs: posts, buys, what you paid, market prices then, time to sell

local function NameOf(id)
	local name = C_Item.GetItemNameByID and C_Item.GetItemNameByID(id) or C_Item.GetItemInfo(id)
	if not name then ItemName(id) end -- asks the server; the tab is rebuilt when it answers
	return name
end

local function TimeLeft(s)
	if s <= 0 then return "now" end
	if s < 3600 then return math.ceil(s / 60) .. "m" end
	return math.floor(s / 3600) .. "h " .. math.floor(s % 3600 / 60) .. "m"
end

-- Posts, rebuilt from the journal: a deposit paid while exactly one kind of item left the bags and
-- nothing came in. Until Journal.lua checked the auction house first, posting was often logged as
-- the mailbox; a 30c payment there is postage, not a deposit. AHTrack's own log (which until the
-- 2/8/24h fix caught nothing) adds the price per unit when it saw the same post.
-- Returns { i, who, t, id, q, deposit, unit? }, oldest first.
local POSTAGE = 30
local function Posts()
	local logged = {}
	for who, c in pairs(GoldScoutDB and GoldScoutDB.chars or {}) do
		for _, p in ipairs(Values(c.ah and c.ah.posts)) do
			local t, id, q, unit = strsplit(":", p)
			logged[who] = logged[who] or {}
			table.insert(logged[who], { t = tonumber(t), id = tonumber(id), q = tonumber(q), unit = tonumber(unit) })
		end
	end
	local out = {}
	for i, line in ipairs(GoldScoutDB and GoldScoutDB.journal or {}) do
		local t, who, kind, a, b, c = strsplit("|", line)
		if kind == "inv" and (a == "ah" or a == "mail") then
			local dm = tonumber(b) or 0
			local id, n = (c or ""):match("^(%d+):%-(%d+)$")
			if dm < 0 and id and dm ~= -POSTAGE then
				local p = { i = i, who = who, t = tonumber(t), id = tonumber(id), q = tonumber(n), deposit = -dm }
				for _, l in ipairs(logged[who] or {}) do
					if not l.used and l.id == p.id and l.q == p.q and math.abs(l.t - p.t) < 120 then
						p.unit, l.used = l.unit, true
						break
					end
				end
				out[#out + 1] = p
			end
		end
	end
	return out
end

-- Mail between your characters, rebuilt from the journal: a send is money or items leaving at the
-- mailbox with postage paid (30c a mail, 30c per attachment); the receive is the same amount, or the
-- same stack, arriving at another of your characters' mailboxes later. What finds no match went to
-- someone else. Lines already explained as posts or auction buys are passed in `skip`.
-- Returns { t, from, to?, money, items = { [id] = n }, got? }, oldest first.
local MAIL_DAYS_KEPT = 30 * 86400
local function Transfers(skip)
	local sends, gains = {}, {}
	for i, line in ipairs(GoldScoutDB and GoldScoutDB.journal or {}) do
		local t, who, kind, a, b, c = strsplit("|", line)
		if kind == "inv" and a == "mail" and not (skip and skip[i]) then
			t = tonumber(t)
			local dm = tonumber(b) or 0
			local out, came, n = {}, {}, 0
			for part in (c or ""):gmatch("[^,]+") do
				local id, d = part:match("^(%d+):([%+%-]?%d+)$")
				id, d = tonumber(id), tonumber(d)
				if id and d < 0 then out[id], n = -d, n + 1 elseif id and d > 0 then came[id] = d end
			end
			if next(came) == nil and dm < 0 then
				if n == 0 and -dm > POSTAGE then
					sends[#sends + 1] = { t = t, from = who, money = -dm - POSTAGE, items = {} }
				elseif n > 0 and -dm % POSTAGE == 0 then
					sends[#sends + 1] = { t = t, from = who, money = 0, items = out }
				end
			elseif dm > 0 or next(came) then
				gains[#gains + 1] = { t = t, who = who, money = math.max(dm, 0), items = came }
			end
		end
	end
	for _, s in ipairs(sends) do
		for _, g in ipairs(gains) do
			if g.who ~= s.from and g.t >= s.t - 60 and g.t - s.t < MAIL_DAYS_KEPT then
				local hit = false
				if s.money > 0 and g.money == s.money then
					g.money, hit = 0, true
				end
				for id, n in pairs(s.items) do
					if g.items[id] == n and not (s.got and s.got[id]) then
						g.items[id] = nil
						s.got = s.got or {}
						s.got[id] = true
						hit = true
					end
				end
				if hit then s.to = s.to or g.who end
				if s.money > 0 and hit then break end
			end
		end
	end
	return sends
end

-- name -> itemID, for invoices and expiry mails, which only carry names
local nameToID = {}
local function NameIndex()
	local ids = {}
	for _, p in ipairs(Posts()) do ids[p.id] = true end
	for _, c in pairs(GoldScoutDB and GoldScoutDB.chars or {}) do
		for _, p in ipairs(Values(c.ah and c.ah.posts)) do
			local id = tonumber((select(2, strsplit(":", p))))
			if id then ids[id] = true end
		end
		for _, src in ipairs({ "bags", "bank", "mail" }) do
			for id in pairs(c[src] or {}) do ids[tonumber(id)] = true end
		end
		for _, list in pairs(c.recipes or {}) do
			for _, r in ipairs(Values(list)) do
				local made, _, _, reagents = strsplit("|", r)
				if tonumber(made) then ids[tonumber(made)] = true end
				for rid in (reagents or ""):gmatch("(%d+):%d+") do ids[tonumber(rid)] = true end
			end
		end
	end
	for id in pairs(ids) do
		local name = NameOf(id)
		if name then nameToID[name] = id end
	end
	return nameToID
end

-- Buy invoices in this client often repeat the count where the price belongs. The real price is the
-- money that left the bags at the auction house or mailbox at that moment (journal "inv" lines with
-- no items leaving, so not a post), else today's market price.
-- Returns { who, t, name, q, price, estimated } and the journal lines used.
local MATCH_EXACT, MATCH_NEAR = 3600, 600
local function ResolveBuys(names)
	local journal = GoldScoutDB and GoldScoutDB.journal or {}
	local candidates = {}
	for i, line in ipairs(journal) do
		local t, who, kind, a, b, c = strsplit("|", line)
		if kind == "inv" and (a == "ah" or a == "mail") and not (c or ""):find(":%-") then
			local dm = tonumber(b) or 0
			if dm < 0 then
				candidates[who] = candidates[who] or {}
				table.insert(candidates[who], { i = i, t = tonumber(t), paid = -dm })
			end
		end
	end
	local out, claimed = {}, {}
	for who, c in pairs(GoldScoutDB and GoldScoutDB.chars or {}) do
		for _, s in ipairs(Values(c.ah and c.ah.buys)) do
			local t, name, q, price = strsplit("|", s)
			t, q, price = tonumber(t), tonumber(q) or 1, tonumber(price) or 0
			local valid = price > q
			local best, bestDist
			for _, cand in ipairs(candidates[who] or {}) do
				if not claimed[cand.i] then
					local dist = math.abs(cand.t - t)
					local fits = valid and cand.paid == price and dist <= MATCH_EXACT
						or not valid and cand.paid > q and dist <= MATCH_NEAR
					if fits and (not bestDist or dist < bestDist) then best, bestDist = cand, dist end
				end
			end
			local estimated = false
			if best then
				claimed[best.i] = true
				price = best.paid
			elseif not valid then
				local id = names and names[name]
				price = (id and Price(id) or 0) * q
				estimated = true
			end
			out[#out + 1] = { who = who, t = t, name = name, q = q, price = price, estimated = estimated }
		end
	end
	return out, claimed
end

-- itemID -> average price you paid per unit at the auction house
local function PaidPrices(names)
	local sum, qty = {}, {}
	for _, r in ipairs((ResolveBuys(names))) do
		local id = names[r.name]
		if id and r.q > 0 then
			sum[id], qty[id] = (sum[id] or 0) + r.price, (qty[id] or 0) + r.q
		end
	end
	local out = {}
	for id, s in pairs(sum) do out[id] = s / qty[id] end
	return out
end

-- itemID -> cheapest cost of making one, reagents at what you paid for them when you bought them,
-- else at today's price (pass no paid table for today's prices only)
local function CraftCosts(paid)
	local out = {}
	for _, c in ipairs(Chars()) do
		for _, list in pairs(c.recipes or {}) do
			for _, r in ipairs(Values(list)) do
				local p = { strsplit("|", r) }
				local made = tonumber(p[1])
				if made then
					local cost = 0
					for part in (p[4] or ""):gmatch("[^,]+") do
						local rid, n = part:match("(%d+):(%d+)")
						rid = tonumber(rid)
						cost = cost + (paid and paid[rid] or ReagentPrice(rid) or 0) * tonumber(n)
					end
					cost = cost / (tonumber(p[5]) or 1)
					if not out[made] or cost < out[made] then out[made] = cost end
				end
			end
		end
	end
	return out
end

-- What one unit cost: average auction purchase price, else crafting cost, else 0 (farmed)
local function CostBasis(name, id, buys, crafts)
	local b = buys[name]
	if b and b.q > 0 then return b.price / b.q, "bought" end
	if id and crafts[id] then return crafts[id], "crafted" end
	return 0, "farmed"
end

-- Auction house scans (Scans.lua), parsed once each
local parsed = {} -- scan time -> { [itemID] = { min, qty, auctions, median } }
local function Parse(scan)
	local p = parsed[scan.t]
	if p then return p end
	p = {}
	for id, min, qty, auctions, median in (scan.data or ""):gmatch("(%d+):(%d+):(%d+):(%d+):(%d+)") do
		p[tonumber(id)] = { tonumber(min), tonumber(qty), tonumber(auctions), tonumber(median) }
	end
	parsed[scan.t] = p
	return p
end

-- The market for an item at a moment: the last full scan of that realm before it (at most 3 days
-- old). Returns cheapest listing, median listing, scan time; nil when no scan covers it.
local MARKET_AGE = 3 * 86400
local function MarketAt(id, t, realm)
	local scans = GoldScoutDB and GoldScoutDB.scans or {}
	for i = #scans, 1, -1 do
		local s = scans[i]
		if s.t <= t and (not realm or not s.realm or s.realm == realm) then
			if t - s.t > MARKET_AGE then return nil end
			local v = Parse(s)[id]
			if v then return v[1], v[4], s.t end
		end
	end
end

-- Time to sell: posts are used up, oldest first, by the sales, expiries and cancels of the same item
-- on the same character. Returns itemID -> { sold, wait (seconds, summed per item sold), ended,
-- lostDeposit, posted, deposits }.
local function TimeToSell(posts, names)
	local queues, out = {}, {}
	local function Stat(id)
		local s = out[id]
		if not s then
			s = { sold = 0, wait = 0, ended = 0, lostDeposit = 0, posted = 0, deposits = 0 }
			out[id] = s
		end
		return s
	end
	for _, p in ipairs(posts) do
		local k = p.who .. ":" .. p.id
		queues[k] = queues[k] or {}
		table.insert(queues[k], { t = p.t, left = p.q, q = p.q, deposit = p.deposit })
		local s = Stat(p.id)
		s.posted, s.deposits = s.posted + p.q, s.deposits + p.deposit
	end
	local events = {}
	for who, c in pairs(GoldScoutDB and GoldScoutDB.chars or {}) do
		for _, line in ipairs(Values(c.ah and c.ah.sales)) do
			local t, name, q = strsplit("|", line)
			events[#events + 1] = { who = who, t = tonumber(t), name = name, q = tonumber(q) or 1, sold = true }
		end
		for _, line in ipairs(Values(c.ah and c.ah.ended)) do
			local t, subject = strsplit("|", line)
			local name, q = (subject or ""):match("^(.-) %((%d+)%)$")
			events[#events + 1] = { who = who, t = tonumber(t), name = name or subject, q = tonumber(q) or 1 }
		end
	end
	table.sort(events, function(a, b) return a.t < b.t end)
	for _, e in ipairs(events) do
		local id = names[e.name]
		local queue = id and queues[e.who .. ":" .. id]
		local need = e.q
		while queue and need > 0 do
			local p = queue[1]
			if not p or p.t > e.t then break end
			local take = math.min(need, p.left)
			local s = Stat(id)
			if e.sold then
				s.sold, s.wait = s.sold + take, s.wait + (e.t - p.t) * take
			else
				s.ended, s.lostDeposit = s.ended + take, s.lostDeposit + p.deposit * take / p.q
			end
			p.left, need = p.left - take, need - take
			if p.left <= 0 then table.remove(queue, 1) end
		end
	end
	return out
end

------------------------------------------------------------------------------------------------
-- Tabs: each builds rows of { cols = {...}, item = itemID?, search = "lowercase text" }

local TABS = {}

TABS.chars = {
	title = "Characters",
	cols = { { "Character", 150 }, { "Lvl", 34 }, { "Gold", 100 }, { "Professions", 330 }, { "Seen", 70 } },
	build = function()
		local out, total = {}, 0
		for _, c in ipairs(Chars()) do
			total = total + (c.money or 0) + (c.mailMoney or 0)
			local profs = {}
			for name, s in pairs(c.skills or c.profSkill or {}) do
				local rank, max = s[1] or 0, s[2] or 0
				if max > 0 and rank > 1 then
					local color = rank >= max and "|cffff8040" or "|cffffffff"
					profs[#profs + 1] = name .. " " .. color .. rank .. "|r/" .. max
				end
			end
			table.sort(profs)
			out[#out + 1] = {
				cols = { ClassName(c), c.level or "?", Money((c.money or 0) + (c.mailMoney or 0)), table.concat(profs, ", "), Ago(c.seen) },
				search = (c.name or ""):lower(),
			}
		end
		return out, "Total gold on all characters: " .. Money(total)
	end,
}

TABS.items = {
	title = "Items",
	cols = { { "Item", 210 }, { "Count", 50 }, { "Each", 90 }, { "Value", 90 }, { "Where", 250 } },
	build = function()
		local items = {}
		for _, c in ipairs(Chars()) do
			for _, src in ipairs({ "bags", "bank", "mail" }) do
				for id, n in pairs(c[src] or {}) do
					id = tonumber(id)
					local it = items[id] or { n = 0, where = {} }
					items[id] = it
					it.n = it.n + n
					it.where[#it.where + 1] = (c.name or "?") .. " " .. n .. " " .. src
				end
			end
		end
		local out, total = {}, 0
		for id, it in pairs(items) do
			local p = Price(id) or VendorPrice(id)
			local value = p and p * it.n
			total = total + (value or 0)
			local label, plain = ItemName(id)
			out[#out + 1] = {
				cols = { label, it.n, Money(p), Money(value), table.concat(it.where, ", ") },
				item = id, sort = value or 0, search = plain:lower(),
			}
		end
		table.sort(out, function(a, b) return a.sort > b.sort end)
		return out, "Everything valued at auction price (vendor price if not on the auction house): " .. Money(total)
	end,
}

TABS.craft = {
	title = "Crafting",
	cols = { { "Recipe", 190 }, { "Who", 120 }, { "Made", 45 }, { "Cost now", 85 }, { "You paid", 85 }, { "Sells", 85 }, { "Profit now", 90 }, { "Your profit", 90 }, { "", 120 } },
	build = function()
		local out = {}
		-- "You paid": reagents at your average auction buy price, where you bought them
		local paid = PaidPrices(NameIndex())
		local crafted = {}
		for _, line in ipairs(GoldScoutDB and GoldScoutDB.journal or {}) do
			local _, who, kind, id, n = strsplit("|", line)
			if kind == "craft" then
				local k = who .. ":" .. id
				crafted[k] = (crafted[k] or 0) + (tonumber(n) or 1)
			end
		end
		for key, c in pairs(GoldScoutDB and GoldScoutDB.chars or {}) do
			for prof, list in pairs(c.recipes or {}) do
				for _, r in ipairs(Values(list)) do
					local p = { strsplit("|", r) }
					local made = tonumber(p[1])
					if made then
						local qty = tonumber(p[5]) or 1
						local cost, yours, missing, bought = 0, 0, false, false
						for part in (p[4] or ""):gmatch("[^,]+") do
							local rid, n = part:match("(%d+):(%d+)")
							rid, n = tonumber(rid), tonumber(n)
							local rp = ReagentPrice(rid)
							if rp then cost = cost + rp * n else missing = true end
							if paid[rid] then bought = true end
							yours = yours + (paid[rid] or rp or 0) * n
						end
						local sell = Price(made)
						local profit = sell and (sell * qty * AH_CUT - cost)
						local yourProfit = sell and bought and (sell * qty * AH_CUT - yours)
						local n = crafted[key .. ":" .. made] or 0
						local label, plain = ItemName(made)
						local function Profit(v)
							if not v then return "" end
							return v > 0 and Money(v) or ("|cffff4040" .. Money(v) .. "|r")
						end
						out[#out + 1] = {
							cols = {
								label .. (qty > 1 and (" x" .. qty) or ""),
								(c.name or "?") .. " |cff808080" .. prof .. "|r",
								n > 0 and n or "",
								Money(cost) .. (missing and "|cffff4040*|r" or ""),
								bought and Money(yours) or "",
								Money(sell),
								profit and Profit(profit) or Money(nil),
								Profit(yourProfit),
								missing and "|cffff4040* reagent unpriced|r" or "",
							},
							item = made, sort = profit or -1e12, search = (plain .. " " .. prof .. " " .. (c.name or "")):lower(),
						}
					end
				end
			end
		end
		table.sort(out, function(a, b) return a.sort > b.sort end)
		return out, "Profit now = auction price x " .. AH_CUT .. " (the cut) - reagents at today's price. You paid / your profit = reagents at what you paid for the ones you bought. Made = crafted so far."
	end,
}

TABS.vendors = {
	title = "Vendors",
	cols = { { "Item", 200 }, { "Vendor price", 90 }, { "Auction", 90 }, { "Margin", 90 }, { "Vendor", 220 } },
	build = function()
		local out, nVendors = {}, 0
		for name, v in pairs(GoldScoutDB and GoldScoutDB.vendors or {}) do
			nVendors = nVendors + 1
			for _, entry in ipairs(Values(v.items)) do
				local id, price, qty, avail, x = strsplit(":", entry)
				id, price, qty, avail = tonumber(id), tonumber(price) or 0, tonumber(qty) or 1, tonumber(avail) or -1
				if id and price > 0 and not x then
					local ah = Price(id)
					local each = price / qty
					local margin = ah and (ah * AH_CUT - each)
					local label, plain = ItemName(id)
					out[#out + 1] = {
						cols = {
							label .. (avail > 0 and (" |cffff8040(limited " .. avail .. ")|r") or ""),
							Money(each), Money(ah),
							margin and (margin > 0 and Money(margin) or ("|cff808080" .. Money(margin) .. "|r")) or Money(nil),
							name:gsub("@", " |cff808080") .. "|r",
						},
						item = id, sort = margin or -1e12, search = (plain .. " " .. name):lower(),
					}
				end
			end
		end
		table.sort(out, function(a, b) return a.sort > b.sort end)
		return out, nVendors .. " vendors recorded. Open a vendor to add it. Best auction margins first."
	end,
}

-- Auction tracking (AHTrack.lua) ----------------------------------------------------------------

TABS.auctions = {
	title = "Auctions",
	cols = { { "Item", 200 }, { "Who", 90 }, { "Qty", 40 }, { "Each", 90 }, { "Status", 170 }, { "Market now", 220 } },
	build = function()
		local out, listed, pending, oldest = {}, 0, 0, nil
		local now = time()
		for _, c in ipairs(Chars()) do
			local a = c.ah
			if a and a.ownedAt then
				oldest = math.min(oldest or a.ownedAt, a.ownedAt)
				for _, s in pairs(a.owned or {}) do
					local id, q, unit, status, left = strsplit(":", s)
					id, q, unit, status, left = tonumber(id), tonumber(q), tonumber(unit), tonumber(status), tonumber(left)
					local remain = left - (now - a.ownedAt)
					local label, plain = ItemName(id)
					local market = Price(id)
					local statusText, marketText
					if status == 1 then
						pending = pending + unit * q
						statusText = remain > 0 and ("|cff40ff40sold|r, money in ~" .. TimeLeft(remain)) or "|cff40ff40sold|r, money in the mailbox"
						marketText = ""
					else
						listed = listed + unit * q
						statusText = remain > 0 and ("listed, " .. TimeLeft(remain) .. " left") or "|cffff8040probably expired|r"
						if market and market < unit then
							marketText = Money(market) .. " |cffff4040undercut|r"
						else
							marketText = Money(market) .. (market and " |cff40ff40cheapest|r" or "")
						end
					end
					out[#out + 1] = {
						cols = { label, c.name or "?", q, Money(unit), statusText, marketText },
						item = id, sort = status * 1e12 + unit * q, search = (plain .. " " .. (c.name or "")):lower(),
					}
				end
			end
		end
		table.sort(out, function(a, b) return a.sort > b.sort end)
		return out, "Listed " .. Money(listed) .. "   Sold, money on its way " .. Money(pending)
			.. "   |cff808080(as of " .. (oldest and Ago(oldest) or "never: open the auction house") .. ")|r"
	end,
}

TABS.sales = {
	title = "Sales",
	cols = { { "Item", 190 }, { "Sold", 60 }, { "Avg each", 90 }, { "Received", 100 }, { "Profit", 120 }, { "Takes to sell", 90 }, { "Posted / ended", 300 } },
	build = function()
		local ids = NameIndex()
		local crafts = CraftCosts(PaidPrices(ids))
		local posts = Posts()
		local timing = TimeToSell(posts, ids)
		local items, buys = {}, {}
		local function Item(name)
			local it = items[name] or { q = 0, gross = 0, net = 0, dep = 0, posted = 0, expired = 0, cancelled = 0, last = 0 }
			items[name] = it
			return it
		end
		for _, r in ipairs((ResolveBuys(ids))) do
			local b = buys[r.name] or { q = 0, price = 0 }
			buys[r.name] = b
			b.q, b.price = b.q + r.q, b.price + r.price
		end
		for _, c in ipairs(Chars()) do
			local a = c.ah or {}
			for _, s in ipairs(Values(a.sales)) do
				local t, name, q, gross, cut, dep = strsplit("|", s)
				local it = Item(name)
				it.q = it.q + tonumber(q)
				it.gross = it.gross + tonumber(gross)
				it.net = it.net + tonumber(gross) - tonumber(cut)
				it.dep = it.dep + tonumber(dep)
				it.last = math.max(it.last, tonumber(t))
			end
			for _, s in ipairs(Values(a.ended)) do
				local _, name, how = strsplit("|", s)
				-- "Elixir of Agility (5)": the stack size is part of the mail subject
				local it = Item(((name or "?"):gsub(" %(%d+%)$", "")))
				it[how] = (it[how] or 0) + 1
			end
		end
		for _, p in ipairs(posts) do
			local name = NameOf(p.id)
			if name then
				local it = Item(name)
				it.posted = it.posted + 1
			end
		end
		local out, totNet, totProfit = {}, 0, 0
		for name, it in pairs(items) do
			local id = ids[name]
			local unitCost, how = CostBasis(name, id, buys, crafts)
			-- deposits come back with a sale; the ones on expired or cancelled auctions are lost
			local tm = id and timing[id]
			local lostDep = tm and tm.lostDeposit or 0
			local profit = it.net - lostDep - unitCost * it.q
			totNet, totProfit = totNet + it.net, totProfit + profit
			local label = id and (ItemName(id)) or name
			out[#out + 1] = {
				cols = {
					label,
					it.q,
					it.q > 0 and Money(it.gross / it.q) or Money(nil),
					Money(it.net),
					(profit >= 0 and Money(profit) or ("|cffff4040" .. Money(profit) .. "|r")) .. " |cff808080" .. how .. "|r",
					tm and tm.sold > 0 and TimeLeft(tm.wait / tm.sold) or "",
					it.posted .. " posted, " .. it.expired .. " expired, " .. it.cancelled .. " cancelled"
						.. (lostDep > 0 and (", deposits lost " .. Money(lostDep)) or ""),
				},
				item = id, sort = it.net, search = name:lower(),
			}
		end
		table.sort(out, function(a, b) return a.sort > b.sort end)
		return out, "Received " .. Money(totNet) .. " (after the auction house cut)   Profit " .. Money(totProfit)
			.. "   |cff808080cost = what you paid, else crafting cost now, else 0 when farmed|r"
	end,
}

-- Gathering and sessions (Gather.lua) -----------------------------------------------------------

TABS.gather = {
	title = "Gathering",
	cols = { { "Node", 170 }, { "Kind", 60 }, { "Gathered", 70 }, { "Value / node", 100 }, { "Drops per node", 540 } },
	build = function()
		local nodes = {}
		for _, line in ipairs(GoldScoutDB and GoldScoutDB.gather or {}) do
			local _, _, kind, node, _, _, _, _, items = strsplit("|", line)
			if node == "?" and kind == "herb" and ns.NodeFromLoot then
				-- recorded before the name fallbacks: name it after the herb it gave
				local got = {}
				for part in (items or ""):gmatch("[^,]+") do
					local id, q = part:match("(%d+):(%d+)")
					got[tonumber(id)] = tonumber(q)
				end
				node = ns.NodeFromLoot(kind, got) or node
			end
			local k = kind .. "|" .. node
			local n = nodes[k] or { kind = kind, node = node, count = 0, items = {} }
			nodes[k] = n
			n.count = n.count + 1
			for part in (items or ""):gmatch("[^,]+") do
				local id, q = part:match("(%d+):(%d+)")
				id = tonumber(id)
				local d = n.items[id] or { q = 0, nodes = 0 }
				n.items[id] = d
				d.q, d.nodes = d.q + tonumber(q), d.nodes + 1
			end
		end
		local out, total, totalNodes = {}, 0, 0
		for _, n in pairs(nodes) do
			local value, drops = 0, {}
			for id, d in pairs(n.items) do
				value = value + (Price(id) or VendorPrice(id) or 0) * d.q
				drops[#drops + 1] = { id = id, d = d }
			end
			table.sort(drops, function(a, b) return a.d.q > b.d.q end)
			local parts = {}
			for _, x in ipairs(drops) do
				local name = ItemName(x.id)
				local chance = x.d.nodes / n.count * 100
				parts[#parts + 1] = name .. " " .. string.format("%.1f", x.d.q / n.count)
					.. (chance < 100 and string.format(" |cff808080(%.1f%%)|r", chance) or "")
			end
			total, totalNodes = total + value, totalNodes + n.count
			out[#out + 1] = {
				cols = { n.node, n.kind, n.count, Money(value / n.count), table.concat(parts, ", ") },
				sort = value, search = (n.node .. " " .. n.kind .. " " .. table.concat(parts, " ")):lower(),
			}
		end
		table.sort(out, function(a, b) return a.sort > b.sort end)
		return out, totalNodes .. " nodes gathered, worth " .. Money(total) .. " at auction prices. (x%) = share of nodes that gave it"
	end,
}

-- Sessions closer than this are one sitting (a /reload starts a new session)
local SESSION_GAP = 15 * 60
local SOURCES = { "loot", "vendor", "mail", "quest", "ah", "training", "travel", "other" }

TABS.sessions = {
	title = "Sessions",
	cols = { { "Character", 110 }, { "When", 110 }, { "Time", 60 }, { "Gold", 100 }, { "Items looted", 100 }, { "Per hour", 100 }, { "Money by source", 360 } },
	build = function()
		local out = {}
		for _, c in ipairs(Chars()) do
			local merged = {}
			for _, s in ipairs(c.sessions or {}) do
				local last = merged[#merged]
				if last and s.start - last.stop < SESSION_GAP then
					last.stop = math.max(last.stop, s.stop or s.start)
					for k, v in pairs(s.money or {}) do last.money[k] = (last.money[k] or 0) + v end
					for id, n in pairs(s.items or {}) do last.items[id] = (last.items[id] or 0) + n end
				else
					local copy = { start = s.start, stop = s.stop or s.start, money = {}, items = {} }
					for k, v in pairs(s.money or {}) do copy.money[k] = v end
					for id, n in pairs(s.items or {}) do copy.items[id] = n end
					merged[#merged + 1] = copy
				end
			end
			for _, s in ipairs(merged) do
				local secs = math.max(s.stop - s.start, 1)
				local gold, parts = 0, {}
				for _, src in ipairs(SOURCES) do
					local v = s.money[src]
					if v and v ~= 0 then
						gold = gold + v
						parts[#parts + 1] = src .. " " .. Money(v)
					end
				end
				local items = 0
				for id, n in pairs(s.items) do items = items + (Price(id) or VendorPrice(id) or 0) * n end
				if secs >= 60 then
					out[#out + 1] = {
						cols = {
							ClassName(c), date("%a %H:%M", s.start), TimeLeft(secs), Money(gold), Money(items),
							Money((gold + items) / secs * 3600), table.concat(parts, ", "),
						},
						sort = s.start, search = (c.name or ""):lower(),
					}
				end
			end
		end
		table.sort(out, function(a, b) return a.sort > b.sort end)
		return out, "Per hour = (gold gained + looted items at auction price) per hour played. Items you sell later are counted when looted, so don't add both."
	end,
}

-- Journal (Journal.lua) --------------------------------------------------------------------------

local function ItemList(s)
	local parts, value = {}, 0
	for part in (s or ""):gmatch("[^,]+") do
		local id, n = part:match("(%d+):([%+%-]?%d+)")
		id, n = tonumber(id), tonumber(n)
		if id then
			value = value + (Price(id) or VendorPrice(id) or 0) * math.abs(n)
			parts[#parts + 1] = (ItemName(id)) .. (n ~= 1 and (" " .. (n > 0 and "x" or "") .. n) or "")
		end
	end
	return table.concat(parts, ", "), value
end

TABS.loot = {
	title = "Loot",
	cols = { { "Source", 170 }, { "Kind", 70 }, { "Kills", 50 }, { "Looted", 55 }, { "Money / loot", 95 }, { "Items / loot", 95 }, { "Drops", 500 } },
	build = function()
		local src = {}
		-- gathering has its own tab: skip loot tagged as gathering, and (for loot recorded before the
		-- tag existed) objects named like a gathered node
		local GATHER = { herb = true, mining = true, skinning = true, fishing = true }
		local nodeNames = {}
		for _, line in ipairs(GoldScoutDB and GoldScoutDB.gather or {}) do
			local node = select(4, strsplit("|", line))
			if node then nodeNames[node] = true end
		end
		-- kills are counted by KillValue (this client hides the combat log from addons)
		local kv = KillValueDB and KillValueDB.learned or {}
		for _, line in ipairs(GoldScoutDB and GoldScoutDB.journal or {}) do
			local _, _, kind, a, b, c, _, e, items = strsplit("|", line)
			if kind == "loot" and not GATHER[a] and not (a == "GameObject" and nodeNames[c]) then
				local k = a .. "|" .. b
				local s = src[k] or { kind = a, id = b, name = c, n = 0, money = 0, items = {} }
				src[k] = s
				if s.name == "?" then s.name = c end
				if s.name == "?" and a == "Creature" and kv[tonumber(b)] and kv[tonumber(b)].name then
					-- looted without being targeted: KillValue knows the mob by its id
					s.name = kv[tonumber(b)].name
				end
				s.n = s.n + 1
				s.money = s.money + (tonumber(e) or 0)
				for part in (items or ""):gmatch("[^,]+") do
					local id, q = part:match("(%d+):(%d+)")
					id = tonumber(id)
					local d = s.items[id] or { q = 0, n = 0 }
					s.items[id] = d
					d.q, d.n = d.q + tonumber(q), d.n + 1
				end
			end
		end
		local out = {}
		for _, s in pairs(src) do
			local value, drops = 0, {}
			for id, d in pairs(s.items) do
				local p = Price(id) or VendorPrice(id) or 0
				value = value + p * d.q
				drops[#drops + 1] = { id = id, d = d, v = p * d.q }
			end
			table.sort(drops, function(x, y) return x.v > y.v end)
			local parts = {}
			for i = 1, math.min(#drops, 8) do
				local x = drops[i]
				parts[#parts + 1] = (ItemName(x.id)) .. string.format(" |cff808080%.1f%%|r", x.d.n / s.n * 100)
			end
			out[#out + 1] = {
				cols = {
					s.name, s.kind, s.kind == "Creature" and kv[tonumber(s.id)] and kv[tonumber(s.id)].kills or "", s.n,
					Money(s.money / s.n), Money(value / s.n), table.concat(parts, ", "),
				},
				sort = (s.money + value), search = (s.name .. " " .. table.concat(parts, " ")):lower(),
			}
		end
		table.sort(out, function(a, b) return a.sort > b.sort end)
		return out, "Every loot window from mobs, chests and containers (gathering is on the Gathering tab). Drops = what was in the window, % = share of loots"
	end,
}

local function Describe(kind, a, b, c, d, e, items)
	if kind == "kill" then return "killed " .. (b or "?") .. " |cff808080" .. (c or "") .. "|r", 0 end
	if kind == "loot" then
		local list, value = ItemList(items)
		return "looted " .. (c or "?") .. ": " .. ((tonumber(e) or 0) > 0 and (Money(tonumber(e)) .. " ") or "") .. list, value
	end
	if kind == "inv" then
		local list = ItemList(c)
		local money = tonumber(b) or 0
		return a .. ": " .. (money ~= 0 and (Money(money) .. " ") or "") .. list, money
	end
	if kind == "repair" then return "repaired gear: " .. Money(tonumber(a) or 0), -(tonumber(a) or 0) end
	if kind == "wear" then
		local why = { death = "dying", spirit = "the spirit healer", combat = "fighting" }
		return "gear wear from " .. (why[a] or a or "?") .. ": " .. Money(tonumber(b) or 0) .. " repair bill", 0
	end
	if kind == "used" then
		local list, value = ItemList(a)
		return "used " .. list .. (value > 0 and (" |cff808080worth " .. Money(value) .. "|r") or ""), -value
	end
	if kind == "delete" then
		local id, n = tonumber(a) or 0, tonumber(b) or 1
		local worth = (Price(id) or VendorPrice(id) or 0) * n
		return "|cffff4040deleted|r " .. (ItemName(id)) .. (n > 1 and (" x" .. n) or "") .. (worth > 0 and (" |cff808080worth " .. Money(worth) .. "|r") or ""), -worth
	end
	if kind == "craft" then return "crafted " .. (ItemName(tonumber(a) or 0)) .. " x" .. (b or 1), 0 end
	if kind == "roll" then return a .. " roll: " .. (ItemName(tonumber(b) or 0)), 0 end
	if kind == "quest" then return "quest " .. (a or "?") .. " turned in: " .. (b or 0) .. " xp, " .. Money(tonumber(c) or 0), tonumber(c) or 0 end
	if kind == "level" then return "reached level " .. (a or "?"), 0 end
	if kind == "xp" then
		local what = { kill = "killing " .. (c or "?"), quest = "a quest", explore = "discovering " .. (c or "?"), other = "elsewhere" }
		return "gained " .. (b or 0) .. " xp from " .. (what[a] or a or "?"), 0
	end
	if kind == "skill" then return (a or "?") .. " skill up to " .. (b or "?") .. " |cff808080/ " .. (c or "?") .. "|r", 0 end
	if kind == "rep" then return "reputation with " .. (a or "?") .. ": " .. ((tonumber(b) or 0) >= 0 and "+" or "") .. (b or 0), 0 end
	if kind == "instance" then
		if a == "enter" then return "entered " .. (b or "?") .. " |cff808080" .. (c or "") .. "|r", 0 end
		return "left " .. (b or "?") .. " after " .. math.floor((tonumber(d) or 0) / 60) .. "m", 0
	end
	if kind == "duel" then return (a == "won" and "|cff40ff40won|r" or "|cffff4040lost|r") .. " a duel against " .. (b or "?") .. " |cff808080" .. (c or "") .. "|r", 0 end
	if kind == "hk" then return "honorable kill: " .. (a or "?") .. ((tonumber(b) or 0) > 0 and (" |cff808080" .. b .. " honor|r") or ""), 0 end
	if kind == "accept" then return "accepted quest " .. ((b and b ~= "") and b or (a or "?")), 0 end
	if kind == "abandon" then return "|cffff8040abandoned|r quest " .. (GoldScoutDB.quests and GoldScoutDB.quests[tonumber(a) or 0] or a or "?"), 0 end
	if kind == "zone" then return "entered " .. (a or "?"), 0 end
	if kind == "death" then return "|cffff4040died|r in " .. (a or "?") .. " (" .. (b or "") .. ", " .. (c or "") .. ")", 0 end
	return kind .. " " .. table.concat({ a or "", b or "", c or "" }, " "), 0
end

TABS.journal = {
	title = "Journal",
	cols = { { "When", 110 }, { "Character", 120 }, { "Event", 880 } },
	build = function()
		local out = {}
		local lines = GoldScoutDB and GoldScoutDB.journal or {}
		for i = #lines, math.max(1, #lines - 1500), -1 do
			local t, who, kind, a, b, c, d, e, items = strsplit("|", lines[i])
			local text = Describe(kind, a, b, c, d, e, items)
			out[#out + 1] = {
				cols = { date("%a %H:%M:%S", tonumber(t)), (who or ""):match("^[^-]+") or who, text },
				search = (kind .. " " .. (who or "") .. " " .. text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")):lower(),
			}
		end
		return out, #lines .. " events recorded (newest 1500 shown). Search e.g. vendor, deleted, use, quest"
	end,
}

-- Auction house scans (Scans.lua) --------------------------------------------------------------

local scanIndex -- the scan shown on the detail page
-- the scan before this one from the same auction house
local function Previous(i)
	local scans = GoldScoutDB.scans or {}
	local s = scans[i]
	for j = i - 1, 1, -1 do
		if scans[j].realm == s.realm and scans[j].faction == s.faction then return scans[j] end
	end
end

local function Change(now, before)
	if not before or before == 0 then return "|cff40c0ffnew|r" end
	local pct = (now - before) / before * 100
	if math.abs(pct) < 0.5 then return "|cff808080same|r" end
	return (pct > 0 and "|cff40ff40+" or "|cffff4040") .. string.format("%.0f%%", pct) .. "|r"
end

TABS.scans = {
	title = "Scans",
	cols = { { "When", 130 }, { "Auction house", 150 }, { "Items", 70 }, { "Auctions", 80 }, { "Listed value", 120 }, { "Since the scan before", 420 } },
	build = function()
		local out = {}
		local scans = GoldScoutDB and GoldScoutDB.scans or {}
		for i = #scans, 1, -1 do
			local s = scans[i]
			local p = Parse(s)
			local auctions, value = 0, 0
			for _, v in pairs(p) do
				auctions = auctions + v[3]
				value = value + v[4] * v[2]
			end
			local since = "|cff808080first scan of this auction house|r"
			local prev = Previous(i)
			if prev then
				local pp = Parse(prev)
				local new, gone, up, down = 0, 0, 0, 0
				for id, v in pairs(p) do
					local o = pp[id]
					if not o then new = new + 1
					elseif v[1] > o[1] * 1.05 then up = up + 1
					elseif v[1] < o[1] * 0.95 then down = down + 1 end
				end
				for id in pairs(pp) do if not p[id] then gone = gone + 1 end end
				since = string.format("%s later: %d new, %d gone, lowest price |cff40ff40%d up|r |cffff4040%d down|r",
					TimeLeft(s.t - prev.t), new, gone, up, down)
			end
			out[#out + 1] = {
				cols = { date("%a %d %b %H:%M", s.t), (s.realm or "?") .. " " .. (s.faction or ""), s.n, auctions, Money(value), since },
				search = ((s.realm or "") .. " " .. (s.faction or "")):lower(),
				click = function() if ns.OpenScan then ns.OpenScan(i) end end,
			}
		end
		return out, #scans .. " full scans kept (newest 40). Click a scan to open it. Run a Full Scan in Auctionator to add one."
	end,
}

TABS.scan = {
	title = "Scan",
	parent = "scans",
	cols = { { "Item", 230 }, { "Qty", 60 }, { "Auctions", 70 }, { "Lowest", 100 }, { "Median", 100 }, { "Lowest vs before", 120 }, { "Qty vs before", 120 } },
	build = function()
		local scans = GoldScoutDB and GoldScoutDB.scans or {}
		local s = scans[scanIndex or #scans]
		if not s then return {}, "No scan selected" end
		local p = Parse(s)
		local prev = Previous(scanIndex or #scans)
		local pp = prev and Parse(prev) or {}
		local out = {}
		for id, v in pairs(p) do
			local o = pp[id]
			local name, _, quality = C_Item.GetItemInfo(id)
			local color = name and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
			out[#out + 1] = {
				cols = {
					name and (color and (color.hex .. name .. "|r") or name) or ("|cff808080item " .. id .. "|r"),
					v[2], v[3], Money(v[1]), Money(v[4]),
					prev and Change(v[1], o and o[1]) or "",
					prev and (o and ((v[2] - o[2] >= 0 and "+" or "") .. (v[2] - o[2])) or "|cff40c0ffnew|r") or "",
				},
				item = id, sort = v[4] * v[2], search = (name or ("item " .. id)):lower(), lazy = not name,
			}
		end
		table.sort(out, function(a, b) return a.sort > b.sort end)
		-- names of the most valuable items first; the rest arrive as they are looked at
		for i = 1, math.min(#out, 300) do
			if not C_Item.GetItemInfo(out[i].item) then ItemName(out[i].item) end
		end
		return out, date("%a %d %b %H:%M", s.t) .. "  " .. (s.realm or "?") .. " " .. (s.faction or "") .. ", " .. #out
			.. " items, most listed value first" .. (prev and (". Compared with " .. date("%a %H:%M", prev.t)) or "")
			.. ". Click the Scans tab to go back."
	end,
}

-- Spending (Journal.lua) ---------------------------------------------------------------------------

-- What a consumable costs you: the vendor price if GoldScout saw it at a vendor, else the auction price
local function VendorBuyPrices()
	local out = {}
	for _, v in pairs(GoldScoutDB and GoldScoutDB.vendors or {}) do
		for _, entry in ipairs(Values(v.items)) do
			local id, price, qty, _, x = strsplit(":", entry)
			id, price, qty = tonumber(id), tonumber(price), tonumber(qty) or 1
			if id and price and price > 0 and not x then
				local each = price / qty
				if not out[id] or each < out[id] then out[id] = each end
			end
		end
	end
	return out
end

TABS.spending = {
	title = "Spending",
	cols = { { "Day", 180 }, { "Total", 100 }, { "Consumables", 105 }, { "Repairs paid", 100 }, { "Gear wear", 100 }, { "Vendor buys", 100 }, { "Training", 90 }, { "Flights", 85 }, { "AH deposits", 95 } },
	build = function()
		local buy = VendorBuyPrices()
		local function Cost(id) return buy[id] or Price(id) or VendorPrice(id) or 0 end
		local days = {}
		local function Day(t)
			local k = date("%Y-%m-%d", t)
			local d = days[k] or { key = k, t = t, cons = 0, repair = 0, wear = 0, vendor = 0, training = 0, travel = 0, ah = 0, items = {} }
			days[k] = d
			return d
		end
		local function Used(d, id, n)
			d.items[id] = (d.items[id] or 0) + n
			d.cons = d.cons + Cost(id) * n
		end
		for _, line in ipairs(GoldScoutDB and GoldScoutDB.journal or {}) do
			local t, _, kind, a, b, c = strsplit("|", line)
			t = tonumber(t)
			if kind == "repair" then
				local d = Day(t)
				d.repair = d.repair + (tonumber(a) or 0)
			elseif kind == "wear" then
				local d = Day(t)
				d.wear = d.wear + (tonumber(b) or 0)
			elseif kind == "used" then
				local d = Day(t)
				for part in (a or ""):gmatch("[^,]+") do
					local id, n = part:match("(%d+):(%d+)")
					Used(d, tonumber(id), tonumber(n))
				end
			elseif kind == "inv" then
				local money = tonumber(b) or 0
				if a == "use" then -- recorded before consumption was summed
					local d = Day(t)
					for part in (c or ""):gmatch("[^,]+") do
						local id, n = part:match("(%d+):%-(%d+)")
						if id then Used(d, tonumber(id), tonumber(n)) end
					end
				elseif money < 0 then
					local d = Day(t)
					if a == "vendor" then
						if (c or "") == "" then d.repair = d.repair - money else d.vendor = d.vendor - money end
					elseif a == "training" then d.training = d.training - money
					elseif a == "travel" then d.travel = d.travel - money
					elseif a == "ah" then d.ah = d.ah - money end
				end
			end
		end
		local list = {}
		for _, d in pairs(days) do list[#list + 1] = d end
		table.sort(list, function(x, y) return x.key > y.key end)
		local out, all = {}, 0
		for _, d in ipairs(list) do
			local total = d.cons + d.repair + d.vendor + d.training + d.travel + d.ah
			all = all + total
			out[#out + 1] = {
				cols = { "|cffffd200" .. date("%A %d %b", d.t) .. "|r", Money(total), Money(d.cons), Money(d.repair), Money(d.wear), Money(d.vendor), Money(d.training), Money(d.travel), Money(d.ah) },
				search = d.key,
			}
			local items = {}
			for id, n in pairs(d.items) do items[#items + 1] = { id = id, n = n, v = Cost(id) * n } end
			table.sort(items, function(x, y) return x.v > y.v end)
			for _, it in ipairs(items) do
				local label, plain = ItemName(it.id)
				out[#out + 1] = {
					cols = { "    " .. label .. " x" .. it.n, "", Money(it.v), "", "", "", "", "", "" },
					item = it.id, search = d.key .. " " .. plain:lower(),
				}
			end
		end
		return out, "Spent " .. Money(all) .. " in total. Gear wear = repair bill added by deaths and fighting (paid later as repairs, so not in the total). Consumables valued at vendor price if seen at a vendor, else auction price."
	end,
}

-- The Stats tab (Stats.lua) is defined there and uses these
ns.TABS, ns.Money, ns.Price, ns.VendorPrice, ns.ItemName, ns.ClassName, ns.Ago, ns.TimeLeft, ns.Values = TABS, Money, Price, VendorPrice, ItemName, ClassName, Ago, TimeLeft, Values
ns.CraftCosts, ns.VendorBuyPrices, ns.ResolveBuys = CraftCosts, VendorBuyPrices, ResolveBuys

ns.NameIndex, ns.Posts, ns.PaidPrices, ns.MarketAt, ns.TimeToSell, ns.Transfers, ns.Parse = NameIndex, Posts, PaidPrices, MarketAt, TimeToSell, Transfers, Parse

local ORDER = { "chars", "stats", "progress", "items", "craft", "auctions", "sales", "scans", "gather", "loot", "sessions", "spending", "vendors", "raid", "journal" }

------------------------------------------------------------------------------------------------
-- Window

-- Tabs marked sortable carry row.keys (one number or lowercase string per column); a header click sorts by it
local function SortData()
	local def = TABS[current]
	local c = def.sortable and def.sortCol
	if not c then return end
	table.sort(data, function(a, b)
		local x, y = a.keys and a.keys[c], b.keys and b.keys[c]
		if x == y or x == nil or y == nil or type(x) ~= type(y) then return false end
		if def.sortDesc then return x > y end
		return x < y
	end)
end

local function Render()
	local def = TABS[current]
	if def.panel then return end
	local filter = search:GetText():lower()
	local shown = {}
	for _, r in ipairs(data) do
		if filter == "" or (r.search and r.search:find(filter, 1, true)) then shown[#shown + 1] = r end
	end
	local maxOffset = math.max(0, #shown - ROWS)
	offset = math.max(0, math.min(offset, maxOffset))
	if scrollbar then
		-- never write back to the slider while it drives the render (dragging the thumb): changing
		-- its range or value mid-drag detaches the thumb from the track
		if not scrollbar.driving then
			scrollbar.syncing = true
			local _, max = scrollbar:GetMinMaxValues()
			if max ~= maxOffset then scrollbar:SetMinMaxValues(0, maxOffset) end
			scrollbar:SetValue(offset)
			scrollbar.syncing = false
		end
		scrollbar:SetShown(maxOffset > 0)
	end
	for c = 1, 9 do
		local col = def.cols[c]
		local arrow = def.sortable and def.sortCol == c and (def.sortDesc and " |cffffffffv|r" or " |cffffffff^|r") or ""
		header[c]:SetText(col and (col[1] .. arrow) or "")
	end
	for i = 1, ROWS do
		local row, r = rows[i], shown[i + offset]
		row.item = r and r.item
		row.click = r and r.click
		if r and r.lazy then
			-- a name that was not cached when the table was built: ask for it, show it once it is there
			local label = ItemName(r.item)
			if C_Item.GetItemInfo(r.item) then
				r.cols[1], r.lazy = label, nil
				r.search = (C_Item.GetItemInfo(r.item)):lower()
			end
		end
		for c = 1, 9 do
			local col = def.cols[c]
			row.cols[c]:SetText(r and col and tostring(r.cols[c] or "") or "")
		end
		row:SetShown(r ~= nil)
	end
	frame.count:SetText(#shown > ROWS and string.format("%d-%d of %d", offset + 1, math.min(offset + ROWS, #shown), #shown) or (#shown .. " rows"))
end

local function Layout()
	local def = TABS[current]
	if def.panel then return end
	local x = 0
	for c = 1, 9 do
		local col = def.cols[c]
		local w = col and col[2] or 0
		header[c]:ClearAllPoints()
		header[c]:SetPoint("LEFT", frame.head, "LEFT", x, 0)
		header[c]:SetWidth(math.max(w - 6, 1))
		for i = 1, ROWS do
			local fs = rows[i].cols[c]
			fs:ClearAllPoints()
			fs:SetPoint("LEFT", rows[i], "LEFT", x, 0)
			fs:SetWidth(math.max(w - 6, 1))
		end
		x = x + w
	end
end

local function Refresh()
	if not frame or not frame:IsShown() then return end
	local def = TABS[current]
	if def.panel then
		-- a page of its own (graphs) instead of the table
		footer:SetText(def.refresh(def.frame) or "")
		return
	end
	local text
	data, text = def.build()
	footer:SetText(text or "")
	SortData()
	Render()
end

-- Views of one tab family (TABS[family].subs) get a second row of smaller buttons under the tabs
local function ShowSubTabs(name)
	local def = TABS[name]
	local family = TABS[def.parent or name]
	local subs = family and family.subs
	subTabs = subTabs or {}
	for _, b in ipairs(subTabs) do b:Hide() end
	if not subs then return end
	local x = 14
	for i, sub in ipairs(subs) do
		local b = subTabs[i]
		if not b then
			b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
			b.text = b:GetFontString()
			b:SetScript("OnClick", function(self) Select(self.sub) end)
			subTabs[i] = b
		end
		local d = TABS[sub]
		b.sub = sub
		b:SetText(d.tab or d.title)
		local w = math.max(40, math.floor((b.text and b.text:GetStringWidth() or 40) + 16))
		b:SetSize(w, 20)
		b:ClearAllPoints()
		b:SetPoint("TOPLEFT", x, -54)
		x = x + w + 2
		if sub == name then b:LockHighlight() b.text:SetTextColor(1, 0.82, 0) else b:UnlockHighlight() b.text:SetTextColor(0.8, 0.8, 0.8) end
		b:Show()
	end
	-- the family's filter button (TABS[family].filter = { label(), click() }), if it has one
	if not frame.filterButton then
		local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
		b.text = b:GetFontString()
		b:SetPoint("TOPRIGHT", -18, -54)
		b:SetScript("OnClick", function(self)
			if not self.filter then return end
			self.filter.click()
			self:SetText(self.filter.label())
			offset = 0
			Refresh()
		end)
		frame.filterButton = b
	end
	local fb = frame.filterButton
	fb.filter = family.filter
	if family.filter then
		fb:SetText(family.filter.label())
		fb:SetSize(math.max(60, math.floor((fb.text and fb.text:GetStringWidth() or 60) + 24)), 20)
		fb:Show()
	else
		fb:Hide()
	end
end

function Select(name)
	current, offset = name, 0
	local def = TABS[name]
	for _, t in ipairs(tabs) do
		if t.name == (def.parent or name) then t:LockHighlight() t.text:SetTextColor(1, 0.82, 0) else t:UnlockHighlight() t.text:SetTextColor(0.8, 0.8, 0.8) end
	end
	ShowSubTabs(name)
	if def.panel and not def.frame then def.frame = def.panel(frame) end
	for n, t in pairs(TABS) do
		if t.frame then t.frame:SetShown(n == name) end
	end
	local isTable = not def.panel
	frame.head:SetShown(isTable)
	search:SetShown(isTable)
	frame.count:SetShown(isTable)
	if not isTable then
		for i = 1, ROWS do rows[i]:Hide() end
		if scrollbar then scrollbar:Hide() end
	end
	Layout()
	Refresh()
end

local function Create()
	frame = CreateFrame("Frame", "GoldScoutOverview", UIParent, "BasicFrameTemplateWithInset")
	frame:SetSize(1200, TOP + 62 + ROWS * ROW_H)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("HIGH")
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:SetClampedToScreen(true)
	tinsert(UISpecialFrames, "GoldScoutOverview")

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	title:SetPoint("TOP", 0, -5)
	title:SetText("Gold Scout")

	tabs = {}
	local x = 14
	for i, name in ipairs(ORDER) do
		local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
		b:SetText(TABS[name].title)
		b.text = b:GetFontString()
		-- as wide as its title, so all the tabs fit beside the search box
		local w = math.max(40, math.floor((b.text and b.text:GetStringWidth() or 40) + 16))
		b:SetSize(w, 22)
		b:SetPoint("TOPLEFT", x, -30)
		x = x + w + 2
		b.name = name
		b:SetScript("OnClick", function() Select(name) end)
		tabs[i] = b
	end

	search = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
	search:SetSize(170, 20)
	search:SetPoint("TOPRIGHT", -18, -31)
	search:SetAutoFocus(false)
	search:SetScript("OnTextChanged", function() offset = 0 Render() end)
	search:SetScript("OnEscapePressed", search.ClearFocus)
	local hint = search:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("RIGHT", search, "LEFT", -8, 0)
	hint:SetText("Search")

	frame.head = CreateFrame("Frame", nil, frame)
	frame.head:SetPoint("TOPLEFT", 18, -(TOP - 18))
	frame.head:SetPoint("TOPRIGHT", -40, -(TOP - 18))
	frame.head:SetHeight(18)
	header = {}
	for c = 1, 9 do
		local fs = frame.head:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		fs:SetJustifyH("LEFT")
		fs:SetWordWrap(false)
		header[c] = fs
		local hit = CreateFrame("Button", nil, frame.head)
		hit:SetAllPoints(fs)
		hit:SetScript("OnClick", function()
			local def = TABS[current]
			if not def.sortable then return end
			if def.sortCol == c then def.sortDesc = not def.sortDesc else def.sortCol, def.sortDesc = c, true end
			offset = 0
			SortData()
			Render()
		end)
	end

	rows = {}
	for i = 1, ROWS do
		local row = CreateFrame("Button", nil, frame)
		row:SetHeight(ROW_H)
		row:SetPoint("TOPLEFT", 18, -TOP - (i - 1) * ROW_H)
		row:SetPoint("TOPRIGHT", -40, -TOP - (i - 1) * ROW_H)
		local bg = row:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.04 or 0)
		local hl = row:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 0.82, 0, 0.1)
		row.cols = {}
		for c = 1, 9 do
			local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			fs:SetJustifyH("LEFT")
			fs:SetWordWrap(false)
			row.cols[c] = fs
		end
		row:SetScript("OnClick", function(self) if self.click then self.click() end end)
		row:SetScript("OnEnter", function(self)
			if not self.item then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetItemByID(self.item)
			GameTooltip:Show()
		end)
		row:SetScript("OnLeave", GameTooltip_Hide)
		rows[i] = row
	end

	frame:EnableMouseWheel(true)
	frame:SetScript("OnMouseWheel", function(_, delta)
		offset = math.max(0, offset - delta * 3)
		Render()
	end)

	-- a scrollbar beside the rows; the template expects a scroll frame as parent, so its value
	-- handler is replaced with one that moves the row offset
	scrollbar = CreateFrame("Slider", "GoldScoutOverviewScrollBar", frame, "UIPanelScrollBarTemplate")
	-- the scripts first: the template's own run at the first SetValue and expect a scroll frame
	scrollbar:SetScript("OnValueChanged", function(self, value)
		if self.syncing then return end
		local v = math.floor(value + 0.5)
		if v ~= offset then
			offset = v
			self.driving = true
			Render()
			self.driving = false
		end
	end)
	for name, step in pairs({ ScrollUpButton = -3, ScrollDownButton = 3 }) do
		local b = scrollbar[name] or _G["GoldScoutOverviewScrollBar" .. name]
		if b then b:SetScript("OnClick", function() scrollbar:SetValue(scrollbar:GetValue() + step) end) end
	end
	scrollbar:SetPoint("TOPRIGHT", -22, -TOP - 16)
	scrollbar:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", -22, -(TOP + ROWS * ROW_H) + 16)
	scrollbar:SetMinMaxValues(0, 0)
	scrollbar:SetValueStep(1)
	if scrollbar.SetObeyStepOnDrag then scrollbar:SetObeyStepOnDrag(true) end
	scrollbar:SetValue(0)
	scrollbar:Hide()

	footer = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	footer:SetPoint("BOTTOMLEFT", 18, 14)
	footer:SetPoint("BOTTOMRIGHT", -120, 14)
	footer:SetJustifyH("LEFT")
	frame.count = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	frame.count:SetPoint("BOTTOMRIGHT", -18, 14)

	frame:SetScript("OnShow", Refresh)

	-- names of items that were not cached yet arrive later
	local queued
	frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
	frame:SetScript("OnEvent", function()
		if queued or not frame:IsShown() then return end
		queued = true
		C_Timer.After(0.3, function() queued = false Refresh() end)
	end)

	Select("chars")
end

local function Toggle(tab)
	if not frame then
		-- a new frame starts out shown, so the first call only creates it and keeps it open
		Create()
		frame:Show()
		if tab and TABS[tab] then Select(tab) end
		return
	end
	if tab and TABS[tab] then
		frame:Show()
		Select(tab)
	else
		frame:SetShown(not frame:IsShown())
	end
end

SLASH_GOLDSCOUT1 = "/goldscout"
SLASH_GOLDSCOUT2 = "/gs"
ns.Toggle = Toggle

-- Open a tab with the search box set (Raid.lua: click a person to see their log)
function ns.SearchFor(text, tab)
	if not frame then Create() end
	frame:Show()
	search:SetText(text or "")
	Select(tab or current)
end

function ns.OpenScan(i)
	scanIndex = i
	if not frame then Create() end
	frame:Show()
	search:SetText("")
	Select("scan")
end

SlashCmdList.GOLDSCOUT = function(msg)
	msg = (msg or ""):lower():match("^%s*(%S*)")
	if msg == "minimap" then
		if ns.ToggleMinimap then ns.ToggleMinimap() end
		return
	end
	if msg == "debug" then
		GoldScoutDB.debug = not GoldScoutDB.debug
		print("|cffffd200Gold Scout|r debug " .. (GoldScoutDB.debug and "on" or "off"))
		return
	end
	local alias = { char = "chars", characters = "chars", item = "items", crafting = "craft", vendor = "vendors" }
	Toggle(alias[msg] or (msg ~= "" and msg) or nil)
end
