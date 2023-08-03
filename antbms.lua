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

----------------------------------------------------------------

local AntBMS = {
    timeOfLastRequiredData = 0, -- no data yet
    answer = {},
    v = {},
}

-- Todo honor self.validStatus
function AntBMS:init()
    local retval = os.execute("sh init_Ant_BMS.sh")
    if retval ~= 0 then
        self.validStatus = false
        util:log("XXXXXXXXXXXXXXXXXX initialization error")
    end
    self.validStatus = true
    self.MOSFETChargeStatusFlag = {
        "Open",
        "Overvoltage protection",
        "Over current protection",
        "Battery full",
        "Total overpressure",
        "Battery over temperature",
        "Power over temperature",
        "Abnormal current",
        "Balanced line dropped string",
        "Motherboard over temperature",
        "11", -- 11
        "12", -- 12
        "Discharge tube abnormality",
        "14", -- 14
        "Manually closed",
    }
    self.MOSFETChargeStatusFlag[0] = "Off"

    self.MOSFETDischargeStatusFlag = {
        "Open",
        "Over discharge protection",
        "Over current protection",
        "4", -- 4
        "Total overpressure",
        "Battery over temperature",
        "Power over temperature",
        "Abnormal current",
        "Balanced line dropped string",
        "Motherboard over temperature",
        "Charge on",
        "Short circuit protection",
        "Discharge tube abnormality",
        "Start exception",
        "Manually closed",
    }
    self.MOSFETDischargeStatusFlag[0] = "Off"

    self.BalancedStatusText = {
        "Exceeds the limit equilibrium",
        "Charge differential pressure balance",
        "Balanced over temperature",
        "Automatic equalization (on)",
        "5",
        "6",
        "7",
        "8",
        "9",
        "Motherboard over temperature",
        "11",
        "12",
        "13",
        "14",
        "15",
    }
    self.BalancedStatusText[0] = "Off"
end

function AntBMS:setAutoBalance(on)
    if on == nil then
        on = true
    end

    self:evaluateParameters()

    util:log("Balancer status was", string.lower(self.v.BalancedStatusText))
    print(string.find(string.lower(self.v.BalancedStatusText),"on"))
    if on then
        if string.find(string.lower(self.v.BalancedStatusText), "on") then
            return -- already on
        else
            self:toggleAutoBalance()
        end
    else
        if string.find(string.lower(self.v.BalancedStatusText), "off") then
            return -- already off
        else
            self:toggleAutoBalance()
        end
    end
end

function AntBMS:toggleAutoBalance()
    local serial_out
    local auto_balance = 252 -- adress of auto balance
    local write_data_hex = "A5A5".. string.format("%02x", auto_balance) .. "00" .. "00" .. string.format("%02x", auto_balance)

    self.answer = {}

    print("xxx setAutoBalance", write_data_hex)

    local fd = ffi.C.open(SERIAL_PORT, O_NONBLOCK)
    if fd <= 0 then
        util:log("ERROR opening serial_in")
        return -1
    end

    -- wait and read some existing(?) crap
    util.sleep_time(0.1)
    ffi.C.read(fd, buffer, chunk_size)

    serial_out = io.open(SERIAL_PORT, "wb")
    if not serial_out then
        util:log("ERROR opening serial_out")
        ffi.C.close(fd)
        return
    end
    serial_out:write(util.HexToNum(write_data_hex))
    serial_out:flush()

    while true do
        util.sleep_time(0.25)
        local nbytes = ffi.C.read(fd, buffer, chunk_size)

        print("nbytes=", nbytes)
        if nbytes <= 0 then
            break
        end

        for i = 0, nbytes-1 do
            table.insert(self.answer, buffer[i])
        end
    end

    serial_out:close()
    ffi.C.close(fd)

    for i = 1, #self.answer do
        print("xxx", string.format("x%02x", self.answer[i]))
    end
end

function AntBMS:reboot()
    local serial_out
    local reboot = 254 -- adress of auto balance
    local write_data_hex = "A5A5".. string.format("%02x", reboot) .. "00" .. "00" .. string.format("%02x", reboot)

    self.answer = {}

    print("xxx setAutoBalance", write_data_hex)

    local fd = ffi.C.open(SERIAL_PORT, O_NONBLOCK)
    if fd <= 0 then
        util:log("ERROR opening serial_in")
        return -1
    end

    -- wait and read some existing(?) crap
    util.sleep_time(0.1)
    ffi.C.read(fd, buffer, chunk_size)

    serial_out = io.open(SERIAL_PORT, "wb")
    if not serial_out then
        util:log("ERROR opening serial_out")
        ffi.C.close(fd)
        return
    end
    serial_out:write(util.HexToNum(write_data_hex))
    serial_out:flush()

    while true do
        util.sleep_time(0.25)
        local nbytes = ffi.C.read(fd, buffer, chunk_size)

        print("nbytes=", nbytes)
        if nbytes <= 0 then
            break
        end

        for i = 0, nbytes-1 do
            table.insert(self.answer, buffer[i])
        end
    end

    serial_out:close()
    ffi.C.close(fd)

    for i = 1, #self.answer do
        print("xxx", string.format("x%02x", self.answer[i]))
    end
