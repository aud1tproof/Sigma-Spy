local Ui = {
    DefaultEditorContent = "--Welcome to Sigma Spy",

    SeasonLabels = {
        January   = "⛄%s⛄",   February  = "🌨️%s🏂",  March     = "🌹%s🌺",
        April     = "🐣%s✝️",   May       = "🐝%s🌞",   June      = "🪴%s🥕",
        July      = "🌊%s🏖️",  August    = "☀️%s🌞",   September = "🍁%s🍁",
        October   = "🎃%s🎃",   November  = "🍂%s🍂",   December  = "🎄%s🎁",
    },

    RandomSeed = Random.new(tick()),

    -- Log storage
    Logs     = {},  -- [id] = HeaderData
    LogOrder = {},  -- ordered array of remote IDs (newest-first for display)
    LogQueue = {},

    -- Aura ticker
    _auraTitle = "Sigma Spy",
    _nextAura  = 0,

    -- Modal state (plain Lua, toggled before next Render)
    _showModal = false,
    _modalMsg  = "",

    -- Iris.State handles — populated in Init() after Iris.Init()
    _editorText   = nil,
    _uiVisible    = nil,
    _infoVisible  = nil,

    -- Cached Iris.State objects for flag checkboxes  { [flagName] = Iris.State }
    _flagStates   = {},
    -- Cached Iris.State objects for per-remote option checkboxes  { [key] = Iris.State }
    _remoteStates = {},
}

type table = { [any]: any }
type Log = {
    Remote: Instance, Method: string, Args: table,
    IsReceive: boolean?,  MetaMethod: string?,
    OriginalFunc: ((...any) -> ...any)?,
    CallingScript: Instance?, CallingFunction: ((...any) -> ...any)?,
    ClassData: table?, ReturnValues: table?, RemoteData: table?,
    Id: string, HeaderData: table,
}

-- ── Compat ────────────────────────────────────────────────────────────────────
local SetClipboard = setclipboard or toclipboard or set_clipboard

-- ── Upvalues set in Init ──────────────────────────────────────────────────────
local Iris
local Flags, Generation, Process, Hook, Config
local InsertService: InsertService

-- ── Module-level mutable state ────────────────────────────────────────────────
local ActiveData     = nil
local RemotesCount   = 0
local TextFont       = Font.fromEnum(Enum.Font.Code)
local FontSuccess    = false

-- ── Utility ───────────────────────────────────────────────────────────────────

local function DeepCloneTable(t)
    local n = {}
    for k, v in next, t do
        n[k] = typeof(v) == "table" and DeepCloneTable(v) or v
    end
    return n
end

-- Returns (or lazily creates) a persistent Iris.State in a cache table.
local function GetCachedState(cache, key, defaultValue)
    if not cache[key] then
        cache[key] = Iris.State(defaultValue)
    end
    return cache[key]
end

-- ── Public helpers ────────────────────────────────────────────────────────────

function Ui:SetClipboard(content: string)
    SetClipboard(content)
end

function Ui:TurnSeasonal(text: string): string
    local base = self.SeasonLabels[os.date("%B")]
    return base:format(text)
end

function Ui:SetFont(jsonFile: string, fontContent: string)
    if not jsonFile then return end
    FontSuccess = fontContent ~= ""
    if not FontSuccess then return end
    TextFont = Font.new(getcustomasset(jsonFile, false))
end

-- ── Aura title (no separate thread — ticked inside Render) ───────────────────

function Ui:TickAura()
    local now = tick()
    if now < self._nextAura then return end
    local r     = self.RandomSeed
    local title = ` Sigma Spy - Depso | AURA: {r:NextInteger(1, 9999999)} `
    self._auraTitle = self:TurnSeasonal(title)
    self._nextAura  = now + r:NextInteger(1, 5)
end

-- ── Editor text helpers ───────────────────────────────────────────────────────

function Ui:SetEditorText(text: string)
    self._editorText:set(text)
end

