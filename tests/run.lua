-- Usage: lua5.4 run.lua <path-to-qbx_core> [test-name-filter]
local here = arg[0]:gsub('[^/]+$', '')
package.path = here .. '?.lua;' .. package.path

local Boot = require 'boot'
local root = assert(arg[1], 'usage: run.lua <qbx_core path> [filter]')
local filter = arg[2]

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

local function assertEq(actual, expected, msg)
    if actual ~= expected then
        error(('%s: expected %s, got %s'):format(msg or 'assertEq', tostring(expected), tostring(actual)), 2)
    end
end

-- Default DB behaviour shared by most tests.
local function defaultDb(extra)
    local db = {
        single = function(q, p)
            if q:find('COUNT%(%*%) as count') then return { count = 0 } end
            if q:find('information_schema') then return { ['COUNT(*)'] = 1 } end
        end,
        scalar = function(q) if q:find('FROM `users`') then return 1 end end,
        query = function() return {} end,
    }
    for k, v in pairs(extra or {}) do db[k] = v end
    return db
end

local function countEvents(E, name)
    local n = 0
    E.G.AddEventHandler(name, function() n = n + 1 end)
    return function() return n end
end

---------------------------------------------------------------------------
-- 1. Concurrent loadCharacter calls log the same character in twice.
test('login: concurrent loadCharacter requests create only one player', function()
    local E
    E = Boot.core(root, { db = defaultDb({
        single = function(q, p)
            if q:find('FROM players WHERE citizenid') then
                return Boot.playerRow(E, { citizenid = p[1], license = 'license2:bbb1' })
            end
            if q:find('COUNT%(%*%) as count') then return { count = 0 } end
        end,
    }) })
    E.addPlayer(1)
    local loaded = countEvents(E, 'QBCore:Server:PlayerLoaded')
    local cb = E.callbacks['qbx_core:server:loadCharacter']
    E.G.CreateThread(function() cb(1, 'CID00001') end)
    E.G.CreateThread(function() cb(1, 'CID00001') end)
    E.run()
    assertEq(loaded(), 1, 'QBCore:Server:PlayerLoaded fired')
    assertEq(E.globalState.PlayerCount, 1, 'GlobalState.PlayerCount')
end)

-- 2. Concurrent createCharacter calls bypass the character limit and duplicate starter items.
test('createCharacter: concurrent requests cannot exceed the character limit', function()
    local inserted, itemsGiven = 0, 0
    local E
    E = Boot.core(root, {
        resourceStates = { ox_inventory = 'started', qbx_idcard = 'started' },
        exports = { ox_inventory = {
            GetInventory = function() return {} end,
            AddItem = function() itemsGiven = itemsGiven + 1; return true end,
        } },
        db = defaultDb({
            query = function(q)
                if q:find('FROM players WHERE license') then return {} end -- no characters yet
                return {}
            end,
            update = function(q) if q:find('UPDATE players SET') then return 0 end return 1 end,
            insert = function(q) if q:find('INSERT INTO players') then inserted = inserted + 1 end return 1 end,
        }),
    })
    -- limit every account to one character
    E.G.require('config.server').characters.defaultNumberOfCharacters = 1
    E.addPlayer(1)
    local cb = E.callbacks['qbx_core:server:createCharacter']
    local data = { firstname = 'A', lastname = 'B', nationality = 'X', birthdate = '2000-01-01', gender = 0 }
    E.G.CreateThread(function() cb(1, data) end)
    E.G.CreateThread(function() cb(1, data) end)
    E.run()
    assertEq(inserted, 1, 'characters inserted')
    local starterCount = #E.G.require('config.shared').starterItems
    assertEq(itemsGiven, starterCount, 'starter items given')
end)

---------------------------------------------------------------------------
-- 3. Committing jobs to file drops `type` (leo/ems/...) from every job.
test('groups: CreateJob(..., commitToFile) keeps job type in shared/jobs.lua', function()
    local E = Boot.core(root, { db = defaultDb() })
    local ok, err = E.G.CreateJob('testjob', {
        label = 'Test', type = 'leo', defaultDuty = true, offDutyPay = false,
        grades = { [0] = { name = 'Rookie', payment = 10 } },
    }, true)
    assert(ok, err)
    local file = assert(E.savedFiles['shared/jobs.lua'], 'jobs.lua not written')
    local police = file:match("%['police'%] = {(.-)\n    },")
    assert(police, 'police entry missing from written file')
    assert(police:find("type = 'leo'"), "police lost type = 'leo' after commit:\n" .. police)
    -- the written file must load back into the same data
    local reloaded = assert(load(file))()
    assertEq(reloaded.police.type, 'leo', 'reloaded police.type')
    assertEq(reloaded.testjob.grades[0].payment, 10, 'reloaded testjob payment')
end)

