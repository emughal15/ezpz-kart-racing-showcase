-- EZPZ Kart Racing: the Robux store. VIP game pass and coin packs (developer products); ids and prices in KartConfig.Store.
-- VIP sets the player attribute "VIP"; RaceManager pays the VIP coin bonus, Economy unlocks the VIP-only shop items,
-- KartFactory crowns the name tag and StoreUI adds the chat tag. Coin packs pay out through Economy.grantPurchase.
local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local Config = require(ReplicatedStorage:WaitForChild("KartConfig"))
local Economy = require(ServerScriptService:WaitForChild("Economy"))
local LaunchStats = require(ServerScriptService:WaitForChild("LaunchStats"))
local Analytics = require(ServerScriptService:WaitForChild("Analytics"))
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local S = Config.Store
local studio = RunService:IsStudio()
local studioVip = {} -- Studio test purchases of the pass, [player] = true

local function notify(plr, text, kind) if plr.Parent then Remotes.Notify:FireClient(plr, text, kind) end end

-- ===== VIP game pass =====
local function checkVip(plr)
	if studioVip[plr] then plr:SetAttribute("VIP", true) return end
	if S.VIP.PassId == 0 then plr:SetAttribute("VIP", false) return end
	for attempt = 1, 4 do
		local ok, owns = pcall(MarketplaceService.UserOwnsGamePassAsync, MarketplaceService, plr.UserId, S.VIP.PassId)
		if ok then
			plr:SetAttribute("VIP", owns == true)
			return
		end
		task.wait(attempt * 2)
	end
	warn("[EZPZ] couldn't check the VIP pass for " .. plr.UserId)
end
Players.PlayerAdded:Connect(checkVip)
for _, plr in Players:GetPlayers() do task.spawn(checkVip, plr) end
Players.PlayerRemoving:Connect(function(plr) studioVip[plr] = nil end)

local function welcomeVip(plr)
	plr:SetAttribute("VIP", true)
	notify(plr, "👑 Welcome to VIP! +" .. math.floor(S.VIP.CoinBonus * 100) .. "% coins every race, plus 5 VIP items in the shop: paint, trail, glow, horn and finish crowns.", "good")
end
MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(plr, passId, bought)
	if bought and passId == S.VIP.PassId and passId ~= 0 then
		LaunchStats.add("buy.VIP")
		Analytics.funnel(plr, "RobuxStore", 3)
		welcomeVip(plr)
	end
end)

-- ===== coin packs =====
local packById = {}
for _, pack in S.CoinPacks do
	if pack.Id ~= 0 then packById[pack.Id] = pack end
end
-- Roblox keeps retrying a receipt (even on later joins) until it is marked granted, and Economy records each
-- PurchaseId in the saved profile, so a pack is paid exactly once.
MarketplaceService.ProcessReceipt = function(info)
	local pack = packById[info.ProductId]
	if not pack then
		warn("[EZPZ] receipt for an unknown product " .. tostring(info.ProductId))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local plr = Players:GetPlayerByUserId(info.PlayerId)
	if not plr then return Enum.ProductPurchaseDecision.NotProcessedYet end
	local ok, fresh = Economy.grantPurchase(plr, info.PurchaseId, pack.Coins)
	if fresh then
		LaunchStats.add("buy.coins" .. pack.Coins)
		Analytics.funnel(plr, "RobuxStore", 3)
		notify(plr, "💰 +" .. pack.Coins .. " coins! Thanks for supporting EZPZ Kart Racing!", "good")
	end
	return ok and Enum.ProductPurchaseDecision.PurchaseGranted or Enum.ProductPurchaseDecision.NotProcessedYet
end

-- ===== Studio only: store buttons whose id is still 0 hand the item over for free, so the flow can be tested =====
if studio then
	local test = Remotes:FindFirstChild("StoreTest") or Instance.new("RemoteEvent")
	test.Name = "StoreTest"
	test.Parent = Remotes
	test.OnServerEvent:Connect(function(plr, kind, i)
		if kind == "vip" then
			studioVip[plr] = true
			Analytics.funnel(plr, "RobuxStore", 3)
			welcomeVip(plr)
		elseif kind == "pack" and type(i) == "number" and S.CoinPacks[i] then
			local pack = S.CoinPacks[i]
			local _, fresh = Economy.grantPurchase(plr, "studio-" .. HttpService:GenerateGUID(false), pack.Coins)
			if fresh then
				LaunchStats.add("buy.coins" .. pack.Coins)
				Analytics.funnel(plr, "RobuxStore", 3)
				notify(plr, "💰 +" .. pack.Coins .. " coins! (Studio test purchase)", "good")
			end
		end
	end)
	-- ServerStorage.EZPZ_StoreDebug: Invoke("vip", name, on) turns VIP on or off for a test
	local bf = game:GetService("ServerStorage"):FindFirstChild("EZPZ_StoreDebug") or Instance.new("BindableFunction")
	bf.Name = "EZPZ_StoreDebug"
	bf.OnInvoke = function(action, name, on)
		local plr = Players:FindFirstChild(name)
		if not plr then return "no player" end
		if action == "vip" then
			studioVip[plr] = on and true or nil
			plr:SetAttribute("VIP", on == true)
			return plr:GetAttribute("VIP")
		end
	end
	bf.Parent = game:GetService("ServerStorage")
end