function Ui:GetEditorText(): string
    return self._editorText.value
end

-- ── Init ─────────────────────────────────────────────────────────────────────

function Ui:Init(data)
    local Modules  = data.Modules
    local Services = data.Services

    InsertService = Services.InsertService
    Flags         = Modules.Flags
    Generation    = Modules.Generation
    Process       = Modules.Process
    Hook          = Modules.Hook
    Config        = Modules.Config

    -- Load Iris
    Iris = loadstring(game:HttpGet(
        "https://raw.githubusercontent.com/SirMallard/Iris/main/lib/init.lua"
    ))()
    Iris.Init()

    -- Optional: apply custom font
    if FontSuccess then
        Iris.UpdateGlobalConfig({ TextFont = TextFont })
    else
        -- No font warning modal shown on first render via _showModal flag
        self._showModal = true
        self._modalMsg  = table.concat({
            "Unfortunately your executor was unable to download the font.",
            "\nIf you would like to use a custom font,",
            "\ndownload assets/ProggyClean.ttf into your workspace folder.",
        }, "\n")
    end

    -- Persistent Iris states (must be created after Iris.Init())
    self._editorText  = Iris.State(self.DefaultEditorContent)
    self._uiVisible   = Iris.State(true)
    self._infoVisible = Iris.State(true)

    -- Bind UiVisible flag to window visibility
    Flags:SetFlagCallback("UiVisible", function(_, visible)
        self._uiVisible:set(visible)
    end)

    -- Start render loop (replaces CreateWindow + BeginLogService + AuraCounterService)
    Iris:Connect(function()
        self:Render()
    end)
end

-- ── Modal ─────────────────────────────────────────────────────────────────────

function Ui:ShowModal(lines: table)
    self._modalMsg  = table.concat(lines, "\n")
    self._showModal = true
end

function Ui:ShowUnsupported(funcName: string)
    self:ShowModal({
        "Unfortunately Sigma Spy is not supported on your executor",
        `\n\nMissing function: {funcName}`,
    })
end

function Ui:RenderModal()
    if not self._showModal then return end

    Iris.SetNextWindowSize(Vector2.new(420, 0))
    Iris.Window({"Sigma Spy – Notice"})
        Iris.Text({self._modalMsg, [Iris.Args.Text.Wrapped] = true})
        if Iris.Button({"Okay"}).clicked() then
            self._showModal = false
        end
    Iris.End()
end

-- ── Main render entry ─────────────────────────────────────────────────────────

function Ui:Render()
    self:TickAura()
    self:ProcessLogQueue()
    self:RenderModal()
    self:RenderRemoteList()
    self:RenderInfoPanel()
end

-- ── Remote list window (left panel) ──────────────────────────────────────────

function Ui:RenderRemoteList()
    Iris.SetNextWindowSize(Vector2.new(170, 440))
    Iris.Window({self._auraTitle}, {isOpened = self._uiVisible})
        local noTree = Flags:GetFlagValue("NoTreeNodes")

        for _, id in ipairs(self.LogOrder) do
            local hdr = self.Logs[id]
            if not hdr then continue end

            if noTree then
                -- Flat list: prefix each row with remote name
                for _, logData in ipairs(hdr.Entries) do
                    self:RenderLogRow(logData, true)
                end
            else
                -- Tree node per remote
                Iris.Tree({`{hdr.Remote}`})
                    for _, logData in ipairs(hdr.Entries) do
                        self:RenderLogRow(logData, false)
                    end
                Iris.End()
            end
        end
    Iris.End()
end

function Ui:RenderLogRow(logData: Log, showRemote: boolean)
    local method = logData.Method
    local args   = logData.Args
    local label  = showRemote and `{logData.Remote} | {method}` or method

    if Flags:GetFlagValue("FindStringForName") then
        for _, arg in next, args do
            if typeof(arg) == "string" then
                label = `{arg:sub(1, 15)} | {label}`
                break
            end
        end
    end

    -- Iris.Selectable({label, isSelected})
    -- isSelected is re-evaluated each frame; Iris handles visual highlight.
    local sel = Iris.Selectable({label, ActiveData == logData})
    if sel.clicked() then
        self:SetFocusedRemote(logData)
    end
