-- Build tool (Edit mode only): writes the snowy mountain island's terrain around ServerStorage.TrackPath_Snow.
-- Road (Pavement) follows the path heights, snow banks line it, the lake section is ice, an ice cave covers the
-- tunnel stretch and a ring of peaks closes the island in.
local Gen = {}
local data = game:GetService("HttpService"):JSONDecode(game.ServerStorage.TrackPath_Snow.Value)
local P = {}
for i, p in data.pts do P[i] = {p[1], p[2], p[3]} end
local N = #P
Gen.N = N
Gen.P = P
-- the road's half width (W in TrackPath_Snow: 48 when built, 60 since 2026-10-30); the paving reaches HALF + 2 and
-- everything beside the road (berms, cave walls) moves out with it. With W = 48 these are the original numbers.
local HALF = (data.W or 48) / 2
Gen.HALF = HALF

local TUNNEL = {370, 420} -- path indices covered by the ice cave
local LAKE = {576, 634} -- path indices across the frozen lake
Gen.TUNNEL, Gen.LAKE = TUNNEL, LAKE

local CELL = 64
local buckets = {}
local function key(cx, cz) return cx * 100000 + cz end
for i = 1, N do
	local a, b = P[i], P[i % N + 1]
	for cx = math.floor(math.min(a[1], b[1]) / CELL), math.floor(math.max(a[1], b[1]) / CELL) do
		for cz = math.floor(math.min(a[2], b[2]) / CELL), math.floor(math.max(a[2], b[2]) / CELL) do
			local k = key(cx, cz)
			buckets[k] = buckets[k] or {}
			table.insert(buckets[k], i)
		end
	end
end

local R = 170
-- nearest road point: distance, its height, segment index, and a smooth distance-weighted road height
function Gen.road(x, z)
	local cx, cz = math.floor(x / CELL), math.floor(z / CELL)
	local dmin, hr, imin = math.huge, 0, 0
	local sw, swh = 0, 0
	for i = -3, 3 do
		for j = -3, 3 do
			local t = buckets[key(cx + i, cz + j)]
			if t then
				for _, s in t do
					local a, b = P[s], P[s % N + 1]
					local abx, abz = b[1] - a[1], b[2] - a[2]
					local l2 = abx * abx + abz * abz
					local tt = l2 > 0 and math.clamp(((x - a[1]) * abx + (z - a[2]) * abz) / l2, 0, 1) or 0
					local px, pz = a[1] + abx * tt - x, a[2] + abz * tt - z
					local d = math.sqrt(px * px + pz * pz)
					if d < R then
						local h = a[3] + (b[3] - a[3]) * tt
						if d < dmin then dmin, hr, imin = d, h, s end
						local w = 1 / (d * d + 64) ^ 1.5
						sw += w
						swh += w * h
					end
				end
			end
		end
	end
	if dmin == math.huge then return nil end
	return dmin, hr, imin, swh / sw
end