end

function AntBMS:readAutoBalance()
    local serial_out
    local auto_balance = 252 -- adress of auto balance

    local read_data_hex = "5A5A" .. string.format("%02x", auto_balance) .. "00" .. "00" .. string.format("%02x", auto_balance)

    self.answer = {}

    print("xxx ReadAutoBalance", read_data_hex)

    local fd = ffi.C.open(SERIAL_PORT, O_NONBLOCK)
    if fd <= 0 then
        util:log("ERROR opening serial_in")
        return -1
    end

    -- wait and read some existing(?) crap
    util.sleep_time(0.1)
    ffi.C.read(fd, buffer, chunk_size)

    serial_out = io.open(SERIAL_PORT, "wb")
    if not serial_out then
        util:log("ERROR opening serial_out")
        ffi.C.close(fd)
        return
    end
    serial_out:write(util.HexToNum(read_data_hex))
    serial_out:flush()

    while true do
        util.sleep_time(0.25)
        local nbytes = ffi.C.read(fd, buffer, chunk_size)

        print("nbytes=", nbytes)
        if nbytes <= 0 then
            break
        end

        for i = 0, nbytes-1 do
            table.insert(self.answer, buffer[i])
        end
    end

    serial_out:close()
    ffi.C.close(fd)

    for i = 1, #self.answer do
        print("xxx", string.format("x%02x", self.answer[i]))
    end

end

function AntBMS:_readData()
    local serial_out
    local request_hex = "DBDB00000000"

    local fd = ffi.C.open(SERIAL_PORT, O_NONBLOCK)
    if fd <= 0 then
        util:log("ERROR opening serial_in")
        return -1
    end

    -- wait and read some existing(?) crap
    util.sleep_time(0.1)
    ffi.C.read(fd, buffer, chunk_size)

    serial_out = io.open(SERIAL_PORT, "wb")
    if not serial_out then
        util:log("ERROR opening serial_out")
        ffi.C.close(fd)
        return
    end
    serial_out:write(util.HexToNum(request_hex))
    serial_out:flush()

    while true do
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
end

function AntBMS:isChecksumOk()
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
            util:log("to less data")
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

    util:log("xxx checksum error", checksum, expected)
    return false
end

-- This is the usual way of reading new parameters
function AntBMS:evaluateParameters()
    -- Require Data only, if the last require was at least a second ago
    if self:getDataAge() < 1 then -- todo make this configurable
        return true
    end

    -- see https://github.com/klotztech/VBMS/wiki/Serial-protocol
    self.v = {} -- clear old values

    local checksum = false
    local retries = 10
    while #self.answer < 140 and retries > 0 do
        self:_readData()
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

    self.v.uptime = getInt32(self.answer, 87)

    self.v.Temperature = {}
    for i = 1, 6 do
        local start = 2*(i-1) + 91
        self.v.Temperature[i] = getInt16(self.answer, start) --todo getInt might return neg. values
        if math.abs(self.v.Temperature[i]) > 300 then -- not connected
            self.v.Temperature[i] = 0
        end
    end

    self.v.ChargeMos = getInt8(self.answer, 103)
    self.v.DischargeMos = getInt8(self.answer, 104)
    self.v.BalancedStatusFlag = getInt8(self.answer, 105)

    self.v.ChargeMosText = self.MOSFETChargeStatusFlag[self.v.ChargeMos]
    self.v.DischargeMosText = self.MOSFETChargeStatusFlag[self.v.DischargeMos]
    self.v.BalancedStatusText = self.BalancedStatusText[self.v.BalancedStatusFlag]

    self.v.TireLength = getInt16(self.answer, 106)
    self.v.PulsesPerWeek = getInt16(self.answer, 108)

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


    self.v.BalancingFlags = getInt32(self.answer, 132)

    self.answer = {} -- clear old received bytes
    self.timeOfLastRequiredData = util.getCurrentTime()

    return true
end

