
local json = require("dkjson")
local lfs = require("lfs")
local posix = require("posix")


if not table.unpack then
    table.unpack = unpack
end


local json_decode_tmp = json.decode

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

function util.HexToNum(str)
  if str ~= nil then
    return (str:gsub('..', function (cc)
        return string.char(tonumber(cc, 16))
    end))
  end
  return 0
end

function util.StringToHex(str)
  if str ~= nil then
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
function util.sleep_time(time)
    if time <= 0 then return end
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

function util.hourToTime(h)
    local hour, min, sec

    hour = math.floor(h)
    h = (h - hour) * 60
    min = math.floor(h)
    h = (h - min) * 60
    sec = math.floor(h + 0.5)
    return hour, min, sec
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

function util.httpRequest(url)
    local command = string.format("wget -nv --timeout=2 --server-response '%s'  -o /tmp/code -O /tmp/body", url)

-- "curl  url --tcp-nodelay --connect-timeout 2 -o /tmp/body --dump-header /tmp/code --silent --tcp-fastopen

    os.execute("rm -f /tmp/code /tmp/body")

    -- depending on what lua version there are two possibilities
    -- luajit and lua 5.1: retval = os.execute( ... )
    --           retval is the return value
    -- lua >= 5.2: success, reason, code = os.execute( ... )
    --           if reason == "exit" then code = retval
    local success, reason, retval = os.execute(command)

    if not reason and not retval then
        retval = success
    end

    if retval ~= 0 then
        return "", -retval
    end

    local body, code
    local f

    f = io.open("/tmp/body", "r")
    if f then
        body = f:read("*all")
        f:close()
    else
        body = ""
    end

    f = io.open("/tmp/code", "r")
    if f then
        code = f:read("*all")
        f:close()
        code = code:gsub("^ *HTTP[^ ]* +", "")
        code = code:gsub(" +.*", "")
    else
        code = 999
    end

    return body, code
end

return util
