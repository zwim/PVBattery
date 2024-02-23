--
--
-- see:
-- https://github.com/syssi/esphome-ant-bms
-- see https://github.com/klotztech/VBMS/wiki/Serial-protocol

local http = require("socket.http")
local util = require("util")
local config = require("configuration")

local READ_DATA_SIZE = 140
-- command to hard reset a connected ESP32 device
local ESP32_HARD_RESET_COMMAND = "killall minicom; killall tio; " ..
    "esptool.py --chip esp32 --port /dev/ttyUSB0 --baud 460800 --before default_reset --after hard_reset run"


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
    host = "",
    v = {},
    timeOfLastRequiredData = 0, -- no data yet
    timeOfLastFullBalancing = 0, -- no data yet

    MOSFETChargeStatusFlag = {
        [0] = "Off",
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
    },

    MOSFETDischargeStatusFlag = {
        [0] = "Off",
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
    },

    BalancedStatusText = {
        [0] = "Off",
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
    },
--    BalancedStatusText[0] = "Off",

    answer = {},
    rescue_charge = false, -- flag if battery is to low
}

function AntBMS:new(o)
    o = o or {}   -- create object if user does not provide one
    o.lastFullPeriod = o.lastFullPeriod or 2*24*3600 -- two days for now xxx
    o.minCellDiff = o.minCellDiff or 0.03
    o.minPower = o.minPower or 50
    setmetatable(o, self)
    self.__index = self
    return o
end

function AntBMS:setAutoBalance(on)
    if on == nil then
        on = true
    end

    self:evaluateData(true)

    util:log("Balancer status was ",
        self.v.BalancedStatusText and string.lower(self.v.BalancedStatusText) or self.v.BalancedStatusFlag)

    if not self.v.BalancedStatusText then
        util:log("xxxx error self.v.BalancedStatusText is nil")
        return
    end

    if on then
        if next(self.v) and self.v.CellDiff >= self.minCellDiff then
            self:turnAutoBalanceOn()
        end
    else
        self:turnAutoBalanceOff()
    end
end

function AntBMS:_sendCommand(cmd)
    if not self.host or self.host == "" then return end

    local url = string.format("http://%s/%s", self.host, cmd)
    local body, code = http.request(url)
    code = tonumber(code)
    if not code or code < 200 or code >=300 or not body then
        return nil
    else
        return body
    end
end

function AntBMS:reboot()
    return self:_sendCommand("reboot")
end

function AntBMS:toggleAutoBalance()
    return self:_sendCommand("balance.toggle")
end

function AntBMS:turnAutoBalanceOn()
    return self:_sendCommand("balance.on")
end

function AntBMS:turnAutoBalanceOff()
    return self:_sendCommand("balance.off")
end

function AntBMS:readAutoBalance()
    return self:_sendCommand("balance.get")
end

function AntBMS:enableBluetooth()
    return self:_sendCommand("set?bluetooth=1")
end

-- todo check result
function AntBMS:enableDischarge()
    return self:_sendCommand("set?bms_discharge=1")
end

-- todo check result
function AntBMS:disableDischarge()
    return self:_sendCommand("set?bms_discharge=0")
end

function AntBMS:getDischargeState()
    if self:evaluateData() then
        return (self.v.DischargeMos == 1) and "on" or "off"
    end
end

-- set power and en/disable bms discharge mos
function AntBMS:setPower(power)
    if not self.host or self.host == "" then return end

    if power > 0 then
        self:enableDischarge()
        util.sleep_time(1)
    end

    self:_sendCommand(string.format("set?power=%d", power))

    if power == 0 then
        util.sleep_time(1)
        self:disableDischarge()
    end
end