end

-- ── Info panel window (right panel) ──────────────────────────────────────────

function Ui:RenderInfoPanel()
    Iris.SetNextWindowSize(Vector2.new(480, 440))
    Iris.Window({"Info"}, {isOpened = self._infoVisible})
        Iris.TabBar()

            Iris.Tab({"Editor"})
                self:RenderEditorTab()
            Iris.End()

            Iris.Tab({"Options"})
                self:RenderOptionsTab()
            Iris.End()

            -- Remote detail tab only exists while a remote is focused
            if ActiveData then
                Iris.Tab({`Remote: {ActiveData.Remote}`})
                    self:RenderRemoteDetailTab()
                Iris.End()
            end

        Iris.End() -- TabBar
    Iris.End()     -- Window
end

-- ── Editor tab ────────────────────────────────────────────────────────────────

function Ui:RenderEditorTab()
    -- Button row
    local btns = {
        {"Copy",          function() SetClipboard(self:GetEditorText()) end},
        {"Repeat call",   function() if ActiveData then ActiveData:RepeatCall()   end end},
        {"Get return",    function() if ActiveData then ActiveData:GetReturn()    end end},
        {"Generate info", function() if ActiveData then ActiveData:GenerateInfo() end end},
        {"Decompile",     function() if ActiveData then ActiveData:Decompile()    end end},
    }
    for i, pair in ipairs(btns) do
        if i > 1 then Iris.SameLine() end
        if Iris.Button({pair[1]}).clicked() then pair[2]() end
    end

    -- Multiline script view (editable so the user can tweak before copying)
    Iris.InputText({
        "##editor",
        [Iris.Args.InputText.MultiLine] = true,
    }, {text = self._editorText})
end

-- ── Options tab ───────────────────────────────────────────────────────────────

function Ui:RenderOptionsTab()
    -- Log management
    Iris.SeparatorText({"Logs"})
    local logBtns = {
        {"Clear logs",     function()
            ActiveData = nil
            self:ClearLogs()
        end},
        {"Clear blocks",   function() Process:UpdateAllRemoteData("Blocked",  false) end},
        {"Clear excludes", function() Process:UpdateAllRemoteData("Excluded", false) end},
    }
    for i, pair in ipairs(logBtns) do
        if i > 1 then Iris.SameLine() end
        if Iris.Button({pair[1]}).clicked() then pair[2]() end
    end

    -- Per-flag checkboxes
    Iris.SeparatorText({"Settings"})
    self:RenderFlagOptions()

    -- Credits / info
    Iris.SeparatorText({"Information"})
    Iris.Text({"Sigma spy - Created by depso!"})
    Iris.Text({"Thank you to syn for your suggestions and testing"})
    Iris.Text({"I wish potassium wasn't so crudely produced"})
    Iris.Text({"Boiiiiii what did you say about Sigma Spy 💀💀 (+999999 AURA)"})
end

function Ui:RenderFlagOptions()
    for name, data in next, Flags:GetFlags() do
        if typeof(data.Value) ~= "boolean" then continue end

        -- Lazily create a persistent Iris.State per flag
        local st = GetCachedState(self._flagStates, name, data.Value)
        -- Sync in case the value was changed externally
        st:set(data.Value)

        local cb = Iris.Checkbox({name}, {isChecked = st})
        if cb.checked() or cb.unchecked() then
            data.Value = st.value
            if data.Callback then
                data:Callback(nil, st.value)
            end
        end
    end
end

-- ── Remote detail tab ─────────────────────────────────────────────────────────

