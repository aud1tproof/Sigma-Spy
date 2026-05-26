--[[
    Parser Module
    Drop-in replacement for the original, inferred from Generation.lua usage.
    
    API surface:
        ParserModule:Load()
        ParserModule:New({ VariableBase, Swaps, IndexFunc }) -> Module
        Module.Formatter:Format(value, opts?)
        Module.Formatter:MakeName(instance)
        Module.Variables:PrerenderVariables(table, classFilter)
        Module.Variables:MakeVariable({ Value, Comment, Lookup, Name, Class })
        Module.Parser:ParseTableIntoString({ Table, NoBrackets? }) -> string, count
        Module.Parser:MakeVariableCode({ ...classNames })
]]

local ParserModule = {}
ParserModule.__index = ParserModule

-- ============================================================
-- Utilities
-- ============================================================

local KEYWORDS = {
    ["and"]=1,["break"]=1,["do"]=1,["else"]=1,["elseif"]=1,
    ["end"]=1,["false"]=1,["for"]=1,["function"]=1,["if"]=1,
    ["in"]=1,["local"]=1,["nil"]=1,["not"]=1,["or"]=1,
    ["repeat"]=1,["return"]=1,["then"]=1,["true"]=1,
    ["until"]=1,["while"]=1,
}

local function isValidIdent(s)
    return type(s) == "string"
        and s:match("^[%a_][%w_]*$") ~= nil
        and not KEYWORDS[s]
end

local function sanitizeName(name)
    if type(name) ~= "string" then name = tostring(name) end
    name = name:gsub("[^%w_]", "_")
    if name:match("^%d") then name = "_" .. name end
    return name ~= "" and name or "var"
end

-- ============================================================
-- Formatter
-- Converts any Roblox value into its Lua source representation.
-- ============================================================

local Formatter = {}
Formatter.__index = Formatter

function Formatter.new(ctx)
    return setmetatable({ _ctx = ctx }, Formatter)
end

function Formatter:MakeName(instance)
    local name = self._ctx.IndexFunc(instance, "Name")
    return sanitizeName(name)
end

-- Walks up the instance tree to build a full access path string.
-- noCreate=true means don't touch the variable registry (used for
-- generating the right-hand side of a variable's own declaration).
function Formatter:_buildPath(instance, noCreate)
    local ctx = self._ctx

    -- Swaps take highest priority
    if ctx.Swaps[instance] then
        local s = ctx.Swaps[instance]
        return s.Code or s.Path or tostring(instance)
    end

    -- Already registered as a variable?
    if not noCreate and ctx.Variables then
        local existing = ctx.Variables:_getLookup(instance)
        if existing then return existing.VarName end
    end

    if instance == game then return "game" end

    local indexFunc = ctx.IndexFunc
    local className = indexFunc(instance, "ClassName")
    local name      = indexFunc(instance, "Name")
    local parent    = indexFunc(instance, "Parent")

    -- Service shorthand: game:GetService("X")
    local ok, svc = pcall(function() return game:GetService(className) end)
    if ok and svc == instance then
        return string.format('game:GetService("%s")', className)
    end

    -- workspace alias
    if instance == workspace then return "workspace" end

    -- No parent — can't build a real path
    if parent == nil then
        return string.format('nil --[[%s "%s" (no parent)]]', className, name)
    end

    local parentPath = self:_buildPath(parent, noCreate)

    -- Prefer dot syntax, fall back to WaitForChild for safety
    if isValidIdent(name) then
        return parentPath .. "." .. name
    else
        return string.format('%s:WaitForChild("%s")', parentPath, name)
    end
end