function AntBMS:getSOC()
    -- Require SOC at mostly 1 time per minute
    if self:getDataAge() > 60 or not self.v.SOC then
        self:evaluateParameters()
    end
    return self.v.SOC or 50
end

function AntBMS:getDataAge()
    return util.getCurrentTime() - self.timeOfLastRequiredData
end

function AntBMS:printValues()
    local success, err = pcall(self._printValuesNotProtected, self)
    if not success then
        util:log("BMS reported no values; Error: ", tostring(err))
    end
end

function AntBMS:_printValuesNotProtected()
    self:evaluateParameters()

    if self.v == {} then
        util:log("No values decoded yet!")
        return false
    end

    util:log(string.format("SOC = %3d%%", self:getSOC()))
    util:log(string.format("Current Power = %d W", self.v.CurrentPower))
    util:log(string.format("Current = %3.1f A", self.v.Current))

    util:log(string.format("rem. capacity  = %3.3f Ah", self.v.RemainingCapacity))
    util:log(string.format("phys. capacity = %3.3f Ah", self.v.PhysicalCapacity))

    util:log(string.format("Number of Batteries = %2d", self.v.NumberOfBatteries))

    util:log(string.format("Charge MOSFET status: %s", self.v.ChargeMosText))
    util:log(string.format("Charge MOSFET status: %s", self.v.DischargeMosText))
    util:log(string.format("Balanced status: %s", self.v.BalancedStatusText))

    local _, bitString
    _, bitString = util.numToBits(self.v.BalancingFlags, self.v.NumberOfBatteries) -- _ is a table of the bits ;-)

    util:log(string.format("Active Balancers : %s", bitString))

    for i = 1, self.v.NumberOfBatteries, 2 do
        util:log(string.format("Voltage[%2d] = %2.3f V", i, self.v.Voltage[i]),
            i+1 <= self.v.NumberOfBatteries and string.format("Voltage[%2d] = %2.3f V", i+1, self.v.Voltage[i+1]) or "")
    end
    util:log(string.format("TotalVoltage    = %3.1f V", self.v.TotalVoltage))
    util:log(string.format("Voltage sum     = %3.3f V", self.v.VoltageSum))

    util:log(string.format("average voltage = %1.3f V", self.v.AverageVoltage))
    util:log(string.format("Cell difference = %1.3f V", self.v.HighestVoltage - self.v.LowestVoltage))

    util:log(string.format("lowest monomer  = %d ", self.v.LowestMonomer), "", string.format("highest monomer = %d ", self.v.HighestMonomer ))
    util:log(string.format("lowest voltage  = %1.3f V", self.v.LowestVoltage), string.format("highest voltage = %1.3f V", self.v.HighestVoltage))


    util:log("")
    util:log(string.format("DischargeTubeVoltageDrop    = % 3.1f V", self.v.DischargeTubeVoltageDrop))
    util:log(string.format("DischargeTubeDriveVoltage   = % 3.1f V", self.v.DischargeTubeDriveVoltage))
    util:log(string.format("ChargeTubeDriveVoltage      = % 3.1f V", self.v.ChargeTubeDriveVoltage))

    util:log("Temperatures:")
    for i = 1,6,2 do
        util:log(string.format("%d = %3d°C", i, self.v.Temperature[i]), string.format("%d = %3d°C", i, self.v.Temperature[i+1]))
    end

    util:log(string.format("Age of data = %6.3f s", self:getDataAge()))
    return true
end

AntBMS:init()

AntBMS:evaluateParameters()

local help_string = [[
This module provides methods to control an ANT-BMS (version before 2021; the "old one").

When this module is called with parameters, certain functions of the ANT-BMS can be executed.

usage: lua antbms.lua [command]
    command can be:
        show      ... shows current BMS values
        balon     ... turns auto balance on
        baloff    ... turns auto balance off
        baltoggle ... toggles auto balance
        reboot    ... reboot bms
]]

-- Show initial values
arg[1] = arg[1] and string.lower(arg[1])
if arg[1] and string.find(arg[1], "help") then
    print(help_string)
elseif arg[1] and string.find(arg[1], "show") then
    AntBMS:printValues()
elseif arg[1] and string.find(arg[1], "balon") then
    AntBMS:setAutoBalance(true)
elseif arg[1] and string.find(arg[1], "baloff") then
    AntBMS:setAutoBalance(false)
elseif arg[1] and string.find(arg[1], "baltog") then
    AntBMS:toggleAutoBalance()
elseif arg[1] and string.find(arg[1], "reboot") then
    AntBMS:reboot()
elseif arg[1] then
    print(help_string)
    print("Wrong argument: " .. arg[1])
end

return AntBMS