function Ui:RenderRemoteDetailTab()
    local data = ActiveData
    if not data then return end

    local id     = data.Id
    local remote = data.Remote
    local script = data.CallingScript
    local rdata  = Process:GetRemoteData(id)
    local parser = Generation:NewParser().Parser

    -- Block / Exclude toggles sourced from RemoteData
    for key, val in next, rdata do
        if typeof(val) ~= "boolean" then continue end

        local stKey = id .. ":" .. key
        local st = GetCachedState(self._remoteStates, stKey, val)
        st:set(val)

        local cb = Iris.Checkbox({key}, {isChecked = st})
        if cb.checked() or cb.unchecked() then
            rdata[key] = st.value
            Process:UpdateRemoteData(id, rdata)
        end
    end

    Iris.Separator()

    -- Action buttons
    local actionBtns = {
        {"Copy script path", function()
            SetClipboard(parser:MakePathString({Object = script, NoVariables = true}))
        end},
        {"Copy remote path", function()
            SetClipboard(parser:MakePathString({Object = remote, NoVariables = true}))
        end},
        {"Remove log", function()
            if data.HeaderData then data.HeaderData:Remove() end
            ActiveData = nil
        end},
    }
    for i, pair in ipairs(actionBtns) do
        if i > 1 then Iris.SameLine() end
        if Iris.Button({pair[1]}).clicked() then pair[2]() end
    end

    -- Remote info table
    Iris.SeparatorText({"Remote Info"})
    local display = {
        "MetaMethod", "Method", "Remote", "CallingScript",
        "CallingActor", "IsActor", "Id",
    }
    Iris.Table({
        2,
        [Iris.Args.Table.RowBg]        = true,
        [Iris.Args.Table.BordersInner] = true,
    })
        -- Header row
        Iris.TableNextColumn() Iris.Text({"Name"})
        Iris.TableNextColumn() Iris.Text({"Value"})

        for _, name in ipairs(display) do
            local val = data[name]
            if val == nil then continue end
            Iris.TableNextColumn() Iris.Text({name})
            Iris.TableNextColumn() Iris.Text({tostring(val)})
        end
    Iris.End()
end

-- ── SetFocusedRemote ──────────────────────────────────────────────────────────

function Ui:SetFocusedRemote(data: Log)
    local remote      = data.Remote
    local method      = data.Method
    local metaMethod  = data.MetaMethod
    local isReceive   = data.IsReceive
    local script      = data.CallingScript
    local func        = data.CallingFunction
    local classData   = data.ClassData
    local args        = data.Args
    local id          = data.Id
    local isRemoteFunc = classData.IsRemoteFunction

    -- Safely retrieve the source script from the calling function's env
    local sourceScript = func and rawget(getfenv(func), "script") or nil

    -- Wipe cached remote-option states when switching focus
    self._remoteStates = {}

    ActiveData = data

    local function setIDE(text) self:SetEditorText(text) end

    -- Attach action methods to the data object

    function data:RepeatCall()
        local sig = Hook:Index(remote, method)
        if isReceive then
            firesignal(sig, unpack(args))
        else
            sig(remote, unpack(args))
        end
    end

    function data:GetReturn()
        if not isRemoteFunc then
            setIDE("-- Remote is not a function bozo (-9999999 AURA)")
            return
        end
        if not data.ReturnValues then
            setIDE("-- No return values (-9999999 AURA)")
            return
        end
        setIDE(Generation:TableScript(data.ReturnValues))
    end

    function data:GenerateInfo()
        if isReceive then
            setIDE(
                "-- Boiiiii what did you say about IsReceive (-9999999 AURA)\n"
                .. "\n-- Voice message: ▶ .ılıılıılıılıılıılı. 0:69\n"
            )
            return
        end

        local connections = {}
        local info = {
            Script = {
                SourceScript  = sourceScript,
                CallingScript = script,
            },
            Remote = {
                Remote   = remote,
                RemoteID = id,
                Method   = method,
            },
            MetaMethod      = metaMethod,
            IsActor         = data.IsActor,
            CallingFunction = func,
            Connections     = connections,
        }

        if func and islclosure(func) then
            info.UpValues  = debug.getupvalues(func)
            info.Constants = debug.getconstants(func)
        end

        for _, m in next, classData.Receive do
            pcall(function()
                local sig = Hook:Index(remote, m)
                connections[m] = Generation:ConnectionsTable(sig)
            end)
        end

        setIDE(Generation:TableScript(info))
    end

    function data:Decompile()
        if not decompile then
            setIDE("--Exploit is missing 'decompile' function (-9999999 AURA)")
            return
        end
        if not script then
            setIDE("--Script is missing (-9999999 AURA)")
            return
        end
        setIDE("--Decompiling... +9999999 AURA (mango phonk)")
        local decompiled = decompile(script)
        setIDE("--BOOIIII THIS IS SO TUFF FLIPPY SKIBIDI AURA (SIGMA SPY)\n" .. decompiled)
    end

    -- Immediately render the generated remote script into the editor
    local mod = Generation:NewParser()
    setIDE(Generation:RemoteScript(mod, data))