function Formatter:Format(value, opts)
    opts = opts or {}
    local t = typeof(value)

    -- Instance
    if t == "Instance" then
        if not opts.NoVariableCreate and self._ctx.Variables then
            local existing = self._ctx.Variables:_getLookup(value)
            if existing then return existing.VarName end
        end
        return self:_buildPath(value, opts.NoVariableCreate)
    end

    if t == "nil"     then return "nil" end
    if t == "boolean" then return tostring(value) end

    if t == "number" then
        if value ~= value           then return "0/0"         end  -- NaN
        if value ==  math.huge      then return "math.huge"   end
        if value == -math.huge      then return "-math.huge"  end
        if math.floor(value) == value and math.abs(value) < 1e15 then
            return string.format("%d", value)
        end
        return tostring(value)
    end

    if t == "string" then return string.format("%q", value) end

    -- Roblox value types
    if t == "Vector3" then
        return string.format("Vector3.new(%g, %g, %g)", value.X, value.Y, value.Z)
    end

    if t == "Vector2" then
        return string.format("Vector2.new(%g, %g)", value.X, value.Y)
    end

    if t == "CFrame" then
        local c = {value:GetComponents()}
        -- Pure translation — no need for 12 components
        if c[4]==1 and c[5]==0 and c[6]==0
        and c[7]==0 and c[8]==1 and c[9]==0
        and c[10]==0 and c[11]==0 and c[12]==1 then
            return string.format("CFrame.new(%g, %g, %g)", c[1], c[2], c[3])
        end
        return "CFrame.new(" .. table.concat(c, ", ") .. ")"
    end

    if t == "Color3" then
        local r = math.clamp(math.round(value.R * 255), 0, 255)
        local g = math.clamp(math.round(value.G * 255), 0, 255)
        local b = math.clamp(math.round(value.B * 255), 0, 255)
        return string.format("Color3.fromRGB(%d, %d, %d)", r, g, b)
    end

    if t == "UDim2" then
        return string.format("UDim2.new(%g, %d, %g, %d)",
            value.X.Scale, value.X.Offset,
            value.Y.Scale, value.Y.Offset)
    end

    if t == "UDim" then
        return string.format("UDim.new(%g, %d)", value.Scale, value.Offset)
    end

    if t == "EnumItem" or t == "Enum" then
        return tostring(value)
    end

    if t == "BrickColor" then
        return string.format('BrickColor.new("%s")', value.Name)
    end

    if t == "TweenInfo" then
        return string.format("TweenInfo.new(%g, %s, %s, %d, %s, %g)",
            value.Time,
            tostring(value.EasingStyle),
            tostring(value.EasingDirection),
            value.RepeatCount,
            tostring(value.Reverses),
            value.DelayTime)
    end

    if t == "NumberRange" then
        return string.format("NumberRange.new(%g, %g)", value.Min, value.Max)
    end

    if t == "NumberSequence" then
        local kps = {}
        for _, kp in ipairs(value.Keypoints) do
            table.insert(kps, string.format(
                "NumberSequenceKeypoint.new(%g, %g, %g)", kp.Time, kp.Value, kp.Envelope))
        end
        return string.format("NumberSequence.new({%s})", table.concat(kps, ", "))
    end

    if t == "ColorSequence" then
        local kps = {}
        for _, kp in ipairs(value.Keypoints) do
            local c = kp.Value
            table.insert(kps, string.format(
                "ColorSequenceKeypoint.new(%g, Color3.fromRGB(%d, %d, %d))",
                kp.Time,
                math.round(c.R * 255),
                math.round(c.G * 255),
                math.round(c.B * 255)))
        end
        return string.format("ColorSequence.new({%s})", table.concat(kps, ", "))
    end

    if t == "Rect" then
        return string.format("Rect.new(%g, %g, %g, %g)",
            value.Min.X, value.Min.Y, value.Max.X, value.Max.Y)
    end

    if t == "Ray" then
        return string.format("Ray.new(Vector3.new(%g,%g,%g), Vector3.new(%g,%g,%g))",
            value.Origin.X, value.Origin.Y, value.Origin.Z,
            value.Direction.X, value.Direction.Y, value.Direction.Z)
    end

    if t == "function" then return "function() end" end
    if t == "thread"   then return "nil --[[thread]]" end

    return string.format("nil --[[%s]]", t)
end

-- ============================================================
-- Variables
-- Tracks named local variables, deduplicates by Lookup object,
-- and buckets them by Class for header code generation.
-- ============================================================

local Variables = {}
Variables.__index = Variables

function Variables.new(ctx)
    return setmetatable({
        _ctx        = ctx,
        _vars       = {},   -- ordered; entries are the source of truth
        _lookup     = {},   -- Instance -> entry  (fast dedup)
        _nameCounts = {},   -- baseName -> next suffix number
    }, Variables)
end

function Variables:_getLookup(obj)
    return self._lookup[obj]
end

function Variables:_uniqueName(base)
    base = sanitizeName(base)
    if not self._nameCounts[base] then
        self._nameCounts[base] = 1
        return base
    end
    local n = self._nameCounts[base]
    self._nameCounts[base] = n + 1
    return base .. n
end

function Variables:MakeVariable(data)
    -- Return existing variable name if this object was already registered
    if data.Lookup and self._lookup[data.Lookup] then
        return self._lookup[data.Lookup].VarName
    end

    local varName = self:_uniqueName(data.Name or self._ctx.VariableBase)

    local entry = {
        VarName = varName,
        Value   = data.Value,
        Comment = data.Comment,
        Lookup  = data.Lookup,
        -- "Services" | "Variables" | "Remote" — controls output order
        Class   = data.Class or "Variables",
    }

    table.insert(self._vars, entry)
    if data.Lookup then self._lookup[data.Lookup] = entry end

    return varName
end

-- Pre-scan a flat argument list and register any instances as variables
-- before the main formatting pass runs, so forward references resolve.
-- filterClasses: e.g. {"Instance"} means register all Instances found.
function Variables:PrerenderVariables(tbl, filterClasses)
    local classSet = {}
    for _, c in ipairs(filterClasses) do classSet[c] = true end

    local visited = {}

    local function scan(value)
        local t = typeof(value)
        if visited[value] then return end

        if t == "Instance" then
            visited[value] = true
            if classSet["Instance"] or classSet[t] then
                if not self._lookup[value] then
                    local ctx = self._ctx
                    -- Detect services for correct class bucketing
                    local className = ctx.IndexFunc(value, "ClassName")
                    local ok, svc = pcall(function() return game:GetService(className) end)
                    local class = (ok and svc == value) and "Services" or "Variables"

                    self:MakeVariable({
                        Value   = ctx.Formatter:Format(value, {NoVariableCreate = true}),
                        Comment = className,
                        Lookup  = value,
                        Name    = ctx.Formatter:MakeName(value),
                        Class   = class,
                    })
                end
            end

        elseif t == "table" then
            visited[value] = true
            for k, v in pairs(value) do scan(k); scan(v) end
        end
    end

    if type(tbl) == "table" then
        for _, v in ipairs(tbl) do scan(v) end
    end