function AntBMS:isChecksumOk()
    if #self.answer < READ_DATA_SIZE then
        return false
    end

    local expected, checksum
    -- We leaf the loop if checksum is OK or if there is to less data
    while true do
        -- delete leading bytes until 0xAA55AAFF
        while getInt32(self.answer, 0) ~= 0xAA55AAFF and #self.answer >= READ_DATA_SIZE do
            table.remove(self.answer, 1)
        end

        -- bail out if to less data left, after cleaning
        if #self.answer < READ_DATA_SIZE then
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
function AntBMS:evaluateData(force)
    if not self.host or self.host == "" then
        return false
    end

    -- Require Data only, if the last require was at least update_interval seconds ago.
    if not force and self:getDataAge() < config.update_interval then
        return true
    end

    -- If we get here, make invalidate the last data aquisition date.
    -- Will be updated when new correct data are read.
    self:clearDataAge()

    local checksum = false
    local retries = 10
    while #self.answer < READ_DATA_SIZE and retries > 0 do
        local url = string.format("http://%s/live.data", self.host)
        local body, code
        for _ = 1, 2 do -- try to wake up BT-Module by starting a short charge
            for _ = 1, 4 do -- try to read a few times
                body, code = http.request(url)
                code = tonumber(code)
                if code and body then break end
                os.execute("date")
                os.execute("echo Could not read bms.data -> try again.")
                util.sleep_time(1)
            end
            if code and body then break end
            os.execute("date")
            os.execute("echo Could not get bms.data -> starting a wakup charge.")
            self.wakeup()
            util.sleep_time(config.sleep_time)
        end
        if not code or not body then
            -- maybe the BMS has lost internet connection, so reset the ESP32
            -- no need any more, as bsm will reset itself now.
            --os.execute(ESP32_HARD_RESET_COMMAND)
            os.execute(ESP32_HARD_RESET_COMMAND)
            os.execute("date")
            os.execute("Could not read bsm.data -> reboot ESP32 -> echo sleeping " .. config.sleep_time)
            util.sleep_time(config.sleep_time)
            return false
        end
        self.answer = {}
        for n = 1, #body do
            table.insert(self.answer, body:byte(n))
        end

        checksum = self:isChecksumOk()
        if checksum then
            break
        end
        retries = retries - 1
    end

    if not checksum then
        self:enableBluetooth()
        return false
    end

    -- see https://github.com/klotztech/VBMS/wiki/Serial-protocol
    self.v = {} -- clear old values

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
    self.v.CalculatedSOC = util.roundTo(self.v.RemainingCapacity / self.v.PhysicalCapacity * 100, -2)

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
    self.v.DischargeMosText = self.MOSFETDischargeStatusFlag[self.v.DischargeMos]
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

    self.v.CellDiff = util.roundTo(self.v.HighestVoltage - self.v.LowestVoltage, -3)

    self.v.AverageVoltage = getInt16(self.answer, 121)* 1e-3

    self.v.NumberOfBatteries = getInt8(self.answer, 123)

    self.v.DischargeTubeVoltageDrop = getInt16(self.answer, 124) * 0.1
    if self.v.DischargeTubeVoltageDrop > 2^15 then
        self.v.DischargeTubeVoltageDrop = self.v.DischargeTubeVoltageDrop - 2^15
    end
    self.v.DischargeTubeVoltageDrop = self.v.DischargeTubeVoltageDrop * 0.1

    self.v.DischargeTubeDriveVoltage = getInt16(self.answer, 126) * 0.1
    self.v.ChargeTubeDriveVoltage = getInt16(self.answer, 128) * 0.1

    self.v.BalancingFlags = getInt32(self.answer, 132)

    self.v.ActiveBalancersBits, self.v.ActiveBalancers
        = util.numToBits(self.v.BalancingFlags, self.v.NumberOfBatteries)

    self.answer = {} -- clear old received bytes

print(os.time())
    if util.getCurrentTime() >= self.timeOfLastFullBalancing + config.lastFullPeriod then
        config.bat_SOC_max = 101
    end
    
    if self.v.SOC >= 100 and self.v.CalculatedSOC >= 100 and self.v.CellDiff <= self.minCellDiff 
        and self.v.CurrentPower > 0 and self.v.CurrentPower <= self.minPower then

        self.timeOfLastFullBalancing = util.getCurrentTime()
        config.bat_SOC_max = config.bat_SOC_full
    end

    -- Now we store the new aquisition time.
    self:setDataAge()
    return true
end

