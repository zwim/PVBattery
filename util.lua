
local posix = require("posix")

local util = {}


function util.fromhex(str)
  if str ~= nil then
    return (str:gsub('..', function (cc)
        return string.char(tonumber(cc, 16))
    end))
  end
end

function util.tohex(str)
  if str ~= nil then
    return (str:gsub('.', function (c)
        if c == 0 then return "00" end
        return string.format('%02X', string.byte(c))
    end))
  end
end

function util.numToBits(num, nb)
    -- returns a table of bits, least significant first.
    nb = nb or math.floor(math.log(num)/math.log(2) + 1)
    print("nb=",nb)
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