
local dnshelper = require("base/dnshelper")
local ffi = require("ffi")
local json = require("dkjson")
local lfs = require("lfs")
local posix = require("posix")

if not table.unpack then
    table.unpack = unpack
end

--local json_decode_tmp = json.decode

--[[
function json.decode(str)
    if str then
        str = str:gsub("^%s*(.-)%s*$", "%1")
        str = str:gsub("\\n", "\n")
        str = str:gsub("\\\"", "\"")
        str = str:gsub("null", "0")

        local x, y, z = json_decode_tmp(str)
        return x, y, z
    else
        return 0
    end
end
]]
local util = {
    log = nil,
    log_file_name = nil,
    log_file = nil,
    nl = "\n",
}

function util:setLogNewLine(nl)
    self.nl = nl and "\n" or ""
end

function util:setCompressor(compressor)
    self.compressor = compressor
end

function util:setLog(log_file_name)
    if self.log_file and self.log_file_name ~= log_file_name then
        self.log_file:close()
    end
    if log_file_name then
        self.log_file = io.open(log_file_name , "a")
        if not self.log_file then
            print("ERROR opening log file:", log_file_name, self.log_file_name)
        end
        util.log = util.logToFile
        self.log_file_name = log_file_name
    else
        util.log = util.logToScreen
    end
end

function util:logToFile(...)
    local message = table.concat({...}, "\t")
    self.log_file:write(message, self.nl)
    self.log_file:flush()
end

function util:logToScreen(...)
    local message = table.concat({...}, "\t")
    io.write(message, self.nl)
    io.flush()
end

util.log = util.logToScreen

function util.exToNum(str)
    if str then
        return (str:gsub('..', function (cc)
                    return string.char(tonumber(cc, 16))
                end))
    end
    return 0
end

function util.stringToHex(str)
    if str then
        return (str:gsub('.', function (c)
                    if c == 0 then return "00" end
                    return string.format('%02X', string.byte(c))
                end))
    end
    return ""
end