-- This is the usual way of reading new parameters
function AntBMS:getParameters()
    if not self.host or self.host == "" then
        return false
    end

    local retries = 10
    while #self.answer < READ_DATA_SIZE and retries > 0 do
        local url = string.format("http://%s/parameters.backup", self.host)
        local body, code
        for _ = 1, 5 do -- try to read a few times
            body, code = http.request(url)
            code = tonumber(code)
            if code and body then break end
            os.execute("date")
            os.execute("echo Could not get bms parameters")
            util.sleep_time(1)
        end
        if not code or not body then
            -- maybe the BMS has lost internet connection, so reset the ESP32
            -- no need any more, as bsm will reset itself now.
            --os.execute(ESP32_HARD_RESET_COMMAND)
            os.execute(ESP32_HARD_RESET_COMMAND)
            os.execute("date")
            os.execute("echo sleeping " .. config.sleep_time)
            util.sleep_time(config.sleep_time)
            return false
        end
        self.answer = {}
        for n = 1, #body do
            table.insert(self.answer, body:byte(n))
        end

        if #self.answer == 256*2 then
            break
        end
        retries = retries - 1
    end

    if #self.answer ~= 256*2 then
        return false
    end

    -- see https://github.com/klotztech/VBMS/wiki/Serial-protocol
    self.Parameters = {} -- clear old values
    for n = 1, 256 do
        self.Parameter[n] = self.answer[n*2] * 256 + self.answer[n*2-1]
    end

    self.answer = {} -- clear old received bytes

    for n = 1, 256 do
        print(string:format("%3d: 0x%X", n, self.Parameter[n]))
    end


    return true
end

function AntBMS:getDataAge()
    return util.getCurrentTime() - self.timeOfLastRequiredData
end

function AntBMS:setDataAge()
    self.timeOfLastRequiredData = util.getCurrentTime()
end

function AntBMS:clearDataAge()
    self.timeOfLastRequiredData = 0
end

function AntBMS:printValues()
    self:evaluateData()
    local success, err = pcall(self._printValuesNotProtected, self)
    if not success then
        util:log("BMS reported no values; Error: ", tostring(err))
    end
end

function AntBMS:readyToCharge()
    if self:evaluateData() then
        if self.v.HighestVoltage >= config.bat_highest_voltage then
            return false
        elseif self.v.SOC > config.bat_SOC_max and self.v.CellDiff >= config.max_cell_diff then
            return false
        elseif self.v.SOC > config.bat_SOC_max then
            return false
        else
            return true
        end
    end
    return nil
end

function AntBMS:readyToDischarge()
    if self:evaluateData() then
        local start_discharge, continue_discharge
        if self.v.CellDiff > config.max_cell_diff then
            start_discharge = false
            if -1.0 <= self.v.Current and self.v.Current < 1.0 then
                continue_discharge = true
            else
                continue_discharge = false
            end
        elseif self.v.LowestVoltage < config.bat_lowest_voltage then
            start_discharge = false
            continue_discharge = false
        elseif self.v.LowestVoltage < config.bat_lowest_voltage + config.bat_voltage_hysteresis then
            start_discharge = false
            continue_discharge = true
        elseif self.v.SOC < config.bat_SOC_min + config.bat_SOC_hysteresis then
            start_discharge = false
            continue_discharge = false
        else
            start_discharge = true
            continue_discharge = true
        end
        return start_discharge, continue_discharge
    end
end

function AntBMS:isLowChargedOrNeedsRescue()
    if self:evaluateData() then
        if self.v.LowestVoltage < config.bat_lowest_rescue or self.v.SOC < config.bat_SOC_min_rescue then
            self.rescue_charge = true
            return true
        elseif self.v.LowestVoltage < config.bat_lowest_voltage or self.v.SOC <= config.bat_SOC_min then
            return true
        else
            self.rescue_charge = false
            return false
        end
    end
    return
end

function AntBMS:needsRescueCharge()
    return self.rescue_charge
end

function AntBMS:recoveredFromRescueCharge()

    if not self.rescue_charge then
        return true
    end

    if self:evaluateData(true) then
        if self.v.LowestVoltage > config.bat_lowest_rescue
            and self.v.LowestVoltage > config.bat_lowest_voltage
            and self.v.SOC > config.bat_SOC_min_rescue
            and self.v.SOC > config.bat_SOC_min then
                self.rescue_charge = false
                return true
        else
                return false
        end
    end
    return