local CX, CZ, A, B = 2700, -75, 1000, 860
local function smooth(e0, e1, v)
	local t = math.clamp((v - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
end
Gen.smooth = smooth
-- the land away from the road: rolling snowfields inside, a ring of peaks at the island's edge
local function far(x, z)
	local r = math.sqrt(((x - CX) / A) ^ 2 + ((z - CZ) / B) ^ 2)
	local ring = smooth(0.78, 1.04, r) ^ 1.4 * 230
	local rough = math.noise(x / 170, z / 170, 1.3) * 60 * smooth(0.8, 1.0, r) + math.noise(x / 70, z / 70, 7.7) * 10 * smooth(0.85, 1, r)
	local base = 2 + math.noise(x / 150, z / 150, 3.1) * 6
	local h = math.max(base, ring + rough)
	local edge = smooth(1.12, 1.24, r)
	return h * (1 - edge) - 30 * edge, r, ring
end

-- one terrain column: ground height and material, plus an optional solid ceiling (c0..c1) over the ice cave
function Gen.column(x, z)
	local hf, r, ring = far(x, z)
	if r > 1.26 then return nil end
	local mat = (ring > 50 and math.noise(x / 55, z / 55, 4.2) > 0.05) and Enum.Material.Rock or Enum.Material.Snow
	local dmin, hr, idx, hs = Gen.road(x, z)
	if not dmin then return hf, mat end
	local lake = idx >= LAKE[1] and idx <= LAKE[2] and dmin < 130
	local tunnel = idx >= TUNNEL[1] and idx <= TUNNEL[2]
	local near = hr + (hs - hr) * smooth(HALF, HALF + 46, dmin)
	local g
	if dmin <= HALF + 2 then
		g = hr -- the road: karts drive on the terrain itself (one continuous surface, no part edges to catch on)
		mat = lake and Enum.Material.Glacier or Enum.Material.Pavement
	elseif lake then
		local b = smooth(100, 130, dmin)
		g = near + (hf - near) * b
		mat = b > 0.5 and mat or Enum.Material.Glacier
	else
		local berm = (dmin > HALF + 4 and dmin < HALF + 22) and 3.2 * math.sin(math.pi * (dmin - HALF - 4) / 18) or 0
		local b = smooth(HALF + 22, 170, dmin)
		g = near + berm
		g = g + (hf - g) * b
		if b < 0.3 then mat = Enum.Material.Snow end
	end
	if tunnel then
		local top = hr + 48 + math.noise(x / 40, z / 40, 9.1) * 6
		if dmin < HALF + 6 then
			return g, mat, hr + 21 - (dmin / (HALF + 6)) ^ 2 * 5, top
		elseif dmin < 100 then
			local ridge = top - math.max(0, dmin - HALF - 16) * 0.55
			if ridge > g then return ridge, Enum.Material.Snow end
		end
	end
	return g, mat
end

-- write one 128 x 128 stud chunk (x0, z0 multiples of 128); returns false if it's off the island
function Gen.writeChunk(x0, z0)
	local cols = {}
	local top, any = -16, false
	for i = 1, 32 do
		cols[i] = {}
		for j = 1, 32 do
			local g, mat, c0, c1 = Gen.column(x0 + (i - 0.5) * 4, z0 + (j - 0.5) * 4)
			if g then
				any = true
				top = math.max(top, c1 or g)
			end
			cols[i][j] = {g, mat, c0, c1}
		end
	end
	if not any then return false end
	local yb = -48
	local ny = math.ceil((top + 8 - yb) / 4)
	local region = Region3.new(Vector3.new(x0, yb, z0), Vector3.new(x0 + 128, yb + ny * 4, z0 + 128))
	local mats, occs = {}, {}
	local AIR, ROCK, GLACIER, SNOW = Enum.Material.Air, Enum.Material.Rock, Enum.Material.Glacier, Enum.Material.Snow
	for i = 1, 32 do
		mats[i], occs[i] = {}, {}
		for k = 1, ny do mats[i][k], occs[i][k] = {}, {} end
		for j = 1, 32 do
			local c = cols[i][j]
			-- smooth terrain draws its surface about 2 studs above the occupancy maths, so write everything 2 lower
			if c[1] then c = {c[1] - 2, c[2], c[3] and c[3] - 2, c[4] and c[4] - 2} end
			for k = 1, ny do
				local y0 = yb + (k - 1) * 4
				local occ, m = 0, AIR
				if c[1] then
					occ = math.clamp((c[1] - y0) / 4, 0, 1)
					local roof = 0
					if c[3] then roof = math.clamp((math.min(c[4], y0 + 4) - math.max(c[3], y0)) / 4, 0, 1) end
					if roof > 0 and y0 + 2 > c[1] then
						occ = math.min(occ + roof, 1)
						m = (y0 < c[3] + 6) and GLACIER or ((y0 + 6 > c[4]) and SNOW or ROCK)
					elseif occ > 0 then
						m = (y0 + 8 < c[1]) and ROCK or c[2]
					end
				end
				mats[i][k][j], occs[i][k][j] = m, occ
			end
		end
	end
	workspace.Terrain:WriteVoxels(region, 4, mats, occs)
	return true
end

return Gen
