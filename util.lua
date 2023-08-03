
local posix = require("posix")

local util = {
    log = nil,
    log_file_name = nil,
    log_file = nil,
    nl = "\n",
}

function util:setLogNewLine(nl)
    self.nl = nl and "\n" or ""
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
    for i = #bits, nb do
        bits[i] = 0
    end
    return bits, table.concat(bits)
end

function util.sleep_time(time)
    local sec = math.floor(time)
    local nsec = (time - sec) * 1e9
    posix.time.nanosleep({tv_sec = sec, tv_nsec = nsec})
end

-- returns time in seconds
function util.getCurrentTime()
    local sec, nsec = posix.clock_gettime(0)
    return sec + nsec * 1e-9
end


return util