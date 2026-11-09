-- Boots qbx_core's server scripts (in fxmanifest order) inside a fake runtime.
local Env = require 'env'

local Boot = {}

local function deepcopy(v)
    if type(v) ~= 'table' then return v end
    local r = {}
    for k, x in pairs(v) do r[k] = deepcopy(x) end
    return setmetatable(r, getmetatable(v))
end
Boot.deepcopy = deepcopy

---@param root string path to a qbx_core checkout
---@param opts table? { convars, db, exports, aces, resourceStates, files = {...}, modules = {...} }
function Boot.core(root, opts)
    opts = opts or {}
    -- json "blobs" are references into this store so decode returns real tables
    local store, nextId = {}, 0
    opts.jsonDecode = function(s) return deepcopy(store[s]) end
    opts.modules = opts.modules or {}
    opts.convars = opts.convars or {}
    opts.convars['inventory:framework'] = 'qbx'
    opts.convars['onesync_enableInfinity'] = '1'
    opts.modules['shared.main'] = opts.modules['shared.main'] or {
        ForceJobDefaultDutyAtLogin = true, Vehicles = {}, VehicleHashes = {}, Locations = {}, Weapons = {},
    }
    opts.modules['modules.logger'] = opts.modules['modules.logger'] or { log = function() end }
    local E = Env.new(root, opts)
    function E.blob(tbl)
        nextId = nextId + 1
        local key = 'blob#' .. nextId
        store[key] = tbl
        return key
    end

    local files = opts.files or {
        'modules/lib.lua',
        'shared/functions.lua',
        'server/main.lua',
        'server/groups.lua',
        'server/functions.lua',
        'server/player.lua',
        'server/events.lua',
        'server/character.lua',
    }
    for _, f in ipairs(files) do E.exec(f) end
    E.run(200)
    return E
end

---Builds a stored character row as returned by `SELECT ... FROM players WHERE citizenid = ?`.
function Boot.playerRow(E, fields)
    fields = fields or {}
    return {
        userId = fields.userId or 1,
        citizenid = fields.citizenid or 'CID00001',
        license = fields.license,
        name = fields.name or 'Tester',
        charinfo = E.blob(fields.charinfo or { firstname = 'Test', lastname = 'Er', cid = 1, phone = '555', account = 'ACC' }),
        money = E.blob(fields.money or { cash = 100, bank = 200, crypto = 0 }),
        job = E.blob(fields.job or { name = 'unemployed', grade = { level = 0 } }),
        gang = E.blob(fields.gang or { name = 'none', grade = { level = 0 } }),
        position = nil,
        metadata = E.blob(fields.metadata or { fingerprint = 'F', walletid = 'W', phonedata = { SerialNumber = 1, InstalledApps = {} } }),
        lastLoggedOutUnix = 0,
    }
end

---Creates an online, logged-in player directly through CheckPlayerData.
function Boot.loadPlayer(E, src, data)
    if not E.players[src] then E.addPlayer(src) end
    local player
    E.call(function()
        player = E.G.CheckPlayerData(src, data or {
            citizenid = 'CID' .. src,
            userId = src,
            charinfo = { firstname = 'A', lastname = 'B', cid = 1, phone = '1', account = '1' },
            metadata = { fingerprint = 'F', walletid = 'W', phonedata = { SerialNumber = 1, InstalledApps = {} } },
        })
    end)
    E.players[src].state.isLoggedIn = true
    return player
end

return Boot
