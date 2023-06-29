--
--
-- see:
-- https://github.com/syssi/esphome-ant-bms
-- see https://github.com/klotztech/VBMS/wiki/Serial-protocol


local util = require("util")
local ffi = require("ffi")

local SERIAL_PORT = "/dev/rfcomm0"

--- The libc functions used by this process.
ffi.cdef[[
  int open(const char* pathname, int flags);
  int close(int fd);
  int read(int fd, void* buf, size_t count);
]]
local O_NONBLOCK = 2048
local chunk_size = 4096

local buffer = ffi.new('uint8_t[?]',chunk_size)


-- Get data at `pos` in `buffer` attention lua table starts with 1
-- whereas the protocol is defined for a C-buffer starting with 0
local function getInt8(ans, pos)
    return ans[pos + 1]
end

-- Get data at `pos` in `buffer` attention lua table starts with 1
-- whereas the protocol is defined for a C-buffer starting with 0
local function getInt16(ans, pos)
    return ans[pos + 1]*256 + ans[pos + 2]
end

-- Get data at `pos` in `buffer` attention lua table starts with 1
-- whereas the protocol is defined for a C-buffer starting with 0
local function getInt32(ans, pos)
    return ((ans[pos + 1]*256 + ans[pos + 2])*256 + ans[pos + 3])*256 + ans[pos + 4]
end



local AntBms = {
    timeOfLastRequiredData = 0, -- no data yet
    answer = {},
    v = {},
}

function AntBms:init()
    local retval = os.execute("sh init_ant_bms.sh")
    if retval ~= 0 then
        print("XXXXXXXXXXXXXXXXXX initialization error")
    end
end

function AntBms:readData()
    local serial_out
    local request_hex = "DBDB00000000"

    local fd = ffi.C.open(SERIAL_PORT, O_NONBLOCK)
    if fd <= 0 then
        print("ERROR opening serial_in")
        return -1
    end

    -- wait and read some existing(?) crap
    util.sleep_time(0.1)
    ffi.C.read(fd, buffer, chunk_size)

    serial_out = io.open(SERIAL_PORT,"wb")
    if not serial_out then
        print("ERROR opening serial_out")
        ffi.C.close(fd)
        return
    end
    serial_out:write(util.fromhex(request_hex))
    serial_out:flush()

    local answer = {}
    while #answer < 140 do
        util.sleep_time(0.25)
        local nbytes = ffi.C.read(fd, buffer, chunk_size)

--        print("nbytes=", nbytes)
        if nbytes <= 0 then
            ffi.C.close(fd)
            return false
        end

        for i = 0, nbytes-1 do
            table.insert(self.answer, buffer[i])
        end
    end

    serial_out:close()
    ffi.C.close(fd)

    return true
end

function AntBms:isChecksumOk()
    if #self.answer < 140 then
        return false
    end

    local expected, checksum
    -- We leaf the loop if checksum is OK or if there is to less data
    while true do
        -- delete leading bytes until 0xAA55AAFF
        while getInt32(self.answer, 0) ~= 0xAA55AAFF and #self.answer >= 140 do
            table.remove(self.answer, 1)
        end

        -- bail out if to less data left, after cleaning
        if #self.answer < 140 then
            print("to less data")
            break
        end

        expected = 0;
        for i = 4, 137 do
            expected = expected + getInt8(self.answer, i)
        end

        checksum = getInt16(self.answer, 138) -- big endian

        if checksum == expected then
            return true
        else
            -- We got crap, delete first byte in buffer and do the checks again
            table.remove(self.answer, 1)
        end
    end

    print("xxx checksum error", checksum, expected)
    return false
end

