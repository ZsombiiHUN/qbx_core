-- Fake FiveM server runtime (natives, scheduler, oxmysql, ox_lib) for running
-- unmodified qbx_core server files under stock Lua 5.4.
local cfx = require 'cfx'

local Env = {}

function Env.new(root, opts)
    opts = opts or {}
    local E = {
        root = root,
        threads = {},
        events = {},          -- name -> { handlers }
        netEvents = {},       -- name -> true
        callbacks = {},       -- lib.callback.register
        exportsMap = {},      -- qbx_core exports
        dropped = {},         -- { {src, reason} }
        clientEvents = {},    -- { {name, target, ...} }
        savedFiles = {},      -- SaveResourceFile
        players = {},         -- src -> { name, identifiers = {}, ped, state = {} }
        entities = {},        -- entity -> { coords, state = {}, bucket, ... }
        convars = opts.convars or {},
        db = opts.db or {},   -- handler table for MySQL
        prints = {},
        now = 0,
    }

    local G = setmetatable({}, { __index = _G })
    G._G = G
    E.G = G

    ---------------------------------------------------------------- scheduler
    function G.CreateThread(fn)
        local co = coroutine.create(fn)
        E.threads[#E.threads + 1] = co
    end
    G.Citizen = { CreateThread = G.CreateThread }
    function G.Wait(ms)
        E.now = E.now + (ms or 0)
        if coroutine.isyieldable() then coroutine.yield() end
    end
    G.Citizen.Wait = G.Wait
    function G.GetGameTimer() return E.now end

    -- Runs every queued thread until all finish (or maxSteps is hit, for infinite loops).
    function E.run(maxSteps)
        maxSteps = maxSteps or 10000
        local steps = 0
        while #E.threads > 0 and steps < maxSteps do
            steps = steps + 1
            local co = table.remove(E.threads, 1)
            local ok, err = coroutine.resume(co)
            if not ok then
                E.errors = E.errors or {}
                E.errors[#E.errors + 1] = debug.traceback(co, tostring(err))
            elseif coroutine.status(co) ~= 'dead' then
                E.threads[#E.threads + 1] = co
            end
        end
    end

    -- Runs fn inside a thread and returns its results after the scheduler drains.
    function E.call(fn, ...)
        local args = table.pack(...)
        local res
        G.CreateThread(function()
            res = table.pack(pcall(fn, table.unpack(args, 1, args.n)))
        end)
        E.run()
        if not res then error('thread did not finish', 2) end
        if not res[1] then error(res[2], 0) end
        return table.unpack(res, 2, res.n)
    end

    ---------------------------------------------------------------- promise
    local promise = {}
    promise.__index = promise
    function promise.new()
        return setmetatable({ state = 0, cbs = {} }, promise)
    end
    function promise:resolve(v)
        if self.state ~= 0 then return end
        self.state, self.value = 1, v
        for _, cb in ipairs(self.cbs) do cb() end
    end
    function promise:reject(e)
        if self.state ~= 0 then return end
        self.state, self.value = 2, e
        for _, cb in ipairs(self.cbs) do cb() end
    end
    function promise:next(onOk, onErr)
        local p = promise.new()
        local function fire()
            G.CreateThread(function()
                if self.state == 1 then
                    local ok, r = pcall(onOk or function(v) return v end, self.value)
                    if ok then p:resolve(r) else p:reject(r) end
                else
                    if onErr then
                        local ok, r = pcall(onErr, self.value)
                        if ok then p:resolve(r) else p:reject(r) end
                    else p:reject(self.value) end
                end
            end)
        end
        if self.state ~= 0 then fire() else self.cbs[#self.cbs + 1] = fire end
        return p
    end
    G.promise = promise
    function G.Citizen.Await(p)
        while p.state == 0 do G.Wait(0) end
        if p.state == 2 then error(p.value) end
        return p.value
    end

    ---------------------------------------------------------------- events
    G.source = nil
    function G.AddEventHandler(name, fn)
        E.events[name] = E.events[name] or {}
        table.insert(E.events[name], fn)
        return { name = name, fn = fn }
    end
    function G.RegisterNetEvent(name, fn)
        E.netEvents[name] = true
        if fn then return G.AddEventHandler(name, fn) end
    end
    G.RegisterServerEvent = G.RegisterNetEvent
    function G.RemoveEventHandler() end
    function G.CancelEvent() end
    local function dispatch(name, src, ...)
        local hs = E.events[name]
        if not hs then return end
        for _, fn in ipairs(hs) do
            local prev = G.source
            G.source = src
            fn(...)
            G.source = prev
        end
    end
    function G.TriggerEvent(name, ...) dispatch(name, nil, ...) end
    -- Simulates a client sending a net event (runs in its own thread, like FiveM).
    function E.clientEvent(src, name, ...)
        local args = table.pack(...)
        G.CreateThread(function()
            G.source = src
            dispatch(name, src, table.unpack(args, 1, args.n))
        end)
    end
    function E.serverEvent(src, name, ...) dispatch(name, src, ...) end
    function G.TriggerClientEvent(name, target, ...)
        E.clientEvents[#E.clientEvents + 1] = { name = name, target = target, args = table.pack(...) }
    end
    function E.clientEventsNamed(name)
        local r = {}
        for _, e in ipairs(E.clientEvents) do if e.name == name then r[#r + 1] = e end end
        return r
    end
    function G.AddStateBagChangeHandler() end
    function G.GetPlayerFromStateBagName() end

    ---------------------------------------------------------------- exports
    local exportsMt = {}
    exportsMt.__call = function(_, name, fn) E.exportsMap[name] = fn end
    exportsMt.__index = function(_, resource)
        if resource == 'qbx_core' or resource == (G.cache and G.cache.resource) then
            return setmetatable({}, { __index = function(_, fname)
                return function(_, ...) return E.exportsMap[fname](...) end
            end })
        end
        local mock = (opts.exports or {})[resource] or {}
        return setmetatable({}, { __index = function(_, fname)
            return function(_, ...)
                if mock[fname] then return mock[fname](...) end
            end
        end })
    end
    G.exports = setmetatable({}, exportsMt)

    ---------------------------------------------------------------- players / natives
    E.globalState = {}
    G.GlobalState = E.globalState
    G.IsDuplicityVersion = function() return true end
    G.GetCurrentResourceName = function() return 'qbx_core' end
    G.GetInvokingResource = function() return nil end
    G.GetResourceState = function(name) return (opts.resourceStates or {})[name] or 'missing' end
    G.GetResourceMetadata = function() return '1.0.0' end
    G.GetConvar = function(k, d) local v = E.convars[k]; if v == nil then return d end return v end
    G.GetConvarInt = function(k, d) return tonumber(E.convars[k]) or d end
    G.SetRoutingBucketEntityLockdownMode = function() end
    G.ExecuteCommand = function() end
    G.RegisterCommand = function() end
    G.SetConvarReplicated = function() end
    G.SaveResourceFile = function(res, path, content) E.savedFiles[path] = content; return true end
    G.LoadResourceFile = function(res, path)
        local f = io.open(root .. '/' .. path); if not f then return nil end
        local s = f:read('a'); f:close(); return s
    end
    G.joaat = function(s) local h = 0; for i = 1, #tostring(s) do h = (h * 31 + tostring(s):byte(i)) % 4294967296 end return h end
    G.GetHashKey = G.joaat

    function E.addPlayer(src, p)
        p = p or {}
        local idents = p.identifiers or { license = 'license:aaa' .. src, license2 = 'license2:bbb' .. src, discord = 'discord:' .. src }
        E.players[src] = { name = p.name or ('Player' .. src), identifiers = idents, ped = 1000 + src, state = {}, bucket = 0 }
        E.entities[1000 + src] = { coords = p.coords or { x = 0.0, y = 0.0, z = 0.0 }, heading = 0.0, state = {}, health = 200, armour = 0 }
        return E.players[src]
    end
    local function P(src) return E.players[tonumber(src)] end
    G.GetPlayerName = function(src) return P(src) and P(src).name end
    G.GetPlayerIdentifierByType = function(src, t) return P(src) and P(src).identifiers[t] end
    G.GetNumPlayerIdentifiers = function(src)
        local n = 0; for _ in pairs(P(src) and P(src).identifiers or {}) do n = n + 1 end; return n
    end
    G.GetPlayerIdentifier = function(src, i)
        local list = {}; for _, v in pairs(P(src).identifiers) do list[#list + 1] = v end
        table.sort(list); return list[i + 1]
    end
    G.GetPlayerIdentifiers = function(src)
        local list = {}; for _, v in pairs(P(src).identifiers) do list[#list + 1] = v end; return list
    end
    G.GetPlayers = function() local r = {}; for s in pairs(E.players) do r[#r + 1] = tostring(s) end; return r end
    G.GetNumPlayerIndices = function() local n = 0; for _ in pairs(E.players) do n = n + 1 end; return n end
    G.DoesPlayerExist = function(src) return P(src) ~= nil end
    G.DropPlayer = function(src, reason) E.dropped[#E.dropped + 1] = { src = tonumber(src), reason = reason } end
    G.IsPlayerAceAllowed = function(src, ace) return ((opts.aces or {})[tonumber(src)] or {})[ace] or false end
    G.GetPlayerPed = function(src) return P(src) and P(src).ped or 0 end
    G.GetPlayerRoutingBucket = function(src) return P(src) and P(src).bucket or 0 end
    G.SetPlayerRoutingBucket = function(src, b) if P(src) then P(src).bucket = b end end
    G.SetEntityRoutingBucket = function(e, b) if E.entities[e] then E.entities[e].bucket = b end end
    G.GetEntityRoutingBucket = function(e) return E.entities[e] and E.entities[e].bucket or 0 end
    G.DoesEntityExist = function(e) return E.entities[e] ~= nil end
    G.GetEntityCoords = function(e)
        local c = E.entities[e] and E.entities[e].coords or { x = 0.0, y = 0.0, z = 0.0 }
        return G.vec3(c.x, c.y, c.z)
    end
    G.GetEntityHeading = function(e) return E.entities[e] and E.entities[e].heading or 0.0 end
    G.GetEntityHealth = function(e) return E.entities[e] and E.entities[e].health or 0 end
    G.GetPedArmour = function(e) return E.entities[e] and E.entities[e].armour or 0 end
    G.SetPedArmour = function() end
    G.NetworkGetEntityFromNetworkId = function(netId) return (E.netIds or {})[netId] or 0 end
    G.GetVehicleBodyHealth = function(e) return E.entities[e] and E.entities[e].bodyHealth or 1000.0 end
    G.GetVehicleEngineHealth = function(e) return E.entities[e] and E.entities[e].engineHealth or 1000.0 end
    G.GetVehiclePetrolTankHealth = function() return 1000.0 end
    G.GetVehicleDirtLevel = function() return 0.0 end
    G.GetVehicleNumberPlateText = function(e) return E.entities[e] and E.entities[e].plate or '' end
    G.GetVehicleType = function() return 'automobile' end
    G.GetGamePool = function() return {} end

    local function stateBag(store)
        return setmetatable({}, {
            __index = function(_, k)
                if k == 'set' then return function(_, key, value) store[key] = value end end
                return store[k]
            end,
            __newindex = function(_, k, v) store[k] = v end,
        })
    end
    G.Player = function(src)
        local p = P(src)
        if not p then return nil end
        return { state = stateBag(p.state) }
    end
    G.Entity = function(e)
        E.entities[e] = E.entities[e] or { state = {} }
        return { state = stateBag(E.entities[e].state) }
    end

    ---------------------------------------------------------------- vectors
    local vmt = {}
    vmt.__index = vmt
    vmt.__sub = function(a, b) return G.vec3(a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)) end
    vmt.__len = function(a) return math.sqrt(a.x * a.x + a.y * a.y + (a.z or 0) * (a.z or 0)) end
    function G.vec3(x, y, z) return setmetatable({ x = x, y = y, z = z }, vmt) end
    function G.vec4(x, y, z, w) return setmetatable({ x = x, y = y, z = z, w = w, xyz = G.vec3(x, y, z) }, vmt) end
    G.vector3, G.vector4 = G.vec3, G.vec4
    function G.vec2(x, y) return { x = x, y = y } end

    ---------------------------------------------------------------- json
    local function encode(v, seen)
        local t = type(v)
        if t == 'nil' then return 'null'
        elseif t == 'boolean' or t == 'number' then return tostring(v)
        elseif t == 'string' then return '"' .. v:gsub('[%c"\\]', function(c) return string.format('\\u%04x', c:byte()) end) .. '"'
        elseif t == 'table' then
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            local parts = {}
            for _, k in ipairs(keys) do
                if type(v[k]) ~= 'function' then
                    parts[#parts + 1] = encode(tostring(k)) .. ':' .. encode(v[k])
                end
            end
            return '{' .. table.concat(parts, ',') .. '}'
        end
        return 'null'
    end
    local function decodeJson(str)
        local pos = 1
        local function ws() pos = str:find('[^%s]', pos) or #str + 1 end
        local val
        local function parseString()
            local out, i = {}, pos + 1
            while true do
                local c = str:sub(i, i)
                if c == '"' then pos = i + 1; return table.concat(out) end
                if c == '\\' then i = i + 1; c = str:sub(i, i) end
                out[#out + 1] = c; i = i + 1
            end
        end
        function val()
            ws()
            local c = str:sub(pos, pos)
            if c == '{' then
                local t = {}; pos = pos + 1; ws()
                if str:sub(pos, pos) == '}' then pos = pos + 1; return t end
                while true do
                    ws(); local k = parseString(); ws(); pos = pos + 1
                    t[k] = val(); ws()
                    local d = str:sub(pos, pos); pos = pos + 1
                    if d == '}' then return t end
                end
            elseif c == '[' then
                local t = {}; pos = pos + 1; ws()
                if str:sub(pos, pos) == ']' then pos = pos + 1; return t end
                while true do
                    t[#t + 1] = val(); ws()
                    local d = str:sub(pos, pos); pos = pos + 1
                    if d == ']' then return t end
                end
            elseif c == '"' then return parseString()
            elseif str:sub(pos, pos + 3) == 'true' then pos = pos + 4; return true
            elseif str:sub(pos, pos + 4) == 'false' then pos = pos + 5; return false
            elseif str:sub(pos, pos + 3) == 'null' then pos = pos + 4; return nil
            else
                local num = str:match('^-?[%d%.eE+-]+', pos); pos = pos + #num; return tonumber(num)
            end
        end
        return val()
    end
    G.json = { encode = encode, decode = function(s)
        if opts.jsonDecode then
            local v = opts.jsonDecode(s)
            if v ~= nil then return v end
        end
        if type(s) ~= 'string' then return nil end
        return decodeJson(s)
    end }

    ---------------------------------------------------------------- table/math/os extensions
    G.table = setmetatable({
        create = function() return {} end,
        type = function(t)
            if type(t) ~= 'table' then return false end
            local n = #t
            local count = 0
            for _ in pairs(t) do count = count + 1 end
            if count == 0 then return 'empty' end
            if count == n then return 'array' end
            if n == 0 then return 'hash' end
            return 'mixed'
        end,
    }, { __index = table })
    G.os = setmetatable({ microtime = function() return 0 end, time = function() return 1700000000 end }, { __index = os })

    ---------------------------------------------------------------- oxmysql
    -- Every await yields once, like a real async DB round trip.
    local function dbCall(kind)
        return function(query, params)
            G.Wait(0)
            E.queries = E.queries or {}
            E.queries[#E.queries + 1] = { kind = kind, query = query, params = params }
            local h = E.db[kind]
            if h then return h(query, params) end
            if kind == 'single' then return nil end
            if kind == 'query' then return {} end
            if kind == 'scalar' then return nil end
            if kind == 'update' then return 1 end
            if kind == 'insert' then return 1 end
            if kind == 'transaction' then return true end
        end
    end
    G.MySQL = {}
    for _, kind in ipairs({ 'query', 'single', 'scalar', 'insert', 'update', 'transaction', 'prepare' }) do
        G.MySQL[kind] = setmetatable({ await = dbCall(kind) }, { __call = function(_, q, p) E.queries = E.queries or {}; E.queries[#E.queries + 1] = { kind = kind, query = q, params = p } end })
    end

    ---------------------------------------------------------------- ox_lib
    local lib = {}
    lib.print = setmetatable({}, { __index = function(_, level)
        return function(...)
            local parts = {}
            for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
            E.prints[#E.prints + 1] = level .. ': ' .. table.concat(parts, ' ')
        end
    end })
    lib.versionCheck = function() end
    lib.checkDependency = function() return true end
    lib.callback = setmetatable({
        register = function(name, fn) E.callbacks[name] = fn end,
        await = function() return nil end,
    }, { __call = function() end })
    lib.addCommand = function() end
    lib.addPrincipal = function() end
    lib.removePrincipal = function() end
    lib.addAce = function() end
    lib.removeAce = function() end
    lib.math = { clamp = function(v, lo, hi) return math.min(math.max(v, lo), hi) end }
    lib.table = {
        freeze = function(t) return t end,
        matches = function(a, b) return encode(a) == encode(b) end,
        merge = function(a, b) for k, v in pairs(b) do a[k] = v end return a end,
        deepclone = function(t) return t end,
    }
    lib.string = { random = function(p) return p end }
    lib.waitFor = function(cb, msg, timeout)
        local start = E.now
        while true do
            local r = cb()
            if r then return r end
            if E.now - start > (timeout or 1000) then error(msg or 'timed out', 2) end
            G.Wait(100)
        end
    end
    lib.onCache = function() end
    G.lib = lib
    G.cache = { resource = 'qbx_core' }
    G.locale = function(key, ...) return key end
    G.warn = function(msg) E.prints[#E.prints + 1] = 'warn: ' .. tostring(msg) end

    ---------------------------------------------------------------- require / loading
    local loaded = {}
    function E.loadFile(path)
        local f = assert(io.open(root .. '/' .. path), 'missing file ' .. path)
        local src = f:read('a'); f:close()
        local fn = assert(load(cfx.translate(src), '@' .. path, 't', G))
        return fn
    end
    E.moduleOverrides = opts.modules or {}
    function G.require(name)
        if E.moduleOverrides[name] ~= nil then return E.moduleOverrides[name] end
        if loaded[name] ~= nil then return loaded[name] end
        local path = name:gsub('%.', '/') .. '.lua'
        local res = E.loadFile(path)()
        if res == nil then res = true end
        loaded[name] = res
        return res
    end

    function E.exec(path)
        local fn = E.loadFile(path)
        local ok, err = pcall(fn)
        if not ok then error(('loading %s: %s'):format(path, err), 0) end
    end

    return E
end

return Env