function util.numToBits(num, nb)
    -- returns a table of bits, least significant first.
    nb = nb or math.floor(math.log(num)/math.log(2) + 1)
    local bits= {} -- will contain the bits
    while num > 0 do
        local rest = math.fmod(num, 2)
        bits[#bits + 1] = rest
        num = (num - rest) / 2
    end
    for i = #bits+1 , nb do
        bits[i] = 0
    end
    return bits, table.concat(bits)
end

function util.printTime(str)
    local date = os.date("*t")

    local date_time_string = string.format("%d/%d/%d-%02d:%02d:%02d",
        date.year, date.month, date.day, date.hour, date.min, date.sec)

    print("Zeitstempel: " .. str .. "----" .. date_time_string)
end

-- sleeps 'time' seconds
function util.sleepTime(time)
    if time <= 0 then
        return
    end

    local sec = math.floor(time)
    local nsec = (time - sec) * 1e9
    posix.time.nanosleep({tv_sec = sec, tv_nsec = nsec})
end

-- returns time in seconds
function util.getCurrentTime()
    local sec, nsec = posix.clock_gettime(0)
    return sec + nsec * 1e-9
end

function util.hourToTime(h)
    local hour, min, sec

    hour = math.floor(h)
    h = (h - hour) * 60
    min = math.floor(h)
    h = (h - min) * 60
    sec = math.floor(h + 0.5)
    return hour, min, sec
end

function util:cleanLogs()
    -- compress log file
    local handle = io.popen("stat -f -c %T " .. self.log_file_name)
    local result = handle:read("*a")
    handle:close()
    if result:find("btrfs") then
        if os.execute("date; btrfs filesystem defragment -r -v -czstd " .. self.log_file_name) ~= 0 then
            print("Error compressing " .. self.log_file_name)
        end
    end

    local attributes = lfs.attributes(self.log_file_name, "size")
    if attributes and attributes > 1024*1024 then
        local log_file_name_rotated = self.log_file_name:sub(1, self.log_file_name:find(".log$") - 1) ..
        os.date("-%Y%m%d-%H%M%S") .. ".log"
        if os.execute("mv " .. self.log_file_name .. " " .. log_file_name_rotated) ~= 0 then
            print("Error in rotating log file")
        end
        -- close the old log and open a new one
        util:setLog(self.log_file_name)
        util:log("Logfile rotated at " .. os.date())

        -- compress old log file
        if self.compressor then
            if os.execute(self.compressor.." "..log_file_name_rotated) ~= 0 then
                print("Error compressing old log file:", log_file_name_rotated)
            end
        end
    else
        util:log("Logfile NOT rotated at " .. os.date())
    end
end

function util.hostname()
    local file = io.popen("hostname")
    local output = file:read('*all')
    file:close()
    return output
end

-- roundTo(123.4567, 2) -> 123.46
function util.roundTo(num, places)
    return math.floor(num * 10^(-places) + 0.5) * (10^places)
end

function math.roundToZero(x)
    if x > 0 then
        return math.floor(x)
    else
        return math.floor(x+1)
    end
end

function util.deleteRunningInstances(name)
    if not name or name == "" then
        name = "ThisProgramDoesNotRunForShure123"
    end
    local file = io.open("/proc/self/stat", "r")
    if not file then
        print("cannot detect my own PID")
        return
    end
    local ownpid = file:read("*a"):gsub(" .*$", "")
    file:close()
    util:log("Own pid=" .. ownpid)

    file = io.popen("ps -ax")
    if not file then
        util:log("Error calling 'ps -ax'")
        print("Error calling 'ps -ax'")
        return
    end

    local pid_to_kill = {}
    for line in file:lines() do
        if line:find("lua.* .*"..name..".*%.lua") then
            print(line)
            local pid = line:gsub("^ *", "")
            pid = pid:gsub(" .*$", "")
            if pid ~= ownpid then
                table.insert(pid_to_kill, pid)
            end
        end
    end
    file:close()

    local nb_deleted = #pid_to_kill

    if nb_deleted > 0 then
        local pids = table.concat(pid_to_kill, " ")
        print(string.format("kill -term %s", pids))
        os.execute(string.format("kill -term %s", pids))
    end

    return nb_deleted
end

function math.clamp(x, l, u)
    if x < l then
        return l
    elseif x > u then
        return u
    else
        return x
    end
end

-- url can be URL or hostname
function util.getIPfromURL(url)
    dnshelper.debug = false

    -- Extract hostname if URL includes "http://"
    url = url:match("https?://([^/]+)") or url

    -- Resolve hostname to IP
    local ip, err = dnshelper.toip(url)

    if ip then
        print("IP address of " .. url .. " is " .. ip)
    else
        print("Failed to resolve " .. url .. ": " .. tostring(err))
    end
    return ip
end

-- === Fehler-Handler ===
function util.crashHandler(err)
    -- Erzeuge Stacktrace ab Aufrufer-Ebene (2 = skip xpcall)
    local trace = debug.traceback(tostring(err), 2)
    print("\n[CRASH] Unerwarteter Fehler erkannt!\n" .. trace)
    print("\n[Cleanup] Aufräumen wegen:", err or "unbekannt")
    return trace
end

function util.tables_equal_flat(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end

    for k, v in pairs(a) do
        if b[k] ~= v then
            return false
        end
    end
    for k, v in pairs(b) do
        if a[k] ~= v then
            return false
        end
    end
    return true
end

-- 32-Bit-Integer → IEEE754-Float
function util.int32_to_float(value, little_endian)
    -- 4 Byte Speicher reservieren
    local bytes = ffi.new("uint8_t[4]")
    if not little_endian then
        bytes[0] = bit.band(value, 0xFF)
        bytes[1] = bit.band(bit.rshift(value, 8), 0xFF)
        bytes[2] = bit.band(bit.rshift(value, 16), 0xFF)
        bytes[3] = bit.band(bit.rshift(value, 24), 0xFF)
    else
        bytes[2] = bit.band(value, 0xFF)
        bytes[3] = bit.band(bit.rshift(value, 8), 0xFF)
        bytes[0] = bit.band(bit.rshift(value, 16), 0xFF)
        bytes[1] = bit.band(bit.rshift(value, 24), 0xFF)
    end

    -- als float interpretieren
    local fptr = ffi.cast("float*", bytes)

    return fptr[0]
end

-- Safe JSON decode: prevents crashes on invalid JSON
function util.safe_json_decode(payload)
    local ok, result = pcall(json.decode, payload, 1, nil)
    if not ok then
        print("JSON decode error:", result)
        return nil, result
    end
    return result
end

function util.restart(reason, exit_code)
    print("----------------------------------------------------")
    print("PVBattery wird neu gestartet:", reason or "unbekannt")
    print("----------------------------------------------------")
    os.execute("sleep 5")
    os.execute("lua " .. arg[0] .. " &")
    os.exit(exit_code or 12)
end

-- Hilfsfunktion zur Ermittlung des Midnight-TimeStamps für den aktuellen Tag
function util.get_midnight_epoch()
    local t_now = os.date("*t", os.time())
    -- Setze Stunde, Minute, Sekunde auf Null (Mitternacht)
    t_now.hour = 0
    t_now.min = 0
    t_now.sec = 0
    return os.time(t_now)
end

------------------------------------------------------------
-- Zeit: UTC -> Lokal
------------------------------------------------------------
function util:utc_to_local(ts)
    local y,M,d,h,m,s = ts:match("(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)")
    local t = os.time({
        year=y,month=M,day=d,hour=h,min=m,sec=s
    })
    return os.date("%Y-%m-%d %H:%M:%S", t), t
end

function util.utc_to_local_string(utc_str)
    -- Muster: "YYYY-MM-DD HH:MM:SS"
    local year, month, day, hour, min, sec = utc_str:match("(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)")

    if not year then return nil end

    -- 1. Erstelle eine UTC-Zeittabelle
    local utc_table = {
        year = tonumber(year),
        month = tonumber(month),
        day = tonumber(day),
        hour = tonumber(hour),
        min = tonumber(min),
        sec = tonumber(sec)
    }

    -- 2. Konvertiere UTC-Tabelle in UTC-Epoch-Zeitstempel
    -- Das '!' in os.time erzeugt den Epoch-Wert basierend auf der Annahme,
    -- dass die Tabelle eine UTC-Zeit repräsentiert.
    local utc_epoch = os.time(utc_table)

    -- 3. Formatiere den UTC-Epoch-Zeitstempel in die lokale Zeit des Systems.
    -- Wenn das Format-String kein '!' enthält, verwendet os.date die lokale Zeitzone (CET/CEST).
    local local_str = os.date("%Y-%m-%d %H:%M:%S", utc_epoch)

    return local_str, utc_epoch
end

function util.file_exists(path)
    local f = io.open(path, "r")
    if not f then return false end
    f:close()
    return true
end

function util.read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

function util.write_file(path, content)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(content)
    f:close()
    return true
end

function util.merge_sort(a, b)
    local ia, ib = 1, 1
    local na, nb = #a, #b
    local r = {}
    local ir = 1

    while ia <= na and ib <= nb do
        if a[ia].hour <= b[ib].hour then
            r[ir] = a[ia]
            ia = ia + 1
        else
            r[ir] = b[ib]
            ib = ib + 1
        end
        ir = ir + 1
    end

    -- Rest anhängen
    while ia <= na do
        r[ir] = a[ia]
        ia = ia + 1
        ir = ir + 1
    end

    while ib <= nb do
        r[ir] = b[ib]
        ib = ib + 1
        ir = ir + 1
    end

    return r
end

return util