test('groups: commitToFile does not crash on a grade without payment', function()
    local E = Boot.core(root, { db = defaultDb() })
    local ok, err = pcall(E.G.CreateJob, 'nopay', {
        label = 'No pay', defaultDuty = true, offDutyPay = false,
        grades = { [0] = { name = 'Volunteer' } },
    }, true)
    assert(ok, 'CreateJob threw: ' .. tostring(err))
end)

---------------------------------------------------------------------------
-- 4. A player whose stored job no longer exists keeps the deleted job name.
test('CheckPlayerData: removed job falls back to unemployed name, not just its label', function()
    local E = Boot.core(root, { db = defaultDb() })
    local player = Boot.loadPlayer(E, 1, {
        citizenid = 'CID1', userId = 1,
        charinfo = { firstname = 'A', lastname = 'B', cid = 1, phone = '1', account = '1' },
        metadata = { fingerprint = 'F', walletid = 'W', phonedata = { SerialNumber = 1, InstalledApps = {} } },
        job = { name = 'deletedjob', grade = { level = 3 } },
        gang = { name = 'deletedgang', grade = { level = 2 } },
    })
    assertEq(player.PlayerData.job.name, 'unemployed', 'job.name')
    assertEq(player.PlayerData.gang.name, 'none', 'gang.name')
end)

test('CheckPlayerData: gang grade removed from config does not break login', function()
    local E = Boot.core(root, { db = defaultDb() })
    local ok, err = pcall(Boot.loadPlayer, E, 1, {
        citizenid = 'CID1', userId = 1,
        charinfo = { firstname = 'A', lastname = 'B', cid = 1, phone = '1', account = '1' },
        metadata = { fingerprint = 'F', walletid = 'W', phonedata = { SerialNumber = 1, InstalledApps = {} } },
        gang = { name = 'ballas', grade = { level = 99 } },
    })
    assert(ok, 'login crashed: ' .. tostring(err))
end)

---------------------------------------------------------------------------
-- 5. Removing a boss grade at runtime leaves the player with boss/bank rights.
test('onJobUpdate: removing the player\'s grade revokes isboss and bankAuth', function()
    local E = Boot.core(root, { db = defaultDb() })
    local player = Boot.loadPlayer(E, 1, {
        citizenid = 'CID1', userId = 1,
        charinfo = { firstname = 'A', lastname = 'B', cid = 1, phone = '1', account = '1' },
        metadata = { fingerprint = 'F', walletid = 'W', phonedata = { SerialNumber = 1, InstalledApps = {} } },
        job = { name = 'police', grade = { level = 4 } },
    })
    assertEq(player.PlayerData.job.isboss, true, 'precondition isboss')
    E.exportsMap.RemoveJobGrade('police', 4)
    assertEq(player.PlayerData.job.isboss, false, 'isboss after grade removal')
    assertEq(player.PlayerData.job.bankAuth, false, 'bankAuth after grade removal')
end)

