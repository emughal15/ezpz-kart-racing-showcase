-- AI racers: a stand-in "player" object plus a server-side driving controller
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("KartConfig"))
local Ground = require(ReplicatedStorage:WaitForChild("KartGround"))
local K = Config.Kart
local Bot = {}

-- ===== stand-in player (enough of the Player API for the race code) =====
local Stub = {}
Stub.__index = Stub
function Stub:SetAttribute(k, v) self._attrs[k] = v end
function Stub:GetAttribute(k) return self._attrs[k] end
function Stub:FindFirstChild() return nil end
function Bot.newStub(name)
	return setmetatable({Name = name, DisplayName = name, IsBot = true, Parent = nil, Character = nil, _attrs = {}}, Stub)
end

-- ===== track path =====
local pts = {}
local N = 0
local function loadTrack()
	local ok, data = pcall(function() return HttpService:JSONDecode(ServerStorage:WaitForChild("TrackPath", 10).Value) end)
	if ok and data then
		table.clear(pts)
		for i, p in data.pts do pts[i] = Vector3.new(p[1], 0, p[2]) end
	end
	N = #pts
end
loadTrack()
ServerStorage:WaitForChild("TrackPath"):GetPropertyChangedSignal("Value"):Connect(loadTrack)

local function now() return Workspace:GetServerTimeNow() end
local function moveToward(v, target, d)
	if v < target then return math.min(v + d, target) end
	return math.max(v - d, target)
end
local function yawOf(cf)
	local look = cf.LookVector
	return math.atan2(-look.X, -look.Z)
end
local function wrapAngle(a)
	return (a + math.pi) % (2 * math.pi) - math.pi
end
local function nearestIdx(pos)
	local best, bi = math.huge, 1
	for i, p in pts do
		local d = (p - Vector3.new(pos.X, 0, pos.Z)).Magnitude
		if d < best then best, bi = d, i end
	end
	return bi
end

-- set up driving state for a bot racer record
function Bot.attach(r, lane, skill)
	r.isBot = true
	r.lane = lane
	r.skill = skill
	r.align = r.hull:FindFirstChild("UprightAlign")
	r.params = RaycastParams.new()
	r.params.FilterType = Enum.RaycastFilterType.Exclude
	r.params.FilterDescendantsInstances = {r.kart}
	r.yaw = yawOf(r.hull.CFrame)
	r.up = Vector3.yAxis
	r.idx = N > 0 and nearestIdx(r.hull.Position) or 1
	r.nonce = r.kart:GetAttribute("ResetNonce") or 0
	r.hitNonce = r.kart:GetAttribute("HitNonce") or 0
	r.stuck = 0
	r.ground = Ground.new()
end

