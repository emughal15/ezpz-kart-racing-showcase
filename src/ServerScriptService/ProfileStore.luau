-- Atomic profile sessions. No service calls occur until a caller supplies a store.
-- The injected store/clock/wait functions also let failure paths be checked without real player data.
local ProfileStore = {}
ProfileStore.__index = ProfileStore
local Session = {}
Session.__index = Session
local LOCK = "_EZPZSession"
local RECEIPT = "_EZPZWrite"

local function copy(value)
	if type(value) ~= "table" then return value end
	local out = {}
	for k, v in pairs(value) do out[k] = copy(v) end
	return out
end

local function keyInfo(info, userId)
	local ids = info and info:GetUserIds() or {}
	if userId and userId > 0 and not table.find(ids, userId) then table.insert(ids, userId) end
	return ids, info and info:GetMetadata() or {}
end

function ProfileStore.new(options)
	assert(options.memory or options.store, "A profile store is required")
	assert(options.newToken, "A unique session token generator is required")
	return setmetatable({
		store = options.store, memory = options.memory == true,
		newToken = options.newToken, now = options.now or os.time,
		clock = options.clock or os.clock, wait = options.wait or task.wait,
		lease = options.lease or 180, attempts = options.attempts or 5,
		retryDelay = options.retryDelay or 1, validate = options.validate,
	}, ProfileStore)
end

function ProfileStore:open(key, userId, active, deadline)
	local token = self.newToken()
	local s = setmetatable({manager = self, key = key, userId = userId, token = token,
		revision = 0, savedRevision = 0, writeNumber = 0, expires = self.now() + self.lease}, Session)
	if self.memory then s.value = {}; return s end
	deadline = deadline or self.clock() + 40
	local lastError = "Progress could not be loaded"
	local attempted = false
	local function abandon(reason)
		-- A failed network response can hide a successful claim. Only release our own token.
		if attempted then
			pcall(function()
				self.store:UpdateAsync(key, function(old, info)
					local lock = type(old) == "table" and old[LOCK]
					if type(lock) ~= "table" or lock.token ~= token then return nil end
					local value = copy(old)
					value[LOCK] = nil
					return value, keyInfo(info, userId)
				end)
			end)
		end
		return nil, reason
	end
	for attempt = 1, self.attempts do
		if self.clock() >= deadline or (active and not active()) then return abandon("Cancelled") end
		local reason
		attempted = true
		local ok, result = pcall(function()
			return self.store:UpdateAsync(key, function(old, info)
				reason = nil -- UpdateAsync may run this callback more than once.
				if old ~= nil and (type(old) ~= "table" or (self.validate and not self.validate(old))) then
					reason = "InvalidData"; return nil
				end
				local lock = old and old[LOCK]
				if lock ~= nil then
					if type(lock) ~= "table" or type(lock.token) ~= "string" or type(lock.expires) ~= "number" then
						reason = "InvalidData"; return nil
					end
					if lock.token ~= token and lock.expires > self.now() then reason = "SessionBusy"; return nil end
				end
				local nextValue = copy(old or {})
				nextValue[LOCK] = {token = token, expires = self.now() + self.lease}
				return nextValue, keyInfo(info, userId)
			end)
		end)
		if ok and type(result) == "table" and type(result[LOCK]) == "table" and result[LOCK].token == token then
			s.expires = result[LOCK].expires
			s.value = copy(result)
			s.value[LOCK], s.value[RECEIPT] = nil, nil
			return s
		end
		lastError = reason or tostring(result)
		if reason == "InvalidData" then return abandon(reason) end
		if attempt < self.attempts then
			self.wait(math.min(self.retryDelay * 2 ^ (attempt - 1), 8, math.max(0, deadline - self.clock())))
		end
	end
	return abandon(lastError)
end

function Session:touch()
	if self.released or self.closing or self.lost then return false end
	self.revision += 1
	return true
end

function Session:isDirty() return self.revision ~= self.savedRevision end
function Session:isUsable()
	return not (self.released or self.closing or self.lost)
		and (self.manager.memory or self.manager.now() < self.expires)
end

function Session:save(snapshot, release, deadline)
	local m = self.manager
	deadline = deadline or m.clock() + 20
	if release then self.closing = true end
	while self.saving do
		if m.clock() >= deadline then return false, "TimedOut" end
		m.wait(0.05)
	end
	if self.released then return release == true, "Released" end
	if self.lost then return false, "SessionLost" end
	if self.closing and not release then return false, "Closing" end
	if m.clock() >= deadline then return false, "TimedOut" end
	self.saving = true
	local revision = self.revision
	local captured, value = pcall(function() return copy(snapshot()) end)
	if not captured then self.saving = false; return false, tostring(value) end
	self.writeNumber += 1
	local receipt = self.token .. ":" .. self.writeNumber
	if m.memory then
		self.value, self.savedRevision = value, revision
		self.released = release == true
		self.saving = false
		return true
	end
	local success, lastError = false, "Save failed"
	for attempt = 1, m.attempts do
		if m.clock() >= deadline then lastError = "TimedOut"; break end
		local reason, alreadyReleased
		local ok, result = pcall(function()
			return m.store:UpdateAsync(self.key, function(old, info)
				reason, alreadyReleased = nil, false
				-- A request may have committed even if its network response was lost.
				if release and type(old) == "table" and old[RECEIPT] == receipt then
					alreadyReleased = true; return nil
				end
				local lock = type(old) == "table" and old[LOCK]
				if type(lock) ~= "table" or lock.token ~= self.token then reason = "SessionLost"; return nil end
				local nextValue = copy(value)
				nextValue[RECEIPT] = receipt
				if not release then nextValue[LOCK] = {token = self.token, expires = m.now() + m.lease} end
				return nextValue, keyInfo(info, self.userId)
			end)
		end)
		if ok and (alreadyReleased or (type(result) == "table" and result[RECEIPT] == receipt)) then
			success = true
			self.savedRevision = revision -- Changes made during this request remain dirty.
			if release then self.released = true else self.expires = result[LOCK].expires end
			break
		end
		lastError = reason or tostring(result)
		if reason == "SessionLost" then self.lost = true; break end
		if attempt < m.attempts then
			m.wait(math.min(m.retryDelay * 2 ^ (attempt - 1), 4, math.max(0, deadline - m.clock())))
		end
	end
	self.saving = false
	if success then return true end
	return false, lastError
end

return ProfileStore