end

function AntBMS:needsBalancing()
    if self:evaluateData() then
        if self.v.CellDiff >= config.max_cell_diff
                or self.v.HighestVoltage >= config.bat_highest_voltage then
            self:enableDischarge()
            self:setAutoBalance(true)
        elseif -1.0 <= self.v.Current and self.v.Current <= 1.0 then
            if not self:getDischargeState() then
                self:enableDischarge()
                self:setAutoBalance(true)
            end
        end
    end
end

function AntBMS:_printValuesNotProtected()
    if not next(self.v) then -- check if table self.v is empty!
        util:log("No values decoded yet!")
        return false
    end

    util:log(string.format("BMS: %s", self.host))
    util:log(string.format("SOC = %3d%%", self.v.SOC))
    util:log(string.format("calc.SOC = %3.2f%%", self.v.CalculatedSOC or -6.66))

    local charging_text = ""
    if self.v.CurrentPower then
        if self.v.CurrentPower < 0 then
            charging_text = "charge"
        elseif self.v.CurrentPower > 0 then
            charging_text = "discharge"
        end
    end
    util:log(string.format("Current Power = %d W (%s)", self.v.CurrentPower or -666, charging_text))
    util:log(string.format("Current = %3.1f A", self.v.Current))

    util:log(string.format("rem. capacity  = %3.3f Ah", self.v.RemainingCapacity or -666))
    util:log(string.format("phys. capacity = %3.3f Ah", self.v.PhysicalCapacity or -666))
    util:log(string.format("cycle capacity = %3.3f Ah", self.v.CycleCapacity or -666))

    util:log(string.format("Number of Batteries = %2d", self.v.NumberOfBatteries or -666))

    util:log(string.format("Charge MOSFET status:    %s", self.v.ChargeMosText or "-666"))
    util:log(string.format("Discharge MOSFET status: %s", self.v.DischargeMosText or "-666"))
    util:log(string.format("Balanced status: %s", self.v.BalancedStatusText or "-666"))

    util:log(string.format("Active Balancers: %s", self.v.ActiveBalancers))

    local separator = {}
    for i = 1, self.v.NumberOfBatteries do
        separator[i] = tonumber(self.v.ActiveBalancersBits[i]) == 0 and "=" or "x"
    end

    for i = 1, self.v.NumberOfBatteries, 2 do
        util:log(string.format("[%2d] %s %2.3f V", i, separator[i], self.v.Voltage[i]),
            i+1 <= self.v.NumberOfBatteries and
                 string.format("[%2d] %s %2.3f V", i+1, separator[i+1], self.v.Voltage[i+1]) or "")
    end
    util:log(string.format("TotalVoltage    = %3.1f V", self.v.TotalVoltage))
    util:log(string.format("Voltage sum     = %3.3f V", self.v.VoltageSum))

    util:log(string.format("average voltage = %1.3f V", self.v.AverageVoltage))
    util:log(string.format("Cell difference = %1.3f V", self.v.CellDiff))

    util:log(string.format("lowest voltage [%d] = %1.3f V", self.v.LowestMonomer, self.v.LowestVoltage),
             string.format("highest voltage [%d] = %1.3f V", self.v.HighestMonomer, self.v.HighestVoltage))

    util:log("")
    util:log(string.format("DischargeTubeVoltageDrop  = % 4.1f V", self.v.DischargeTubeVoltageDrop))
    util:log(string.format("DischargeTubeDriveVoltage = % 4.1f V", self.v.DischargeTubeDriveVoltage))
    util:log(string.format("ChargeTubeDriveVoltage    = % 4.1f V", self.v.ChargeTubeDriveVoltage))

    util:log("Temperatures:")
    for i = 1,6,2 do
        util:log(string.format("[%d] = %3d°C",
            i, self.v.Temperature[i]), string.format("%d = %3d°C", i, self.v.Temperature[i+1]))
    end

    util:log(string.format("Age of data = %6.3f s", self:getDataAge()))
    util:log(os.date("%c", self.timeOfLastFullBalancing))

    return true
end

function AntBMS:wakeup()
end

return AntBMS