---------------------------------------------------------------------------
-- 6. Player_Buckets is keyed by source but cleared by license on drop.
test('buckets: dropped players are removed from Player_Buckets', function()
    local E = Boot.core(root, { db = defaultDb() })
    Boot.loadPlayer(E, 1)
    E.G.SetPlayerBucket(1, 5)
    assertEq(#E.G.GetPlayersInBucket(5), 1, 'precondition')
    E.call(function() E.serverEvent(1, 'playerDropped', 'quit') end)
    E.players[1] = nil
    assertEq(#E.G.GetPlayersInBucket(5), 0, 'players still listed in bucket 5 after drop')
end)

---------------------------------------------------------------------------
-- 7. Any client can rewrite the saved props of any persisted vehicle.
local function persistenceEnv(saved)
    local E = Boot.core(root, {
        db = defaultDb(),
        convars = { ['qbx:enableVehiclePersistence'] = 'true' },
        exports = { qbx_vehicles = {
            GetVehicleIdByPlate = function() return 7 end,
            GetPlayerVehicle = function() return { props = { plate = 'ABC', fuelLevel = 50.0 } } end,
            SaveVehicle = function(_, data) saved[#saved + 1] = data end,
        } },
        files = { 'modules/lib.lua', 'shared/functions.lua', 'server/main.lua', 'server/groups.lua', 'server/functions.lua',
            'server/player.lua', 'server/events.lua', 'server/vehicle-persistence.lua' },
    })
    E.entities[500] = { coords = { x = 0.0, y = 0.0, z = 0.0 }, state = { persisted = true }, plate = 'ABC' }
    E.netIds = { [55] = 500 }
    return E
end

test('vehicle persistence: far-away client cannot rewrite a vehicle\'s props', function()
    local saved = {}
    local E = persistenceEnv(saved)
    E.addPlayer(2, { coords = { x = 4000.0, y = 4000.0, z = 0.0 } }) -- nowhere near the car
    E.clientEvent(2, 'qbx_core:server:vehiclePropsChanged', 55, { fuelLevel = 0.0 })
    E.run()
    assertEq(#saved, 0, 'SaveVehicle calls from a client 5km away')
end)

test('vehicle persistence: invalid prop values are rejected', function()
    local saved = {}
    local E = persistenceEnv(saved)
    E.addPlayer(2, { coords = { x = 1.0, y = 1.0, z = 0.0 } })
    local huge = {}
    for i = 1, 10000 do huge[i] = ('x'):rep(100) end
    E.clientEvent(2, 'qbx_core:server:vehiclePropsChanged', 55, { fuelLevel = -1e308, windows = huge })
    E.run()
    local props = saved[1] and saved[1].props
    assert(not props or (props.fuelLevel == 50.0 and props.windows == nil),
        ('garbage persisted: fuelLevel=%s windows=%s'):format(props and props.fuelLevel, props and props.windows and #props.windows))
end)

test('vehicle persistence: nearby driver update is still saved', function()
    local saved = {}
    local E = persistenceEnv(saved)
    E.addPlayer(2, { coords = { x = 3.0, y = 0.0, z = 0.0 } }) -- just stepped out
    E.clientEvent(2, 'qbx_core:server:vehiclePropsChanged', 55, { fuelLevel = 42.5, doors = { 0, 1 }, tyres = { [0] = 1 } })
    E.run()
    assertEq(#saved, 1, 'legit update saved')
    assertEq(saved[1].props.fuelLevel, 42.5, 'fuel')
end)

---------------------------------------------------------------------------
-- 8. Banned players are still put in the queue after being rejected.
test('connecting: banned player is not placed in the queue', function()
    local queued = 0
    local E = Boot.core(root, {
        db = defaultDb({
            single = function(q)
                if q:find('FROM bans') then return { expire = 2000000000, reason = 'cheating' } end
            end,
        }),
        modules = { ['server.queue'] = {
            awaitPlayerQueue = function(_, _, deferrals) queued = queued + 1; deferrals.done() end,
            removePlayerJoining = function() end,
        } },
    })
    E.addPlayer(9)
    local doneCalls = {}
    local deferrals = {
        defer = function() end,
        update = function() end,
        presentCard = function() end,
        done = function(reason) doneCalls[#doneCalls + 1] = reason or '<accepted>' end,
    }
    E.clientEvent(9, 'playerConnecting', 'Banned Guy', nil, deferrals)
    E.run()
    assertEq(queued, 0, 'banned player entered the queue')
    assertEq(doneCalls[1] and doneCalls[1]:find('cheating') ~= nil, true, 'rejected with ban reason')
end)

---------------------------------------------------------------------------
-- 9. AddJobReputation errors for any job other than tow/trucker/taxi/hotdog.
test('AddJobReputation: works for jobs without a pre-seeded jobrep entry', function()
    local E = Boot.core(root, { db = defaultDb() })
    local player = Boot.loadPlayer(E, 1, {
        citizenid = 'CID1', userId = 1,
        charinfo = { firstname = 'A', lastname = 'B', cid = 1, phone = '1', account = '1' },
        metadata = { fingerprint = 'F', walletid = 'W', phonedata = { SerialNumber = 1, InstalledApps = {} } },
        job = { name = 'mechanic', grade = { level = 0 } },
    })
    local ok, err = pcall(player.Functions.AddJobReputation, 5)
    assert(ok, 'AddJobReputation threw: ' .. tostring(err))
    assertEq(player.PlayerData.metadata.jobrep.mechanic, 5, 'jobrep.mechanic')
end)

-- 10. Group helpers throw for sources that have not loaded a character yet.
test('HasGroup/HasPrimaryGroup/GetGroups: safe for players without a character', function()
    local E = Boot.core(root, { db = defaultDb() })
    E.addPlayer(3) -- connected, still in character select
    for _, fn in ipairs({ 'HasGroup', 'HasPrimaryGroup' }) do
        local ok, res = pcall(E.exportsMap[fn], 3, 'police')
        assert(ok, fn .. ' threw: ' .. tostring(res))
        assertEq(res, false, fn)
    end
    local ok, res = pcall(E.exportsMap.GetGroups, 3)
    assert(ok, 'GetGroups threw: ' .. tostring(res))
end)

-- 11. Save() dereferences the player before its own nil check.
test('Save: unknown source logs an error instead of throwing', function()
    local E = Boot.core(root, { db = defaultDb() })
    E.addPlayer(4)
    local ok, err = pcall(E.exportsMap.Save, 4)
    assert(ok, 'Save threw: ' .. tostring(err))
end)

-- 12. SearchPlayers with no usable filter builds "... WHERE " (SQL syntax error).
test('SearchPlayers: empty filters produce valid SQL', function()
    local E = Boot.core(root, { db = defaultDb() })
    E.call(function() E.exportsMap.SearchPlayers({}) end)
    local last
    for _, q in ipairs(E.queries) do if q.query:find('SELECT citizenid FROM players') then last = q.query end end
    assert(last, 'no search query issued')
    assert(not last:match('WHERE%s*$'), 'invalid SQL: "' .. last .. '"')
end)

-- 13. A job row whose name only exists as a gang is accepted as a job.
test('fetchPlayerGroups: job rows are only validated against jobs', function()
    local E = Boot.core(root, { db = defaultDb({
        query = function(q)
            if q:find('FROM player_groups WHERE citizenid') then
                return { { group = 'ballas', type = 'job', grade = 0 } } -- stale row: no job called ballas
            end
            return {}
        end,
    }) })
    local storage = E.G.require('server.storage.main')
    local jobs
    E.call(function() jobs = storage.fetchPlayerGroups('CID1') end)
    assertEq(jobs.ballas, nil, 'gang name accepted as a job')
end)

-- 14. SetPlayerBucket accepts a missing bucket because of an inverted guard.
test('SetPlayerBucket: rejects a nil bucket', function()
    local E = Boot.core(root, { db = defaultDb() })
    E.addPlayer(1)
    assertEq(E.G.SetPlayerBucket(1, nil), false, 'SetPlayerBucket(1, nil)')
end)

---------------------------------------------------------------------------
-- Non-regression: normal flows must keep working after the fixes.
test('regression: a single loadCharacter still logs the player in', function()
    local E
    E = Boot.core(root, { db = defaultDb({
        single = function(q, p)
            if q:find('FROM players WHERE citizenid') then
                return Boot.playerRow(E, { citizenid = p[1], license = 'license2:bbb1', job = { name = 'police', grade = { level = 2 } } })
            end
            if q:find('COUNT%(%*%) as count') then return { count = 0 } end
        end,
    }) })
    E.addPlayer(1)
    local loaded = countEvents(E, 'QBCore:Server:PlayerLoaded')
    E.call(E.callbacks['qbx_core:server:loadCharacter'], 1, 'CID00001')
    assertEq(loaded(), 1, 'PlayerLoaded')
    local player = E.G.GetPlayer(1)
    assertEq(player.PlayerData.job.name, 'police', 'valid job kept')
    assertEq(player.PlayerData.job.grade.level, 2, 'valid grade kept')
    assertEq(#E.dropped, 0, 'nobody dropped')
end)

test('regression: logging in again after a completed login is still refused', function()
    local E
    E = Boot.core(root, { db = defaultDb({
        single = function(q, p)
            if q:find('FROM players WHERE citizenid') then
                return Boot.playerRow(E, { citizenid = p[1], license = 'license2:bbb1' })
            end
            if q:find('COUNT%(%*%) as count') then return { count = 0 } end
        end,
    }) })
    E.addPlayer(1)
    E.call(E.callbacks['qbx_core:server:loadCharacter'], 1, 'CID00001')
    E.call(E.callbacks['qbx_core:server:loadCharacter'], 1, 'CID00001')
    assertEq(#E.dropped, 1, 'second login dropped')
    assertEq(E.globalState.PlayerCount, 1, 'PlayerCount')
end)

test('regression: a character can still be created and the lock is released', function()
    local inserted = 0
    local E = Boot.core(root, {
        resourceStates = { ox_inventory = 'started', qbx_idcard = 'started' },
        exports = { ox_inventory = { GetInventory = function() return {} end, AddItem = function() return true end } },
        db = defaultDb({
            update = function(q) if q:find('UPDATE players SET') then return 0 end return 1 end,
            insert = function(q) if q:find('INSERT INTO players') then inserted = inserted + 1 end return 1 end,
        }),
    })
    E.addPlayer(1)
    local data = { firstname = 'A', lastname = 'B', nationality = 'X', birthdate = '2000-01-01', gender = 0 }
    local result = E.call(E.callbacks['qbx_core:server:createCharacter'], 1, { firstname = 1 })
    assertEq(result, nil, 'invalid data refused')
    result = E.call(E.callbacks['qbx_core:server:createCharacter'], 1, data)
    assert(result, 'valid character refused after an earlier invalid request')
    assertEq(inserted, 1, 'inserted')
end)

test('regression: a player who is not banned is still queued', function()
    local queued = 0
    local E = Boot.core(root, {
        db = defaultDb(),
        modules = { ['server.queue'] = {
            awaitPlayerQueue = function(_, _, deferrals) queued = queued + 1; deferrals.done() end,
            removePlayerJoining = function() end,
        } },
    })
    E.addPlayer(9)
    local deferrals = { defer = function() end, update = function() end, presentCard = function() end, done = function() end }
    E.clientEvent(9, 'playerConnecting', 'Fine Guy', nil, deferrals)
    E.run()
    assertEq(queued, 1, 'queued')
end)

test('regression: HasGroup still works for loaded players', function()
    local E = Boot.core(root, { db = defaultDb({
        query = function(q)
            if q:find('FROM player_groups WHERE citizenid') then return { { group = 'police', type = 'job', grade = 1 } } end
            return {}
        end,
    }) })
    Boot.loadPlayer(E, 1, {
        citizenid = 'CID1', userId = 1,
        charinfo = { firstname = 'A', lastname = 'B', cid = 1, phone = '1', account = '1' },
        metadata = { fingerprint = 'F', walletid = 'W', phonedata = { SerialNumber = 1, InstalledApps = {} } },
        job = { name = 'police', grade = { level = 1 } },
    })
    assertEq(E.exportsMap.HasGroup(1, 'police'), true, 'HasGroup police')
    assertEq(E.exportsMap.HasGroup(1, 'ambulance'), false, 'HasGroup ambulance')
    assertEq(E.exportsMap.GetGroups(1).police, 1, 'GetGroups police')
end)

test('regression: SearchPlayers with a filter still builds a WHERE clause', function()
    local E = Boot.core(root, { db = defaultDb() })
    E.call(function() E.exportsMap.SearchPlayers({ job = 'police' }) end)
    local last
    for _, q in ipairs(E.queries) do if q.query:find('SELECT citizenid FROM players') then last = q.query end end
    assert(last and last:find('WHERE JSON_EXTRACT%(job'), 'missing WHERE: ' .. tostring(last))
end)

test('regression: removed job grade for a non-boss keeps the player in the job', function()
    local E = Boot.core(root, { db = defaultDb() })
    local player = Boot.loadPlayer(E, 1, {
        citizenid = 'CID1', userId = 1,
        charinfo = { firstname = 'A', lastname = 'B', cid = 1, phone = '1', account = '1' },
        metadata = { fingerprint = 'F', walletid = 'W', phonedata = { SerialNumber = 1, InstalledApps = {} } },
        job = { name = 'police', grade = { level = 1 } },
    })
    E.exportsMap.UpsertJobGrade('police', 1, { name = 'Officer II', payment = 80 })
    assertEq(player.PlayerData.job.name, 'police', 'job name')
    assertEq(player.PlayerData.job.grade.name, 'Officer II', 'grade renamed')
    assertEq(player.PlayerData.job.payment, 80, 'payment updated')
end)

---------------------------------------------------------------------------
local passed, failed = 0, 0
for _, t in ipairs(tests) do
    if not filter or t.name:find(filter, 1, true) then
        local ok, err = pcall(t.fn)
        if ok then
            passed = passed + 1
            print('PASS  ' .. t.name)
        else
            failed = failed + 1
            print('FAIL  ' .. t.name .. '\n      ' .. tostring(err):gsub('\n', '\n      '))
        end
    end
end
print(('\n%d passed, %d failed'):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
