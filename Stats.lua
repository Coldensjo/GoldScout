-- Gold Scout stats: where the money comes from and where it goes, what sells, how often and how many.
-- Two tabs on the overview window: "stats" (a page of graphs) and "statitems" (every item, sortable).
--
-- Earned = auction sales after the cut (sale invoices), vendor sales, looted coin, quest gold.
-- Spent  = auction buys (buy invoices), auction deposits, vendor buys, repairs, training, flights.
-- Gold mailed between characters is neither: it only moves money around.

local _, ns = ...

local Money, Price, VendorPrice, ItemName, Values = ns.Money, ns.Price, ns.VendorPrice, ns.ItemName, ns.Values
local Ago, TimeLeft = ns.Ago, ns.TimeLeft

local EARN = {
	{ "ah", "Auction sales", { 0.25, 0.8, 0.35 } },
	{ "vendor", "Sold to vendors", { 0.45, 0.85, 0.55 } },
	{ "loot", "Looted coin", { 0.6, 0.9, 0.4 } },
	{ "quest", "Quest rewards", { 0.35, 0.75, 0.75 } },
	{ "other", "Other", { 0.55, 0.65, 0.55 } },
}
local SPEND = {
	{ "ahbuy", "Auction buys", { 0.9, 0.3, 0.25 } },
	{ "ahfee", "Auction deposits", { 0.95, 0.5, 0.3 } },
	{ "vendor", "Vendor buys", { 0.85, 0.4, 0.45 } },
	{ "repair", "Repairs", { 0.75, 0.35, 0.3 } },
	{ "training", "Training", { 0.85, 0.55, 0.45 } },
	{ "travel", "Flights", { 0.7, 0.45, 0.55 } },
	{ "other", "Other", { 0.65, 0.5, 0.5 } },
}
local GREEN, RED, GOLD, BLUE, PURPLE = { 0.25, 0.8, 0.35 }, { 0.9, 0.3, 0.25 }, { 1, 0.82, 0 }, { 0.3, 0.6, 1 }, { 0.65, 0.45, 0.95 }

------------------------------------------------------------------------------------------------
-- Helpers

-- "1.2kg", "45g", "3.5g", "12s", "8c": for axes and small labels
local function Short(c)
	c = c or 0
	local neg = c < 0
	c = math.abs(c)
	local g, s = c / 10000
	if g >= 1000 then s = string.format("%.1fkg", g / 1000)
	elseif g >= 100 then s = string.format("%dg", math.floor(g + 0.5))
	elseif g >= 1 then s = string.format("%.1fg", g)
	elseif c >= 100 then s = math.floor(c / 100) .. "s"
	else s = math.floor(c) .. "c" end
	return (neg and "-" or "") .. s
end

local function Signed(c)
	if c < 0 then return "|cffff4040" .. Money(c) .. "|r" end
	return Money(c)
end

local function Span(s)
	if s < 3600 then return math.max(1, math.floor(s / 60)) .. "m" end
	if s < 86400 then return string.format("%.1fh", s / 3600) end
	return string.format("%.1fd", s / 86400)
end

-- item name -> itemID (shared with Overview.lua, refilled by ns.NameIndex at each build)
local nameToID = {}

local function NameOf(id)
	local name = C_Item.GetItemNameByID and C_Item.GetItemNameByID(id) or C_Item.GetItemInfo(id)
	if name then
		nameToID[name] = id
		return name
	end
	ItemName(id) -- asks the server; the stats are rebuilt when it answers
	return "item " .. id
end