-- This is the usual way of reading new parameters
function AntBms:evaluateParameters()
    -- Require Data only, if the last require was at least a second ago
    if self:getDataAge() < 1 then
        return true
    end

    -- see https://github.com/klotztech/VBMS/wiki/Serial-protocol
    self.v = {} -- clear old values

    local checksum = false
    local retries = 10
    while #self.answer < 140 and retries > 0 do
        self:readData()
        checksum = self:isChecksumOk()
        if checksum then
            break
        end
        retries = retries - 1
    end

    if not checksum then
        return false
    end

    self.v.TotalVoltage = getInt16(self.answer, 4) * 0.1

    self.v.Voltage = {}

    self.v.VoltageSum = 0
    for i = 1, 32 do
        local start = 2*(i-1) + 6
        self.v.Voltage[i] = getInt16(self.answer, start) * 1e-3
        self.v.VoltageSum = self.v.VoltageSum + self.v.Voltage[i]
    end

    self.v.Current = getInt32(self.answer, 70)
    if self.v.Current > 2^31 then
        self.v.Current = self.v.Current - 2^32
    end
    self.v.Current = self.v.Current * 0.1

    self.v.SOC = getInt8(self.answer, 74)

    self.v.PhysicalCapacity = getInt32(self.answer, 75) * 1e-6
    self.v.RemainingCapacity = getInt32(self.answer, 79) * 1e-6
    self.v.CycleCapacity = getInt32(self.answer, 83) * 1e-6

    self.v.uptime = getInt32(self.answer, 87) * .1

    self.v.Temperature = {}
    for i = 1, 6 do
        local start = 2*(i-1) + 91
        self.v.Temperature[i] = getInt16(self.answer, start)
        if math.abs(self.v.Temperature[i]) > 300 then -- not connected
            self.v.Temperature[i] = 0
        end
    end

    self.v.ChargeMos = getInt8(self.answer, 103)
    self.v.DischargeMos = getInt8(self.answer, 104)

    self.v.BalancedStatus = getInt8(self.answer, 105)


    self.v.RelaySwitch = getInt8(self.answer, 110)

    self.v.CurrentPower = getInt32(self.answer, 111)
    if self.v.CurrentPower > 2^31 then
        self.v.CurrentPower = self.v.CurrentPower - 2^32
    end

    self.v.HighestMonomer = getInt8(self.answer, 115)
    self.v.HighestVoltage = getInt16(self.answer, 116) * 1e-3

    self.v.LowestMonomer = getInt8(self.answer, 118)
    self.v.LowestVoltage = getInt16(self.answer, 119) * 1e-3

    self.v.AverageVoltage = getInt16(self.answer, 121)* 1e-3

    self.v.NumberOfBatteries = getInt8(self.answer, 123)

    self.v.DischargeTubeVoltageDrop = getInt16(self.answer, 124) * 0.1
    self.v.DischargeTubeDriveVoltage = getInt16(self.answer, 126) * 0.1
    self.v.ChargeTubeDriveVoltage = getInt16(self.answer, 128) * 0.1

    self.v.StatusFlag = {"Off", "Open", "Overvoltage protection", "Over current protection",
        "Battery full", "Total overpressure", "Battery over temperature", "Power over temperature",
        "Abnormal current", "Balanced line dropped string", "Motherboard over temperature",
        "Charge on", "Short circuit protection", "Discharge tube abnormality",
        "Start exception", "Manually closed"}

    self.v.BalancerFlags = getInt32(self.answer, 132)

    self.answer = {} -- clear old received bytes
    self.timeOfLastRequiredData = util.getCurrentTime()

    return true
end

function AntBms:getSoc()
    -- Require SOC at mostly 1 time per minute
    if self:getDataAge() > 60 then
        self:evaluateParameters()
    end
    return self.v.SOC or 50
end

function AntBms:getDataAge()
    return util.getCurrentTime() - self.timeOfLastRequiredData
end

function AntBms:printValues()
    --AntBms:init()

    self:evaluateParameters()

    if self.v == {} then
        print("No values decoded yet!")
        return -1
    end

    print(string.format("SOC = %3d%%", self.v.SOC))
    print(string.format("Current Power = %d W", self.v.CurrentPower))
    print(string.format("Current = %3.1f A", self.v.Current))

    print(string.format("rem. capacity  = %3.3f Ah", self.v.RemainingCapacity))
    print(string.format("phys. capacity = %3.3f Ah", self.v.PhysicalCapacity))

    print(string.format("Number of Batteries = %2d ", self.v.NumberOfBatteries))


    local bits, bitString = util.numToBits(self.v.BalancerFlags, self.v.NumberOfBatteries)

    print(string.format("balancer = %s", bitString))

    for i = 1, self.v.NumberOfBatteries, 2 do
        print(string.format("Voltage[%2d] = %2.3f V", i, self.v.Voltage[i]),
            i+1 <= self.v.NumberOfBatteries and string.format("Voltage[%2d] = %2.3f V", i+1, self.v.Voltage[i+1]) or "")
    end
    print(string.format("TotalVoltage    = %3.1f V", self.v.TotalVoltage))
    print(string.format("Voltage sum     = %3.3f V", self.v.VoltageSum))

    print(string.format("average voltage = %1.3f V", self.v.AverageVoltage))
    print(string.format("Cell difference = %1.3f V", self.v.HighestVoltage - self.v.LowestVoltage))

    print(string.format("lowest monomer  = %d ", self.v.LowestMonomer ))
    print(string.format("lowest voltage  = %1.3f V", self.v.LowestVoltage))

    print(string.format("highest monomer = %d ", self.v.HighestMonomer ))
    print(string.format("highest voltage = %1.3f V", self.v.HighestVoltage))

    print("")
    print(string.format("DischargeTubeVoltageDrop    = % 3.1f V", self.v.DischargeTubeVoltageDrop))
    print(string.format("DischargeTubeDriveVoltage   = % 3.1f V", self.v.DischargeTubeDriveVoltage))
    print(string.format("ChargeTubeDriveVoltage      = % 3.1f V", self.v.ChargeTubeDriveVoltage))

    for i = 1, 6 do
        print(string.format("Temperature %d = %3d°C", i, self.v.Temperature[i]))
    end

    print(string.format("Age of data = %6.3f s", self:getDataAge()))


    return true
end

AntBms:init()

AntBms:evaluateParameters()

-- Show initial values
if arg[1] and string.lower(arg[1]) == "show" then
    AntBms:printValues()
end

return AntBms