-- one physics step for a bot (server owns the kart)
function Bot.step(r, dt, useItem)
	local hull, kart = r.hull, r.kart
	if not hull.Parent or hull.Anchored or N == 0 then return end
	local t = now()

	-- respawned by the race manager?
	local nonce = kart:GetAttribute("ResetNonce") or 0
	if nonce ~= r.nonce then
		r.nonce = nonce
		r.yaw = yawOf(hull.CFrame)
		r.idx = nearestIdx(hull.Position)
		r.stuck = 0
		return
	end
	-- got hit: hop
	local hn = kart:GetAttribute("HitNonce") or 0
	if hn ~= r.hitNonce then
		r.hitNonce = hn
		hull.AssemblyLinearVelocity += Vector3.new(0, kart:GetAttribute("HitPop") or 20, 0)
		r.popUntil = t + 0.5 -- let the hop take off (see the ground hug below)
	end

	-- caught in someone's magnet: get dragged toward them
	do
		local src = kart:FindFirstChild("MagnetSource")
		if src and src.Value and src.Value.Parent and (kart:GetAttribute("PulledUntil") or 0) > t then
			local d = src.Value.Position - hull.Position
			d = Vector3.new(d.X, 0, d.Z)
			if d.Magnitude > 12 then
				hull.AssemblyLinearVelocity += d.Unit * Config.MagnetPull * dt
			end
		end
	end
	-- follow the racing line in our lane
	local pos = Vector3.new(hull.Position.X, 0, hull.Position.Z)
	-- progress along the racing line: closest point in a short window ahead (never goes backwards)
	do
		local best, bestD = r.idx, (pts[r.idx] - pos).Magnitude
		for k = 1, 16 do
			local j = (r.idx - 1 + k) % N + 1
			local dd = (pts[j] - pos).Magnitude
			if dd < bestD then best, bestD = j, dd end
		end
		r.idx = best
		-- way off the line (e.g. after being knocked away): re-find the nearest point nearby
		if bestD > 60 then
			local b2, d2 = r.idx, math.huge
			for k = -30, 60 do
				local j = (r.idx - 1 + k) % N + 1
				local dd = (pts[j] - pos).Magnitude
				if dd < d2 then b2, d2 = j, dd end
			end
			r.idx = b2
		end
	end
	local ai = (r.idx + 4 - 1) % N + 1
	local bi = ai % N + 1
	local d = (pts[bi] - pts[ai]).Unit
	local right = d:Cross(Vector3.yAxis)
	-- tuck toward the middle of the road in tight corners
	local ci = (ai + 4 - 1) % N + 1
	local cj = ci % N + 1
	local bend = math.clamp(1 - d:Dot((pts[cj] - pts[ci]).Unit), 0, 1)
	local laneNow = r.lane * math.clamp(1 - bend * 12, 0.25, 1)
	local aim = pts[ai] + right * laneNow
	local want = aim - pos
	local desired = math.atan2(-want.X, -want.Z)
	local diff = wrapAngle(desired - r.yaw)

	local boosting = (kart:GetAttribute("BoostUntil") or 0) > t
	local slowed = (kart:GetAttribute("SlowUntil") or 0) > t
	local spinning = (kart:GetAttribute("SpinOutUntil") or 0) > t
	local throttle = (math.abs(diff) > 0.55) and 0.7 or 1
	if boosting then throttle = 1 end

	-- the ground under the kart, smoothed over 5 rays (see KartGround: suspension over the terrain's voxel steps)
	local f0 = Vector3.new(-math.sin(r.yaw), 0, -math.cos(r.yaw))
	local hit, grounded, groundN = Ground.sample(r.ground, hull, f0, f0:Cross(Vector3.yAxis), dt)
	local vel = hull.AssemblyLinearVelocity
	-- jump ramps (same feel as players)
	if grounded then
		if r.rampAir and t - r.rampAir > 0.3 then
			r.rampAir = nil
			kart:SetAttribute("BoostUntil", math.max(kart:GetAttribute("BoostUntil") or 0, t + 0.6))
		end
		r.onRamp = hit.Instance ~= nil and hit.Instance.Name == "Ramp"
	elseif r.onRamp then
		r.onRamp = false
		local flat = Vector3.new(vel.X, 0, vel.Z).Magnitude
		if flat > 30 then
			vel = Vector3.new(vel.X, math.max(vel.Y, 28 + flat * 0.2), vel.Z)
			hull.AssemblyLinearVelocity = vel
			r.rampAir = t
		end
	end
	if not grounded and r.rampAir then
		hull.AssemblyLinearVelocity = vel + Vector3.new(0, Workspace.Gravity * 0.4 * dt, 0)
	end
	local fwd = Vector3.new(-math.sin(r.yaw), 0, -math.cos(r.yaw))
	local fSpeed = vel:Dot(fwd)
	local steerScale = math.clamp(math.abs(fSpeed) / 18, 0.15, 1)
	if spinning then
		r.yaw += K.SpinRate * dt
	else
		local maxTurn = K.TurnRate * 1.15 * steerScale * dt
		r.yaw += math.clamp(diff, -maxTurn, maxTurn)
	end
	fwd = Vector3.new(-math.sin(r.yaw), 0, -math.cos(r.yaw))
	local rightV = fwd:Cross(Vector3.yAxis)
	fSpeed = vel:Dot(fwd)
	local lSpeed = vel:Dot(rightV)
	local uSpeed = vel.Y

	-- drafting: bots slipstream too
	local D = Config.Draft
	local drafting = false
	local kartsFolder = Workspace:FindFirstChild("Karts")
	if D and kartsFolder and grounded and fSpeed > D.MinSpeed and not boosting and not spinning then
		for _, k in kartsFolder:GetChildren() do
			if k ~= kart then
				local h = k:FindFirstChild("Hull")
				if h then
					local rel = h.Position - hull.Position
					local flat = Vector3.new(rel.X, 0, rel.Z)
					local along = flat:Dot(fwd)
					if along > D.MinRange and along < D.Range and math.abs(flat:Dot(rightV)) < D.Width
						and h.AssemblyLinearVelocity:Dot(fwd) > D.MinSpeed * 0.6 then
						drafting = true
						break
					end
				end
			end
		end
	end
	r.draftCharge = r.draftCharge or 0
	if drafting and t > (r.draftCooldown or 0) then
		r.draftCharge = math.min(r.draftCharge + dt / D.ChargeTime, 1)
		if r.draftCharge >= 1 then
			r.draftCharge = 0
			r.draftCooldown = t + D.Cooldown
			kart:SetAttribute("BoostUntil", math.max(kart:GetAttribute("BoostUntil") or 0, t + D.BoostTime))
		end
	else
		r.draftCharge = math.max(r.draftCharge - dt * (D.Decay or 0.6), 0)
	end

	if grounded then
		local mag = math.sqrt(fSpeed * fSpeed + lSpeed * lSpeed)
		lSpeed *= math.clamp(1 - K.Grip * dt, 0, 1)
		local fMag = math.sqrt(math.max(mag * mag - lSpeed * lSpeed, 0))
		fSpeed = fSpeed >= 0 and fMag or -fMag
		if spinning then
			fSpeed = moveToward(fSpeed, 0, K.Drag * 1.6 * dt)
		else
			local maxSpeed = (boosting and K.BoostSpeed or K.MaxSpeed * r.skill) * (slowed and K.SlowFactor or 1) * (drafting and D.SpeedBonus or 1)
			local target = maxSpeed * throttle
			if fSpeed < target then
				fSpeed = math.min(fSpeed + (boosting and K.BoostAccel or K.Accel) * dt, target)
			else
				fSpeed = math.max(fSpeed - K.Drag * 2 * dt, target)
			end
		end
		-- drive in the plane of the (smoothed) ground and hold the ride height over it, so slopes and the
		-- terrain's voxel steps don't bounce the kart (item hits get a moment to pop it up)
		local n = groundN
		local fP = fwd - n * fwd:Dot(n)
		local rP = rightV - n * rightV:Dot(n)
		fP = fP.Magnitude > 0.01 and fP.Unit or fwd
		rP = rP.Magnitude > 0.01 and rP.Unit or rightV
		local un = vel:Dot(n)
		if t > (r.popUntil or 0) then un = Ground.rideSpeed(r.ground, hull, n, dt) end
		hull.AssemblyLinearVelocity = fP * fSpeed + rP * lSpeed + n * un
	end
	if r.align then
		local up = r.up:Lerp(grounded and groundN or Vector3.yAxis, math.clamp(8 * dt, 0, 1))
		r.up = up.Magnitude > 0.1 and up.Unit or Vector3.yAxis
		local f2 = fwd - r.up * fwd:Dot(r.up)
		f2 = f2.Magnitude > 0.01 and f2.Unit or fwd
		r.align.CFrame = CFrame.fromMatrix(Vector3.zero, f2:Cross(r.up), r.up, -f2)
	end

	-- stuck detection (the race manager respawns us)
	if not spinning and vel.Magnitude < 6 then r.stuck += dt else r.stuck = 0 end

	-- use items after a short think
	local item = r.player:GetAttribute("Item")
	if item and item ~= "" and item ~= "Rolling" then
		if not r.useAt then r.useAt = t + 1 + math.random() * 3 end
		if t >= r.useAt then
			r.useAt = nil
			useItem(r)
		end
	else
		r.useAt = nil
	end
end

-- a bot that has crossed the line rolls to a stop, still riding on its suspension
function Bot.coast(r, dt)
	local hull = r.hull
	if not hull.Parent or hull.Anchored then return end
	r.ground = r.ground or Ground.new()
	local fwd = Vector3.new(-math.sin(r.yaw), 0, -math.cos(r.yaw))
	local _, grounded, n = Ground.sample(r.ground, hull, fwd, fwd:Cross(Vector3.yAxis), dt)
	if not grounded then return end
	local vel = hull.AssemblyLinearVelocity
	local planeV = (vel - n * vel:Dot(n)) * math.max(1 - 1.2 * dt, 0)
	hull.AssemblyLinearVelocity = planeV + n * Ground.rideSpeed(r.ground, hull, n, dt)
end

return Bot
