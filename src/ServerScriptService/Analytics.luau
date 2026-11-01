-- Roblox's built-in analytics (Creator Dashboard → your game → Analytics): the new-player funnel (Onboarding),
-- the Robux store and coin shop funnels (Funnels) and every coin earned or spent (Economy). Roblox draws the charts.
-- Live servers send through AnalyticsService. Studio sends nothing to the dashboard, so there each call is kept in a
-- list instead, to check the hooks: ServerStorage.EZPZ_AnalyticsDebug:Invoke() returns it as JSON.
local AnalyticsService = game:GetService("AnalyticsService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Analytics = {}
local studio = RunService:IsStudio()
local studioLog = {}

-- the first-session steps, in order (Economy keeps each new player's last step in the saved profile, so a step
-- is only ever sent once per player, even across visits)
Analytics.ONBOARDING = {"Loaded in", "Pressed PLAY", "Started first race", "Finished first race",
	"Started second race", "Finished third race"}

local function send(what, fn)
	-- Studio makes the real call too (it goes nowhere), so a wrong argument shows up in testing, not after launch
	local ok, err = pcall(fn)
	if not ok then warn("[EZPZ] analytics: " .. tostring(err)) end
	if studio then
		table.insert(studioLog, what .. (ok and "" or "  !! " .. tostring(err)))
		if #studioLog > 200 then table.remove(studioLog, 1) end
	end
end

-- a new player reached onboarding step n (1..#ONBOARDING)
function Analytics.onboarding(plr, n)
	local name = Analytics.ONBOARDING[n]
	if not name then return end
	send("onboarding " .. n .. " " .. name, function()
		AnalyticsService:LogOnboardingFunnelStepEvent(plr, n, name)
	end)
end

-- funnels a player can go through many times ("RobuxStore", "CoinShop"): step 1 starts a new attempt,
-- later steps belong to the latest attempt
local FUNNELS = {
	RobuxStore = {"Opened store", "Pressed buy", "Bought"},
	CoinShop = {"Opened shop", "Bought an item"},
}
local attempts = {} -- [player] = {[funnel] = attempt id}
Players.PlayerRemoving:Connect(function(plr) attempts[plr] = nil end)
function Analytics.funnel(plr, funnel, n)
	local steps = FUNNELS[funnel]
	if not steps or not steps[n] then return end
	local a = attempts[plr] or {}
	attempts[plr] = a
	if n == 1 or not a[funnel] then a[funnel] = HttpService:GenerateGUID(false) end
	send("funnel " .. funnel .. " " .. n .. " " .. steps[n], function()
		AnalyticsService:LogFunnelStepEvent(plr, funnel, a[funnel], n, steps[n])
	end)
end

-- coins earned (amount > 0) or spent (amount < 0). kind is a Roblox transaction type ("Gameplay", "Shop", "IAP",
-- "TimedReward", "Onboarding"...), sku says what exactly ("TrackCoins", "Challenge", "Paint/Diamond"...)
function Analytics.coins(plr, amount, balance, kind, sku)
	if amount == 0 then return end
	local flow = amount > 0 and Enum.AnalyticsEconomyFlowType.Source or Enum.AnalyticsEconomyFlowType.Sink
	send(string.format("coins %+d = %d %s %s", amount, balance, kind, sku or ""), function()
		AnalyticsService:LogEconomyEvent(plr, flow, "Coins", math.abs(amount), balance, kind, sku)
	end)
end

if studio then
	local hook = ServerStorage:FindFirstChild("EZPZ_AnalyticsDebug") or Instance.new("BindableFunction")
	hook.Name = "EZPZ_AnalyticsDebug"
	hook.Parent = ServerStorage
	hook.OnInvoke = function(clear)
		local out = HttpService:JSONEncode(studioLog)
		if clear then table.clear(studioLog) end
		return out
	end
end

return Analytics