end

-- ============================================================
-- Parser
-- Serializes tables and emits the variable declaration block.
-- ============================================================

local Parser = {}
Parser.__index = Parser

function Parser.new(ctx)
    return setmetatable({ _ctx = ctx }, Parser)
end

function Parser:_formatValue(value, depth)
    if typeof(value) == "table" then
        local str, _ = self:ParseTableIntoString({ Table = value, _depth = (depth or 0) + 1 })
        return str
    end
    return self._ctx.Formatter:Format(value)
end

-- Returns: serialized string, item count
-- NoBrackets=true → "a, b, c"  instead of  "{a, b, c}"
-- (used for argument lists)
function Parser:ParseTableIntoString(opts)
    local tbl       = opts.Table
    local noBrackets = opts.NoBrackets
    local depth      = opts._depth or 0

    local items    = {}
    local count    = 0
    local maxArray = 0

    -- Separate array portion from dict portion
    local arrayPart = {}
    local dictPart  = {}

    for k, v in pairs(tbl) do
        if type(k) == "number" and k == math.floor(k) and k >= 1 then
            arrayPart[k] = v
            if k > maxArray then maxArray = k end
        else
            table.insert(dictPart, {k, v})
        end
    end

    -- Array items (preserves holes with explicit nil)
    for i = 1, maxArray do
        local v = arrayPart[i]
        table.insert(items, v == nil and "nil" or self:_formatValue(v, depth))
        count += 1
    end

    -- Dict items
    for _, pair in ipairs(dictPart) do
        local k, v = pair[1], pair[2]
        local valStr = self:_formatValue(v, depth)

        if type(k) == "string" and isValidIdent(k) then
            table.insert(items, k .. " = " .. valStr)
        else
            table.insert(items, "[" .. self._ctx.Formatter:Format(k) .. "] = " .. valStr)
        end
        count += 1
    end

    if count == 0 then
        return noBrackets and "" or "{}", 0
    end

    local body = table.concat(items, ", ")
    return noBrackets and body or "{" .. body .. "}", count
end

-- Emit all registered `local x = ...` declarations,
-- grouped and ordered by the provided class list.
function Parser:MakeVariableCode(classList)
    local vars = self._ctx.Variables._vars

    -- Build ordered buckets
    local buckets = {}
    for _, class in ipairs(classList) do
        buckets[class] = { _order = #buckets + 1, entries = {} }
    end

    for _, entry in ipairs(vars) do
        local bucket = buckets[entry.Class]
        if not bucket then
            -- Unknown class: tack onto the last bucket
            local last = classList[#classList]
            bucket = buckets[last]
        end
        if bucket then
            table.insert(bucket.entries, entry)
        end
    end

    local lines = {}

    for _, class in ipairs(classList) do
        local bucket = buckets[class]
        if bucket and #bucket.entries > 0 then
            for _, entry in ipairs(bucket.entries) do
                local line = string.format("local %s = %s", entry.VarName, entry.Value)
                if entry.Comment then
                    line = line .. " -- " .. entry.Comment
                end
                table.insert(lines, line)
            end
            table.insert(lines, "") -- blank line between groups
        end
    end

    -- Strip trailing blank lines
    while lines[#lines] == "" do table.remove(lines) end

    return #lines > 0 and (table.concat(lines, "\n") .. "\n") or ""
end

-- ============================================================
-- Module Instance  (what ParserModule:New returns)
-- ============================================================

local ModuleInstance = {}
ModuleInstance.__index = ModuleInstance

function ModuleInstance.new(config)
    -- Shared context table — all three sub-modules read/write this
    local ctx = {
        VariableBase = config.VariableBase or "var",
        Swaps        = config.Swaps        or {},
        IndexFunc    = config.IndexFunc    or function(obj, prop) return obj[prop] end,
    }

    local formatter = Formatter.new(ctx)
    local variables = Variables.new(ctx)
    local parser    = Parser.new(ctx)

    -- Wire cross-references so each sub-module can reach the others
    ctx.Formatter = formatter
    ctx.Variables = variables
    ctx.Parser    = parser

    return setmetatable({
        Formatter = formatter,
        Variables = variables,
        Parser    = parser,
    }, ModuleInstance)
end

-- ============================================================
-- Top-level ParserModule API
-- ============================================================

function ParserModule:Load()
    -- No-op: all sub-modules are inline. Kept for API compatibility.
end

function ParserModule:Import(_name)
    -- No-op: nothing to import. Kept for API compatibility.
    return {}
end

function ParserModule:New(config)
    return ModuleInstance.new(config)
end

return ParserModule