end

-- ── Log management ────────────────────────────────────────────────────────────

function Ui:GetRemoteHeader(data: Log)
    local id     = data.Id
    local remote = data.Remote

    local existing = self.Logs[id]
    if existing then return existing end

    RemotesCount += 1

    local hdr = {
        Remote   = remote,
        Entries  = {},
        LogCount = 0,
    }

    function hdr:LogAdded(logData)
        self.LogCount += 1
        table.insert(self.Entries, 1, logData) -- newest first
        return self
    end

    function hdr:Remove()
        self.Logs[id] = nil
        for i, oid in ipairs(self.LogOrder) do
            if oid == id then
                table.remove(self.LogOrder, i)
                break
            end
        end
        table.clear(hdr)
    end
    -- Bind Remove to Ui so it can clear self.Logs / self.LogOrder
    local uiRef = self
    hdr.Remove = function(h)
        uiRef.Logs[id] = nil
        for i, oid in ipairs(uiRef.LogOrder) do
            if oid == id then table.remove(uiRef.LogOrder, i) break end
        end
        table.clear(h)
    end

    self.Logs[id] = hdr
    table.insert(self.LogOrder, 1, id) -- newest remote at top
    return hdr
end

function Ui:ClearLogs()
    RemotesCount = 0
    ActiveData   = nil
    self._remoteStates = {}
    table.clear(self.Logs)
    table.clear(self.LogOrder)
end

function Ui:QueueLog(data: Log)
    table.insert(self.LogQueue, data)
end

-- Called each frame from Render(); replaces the separate coroutine thread.
function Ui:ProcessLogQueue()
    local queue = self.LogQueue
    if #queue == 0 then return end
    -- Process all queued entries this frame
    for i = #queue, 1, -1 do
        self:CreateLog(queue[i])
        table.remove(queue, i)
    end
end

-- No-op: processing is now driven by the Iris render loop.
function Ui:BeginLogService() end

function Ui:CreateLog(data: Log)
    local remote    = data.Remote
    local method    = data.Method
    local args      = data.Args
    local isReceive = data.IsReceive
    local id        = data.Id

    local isNilParent = Hook:Index(remote, "Parent") == nil
    local remoteData  = Process:GetRemoteData(id)

    -- Early-out checks (same logic as original)
    if Flags:GetFlagValue("Paused")      then return end
    if Flags:GetFlagValue("CheckCaller") and not checkcaller() then return end
    if Flags:GetFlagValue("IgnoreNil")   and isNilParent       then return end
    if not Flags:GetFlagValue("LogRecives") and isReceive      then return end
    if remoteData.Excluded               then return end

    -- Deep-clone args so later mutation doesn't corrupt the log
    data.Args = DeepCloneTable({unpack(args)})

    local hdr = self:GetRemoteHeader(data)
    hdr:LogAdded(data)
    data.HeaderData = hdr
end

return Ui
