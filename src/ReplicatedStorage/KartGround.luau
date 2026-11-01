-- Kart suspension, shared by KartController (players) and BotDriver (bots).
-- Roblox terrain's collision surface comes out as ~1-stud stairs on any slope, however smoothly the voxels are written
-- (measured on a 6% test ramp: flat for 12 studs, then a 0.75-stud jump), while the drawn surface is smooth. A
-- flat-bottomed hull sliding on those stairs got kicked up 10-20 studs/s at every step. So the hull doesn't touch the
-- ground at all: its centre is held RIDE above the ground height, and it collides through a "Collider" block (see
-- KartFactory) whose bottom stays 1.2 studs up. On the road of a track with road heights (Snow Mountain, Desert Canyon)
-- that height comes from the racing line itself (ReplicatedStorage.RacePath, published by RaceManager): perfectly
-- smooth. Elsewhere (ramps, the bridge, the flat main track, off the road) it comes from 5 rays, averaged and smoothed.
local Workspace = game:GetService("Workspace")
local RS = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local G = {}
G.RIDE = 0.5 -- hull centre above the ground
G.REACH = 1.7 -- grounded while the ground is this close under the hull centre
local OFFS = {{3.6, 0}, {-3.6, 0}, {0, 2.3}, {0, -2.3}} -- front, back, right, left (studs along fwd, right)
local UP = Vector3.yAxis

local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude
params.RespectCanCollide = true -- only what a kart can actually touch
local function refresh()
	local list = {}
	for _, n in {"Karts", "RaceFX", "EZPZ_LocalFX"} do
		local f = Workspace:FindFirstChild(n)
		if f then table.insert(list, f) end
	end
	params.FilterDescendantsInstances = list
	pcall(function() params.CollisionGroup = "Kart" end) -- skips riders (their group never collides with karts)
end
refresh()
Workspace.ChildAdded:Connect(refresh)

