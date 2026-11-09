-- Minimal CfxLua -> Lua 5.4 source translator for the syntax qbx_core uses:
--   compound assignment  `a.b[c] += expr`
--   safe navigation      `expr?.field`, `expr?[key]`
-- It is deliberately small and only needs to handle qbx_core's own code.
local M = {}

local function translateCompound(line)
    -- skip comment lines
    if line:match('^%s*%-%-') then return line end
    local indent, lhs, op, rhs = line:match('^(%s*)([%w_%.%[%]\'"]+)%s*([%+%-%*/])=%s*(.-)%s*$')
    if indent and not rhs:match('^=') then
        return ('%s%s = %s %s (%s)'):format(indent, lhs, lhs, op, rhs)
    end
    return line
end

-- Find the start index of the suffixed expression that ends at position `stop`.
local function prefixStart(s, stop)
    local i = stop
    while i >= 1 do
        local c = s:sub(i, i)
        if c == ')' or c == ']' then
            local open = c == ')' and '(' or '['
            local depth = 0
            while i >= 1 do
                local ch = s:sub(i, i)
                if ch == c then depth = depth + 1
                elseif ch == open then
                    depth = depth - 1
                    if depth == 0 then break end
                end
                i = i - 1
            end
            i = i - 1
        elseif c:match('[%w_%.:]') then
            i = i - 1
        else
            break
        end
    end
    return i + 1
end

local function translateSafeNav(line)
    while true do
        local q = line:find('?[%.%[]')
        if not q then return line end
        local start = prefixStart(line, q - 1)
        local prefix = line:sub(start, q - 1)
        line = line:sub(1, start - 1) .. '(' .. prefix .. ' or __CFX_EMPTY)' .. line:sub(q + 1)
    end
end

local function translateBackticks(line)
    if line:match('^%s*%-%-') then return line end
    return (line:gsub('==%s*`([%w_]+)`', "== joaat('%1')"))
end

function M.translate(src)
    local out = {}
    for line in (src .. '\n'):gmatch('(.-)\r?\n') do
        line = translateCompound(line)
        line = translateBackticks(line)
        if line:find('?[%.%[]') and not line:match('^%s*%-%-') then
            line = translateSafeNav(line)
        end
        out[#out + 1] = line
    end
    return table.concat(out, '\n')
end

__CFX_EMPTY = setmetatable({}, { __index = function() return nil end, __newindex = function() error('write to nil') end })

return M
