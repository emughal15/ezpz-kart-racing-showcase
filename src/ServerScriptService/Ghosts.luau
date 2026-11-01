-- Time Attack ghosts: each player's best lap per track mode (a Config.LapModes key), kept in the DataStore
-- Config.TimeAttack.Store. A ghost is {t = lap time (the server's own timer), s = samples "t,x,y,z,yaw,pitch;...",
-- c = {seconds into the lap at each checkpoint}}. RaceManager decides what gets saved; this only stores and loads.
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Config = require(ReplicatedStorage:WaitForChild("KartConfig"))

local Ghosts = {}
-- like Economy and the leaderboards: Studio keeps ghosts in memory only, unless ServerScriptService has
-- StudioPersistentProfiles = true, and even then it uses its own "_Studio" store, never the live one
local studio = RunService:IsStudio()
local persistent = not studio or ServerScriptService:GetAttribute("StudioPersistentProfiles") == true
local store
if persistent then
	pcall(function() store = DataStoreService:GetDataStore(Config.TimeAttack.Store .. (studio and "_Studio" or "")) end)
end
local cache = {} -- [key] = ghost, or false once we know there is none (Studio has no DataStore access: the cache is all there is)

local function key(userId, modeKey) return "u" .. userId .. "_" .. modeKey end
local function valid(g) return type(g) == "table" and type(g.t) == "number" and type(g.s) == "string" and type(g.c) == "table" end

-- the player's ghost for this track mode, or nil
function Ghosts.get(userId, modeKey)
	local k = key(userId, modeKey)
	if cache[k] ~= nil then return cache[k] or nil end
	local ok, g = pcall(function() return store and store:GetAsync(k) end)
	cache[k] = (ok and valid(g)) and g or false
	return cache[k] or nil
end

-- keep g if it's quicker than the ghost we have; true if it was kept
function Ghosts.put(userId, modeKey, g)
	local k = key(userId, modeKey)
	local old = cache[k]
	if old and old.t <= g.t then return false end
	cache[k] = g
	if not store then return true end
	task.spawn(function()
		pcall(function()
			store:UpdateAsync(k, function(cur)
				if valid(cur) and cur.t <= g.t then return nil end -- another server already saved a quicker one
				return g
			end)
		end)
	end)
	return true
end

return Ghosts