-- ===== the racing line with its road heights =====
local path, hasHeights = {}, false
-- the paved road's half width plus its shoulder: the racing line's height is used fully out to rideIn studs from the
-- centre line and fades out by rideOut (26 / 32 on a 48-wide road; the path's W says how wide this track is)
local rideIn, rideOut = 26, 32
local function loadPath()
	table.clear(path)
	hasHeights = false
	local v = RS:FindFirstChild("RacePath")
	local ok, d = pcall(function() return HttpService:JSONDecode(v and v.Value or "") end)
	local half = (ok and type(d) == "table" and tonumber(d.W) or 48) / 2
	rideIn, rideOut = half + 2, half + 8
	if ok and type(d) == "table" and type(d.pts) == "table" then
		for i, p in d.pts do
			path[i] = Vector3.new(p[1], p[3] or 0, p[2])
			if (p[3] or 0) ~= 0 then hasHeights = true end
		end
	end
end
local function watch(v)
	if v.Name == "RacePath" and v:IsA("StringValue") then
		v:GetPropertyChangedSignal("Value"):Connect(loadPath)
		loadPath()
	end
end
for _, v in RS:GetChildren() do watch(v) end
RS.ChildAdded:Connect(watch)

local function flatDist2(a, x, z) local dx, dz = a.X - x, a.Z - z return dx * dx + dz * dz end
-- the road height under (x, z): height, distance from the centre line, and the road's direction (with its slope).
-- st.ri remembers where on the line this kart was, so only a short window is searched each frame.
local function roadAt(st, x, z)
	local N = #path
	if N < 2 then return nil end
	local i = st.ri
	if not i or st.riPath ~= path then
		local best = math.huge
		for k = 1, N do
			local dd = flatDist2(path[k], x, z)
			if dd < best then best, i = dd, k end
		end
		st.riPath = path
	else
		local best, bi = math.huge, i
		for k = -8, 12 do
			local j = (i + k - 1) % N + 1
			local dd = flatDist2(path[j], x, z)
			if dd < best then best, bi = dd, j end
		end
		i = bi
		-- far from where we were (a respawn): search everywhere again
		if best > 60 * 60 then st.ri = nil return roadAt(st, x, z) end
	end
	st.ri = i
	local bestD, bh, bt = math.huge, 0, nil
	for k = -1, 0 do
		local a, b = path[(i + k - 1) % N + 1], path[(i + k) % N + 1]
		local abx, abz = b.X - a.X, b.Z - a.Z
		local l2 = abx * abx + abz * abz
		local t = l2 > 0 and math.clamp(((x - a.X) * abx + (z - a.Z) * abz) / l2, 0, 1) or 0
		local px, pz = a.X + abx * t, a.Z + abz * t
		local dd = (px - x) ^ 2 + (pz - z) ^ 2
		if dd < bestD then bestD, bh, bt = dd, a.Y + (b.Y - a.Y) * t, (b - a) end
	end
	return bh, math.sqrt(bestD), bt
end

function G.new() return {} end

-- returns the ground hit straight under the hull (for ramp checks), whether the kart is grounded, and the
-- smoothed ground normal
function G.sample(st, hull, fwd, right, dt)
	local pos = hull.Position
	-- (from 1.5 studs up: the stepped collision surface can reach nearly as high as the hull's centre)
	local center = Workspace:Raycast(pos + UP * 1.5, Vector3.new(0, -4.7, 0), params)
	if not center or center.Distance - 1.5 > G.REACH then
		st.was = false
		return center, false, st.n or UP
	end
	local cy = center.Position.Y
	local sum, n = cy, 1
	local hits = {}
	for k, o in OFFS do
		local origin = pos + fwd * o[1] + right * o[2] + UP * 1.5
		local r = Workspace:Raycast(origin, Vector3.new(0, -6, 0), params)
		-- ignore a ray that fell off an edge (the lip of a ramp) or landed on something much higher
		if r and math.abs(r.Position.Y - cy) < 1.2 then
			hits[k] = r.Position
			sum += r.Position.Y
			n += 1
		end
	end
	local gy = sum / n
	-- the plane through the samples
	local cn = center.Normal
	local tf = (hits[1] and hits[2]) and (hits[1] - hits[2]) or (fwd - cn * fwd:Dot(cn))
	local tr = (hits[3] and hits[4]) and (hits[3] - hits[4]) or (right - cn * right:Dot(cn))
	local nm = tr:Cross(tf)
	nm = nm.Magnitude > 1e-3 and nm.Unit or cn
	if nm.Y < 0 then nm = -nm end
	-- on the road of a track with road heights, ride on the racing line's own (smooth) height instead of the
	-- terrain's stepped collision surface
	if hasHeights and center.Instance == Workspace.Terrain then
		local h, lat, t3 = roadAt(st, pos.X, pos.Z)
		if h and lat < rideOut then
			local w = 1 - math.clamp((lat - rideIn) / (rideOut - rideIn), 0, 1)
			local side = Vector3.new(-t3.Z, 0, t3.X)
			local rn = t3:Cross(side)
			rn = rn.Magnitude > 1e-3 and rn.Unit or UP
			if rn.Y < 0 then rn = -rn end
			gy = gy + (h - gy) * w
			nm = nm:Lerp(rn, w).Unit
		end
	end
	if not st.was then
		st.gy, st.n = gy, nm
	else
		-- carry the smoothed height along the slope we're driving on first, so smoothing doesn't lag on hills
		local v = hull.AssemblyLinearVelocity
		local sn = st.n
		st.gy -= (sn.X * v.X + sn.Z * v.Z) / math.max(sn.Y, 0.5) * dt
		st.gy += (gy - st.gy) * (1 - math.exp(-25 * dt))
		local s = st.n:Lerp(nm, 1 - math.exp(-15 * dt))
		st.n = s.Magnitude > 0.1 and s.Unit or nm
	end
	st.was = true
	return center, true, st.n
end

-- speed along the ground normal that keeps the hull at its ride height over the ground (plus what gravity will
-- take away during this frame)
function G.rideSpeed(st, hull, nrm, dt)
	local err = st.gy + G.RIDE - hull.Position.Y
	local vy = math.clamp(err * 14, -30, 10) + Workspace.Gravity * dt * 0.5
	return vy / math.max(nrm.Y, 0.5)
end

return G