-- "id:+n,id:-n": the items moving one way, each with a share of the money, weighted by price
local function Split(changes, sign, total, priceOf)
	local parts, weight = {}, 0
	for part in (changes or ""):gmatch("[^,]+") do
		local id, n = part:match("^(%d+):([%+%-]?%d+)$")
		id, n = tonumber(id), tonumber(n)
		if id and n and n * sign > 0 then
			local w = (priceOf(id) or 0) * math.abs(n)
			parts[#parts + 1] = { id = id, n = math.abs(n), w = w }
			weight = weight + w
		end
	end
	for _, p in ipairs(parts) do
		p.share = weight > 0 and total * p.w / weight or total / #parts
	end
	return parts
end

------------------------------------------------------------------------------------------------
-- Everything, in one pass over the records

local RECENT = 3 * 86400 -- sales pace for the wipe is measured over this much time

-- What all characters hold now (bags, bank, mailbox; with listed: auctions still running):
-- itemID -> { n, listed, where = { "Micox bags 5", ... } }
local function Holdings(withListed)
	local now = time()
	local held = {}
	local function Hold(id, n, where, listed)
		id = tonumber(id)
		local h = held[id] or { n = 0, listed = 0, where = {} }
		held[id] = h
		h.n = h.n + n
		if listed then h.listed = h.listed + n end
		h.where[#h.where + 1] = where .. " " .. n
	end
	for _, c in pairs(GoldScoutDB and GoldScoutDB.chars or {}) do
		local who = c.name or "?"
		for _, src in ipairs({ "bags", "bank", "mail" }) do
			for id, n in pairs(c[src] or {}) do Hold(id, n, who .. " " .. src) end
		end
		local a = c.ah
		for _, line in pairs(withListed and a and a.owned or {}) do
			local id, q, _, status, left = strsplit(":", line)
			-- still listed: not sold, and not past its time
			if tonumber(status) == 0 and (tonumber(left) or 0) - (now - (a.ownedAt or now)) > 0 then
				Hold(id, tonumber(q) or 1, who .. " listed", true)
			end
		end
	end
	return held
end

local function Collect()
	nameToID = ns.NameIndex()
	local now = time()
	local S = {
		days = {}, earn = {}, spend = {}, items = {}, chars = {}, hours = {}, wealth = {},
		earned = 0, spent = 0, sold = 0, vendored = 0, sales = 0, ended = 0, estimated = 0, mailedOut = 0,
		first = now,
	}
	for h = 0, 23 do S.hours[h] = { sales = 0, qty = 0 } end

	local function Day(t)
		local k = date("%Y-%m-%d", t)
		local d = S.days[k]
		if not d then
			d = { key = k, t = t, earn = {}, spend = {}, earned = 0, spent = 0, sold = 0, sales = 0, items = {} }
			S.days[k] = d
		end
		return d
	end
	local function Char(who)
		local c = S.chars[who]
		if not c then
			c = { key = who, earned = 0, spent = 0, sold = 0 }
			S.chars[who] = c
		end
		return c
	end
	local function Seen(t) if t and t < S.first then S.first = t end end
	local function Earn(t, who, src, v)
		if not v or v <= 0 then return end
		local d = Day(t)
		d.earn[src] = (d.earn[src] or 0) + v
		d.earned = d.earned + v
		S.earn[src] = (S.earn[src] or 0) + v
		S.earned = S.earned + v
		Char(who).earned = Char(who).earned + v
	end
	local function Spend(t, who, cat, v)
		if not v or v <= 0 then return end
		local d = Day(t)
		d.spend[cat] = (d.spend[cat] or 0) + v
		d.spent = d.spent + v
		S.spend[cat] = (S.spend[cat] or 0) + v
		S.spent = S.spent + v
		Char(who).spent = Char(who).spent + v
	end
	local function Item(name, id)
		local it = S.items[name]
		if not it then
			it = { name = name, sold = 0, sales = 0, expired = 0, cancelled = 0, vendored = 0, ahEarned = 0, vendorEarned = 0,
				gross = 0, spent = 0, bought = 0, first = nil, last = nil,
				recent = 0, mktQty = 0, mktYours = 0, mktLow = 0, mktMedian = 0 }
			S.items[name] = it
		end
		it.id = it.id or id or nameToID[name]
		return it
	end
	local function Touch(it, t)
		if not it.first or t < it.first then it.first = t end
	end

	local journal = GoldScoutDB and GoldScoutDB.journal or {}

	local vendorBuy = ns.VendorBuyPrices()
	local function BuyPrice(id) return vendorBuy[id] or VendorPrice(id) or Price(id) end

	for who, c in pairs(GoldScoutDB and GoldScoutDB.chars or {}) do
		local a = c.ah or {}
		for _, s in ipairs(Values(a.sales)) do
			local t, name, q, gross, cut = strsplit("|", s)
			t, q, gross, cut = tonumber(t), tonumber(q) or 1, tonumber(gross) or 0, tonumber(cut) or 0
			local net = gross - cut
			Earn(t, who, "ah", net)
			Seen(t)
			local it = Item(name)
			Touch(it, t)
			it.sold, it.sales = it.sold + q, it.sales + 1
			it.ahEarned, it.gross = it.ahEarned + net, it.gross + gross
			it.last = math.max(it.last or 0, t)
			if now - t <= RECENT then it.recent = it.recent + q end
			-- the market when it sold: the last full scan before the sale
			local low, median
			if it.id then low, median = ns.MarketAt(it.id, t, c.realm) end
			if low and low > 0 then
				it.mktQty, it.mktYours = it.mktQty + q, it.mktYours + gross
				it.mktLow, it.mktMedian = it.mktLow + low * q, it.mktMedian + median * q
			end
			local d = Day(t)
			d.sold, d.sales = d.sold + q, d.sales + 1
			d.items[name] = (d.items[name] or 0) + q
			local h = S.hours[tonumber(date("%H", t))]
			h.sales, h.qty = h.sales + 1, h.qty + q
			S.sold, S.sales = S.sold + q, S.sales + 1
			Char(who).sold = Char(who).sold + q
		end
		for _, s in ipairs(Values(a.ended)) do
			local t, name, how = strsplit("|", s)
			t = tonumber(t)
			-- "Elixir of Agility (5)": the stack size is part of the mail subject
			name = (name or "?"):gsub(" %(%d+%)$", "")
			local it = Item(name)
			Touch(it, t)
			Seen(t)
			if how == "cancelled" then it.cancelled = it.cancelled + 1 else it.expired = it.expired + 1 end
			S.ended = S.ended + 1
		end
	end
	-- buy invoices, priced by the money that actually left the bags (see ResolveBuys in Overview.lua)
	local buys, claimed = ns.ResolveBuys(nameToID)
	for _, r in ipairs(buys) do
		if r.estimated then S.estimated = S.estimated + 1 end
		Spend(r.t, r.who, "ahbuy", r.price)
		Seen(r.t)
		local it = Item(r.name)
		Touch(it, r.t)
		it.spent, it.bought = it.spent + r.price, it.bought + r.q
	end

	-- posts (rebuilt from the journal) and how long things take to sell
	local posts = ns.Posts()
	local isPost = {}
	for _, p in ipairs(posts) do isPost[p.i] = true end
	S.posts = #posts
	for id, tm in pairs(ns.TimeToSell(posts, nameToID)) do
		local it = Item(NameOf(id), id)
		it.timing = tm
	end

	-- mail between your characters (and to other players)
	local explained = {}
	for i in pairs(claimed) do explained[i] = true end
	for i in pairs(isPost) do explained[i] = true end
	S.transfers = ns.Transfers(explained)

	-- the journal: vendor, loot, quests, repairs, training, flights; and every money change for the
	-- gold-over-time graph
	local deltas = {}
	for i, line in ipairs(journal) do
		local t, who, kind, a, b, c = strsplit("|", line)
		t = tonumber(t)
		if t then
			Seen(t)
			if kind == "inv" then
				local dm = tonumber(b) or 0
				if dm ~= 0 then deltas[#deltas + 1] = { t, dm } end
				if claimed[i] then
					-- paid a buy invoice, already counted
				elseif dm > 0 then
					if a == "vendor" then
						Earn(t, who, "vendor", dm)
						for _, p in ipairs(Split(c, -1, dm, VendorPrice)) do
							local it = Item(NameOf(p.id), p.id)
							Touch(it, t)
							it.vendored, it.vendorEarned = it.vendored + p.n, it.vendorEarned + p.share
							it.last = math.max(it.last or 0, t)
							S.vendored = S.vendored + p.n
						end
					elseif a == "loot" or a == "quest" then
						Earn(t, who, a, dm)
					elseif a ~= "mail" and a ~= "ah" then
						-- mail: auction money (counted from the invoices) or gold from another character
						Earn(t, who, "other", dm)
					end
				elseif dm < 0 then
					local cost = -dm
					if a == "vendor" then
						if (c or "") == "" then
							Spend(t, who, "repair", cost)
						else
							Spend(t, who, "vendor", cost)
							for _, p in ipairs(Split(c, 1, cost, BuyPrice)) do
								local it = Item(NameOf(p.id), p.id)
								Touch(it, t)
								it.spent, it.bought = it.spent + p.share, it.bought + p.n
							end
						end
					elseif a == "training" or a == "travel" then
						Spend(t, who, a, cost)
					elseif a == "ah" or isPost[i] then
						-- posting while the mailbox counted as open was logged as mail
						Spend(t, who, "ahfee", cost)
					elseif a == "mail" then
						S.mailedOut = S.mailedOut + cost
					else
						Spend(t, who, "other", cost)
					end
				end
			elseif kind == "repair" then
				local cost = tonumber(a) or 0
				Spend(t, who, "repair", cost)
				deltas[#deltas + 1] = { t, -cost }
			end
		end
	end

	-- Gold on all characters over time: today's gold, walked back through every recorded change
	local total = 0
	S.nChars = 0
	for _, c in pairs(GoldScoutDB and GoldScoutDB.chars or {}) do
		total = total + (c.money or 0)
		S.nChars = S.nChars + 1
	end
	S.gold = total
	table.sort(deltas, function(x, y) return x[1] < y[1] end)
	local sum = 0
	for _, d in ipairs(deltas) do sum = sum + d[2] end
	local span = math.max(now - S.first, 3600)
	local step
	for _, s in ipairs({ 3600, 2 * 3600, 3 * 3600, 6 * 3600, 12 * 3600, 86400, 2 * 86400, 7 * 86400 }) do
		step = s
		if span / s <= 96 then break end
	end
	local gold, j = total - sum, 1
	for b = 1, math.ceil(span / step) do
		local stop = S.first + b * step
		while deltas[j] and deltas[j][1] <= stop do
			gold = gold + deltas[j][2]
			j = j + 1
		end
		S.wealth[#S.wealth + 1] = { t = math.min(stop, now), gold = gold }
	end
	S.step = step
	S.daysTracked = math.max(1, (now - S.first) / 86400)

	-- Items over time: what is held now, walked back through every change to the bags (used, deleted,
	-- looted, bought, sold, posted...), all valued at today's prices
	local worth = {}
	local function Worth(id)
		local p = worth[id]
		if p == nil then
			p = Price(id) or VendorPrice(id) or 0
			worth[id] = p
		end
		return p
	end
	local count, value = {}, 0
	for id, h in pairs(Holdings(false)) do
		count[id] = h.n
		value = value + Worth(id) * h.n
	end
	S.itemsNow = value
	local moves = {}
	for _, line in ipairs(journal) do
		local t, _, kind, a, b, c = strsplit("|", line)
		t = tonumber(t)
		if not t then
			-- unreadable line
		elseif kind == "inv" then
			for part in (c or ""):gmatch("[^,]+") do
				local id, d = part:match("^(%d+):([%+%-]?%d+)$")
				if id then moves[#moves + 1] = { t, tonumber(id), tonumber(d) } end
			end
		elseif kind == "used" then
			for id, n in (a or ""):gmatch("(%d+):(%d+)") do moves[#moves + 1] = { t, tonumber(id), -tonumber(n) } end
		elseif kind == "delete" and tonumber(a) then
			moves[#moves + 1] = { t, tonumber(a), -(tonumber(b) or 1) }
		end
	end
	table.sort(moves, function(x, y) return x[1] > y[1] end)
	local k = 1
	for b = #S.wealth, 1, -1 do
		local p = S.wealth[b]
		while moves[k] and moves[k][1] > p.t do
			local id, d = moves[k][2], moves[k][3]
			local before = count[id] or 0
			-- gear worn now is not in the bags: counts can dip below zero, which is worth nothing
			value = value + Worth(id) * (math.max(before - d, 0) - math.max(before, 0))
			count[id] = before - d
			k = k + 1
		end
		p.items = value
	end
	return S
end

-- Per item: your average sale price against the cheapest listing when it sold (+0.12 = 12% above)
local function VsMarket(it)
	if it.mktQty == 0 or it.mktLow == 0 then return nil end
	return it.mktYours / it.mktLow - 1
end

local function VsText(v)
	if not v then return "" end
	local pct = math.floor(math.abs(v) * 100 + 0.5)
	if pct == 0 then return "|cff9a9a9amarket|r" end
	return (v < 0 and "|cffff8040-" or "|cff40ff40+") .. pct .. "%|r"
end

-- Per item: average time from posting to selling, per item sold
local function Wait(it)
	local tm = it.timing
	if not tm or tm.sold == 0 then return nil end
	return tm.wait / tm.sold
end

-- Per item: what one unit cost you, to tell profit from revenue
local function UnitCost(it, crafts)
	if it.bought > 0 then return it.spent / it.bought, "bought" end
	if it.id and crafts[it.id] then return crafts[it.id], "crafted" end
	return 0, "farmed"
end

------------------------------------------------------------------------------------------------
-- Drawing: textures, texts and hover areas from pools, laid out from the top left of the page

-- Each page (frame) has its own pools; Begin(frame) picks them
local content, used, pools
local canvases = {}

local function Begin(frame)
	content = frame
	pools = canvases[frame]
	if not pools then
		pools = { tex = {}, text = {}, hit = {} }
		canvases[frame] = pools
	end
	used = { tex = 0, text = 0, hit = 0 }
end

local function Finish()
	for k, list in pairs(pools) do
		for i = used[k] + 1, #list do list[i]:Hide() end
	end
end

local function Tex(x, y, w, h, color, alpha, layer)
	if w <= 0 or h <= 0 then return end
	used.tex = used.tex + 1
	local t = pools.tex[used.tex]
	if not t then
		t = content:CreateTexture()
		pools.tex[used.tex] = t
	end
	t:SetDrawLayer(layer or "ARTWORK")
	t:ClearAllPoints()
	t:SetPoint("TOPLEFT", content, "TOPLEFT", x, -y)
	t:SetSize(w, h)
	t:SetColorTexture(color[1], color[2], color[3], alpha or 1)
	t:Show()
	return t
end

local function Text(x, y, s, font, w, justify)
	used.text = used.text + 1
	local fs = pools.text[used.text]
	if not fs then
		fs = content:CreateFontString(nil, "OVERLAY")
		pools.text[used.text] = fs
	end
	fs:SetFontObject(font or "GameFontHighlightSmall")
	fs:SetWordWrap(false)
	fs:ClearAllPoints()
	fs:SetPoint("TOPLEFT", content, "TOPLEFT", x, -y)
	fs:SetWidth(w or 0)
	fs:SetJustifyH(justify or "LEFT")
	fs:SetText(s)
	fs:Show()
	return fs
end

-- An invisible area with a tooltip: tip(GameTooltip) adds lines; item shows that item first
local function Hit(x, y, w, h, tip, item, click)
	used.hit = used.hit + 1
	local b = pools.hit[used.hit]
	if not b then
		b = CreateFrame("Button", nil, content)
		local hl = b:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 0.82, 0, 0.08)
		b:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			if self.item then GameTooltip:SetItemByID(self.item) end
			if self.tip then
				if self.item then GameTooltip:AddLine(" ") end
				self.tip(GameTooltip)
			end
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", GameTooltip_Hide)
		b:SetScript("OnClick", function(self) if self.click then self.click() end end)
		pools.hit[used.hit] = b
	end
	b:ClearAllPoints()
	b:SetPoint("TOPLEFT", content, "TOPLEFT", x, -y)
	b:SetSize(math.max(w, 1), math.max(h, 1))
	b.tip, b.item, b.click = tip, item, click
	b:Show()
	return b
end

local W = 1060 -- width of a page

local function Title(x, y, s, w)
	Text(x, y, s, "GameFontNormal", w)
	Tex(x, y + 16, w, 1, GOLD, 0.25)
end

local function Empty(x, y, w, h, s)
	Text(x, y + h / 2 - 6, "|cff808080" .. (s or "Nothing recorded yet") .. "|r", "GameFontDisableSmall", w, "CENTER")
end

-- Horizontal gridlines with value labels; returns the plot area
local AXIS = 46
local function Grid(x, y, w, h, max, fmt)
	for _, f in ipairs({ 0, 0.5, 1 }) do
		local gy = y + h - f * h
		Tex(x + AXIS, gy, w - AXIS, 1, { 1, 1, 1 }, f == 0 and 0.25 or 0.07, "BORDER")
		Text(x, gy - 5, "|cff9a9a9a" .. (fmt or Short)(max * f) .. "|r", "GameFontDisableSmall", AXIS - 6, "RIGHT")
	end
	return x + AXIS, w - AXIS
end

local function Breakdown(tt, parts, values, total)
	for _, p in ipairs(parts) do
		local v = values[p[1]]
		if v and v > 0 then
			tt:AddDoubleLine(p[2], Money(v) .. (total and total > 0 and string.format(" |cff9a9a9a%d%%|r", math.floor(v / total * 100 + 0.5)) or ""), 1, 1, 1)
		end
	end
end

------------------------------------------------------------------------------------------------
-- Widgets

local function Tile(x, y, w, label, value, sub, tip)
	Tex(x, y, w, 52, { 1, 1, 1 }, 0.05, "BACKGROUND")
	Tex(x, y, 2, 52, GOLD, 0.6, "BORDER")
	Text(x + 10, y + 6, "|cff9a9a9a" .. label .. "|r", "GameFontDisableSmall", w - 14)
	Text(x + 10, y + 19, value, "GameFontHighlightLarge", w - 14)
	if sub then Text(x + 10, y + 38, "|cff9a9a9a" .. sub .. "|r", "GameFontDisableSmall", w - 14) end
	if tip then Hit(x, y, w, 52, tip) end
end

-- Two bars per day: earned (green) and spent (red)
local function DailyChart(x, y, w, h, days)
	local max = 0
	for _, d in ipairs(days) do max = math.max(max, d.earned, d.spent) end
	if max == 0 then return Empty(x, y, w, h) end
	local gx, gw = Grid(x, y, w, h, max)
	local slot = gw / #days
	local bw = math.max(2, math.min(14, (slot - 6) / 2))
	for i, d in ipairs(days) do
		local cx = gx + (i - 1) * slot + slot / 2
		local eh, sh = d.earned / max * h, d.spent / max * h
		Tex(cx - bw - 1, y + h - eh, bw, eh, GREEN, 0.9)
		Tex(cx + 1, y + h - sh, bw, sh, RED, 0.9)
		Text(cx - slot / 2, y + h + 4, date("%a\n%d", d.t), "GameFontDisableSmall", slot, "CENTER"):SetWordWrap(true)
		Hit(cx - slot / 2, y, slot, h, function(tt)
			tt:AddLine(date("%A %d %B", d.t))
			tt:AddDoubleLine("Earned", Money(d.earned), 0.25, 0.8, 0.35, 1, 1, 1)
			Breakdown(tt, EARN, d.earn, d.earned)
			tt:AddDoubleLine("Spent", Money(d.spent), 0.9, 0.3, 0.25, 1, 1, 1)
			Breakdown(tt, SPEND, d.spend, d.spent)
			tt:AddDoubleLine("Net", Signed(d.earned - d.spent), 1, 0.82, 0, 1, 1, 1)
			if d.sold > 0 then tt:AddDoubleLine("Sold at the auction house", d.sold .. " items in " .. d.sales .. " auctions", 1, 0.82, 0, 1, 1, 1) end
		end)
	end
end

-- Columns, one per time step: gold on all characters, with the items they hold stacked on top
local function WealthChart(x, y, w, h, S)
	local series = S.wealth
	local max = 0
	for _, p in ipairs(series) do max = math.max(max, math.max(0, p.gold) + (p.items or 0)) end
	if max <= 0 or #series < 2 then return Empty(x, y, w, h, "Play a little longer: needs more than an hour of records") end
	local gx, gw = Grid(x, y, w, h, max)
	local cw = gw / #series
	for i, p in ipairs(series) do
		local gh = math.max(0, p.gold) / max * h
		local ih = (p.items or 0) / max * h
		local px = gx + (i - 1) * cw
		Tex(px, y + h - gh, math.max(1, cw - 1), gh, GOLD, 0.55)
		Tex(px, y + h - gh - ih, math.max(1, cw - 1), ih, PURPLE, 0.55)
		Tex(px, y + h - gh - ih, math.max(1, cw - 1), 2, ih > 0 and PURPLE or GOLD, 1)
		local prev = series[i - 1]
		Hit(px, y, cw, h, function(tt)
			local total = p.gold + (p.items or 0)
			tt:AddLine(date("%a %d %b %H:%M", p.t))
			tt:AddDoubleLine("Net worth", Money(total), 1, 0.82, 0, 1, 1, 1)
			tt:AddDoubleLine("  Gold", Money(p.gold), 1, 1, 1)
			tt:AddDoubleLine("  Items (today's prices)", Money(p.items or 0), 1, 1, 1)
			if prev then tt:AddDoubleLine("Change", Signed(total - prev.gold - (prev.items or 0)), 1, 1, 1) end
		end)
	end
	for _, i in ipairs({ 1, math.ceil(#series / 2), #series }) do
		local fmt = S.step >= 86400 and "%a %d %b" or "%a %H:%M"
		local lx = gx + (i - 0.5) * cw - 50
		Text(lx, y + h + 4, "|cff9a9a9a" .. date(fmt, series[i].t) .. "|r", "GameFontDisableSmall", 100, "CENTER")
	end
end

-- One labelled bar per category; fmt formats the values (money unless given)
local function Bars(x, y, w, parts, values, total, base, fmt)
	fmt = fmt or Money
	local max = 0
	for _, p in ipairs(parts) do max = math.max(max, values[p[1]] or 0) end
	if max == 0 then return Empty(x, y, w, 100) end
	local row, labelW, valueW = 0, 110, 90
	for _, p in ipairs(parts) do
		local v = values[p[1]] or 0
		if v > 0 then
			local ry = y + row * 22
			Text(x, ry + 4, p[2], "GameFontHighlightSmall", labelW)
			Tex(x + labelW, ry + 2, w - labelW - valueW, 14, { 1, 1, 1 }, 0.04, "BACKGROUND")
			Tex(x + labelW, ry + 2, (w - labelW - valueW) * v / max, 14, p[3] or base, 0.85)
			Text(x + w - valueW, ry + 4, fmt(v), "GameFontHighlightSmall", valueW, "RIGHT")
			Hit(x, ry, w, 20, function(tt)
				tt:AddLine(p[2])
				tt:AddDoubleLine("Total", fmt(v), 1, 1, 1)
				if total > 0 then tt:AddDoubleLine("Share", string.format("%.1f%%", v / total * 100), 1, 1, 1) end
				if p.note then tt:AddLine(p.note, 0.6, 0.6, 0.6, true) end
			end)
			row = row + 1
		end
	end
end

-- Sales by hour of day
local function HourChart(x, y, w, h, hours)
	local max = 0
	for hr = 0, 23 do max = math.max(max, hours[hr].sales) end
	if max == 0 then return Empty(x, y, w, h) end
	local gx, gw = Grid(x, y, w, h, max, function(v) return math.floor(v + 0.5) end)
	local slot = gw / 24
	for hr = 0, 23 do
		local v = hours[hr]
		local bh = v.sales / max * h
		local px = gx + hr * slot
		Tex(px + 1, y + h - bh, slot - 2, bh, BLUE, 0.85)
		if hr % 3 == 0 then Text(px - 4, y + h + 4, "|cff9a9a9a" .. hr .. "|r", "GameFontDisableSmall", slot + 8, "CENTER") end
		Hit(px, y, slot, h, function(tt)
			tt:AddLine(string.format("%02d:00 - %02d:59", hr, hr))
			tt:AddDoubleLine("Auctions sold", v.sales, 1, 1, 1)
			tt:AddDoubleLine("Items sold", v.qty, 1, 1, 1)
		end)
	end
end

-- Items sold per day
local function SoldChart(x, y, w, h, days)
	local max = 0
	for _, d in ipairs(days) do max = math.max(max, d.sold) end
	if max == 0 then return Empty(x, y, w, h) end
	local gx, gw = Grid(x, y, w, h, max, function(v) return math.floor(v + 0.5) end)
	local slot = gw / #days
	local bw = math.max(3, math.min(26, slot - 8))
	for i, d in ipairs(days) do
		local cx = gx + (i - 1) * slot + slot / 2
		local bh = d.sold / max * h
		Tex(cx - bw / 2, y + h - bh, bw, bh, BLUE, 0.85)
		if d.sold > 0 then Text(cx - slot / 2, y + h - bh - 12, d.sold, "GameFontHighlightSmall", slot, "CENTER") end
		Text(cx - slot / 2, y + h + 4, date("%a\n%d", d.t), "GameFontDisableSmall", slot, "CENTER"):SetWordWrap(true)
		Hit(cx - slot / 2, y, slot, h, function(tt)
			tt:AddLine(date("%A %d %B", d.t))
			tt:AddDoubleLine("Items sold", d.sold .. " in " .. d.sales .. " auctions", 1, 1, 1)
			tt:AddDoubleLine("Auction income", Money(d.earn.ah or 0), 1, 1, 1)
			local list = {}
			for name, n in pairs(d.items) do list[#list + 1] = { name, n } end
			table.sort(list, function(a, b) return a[2] > b[2] end)
			for k = 1, math.min(#list, 12) do tt:AddDoubleLine("  " .. list[k][1], list[k][2], 0.8, 0.8, 0.8, 1, 1, 1) end
		end)
	end
end

-- Top items: name, a bar for the value, the value
local function TopList(x, y, w, entries, color, n)
	if #entries == 0 then return Empty(x, y, w, 100) end
	local max = 0
	for i = 1, math.min(n, #entries) do max = math.max(max, entries[i].value) end
	for i = 1, math.min(n, #entries) do
		local e = entries[i]
		local ry = y + (i - 1) * 19
		if max > 0 then Tex(x, ry + 1, (w - 2) * math.max(0, e.value) / max, 17, color, 0.22, "BORDER") end
		Text(x + 4, ry + 4, (e.id and (ItemName(e.id)) or e.name), "GameFontHighlightSmall", w - 92)
		Text(x + w - 88, ry + 4, e.text, "GameFontHighlightSmall", 84, "RIGHT")
		Hit(x, ry, w, 18, e.tip, e.id)
	end
end

-- The cheapest listing of one item in each full scan, as columns
local function PriceHistory(x, y, w, h, id)
	local realm = GetRealmName()
	local points = {}
	for _, s in ipairs(GoldScoutDB and GoldScoutDB.scans or {}) do
		if not s.realm or s.realm == realm then
			local v = ns.Parse(s)[id]
			if v then points[#points + 1] = { t = s.t, v = v } end
		end
	end
	if #points < 2 then return Empty(x, y, w, h, "Needs two full scans") end
	local max = 0
	for _, p in ipairs(points) do max = math.max(max, p.v[1]) end
	local gx, gw = Grid(x, y, w, h, max)
	local cw = gw / #points
	for i, p in ipairs(points) do
		local bh = p.v[1] / max * h
		local px = gx + (i - 1) * cw
		Tex(px, y + h - bh, math.max(1, cw - 1), bh, BLUE, 0.7)
		Hit(px, y, cw, h, function(tt)
			tt:AddLine(date("%a %d %b %H:%M", p.t))
			tt:AddDoubleLine("Cheapest", Money(p.v[1]), 1, 1, 1)
			tt:AddDoubleLine("Median", Money(p.v[4]), 1, 1, 1)
			tt:AddDoubleLine("Listed", p.v[2] .. " in " .. p.v[3] .. " auctions", 1, 1, 1)
		end)
	end
end

-- The Progress tab (Progress.lua) draws with the same tools
ns.Canvas = { Begin = Begin, Finish = Finish, Tex = Tex, Text = Text, Hit = Hit, Title = Title, Empty = Empty, Grid = Grid,
	Tile = Tile, Bars = Bars, TopList = TopList, Breakdown = Breakdown, Short = Short, Span = Span, Signed = Signed, W = W, AXIS = AXIS }

------------------------------------------------------------------------------------------------
-- Tooltip for one item, shared by the lists and the item table

local function ItemTip(it, crafts)
	return function(tt)
		local unit, how = UnitCost(it, crafts)
		local auctions = it.sales + it.expired + it.cancelled
		tt:AddLine("Gold Scout", 1, 0.82, 0)
		tt:AddDoubleLine("Sold at the auction house", it.sold .. " in " .. it.sales .. " auctions", 1, 1, 1)
		if auctions > 0 then
			tt:AddDoubleLine("Sell-through", string.format("%d%%  (%d expired, %d cancelled)", math.floor(it.sales / auctions * 100 + 0.5), it.expired, it.cancelled), 1, 1, 1)
		end
		if it.sold > 0 then tt:AddDoubleLine("Average price each", Money(it.gross / it.sold), 1, 1, 1) end
		local vs = VsMarket(it)
		if vs then
			tt:AddDoubleLine("Cheapest listing when it sold", Money(it.mktLow / it.mktQty) .. "  " .. VsText(vs), 1, 1, 1)
			tt:AddDoubleLine("Median listing when it sold", Money(it.mktMedian / it.mktQty), 1, 1, 1)
		end
		local wait = Wait(it)
		if wait then tt:AddDoubleLine("Takes to sell", Span(wait) .. " on average", 1, 1, 1) end
		if it.timing and it.timing.lostDeposit > 0 then tt:AddDoubleLine("Deposits lost (expired, cancelled)", Money(it.timing.lostDeposit), 1, 1, 1) end
		if it.vendored > 0 then tt:AddDoubleLine("Sold to vendors", it.vendored .. " for " .. Money(it.vendorEarned), 1, 1, 1) end
		tt:AddDoubleLine("Earned (after the cut)", Money(it.ahEarned + it.vendorEarned), 1, 1, 1)
		if it.bought > 0 then tt:AddDoubleLine("Bought", it.bought .. " for " .. Money(it.spent) .. " (" .. Money(it.spent / it.bought) .. " each)", 1, 1, 1) end
		if it.sales >= 2 then tt:AddDoubleLine("Sells every", Span((it.last - it.first) / (it.sales - 1)), 1, 1, 1) end
		if it.last then tt:AddDoubleLine("Last sold", Ago(it.last), 1, 1, 1) end
		local units = it.sold + it.vendored
		if units > 0 then
			tt:AddDoubleLine("Profit", Signed(it.ahEarned + it.vendorEarned - unit * units) .. " |cff9a9a9a(cost: " .. how .. ")|r", 1, 1, 1)
		end
	end
end

------------------------------------------------------------------------------------------------
-- The stats page

local function LastDays(S, n)
	local today = date("*t")
	today.hour, today.min, today.sec = 12, 0, 0
	local noon = time(today)
	local firstDay = date("%Y-%m-%d", S.first)
	local list = {}
	for i = n - 1, 0, -1 do
		local t = noon - i * 86400
		local k = date("%Y-%m-%d", t)
		if k >= firstDay then
			list[#list + 1] = S.days[k] or { key = k, t = t, earn = {}, spend = {}, earned = 0, spent = 0, sold = 0, sales = 0, items = {} }
		end
	end
	return list
end

local statsPage

local function Draw()
	local S = Collect()
	local crafts = ns.CraftCosts(ns.PaidPrices(nameToID))
	Begin(statsPage)
	local y = 4

	-- Headline numbers
	local net = S.earned - S.spent
	local today = S.days[date("%Y-%m-%d")] or { earned = 0, spent = 0, sold = 0, sales = 0 }
	local auctions = S.sales + S.ended
	local tw = (W - 7 * 8) / 8
	local tiles = {
		{ "Gold now", Money(S.gold), "worth " .. Short(S.gold + S.itemsNow) .. " with items", function(tt)
			tt:AddLine("Net worth")
			tt:AddDoubleLine("Gold on " .. S.nChars .. " characters", Money(S.gold), 1, 1, 1)
			tt:AddDoubleLine("Items held (bags, bank, mail)", Money(S.itemsNow), 1, 1, 1)
		end },
		{ "Earned", Money(S.earned), "since " .. date("%a %d %b", S.first), function(tt)
			tt:AddLine("Earned")
			Breakdown(tt, EARN, S.earn, S.earned)
		end },
		{ "Spent", Money(S.spent), S.mailedOut > 0 and ("mailed away " .. Short(S.mailedOut)) or "", function(tt)
			tt:AddLine("Spent")
			Breakdown(tt, SPEND, S.spend, S.spent)
			if S.mailedOut > 0 then tt:AddLine("Gold mailed (" .. Money(S.mailedOut) .. ") is not counted: most of it goes to your own characters.", 0.6, 0.6, 0.6, true) end
		end },
		{ "Profit", Signed(net), string.format("over %.1f days", S.daysTracked) },
		{ "Profit per day", Signed(net / S.daysTracked), "earned " .. Short(S.earned / S.daysTracked) .. " a day" },
		{ "Today", Signed(today.earned - today.spent), "in " .. Short(today.earned) .. ", out " .. Short(today.spent) },
		{ "Items sold", S.sold + S.vendored, S.sold .. " on the AH, " .. S.vendored .. " to vendors" },
		{ "Sell-through", auctions > 0 and string.format("%d%%", math.floor(S.sales / auctions * 100 + 0.5)) or "-", S.sales .. " of " .. auctions .. " auctions sold", function(tt)
			tt:AddLine("Sell-through")
			tt:AddLine("Share of your auctions that sold, of all that sold, expired or were cancelled.", 1, 1, 1, true)
		end },
	}
	for i, t in ipairs(tiles) do
		Tile((i - 1) * (tw + 8), y, tw, t[1], tostring(t[2]), t[3], t[4])
	end
	y = y + 70

	-- Money per day, and gold over time
	local days = LastDays(S, 14)
	local half = (W - 30) / 2
	Title(0, y, "Earned |cff40cc59|||r and spent |cffe64d40|||r per day", half)
	Title(half + 30, y, "Net worth: gold |cffffd100|||r and items |cffa673f2|||r", half)
	DailyChart(0, y + 28, half, 140, days)
	WealthChart(half + 30, y + 28, half, 140, S)
	y = y + 28 + 140 + 40

	-- Where it comes from, where it goes, when it sells
	local third = (W - 2 * 30) / 3
	Title(0, y, "Where the money comes from", third)
	Title(third + 30, y, "Where the money goes", third)
	Title(2 * (third + 30), y, "When things sell (hour of day)", third)
	Bars(0, y + 26, third, EARN, S.earn, S.earned, GREEN)
	local spendParts = {}
	for i, p in ipairs(SPEND) do spendParts[i] = { p[1], p[2], p[3] } end
	spendParts[1].note = S.estimated > 0 and (S.estimated .. " buys had no readable price and are valued at today's market price.") or nil
	spendParts[2].note = "Deposits and other money paid at the auction house."
	Bars(third + 30, y + 26, third, spendParts, S.spend, S.spent, RED)
	HourChart(2 * (third + 30), y + 26, third, 110, S.hours)
	y = y + 26 + 7 * 22 + 14

	-- Top items
	local quarter = (W - 3 * 24) / 4
	local earners, spenders, sellers, frequent = {}, {}, {}, {}
	for _, it in pairs(S.items) do
		local earned = it.ahEarned + it.vendorEarned
		local tip = ItemTip(it, crafts)
		if earned > 0 then earners[#earners + 1] = { name = it.name, id = it.id, value = earned, text = Money(earned), tip = tip } end
		if it.spent > 0 then spenders[#spenders + 1] = { name = it.name, id = it.id, value = it.spent, text = Money(it.spent), tip = tip } end
		if it.sold > 0 then sellers[#sellers + 1] = { name = it.name, id = it.id, value = it.sold, text = it.sold .. " sold", tip = tip } end
		if it.sales > 0 then
			local perDay = it.sales / math.max(1, (time() - it.first) / 86400)
			frequent[#frequent + 1] = { name = it.name, id = it.id, value = perDay, text = string.format("%.1f / day", perDay), tip = tip }
		end
	end
	for _, list in ipairs({ earners, spenders, sellers, frequent }) do
		table.sort(list, function(a, b) return a.value > b.value end)
	end
	Title(0, y, "Makes the most money", quarter)
	Title(quarter + 24, y, "Costs the most", quarter)
	Title(2 * (quarter + 24), y, "Sells the most", quarter)
	Title(3 * (quarter + 24), y, "Sells most often", quarter)
	TopList(0, y + 24, quarter, earners, GREEN, 10)
	TopList(quarter + 24, y + 24, quarter, spenders, RED, 10)
	TopList(2 * (quarter + 24), y + 24, quarter, sellers, BLUE, 10)
	TopList(3 * (quarter + 24), y + 24, quarter, frequent, GOLD, 10)
	y = y + 24 + 10 * 19 + 10
	-- Pricing and speed
	local priced, slow = {}, {}
	for _, it in pairs(S.items) do
		local tip = ItemTip(it, crafts)
		local vs = VsMarket(it)
		if vs then priced[#priced + 1] = { name = it.name, id = it.id, value = math.abs(vs), sort = it.sold, text = VsText(vs) .. " |cff9a9a9a" .. it.mktQty .. "|r", tip = tip } end
		local wait = Wait(it)
		if wait then slow[#slow + 1] = { name = it.name, id = it.id, value = wait, sort = it.sold, text = Span(wait), tip = tip } end
	end
	for _, list in ipairs({ priced, slow }) do
		table.sort(list, function(a, b) return a.sort > b.sort end)
	end
	Title(0, y, "Your price vs the cheapest listing when it sold", half)
	Title(half + 30, y, "How long it takes to sell (from posting)", half)
	if #priced == 0 then Empty(0, y + 24, half, 100, "Needs full scans from before the sales") end
	TopList(0, y + 24, half, priced, GOLD, 8)
	TopList(half + 30, y + 24, half, slow, BLUE, 8)
	y = y + 24 + 8 * 19 + 14

	local x = 0
	for _, link in ipairs({
		{ "Every item, sortable", "Open the item table", "statitems" },
		{ "Restock plan", "What to craft and buy to keep selling until the sell-by date", "restock" },
		{ "Market and competition", "Sellers, prices and your share of the market, per item", "market" },
		{ "Sell before the wipe", "What you still hold, and whether it sells in time", "liquidate" },
		{ "Mail", "Gold and items sent between your characters", "mail" },
	}) do
		local fs = Text(x, y, "|cffffd200" .. link[1] .. " >|r", "GameFontNormal", 300)
		local w = fs:GetStringWidth() + 6
		Hit(x - 3, y - 3, w, 20, function(tt) tt:AddLine(link[2]) end, nil, function() ns.Toggle(link[3]) end)
		x = x + w + 30
	end
	y = y + 34

	-- The market for your best sellers
	local rows = ns.MarketRows(S)
	table.sort(rows, function(a, b) return (a.it and a.it.ahEarned or 0) > (b.it and b.it.ahEarned or 0) end)
	Title(0, y, "The market for what you sell most: cheapest listing per full scan", W)
	local mw = (W - 3 * 24) / 4
	for i = 1, math.min(4, #rows) do
		local r = rows[i]
		local mx = (i - 1) * (mw + 24)
		Text(mx, y + 24, (ItemName(r.id)), "GameFontHighlightSmall", mw)
		local others = r.nSellers or 0
		for _, sl in ipairs(r.sellers or {}) do
			if ns.Mine(sl.name) then others = others - 1 end
		end
		local line = (r.sellers and (others .. " other sellers") or "no seller scan")
			.. (r.market and string.format(", market %.0f/day", r.market) or "")
			.. (r.share and string.format(", yours %d%%", math.floor(r.share * 100 + 0.5)) or "")
		Text(mx, y + 38, "|cff9a9a9a" .. line .. "|r", "GameFontDisableSmall", mw)
		Hit(mx, y + 22, mw, 30, function(tt)
			tt:AddLine("Sellers in the newest seller scan")
			for k, sl in ipairs(r.sellers or {}) do
				if k > 12 then break end
				local name = ns.Mine(sl.name) and ("|cff40ff40" .. sl.name .. " (you)|r") or sl.name
				tt:AddDoubleLine(name, string.format("%d at %s", math.floor(sl.qty + 0.5), Money(sl.unit)), 1, 1, 1, 1, 1, 1)
			end
			if not r.sellers then tt:AddLine("Not in the seller scan yet", 0.6, 0.6, 0.6) end
		end, r.id)
		PriceHistory(mx, y + 56, mw, 90, r.id)
	end
	if #rows == 0 then Empty(0, y + 24, W, 120, "Sell something first") end
	y = y + 56 + 90 + 20

	-- Mail between your characters
	local pairsOf, others = {}, 0
	for _, t in ipairs(S.transfers or {}) do
		local value = t.money
		for id, n in pairs(t.items) do value = value + (Price(id) or VendorPrice(id) or 0) * n end
		if t.to then
			local k = t.from .. ">" .. t.to
			local e = pairsOf[k] or { from = t.from, to = t.to, value = 0, money = 0, n = 0 }
			pairsOf[k] = e
			e.value, e.money, e.n = e.value + value, e.money + t.money, e.n + 1
		else
			others = others + value
		end
	end
	local mailList = {}
	for _, e in pairs(pairsOf) do
		local function N(key) return (key:match("^[^-]+")) end
		mailList[#mailList + 1] = { name = N(e.from) .. "  >  " .. N(e.to), value = e.value, text = Money(e.value), tip = function(tt)
			tt:AddLine(N(e.from) .. " to " .. N(e.to))
			tt:AddDoubleLine("Mails", e.n, 1, 1, 1)
			tt:AddDoubleLine("Gold", Money(e.money), 1, 1, 1)
			tt:AddDoubleLine("Items (today's prices)", Money(e.value - e.money), 1, 1, 1)
		end }
	end
	table.sort(mailList, function(a, b) return a.value > b.value end)
	Title(0, y, "Mail between your characters (gold + items)" .. (others > 0 and ("  |cff9a9a9ato others or not collected: " .. Short(others) .. "|r") or ""), W)
	if #mailList == 0 then Empty(0, y + 24, half, 60, "No mail between your characters yet") end
	TopList(0, y + 24, half, mailList, PURPLE, 6)
	y = y + 24 + math.max(3, math.min(6, #mailList)) * 19 + 16

	-- Sales per day, and per character
	Title(0, y, "Items sold at the auction house per day", half)
	Title(half + 30, y, "Per character", half)
	SoldChart(0, y + 28, half, 120, days)
	local chars = {}
	for _, c in pairs(S.chars) do chars[#chars + 1] = c end
	table.sort(chars, function(a, b) return a.earned - a.spent > b.earned - b.spent end)
	local cx, cy = half + 30, y + 28
	local max = 0
	for _, c in ipairs(chars) do max = math.max(max, c.earned, c.spent) end
	if #chars == 0 then Empty(cx, cy, half, 120) end
	for i, c in ipairs(chars) do
		local data = GoldScoutDB.chars[c.key] or { name = c.key:match("^[^-]+") }
		local ry = cy + (i - 1) * 24
		local barW = half - 110 - 100
		Text(cx, ry + 6, ns.ClassName(data), "GameFontHighlightSmall", 106)
		if max > 0 then
			Tex(cx + 110, ry + 2, barW * c.earned / max, 9, GREEN, 0.85)
			Tex(cx + 110, ry + 12, barW * c.spent / max, 9, RED, 0.85)
		end
		Text(cx + half - 100, ry + 6, Signed(c.earned - c.spent), "GameFontHighlightSmall", 100, "RIGHT")
		Hit(cx, ry, half, 22, function(tt)
			tt:AddLine(data.name or c.key)
			tt:AddDoubleLine("Earned", Money(c.earned), 1, 1, 1)
			tt:AddDoubleLine("Spent", Money(c.spent), 1, 1, 1)
			tt:AddDoubleLine("Items sold at the auction house", c.sold, 1, 1, 1)
			tt:AddDoubleLine("Gold now", Money(data.money), 1, 1, 1)
		end)
	end
	y = y + 28 + math.max(140, #chars * 24) + 10

	Finish()
	statsPage:SetHeight(y)
	return "Earned = auction sales after the cut, vendor sales, looted coin and quest gold. Gold mailed between characters is not counted. Hover anything for details."
end

ns.TABS.stats = {
	title = "Stats",
	panel = function(parent)
		local scroll = CreateFrame("ScrollFrame", "GoldScoutStatsScroll", parent, "UIPanelScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", 18, -62)
		scroll:SetPoint("BOTTOMRIGHT", -40, 34)
		statsPage = CreateFrame("Frame", nil, scroll)
		statsPage:SetSize(W, 800)
		scroll:SetScrollChild(statsPage)
		return scroll
	end,
	refresh = Draw,
}

------------------------------------------------------------------------------------------------
-- Every item, as a table

ns.TABS.statitems = {
	title = "Stats",
	parent = "stats",
	sortable = true, sortCol = 7, sortDesc = true,
	cols = { { "Item", 200 }, { "Sold", 50 }, { "Vendored", 65 }, { "Sell-through", 90 }, { "How often", 165 }, { "Avg each / vs cheapest", 145 }, { "Earned", 95 }, { "Spent", 95 }, { "Profit", 115 } },
	build = function()
		local S = Collect()
		local crafts = ns.CraftCosts(ns.PaidPrices(nameToID))
		local out = {}
		local now = time()
		for _, it in pairs(S.items) do
			local earned = it.ahEarned + it.vendorEarned
			local auctions = it.sales + it.expired + it.cancelled
			local through = auctions > 0 and it.sales / auctions
			local perDay = it.sales > 0 and it.sales / math.max(1, (now - it.first) / 86400) or 0
			local often
			if it.sales >= 2 then
				often = "every " .. Span((it.last - it.first) / (it.sales - 1)) .. ", last " .. Ago(it.last)
			elseif it.sales == 1 then
				often = "once, " .. Ago(it.last)
			elseif auctions > 0 then
				often = "|cff808080never sold|r"
			else
				often = ""
			end
			local unit, how = UnitCost(it, crafts)
			local units = it.sold + it.vendored
			local profit = units > 0 and (earned - unit * units) or nil
			local label = it.id and (ItemName(it.id)) or it.name
			out[#out + 1] = {
				cols = {
					label,
					it.sold > 0 and it.sold or "",
					it.vendored > 0 and it.vendored or "",
					through and string.format("%d%% |cff808080%d/%d|r", math.floor(through * 100 + 0.5), it.sales, auctions) or "",
					often,
					it.sold > 0 and (Money(it.gross / it.sold) .. " " .. VsText(VsMarket(it))) or "",
					earned > 0 and Money(earned) or "",
					it.spent > 0 and ("|cffff8080" .. Money(it.spent) .. "|r") or "",
					profit and (Signed(profit) .. " |cff808080" .. how .. "|r") or "",
				},
				keys = {
					it.name:lower(), it.sold, it.vendored, through or -1, perDay,
					it.sold > 0 and it.gross / it.sold or 0, earned, it.spent, profit or -1e15,
				},
				item = it.id, search = it.name:lower(),
			}
		end
		return out, "Click a column to sort. How often = average time between sales. Profit = earned - what each unit cost (bought, crafting cost now, or 0 when farmed). Stats tab for graphs."
	end,
}

------------------------------------------------------------------------------------------------
-- Sell before the wipe: everything still held, and whether your sales pace clears it in time

-- The beta wipes on 22 October 2026; aim to be sold out three days before, when buyers thin out
local WIPE = time({ year = 2026, month = 10, day = 22, hour = 12 })
local SELL_BY = time({ year = 2026, month = 10, day = 19, hour = 12 })
local BIND_PICKUP, BIND_QUEST = 1, 4

ns.TABS.liquidate = {
	title = "Stats",
	parent = "stats",
	sortable = true, sortCol = 6, sortDesc = true,
	cols = { { "Item", 200 }, { "Held", 45 }, { "Listed", 45 }, { "Where", 200 }, { "Each", 85 }, { "Value", 90 }, { "Pace", 75 }, { "Clears in", 75 }, { "Advice", 230 } },
	build = function()
		local S = Collect()
		local now = time()
		local held = Holdings(true)
		-- reagents of something you craft and sell at a profit: crafting beats dumping them. Pick the
		-- product with the best margin: your average sale price after the cut - its cost at what you paid
		local crafts = ns.CraftCosts(ns.PaidPrices(nameToID))
		local reagentOf = {}
		for _, c in pairs(GoldScoutDB and GoldScoutDB.chars or {}) do
			for _, list in pairs(c.recipes or {}) do
				for _, r in ipairs(Values(list)) do
					local made, _, _, reagents = strsplit("|", r)
					made = tonumber(made)
					local product = made and S.items[NameOf(made)]
					local margin = product and product.sold > 0 and crafts[made] and (product.gross / product.sold * 0.95 - crafts[made])
					if margin and margin > 0 then
						for rid in (reagents or ""):gmatch("(%d+):%d+") do
							rid = tonumber(rid)
							local best = reagentOf[rid]
							if not best or margin > best.margin then reagentOf[rid] = { name = product.name, margin = margin } end
						end
					end
				end
			end
		end
		local daysLeft = math.max(0, (SELL_BY - now) / 86400)
		local window = math.max(3600, math.min(RECENT, now - S.first))
		local out = {}
		local totals = { pace = 0, slow = 0, stuck = 0, unlisted = 0, vendor = 0, reagent = 0 }
		for id, h in pairs(held) do
			local _, _, _, _, _, _, _, _, _, _, _, classID, _, bindType = C_Item.GetItemInfo(id)
			if bindType ~= BIND_PICKUP and bindType ~= BIND_QUEST and classID ~= 12 then
				local ah, vendor = Price(id), VendorPrice(id)
				local name = NameOf(id)
				local it = S.items[name]
				local perDay = it and it.recent > 0 and it.recent / window * 86400 or 0
				local each, advice, kind, clears
				if not ah or (vendor and vendor >= ah * 0.95) then
					if vendor and vendor > 0 then
						each, kind = vendor, "vendor"
						advice = "|cffc0c0c0Vendor it|r" .. (ah and " (pays as much as the auction house)" or "")
					end
				else
					each = ah
					if reagentOf[id] then
						kind, advice = "reagent", "|cff40c0ffCraft it|r into " .. reagentOf[id].name .. " |cff9a9a9a+" .. Short(reagentOf[id].margin) .. " each|r"
					elseif perDay > 0 then
						clears = h.n / perDay
						if clears <= daysLeft then
							kind, advice = "pace", "|cff40ff40On pace|r"
						else
							kind = "slow"
							advice = "|cffff8040Too slow|r: post more or price lower"
						end
					elseif it and it.sales + it.expired + it.cancelled > 0 then
						kind, advice = "stuck", "|cffff4040Not selling lately|r: price lower"
					else
						kind, advice = "unlisted", "|cffffd200Not listed yet|r"
					end
				end
				if each then
					local value = each * h.n
					totals[kind] = totals[kind] + value
					local label, plain = ItemName(id)
					out[#out + 1] = {
						cols = {
							label, h.n, h.listed > 0 and h.listed or "", table.concat(h.where, ", "),
							Money(each), Money(value),
							perDay > 0 and string.format("%.1f / day", perDay) or "",
							clears and (clears < 1 and "<1 day" or string.format("%.1f days", clears)) or "",
							advice,
						},
						keys = { plain:lower(), h.n, h.listed, "", each, value, perDay, clears or 1e9, kind },
						item = id, search = plain:lower() .. " " .. kind,
					}
				end
			end
		end
		local function G(v) return Money(v) end
		local head
		if now >= WIPE then
			head = "The beta has ended. "
		else
			head = string.format("%.1f days to sell by %s (wipe %s). ", daysLeft, date("%a %d %b", SELL_BY), date("%a %d %b", WIPE))
		end
		return out, head .. "On pace " .. G(totals.pace) .. ", too slow " .. G(totals.slow) .. ", not selling " .. G(totals.stuck)
			.. ", not listed " .. G(totals.unlisted) .. ", reagents to craft " .. G(totals.reagent) .. ", vendor " .. G(totals.vendor)
			.. ". Pace = your auction sales of the last 3 days. Search e.g. slow, stuck, unlisted, reagent."
	end,
}

------------------------------------------------------------------------------------------------
-- Restock: how many of each product to craft to keep selling at your pace until the sell-by date,
-- and the reagents to buy for it (reagents you hold go to the most profitable products first)

-- Products you craft and sell: itemID -> { id, it, reagents = { [id] = n }, per (made per craft), cost, margin }
local function Products(S, crafts)
	local out = {}
	for _, c in pairs(GoldScoutDB and GoldScoutDB.chars or {}) do
		for _, list in pairs(c.recipes or {}) do
			for _, r in ipairs(Values(list)) do
				local made, _, _, reagents, per = strsplit("|", r)
				made = tonumber(made)
				local it = made and S.items[NameOf(made)]
				if it and it.sold > 0 and crafts[made] and not out[made] then
					local need = {}
					for rid, n in (reagents or ""):gmatch("(%d+):(%d+)") do need[tonumber(rid)] = tonumber(n) end
					out[made] = { id = made, it = it, reagents = need, per = tonumber(per) or 1, cost = crafts[made],
						margin = it.gross / it.sold * 0.95 - crafts[made] }
				end
			end
		end
	end
	return out
end

ns.TABS.restock = {
	title = "Stats",
	parent = "stats",
	sortable = true, sortCol = 7, sortDesc = true,
	cols = { { "Product", 190 }, { "Pace", 70 }, { "Sells by then", 85 }, { "Have", 50 }, { "Craft", 50 }, { "Margin each", 85 }, { "Profit", 90 }, { "Reagents to buy", 330 }, { "Buy cost", 85 } },
	build = function()
		local S = Collect()
		local now = time()
		local crafts = ns.CraftCosts(ns.PaidPrices(nameToID))
		local held = Holdings(true)
		local daysLeft = math.max(0, (SELL_BY - now) / 86400)
		local window = math.max(3600, math.min(RECENT, now - S.first))
		-- a reagent costs what a vendor you visited sells it for, else the auction house price
		local vendorBuy = ns.VendorBuyPrices()
		local function ReagentCost(id) return vendorBuy[id] or Price(id) or VendorPrice(id) or 0 end
		local list = {}
		for _, p in pairs(Products(S, crafts)) do
			if p.margin > 0 then list[#list + 1] = p end
		end
		table.sort(list, function(a, b) return a.margin > b.margin end)
		-- reagents you hold (not listed) go to the best margins first
		local pool = {}
		for id, h in pairs(held) do pool[id] = h.n - h.listed end
		local out, shopping, totalProfit, totalCost = {}, {}, 0, 0
		for _, p in ipairs(list) do
			local perDay = p.it.recent / window * 86400
			local sells = perDay * daysLeft
			local have = held[p.id] and held[p.id].n or 0
			local times = math.max(0, math.ceil((sells - have) / p.per))
			local units = times * p.per
			local buy, cost = {}, 0
			for rid, n in pairs(p.reagents) do
				local need = n * times
				local use = math.min(math.max(pool[rid] or 0, 0), need)
				pool[rid] = (pool[rid] or 0) - use
				if need > use then
					local each = ReagentCost(rid)
					buy[#buy + 1] = { id = rid, n = need - use, cost = (need - use) * each }
					cost = cost + (need - use) * each
					local s = shopping[rid] or { n = 0, cost = 0 }
					shopping[rid] = s
					s.n, s.cost = s.n + need - use, s.cost + (need - use) * each
				end
			end
			table.sort(buy, function(a, b) return a.cost > b.cost end)
			local parts = {}
			for _, b in ipairs(buy) do parts[#parts + 1] = b.n .. " " .. (ItemName(b.id)) end
			local profit = units * p.margin
			totalProfit, totalCost = totalProfit + profit, totalCost + cost
			local label, plain = ItemName(p.id)
			out[#out + 1] = {
				cols = {
					label, perDay > 0 and string.format("%.1f / day", perDay) or "|cff808080none lately|r",
					math.floor(sells + 0.5), have, times > 0 and units or "|cff40ff40enough|r",
					Money(p.margin), units > 0 and Money(profit) or "", table.concat(parts, ", "), cost > 0 and Money(cost) or "",
				},
				keys = { plain:lower(), perDay, sells, have, units, p.margin, profit, "", cost },
				item = p.id, search = plain:lower(),
			}
		end
		-- products you sell at a loss: listed last, so you know to stop
		for _, p in pairs(Products(S, crafts)) do
			if p.margin <= 0 then
				local label, plain = ItemName(p.id)
				out[#out + 1] = {
					cols = { label, "", "", held[p.id] and held[p.id].n or 0, "|cffff4040stop|r", Signed(p.margin), "", "|cff808080sells below its cost|r", "" },
					keys = { plain:lower(), 0, 0, 0, 0, p.margin, -1e15, "", 0 },
					item = p.id, search = plain:lower(),
				}
			end
		end
		local buyList = {}
		for id, s in pairs(shopping) do buyList[#buyList + 1] = { id = id, n = s.n, cost = s.cost } end
		table.sort(buyList, function(a, b) return a.cost > b.cost end)
		local parts = {}
		for i = 1, math.min(6, #buyList) do parts[#parts + 1] = buyList[i].n .. " " .. (ItemName(buyList[i].id)) end
		return out, string.format("Until %s (%.1f days) at your pace of the last 3 days: %s profit, buying for %s (you have %s): ",
			date("%a %d %b", SELL_BY), daysLeft, Money(totalProfit), Money(totalCost), Money(S.gold))
			.. (#parts > 0 and table.concat(parts, ", ") or "nothing") .. ". Margin = your average price after the cut - cost at what you paid."
	end,
}

------------------------------------------------------------------------------------------------
-- Market: competition and your share, for everything you sell

-- This realm's data from MarketData.lua (written by the auction house tools), and the whole file
local function MarketRealm()
	local m = GoldScoutMarket
	return m and m.realms and m.realms[GetRealmName()], m
end

-- Units (and value) the whole market sold per day of an item, over the last days the scans covered
local MARKET_DAYS = 3
local function MarketPace(realm, m, id)
	local line = realm and realm.sold and realm.sold[id]
	if not line or not m.day0 then return nil end
	local today = math.floor((time() - m.day0) / 86400)
	local units, value = 0, 0
	for day, u, v in line:gmatch("(%d+):([%d%.]+):(%d+)") do
		day = tonumber(day)
		if day > today - MARKET_DAYS and day <= today then units, value = units + tonumber(u), value + tonumber(v) end
	end
	-- a day nobody scanned estimates zero sales, so divide by the days the scans covered
	local covered = 0
	for day = today - MARKET_DAYS + 1, today do
		if realm.cover and realm.cover[day] then covered = covered + realm.cover[day] / 86400 end
	end
	if covered <= 0 then return nil end
	return units / covered, value / covered
end

-- Sellers of an item in the newest seller scan: { name, qty, unit } cheapest first, how many sellers
-- in all (rows often count sellers the scan could not name), and the scan time
local function Sellers(realm, id)
	local entry = realm and realm.sellers and realm.sellers[id]
	if not entry then return nil end
	local byName, list, unnamed = {}, {}, 0
	for qty, unit, owners, total in (entry[2] or ""):gmatch("(%d+):(%d+):([^:;]*):(%d+)") do
		qty, unit, total = tonumber(qty), tonumber(unit), tonumber(total)
		local names = {}
		for o in owners:gmatch("[^/]+") do names[#names + 1] = o end
		-- a row can have more sellers than names: split its quantity evenly
		local share = qty / math.max(1, total, #names)
		unnamed = unnamed + math.max(0, total - #names)
		for _, o in ipairs(names) do
			local s = byName[o]
			if not s then
				s = { name = o, qty = 0, unit = unit }
				byName[o] = s
				list[#list + 1] = s
			end
			s.qty, s.unit = s.qty + share, math.min(s.unit, unit)
		end
	end
	table.sort(list, function(a, b) return a.unit < b.unit end)
	return list, #list + unnamed, entry[1]
end

-- One of your characters, in a seller list ("Micox" or "Micox Girthuge")
local function Mine(name)
	for _, c in pairs(GoldScoutDB and GoldScoutDB.chars or {}) do
		if c.name and (name == c.name or name:sub(1, #c.name + 1) == c.name .. " ") then return true end
	end
	return false
end

-- An item in the newest full scan and in the scan nearest to a day before it: { min, qty, auctions, median }
local function ScanTrend(id)
	local scans = GoldScoutDB and GoldScoutDB.scans or {}
	local realm = GetRealmName()
	local last, before
	for i = #scans, 1, -1 do
		local s = scans[i]
		if not s.realm or s.realm == realm then
			if not last then
				last = s
			elseif not before or math.abs(last.t - s.t - 86400) < math.abs(last.t - before.t - 86400) then
				before = s
			end
		end
	end
	return last and ns.Parse(last)[id], before and ns.Parse(before)[id], last
end

local function Pct(now, old)
	if not now or not old or old == 0 then return "" end
	local pct = math.floor((now - old) / old * 100 + 0.5)
	if pct == 0 then return "|cff808080same|r" end
	return (pct > 0 and "|cff40ff40+" or "|cffff4040") .. pct .. "%|r"
end

-- Competition and share per item you sell (also used by the stats page)
local function MarketRows(S)
	local now = time()
	local realm, m = MarketRealm()
	local window = math.max(3600, math.min(RECENT, now - S.first))
	local ids = {}
	for _, it in pairs(S.items) do
		if it.id and (it.sold > 0 or it.expired + it.cancelled > 0) then ids[it.id] = it end
	end
	for id, h in pairs(Holdings(true)) do
		if h.listed > 0 and not ids[id] then ids[id] = S.items[NameOf(id)] or false end
	end
	local rows = {}
	for id, it in pairs(ids) do
		local cur, old, scan = ScanTrend(id)
		local sellers, nSellers = Sellers(realm, id)
		local marketPace = MarketPace(realm, m, id)
		local yours = it and it.recent / window * 86400 or 0
		-- the market estimate is a lower bound and includes you: your share can not pass all of it
		local share = marketPace and marketPace > 0 and yours / math.max(marketPace, yours) or nil
		rows[#rows + 1] = { id = id, it = it, cur = cur, old = old, scan = scan, sellers = sellers, nSellers = nSellers, market = marketPace, yours = yours, share = share }
	end
	return rows, realm, m
end

ns.TABS.market = {
	title = "Stats",
	parent = "stats",
	sortable = true, sortCol = 7, sortDesc = true,
	cols = { { "Item", 190 }, { "Cheapest", 85 }, { "vs a day ago", 80 }, { "Listed", 60 }, { "vs a day ago", 80 }, { "Sellers", 240 }, { "Market sells", 90 }, { "You sell", 75 }, { "Your share", 75 } },
	build = function()
		local rows, realm, m = MarketRows(Collect())
		local out, lastScan = {}, nil
		for _, r in ipairs(rows) do
			lastScan = lastScan or r.scan
			local names, others = {}, 0
			for _, s in ipairs(r.sellers or {}) do
				if Mine(s.name) then
					table.insert(names, 1, "|cff40ff40you|r")
				else
					others = others + 1
					if others <= 3 then names[#names + 1] = s.name:match("^%S+") end
				end
			end
			local label, plain = ItemName(r.id)
			local cur, old = r.cur, r.old
			out[#out + 1] = {
				cols = {
					label, cur and Money(cur[1]) or "", cur and old and Pct(cur[1], old[1]) or "",
					cur and cur[2] or "", cur and old and Pct(cur[2], old[2]) or "",
					r.sellers and (r.nSellers .. (#names > 0 and (": " .. table.concat(names, ", ")) or "") .. (others > 3 and ", ..." or "")) or "|cff808080not in the seller scan|r",
					r.market and string.format("%.0f / day", r.market) or "",
					r.yours > 0 and string.format("%.1f / day", r.yours) or "",
					r.share and (r.share < 0.005 and "<1%" or string.format("%d%%", math.floor(r.share * 100 + 0.5))) or "",
				},
				keys = { plain:lower(), cur and cur[1] or 0, cur and old and (cur[1] - old[1]) / math.max(1, old[1]) or 0,
					cur and cur[2] or 0, cur and old and (cur[2] - old[2]) / math.max(1, old[2]) or 0,
					r.nSellers or 0, r.market or 0, r.yours, r.share or -1 },
				item = r.id, search = plain:lower(),
			}
		end
		local note = realm and ("Market sales are estimates from the auction house site (a lower bound), " .. Ago(m.generated) .. ".")
			or "|cffff8040No market data for this realm yet: the auction house tools write MarketData.lua after a sync, then /reload.|r"
		return out, note .. " Cheapest and listed: your newest full scan" .. (lastScan and (" (" .. Ago(lastScan.t) .. ")") or "")
			.. ". Your share = your sales / the market's, last 3 days."
	end,
}

------------------------------------------------------------------------------------------------
-- Mail: gold and items sent, between your characters and to others

local function CharName(key)
	local c = key and GoldScoutDB.chars[key]
	return c and ns.ClassName(c) or (key and key:match("^[^-]+")) or "|cff808080someone else|r"
end

local function TransferItems(s)
	local parts, value = {}, 0
	for id, n in pairs(s.items) do
		parts[#parts + 1] = (ItemName(id)) .. (n > 1 and (" x" .. n) or "")
		value = value + (Price(id) or VendorPrice(id) or 0) * n
	end
	return table.concat(parts, ", "), value
end

ns.TABS.mail = {
	title = "Stats",
	parent = "stats",
	cols = { { "When", 110 }, { "From", 110 }, { "To", 150 }, { "Gold", 100 }, { "Items worth", 100 }, { "Items", 530 } },
	build = function()
		local S = Collect()
		local out = {}
		local toOwn, toOthers = 0, 0
		for i = #S.transfers, 1, -1 do
			local s = S.transfers[i]
			local items, value = TransferItems(s)
			if s.to then toOwn = toOwn + s.money + value else toOthers = toOthers + s.money + value end
			out[#out + 1] = {
				cols = { date("%a %d %H:%M", s.t), CharName(s.from), s.to and CharName(s.to) or "|cff808080unmatched: someone else, or a fee|r",
					s.money > 0 and Money(s.money) or "", value > 0 and Money(value) or "", items },
				search = ((s.from or "") .. " " .. (s.to or "other") .. " " .. items:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")):lower(),
			}
		end
		return out, "Between your characters " .. Money(toOwn) .. "; to others, or not collected yet " .. Money(toOthers)
			.. ". Matched from the mailbox records: sent here, the same gold or stack arriving there."
	end,
}

ns.MarketRows, ns.Mine = MarketRows, Mine
