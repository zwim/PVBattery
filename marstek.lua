local bit = require("bit")
local socket = require("socket")

local Marstek = {
    client = nil,
    host = nil,
    ip = nil, -- IP-Adresse des ELFIN WL11A
    port = nil, -- Modbus TCP Port
    slaveId = nil, -- Slave ID
}

function Marstek:new(o)
    o = o or {}   -- create object if user does not provide one
    setmetatable(o, self)
    self.__index = self
    return o
end

local registers = {}
-- registers.         = {adr = , typ = "", gain = , unit = ""}

registers.readBatteryVoltage     = {adr = 32100, typ = "u16", gain = 0.01, unit = "V"}
registers.readBatteryCurrent     = {adr = 32101, typ = "s16", gain = 0.01, unit = "A"}
registers.readBatteryPower       = {adr = 32102, typ = "s32", gain = 1, unit = "W"}
registers.readBatterySOC         = {adr = 32104, typ = "u16", gain = 1, unit = "%"}
registers.readBatteryTotalEnergy = {adr = 32105, typ = "u16", gain = 0.001, unit = "kWh"}

registers.readACVoltage   = {adr = 32200, typ = "u16", gain = 0.1, unit = "V"}
registers.readACCurrent   = {adr = 32201, typ = "u16", gain = 0.01, unit = "A"}
registers.readACPower     = {adr = 32202, typ = "s32", gain = 1, unit = "W"}

registers.readACOffgridVoltage  = {adr = 32300, typ = "u16", gain = 0.1, unit = "V"}
registers.readACOffgridCurrent  = {adr = 32301, typ = "u16", gain = 0.01, unit = "A"}
registers.readACOffgridPower    = {adr = 32302, typ = "s32", gain = 1, unit = "W"}

registers.readInternalTemperature = {adr = 35000, typ = "s16", gain = 0.1, unit = "°C"}
registers.readMaxCellTemperature  = {adr = 35010, typ = "s16", gain = 0.1, unit = "°C"}
registers.readMinCellTemperature  = {adr = 35011, typ = "s16", gain = 0.1, unit = "°C"}

-- Modbus TCP Funktion zum Lesen von Holding Registers
local transactionId = 0x0001
function Marstek:readHoldingRegisters(ip, port, slaveId, quantity, reg)
    if not self.client then
        self.client = socket.tcp()
        self.client:settimeout(5)
        self.client:setoption("keepalive", true)  -- Aktiviert TCP-Keepalive
        local success, err = self.client:connect(ip, port)
        if not success then
            print("Fehler beim Verbinden: " .. err)
            return nil
        end
    end

    local startAddress = reg.adr
    local size, signed

    if reg.typ:sub(1,1) == "s" then
        signed = true
    end

    size = tonumber(reg.typ:sub(2))
    local bytes = math.floor(size / 8)

    -- Modbus TCP Anfrage erstellen
    transactionId = (transactionId + 1) % 0xFFFF
    local protocolId = 0x0000
    local length = 6
    local functionCode = 0x03

    local request = string.char(
        bit.band(bit.rshift(transactionId, 8), 0xFF),
        bit.band(transactionId, 0xFF),
        bit.band(bit.rshift(protocolId, 8), 0xFF),
        bit.band(protocolId, 0xFF),
        bit.band(bit.rshift(length, 8), 0xFF),
        bit.band(length, 0xFF),
        slaveId,
        functionCode,
        bit.band(bit.rshift(startAddress, 8), 0xFF),
        bit.band(startAddress, 0xFF),
        bit.band(bit.rshift(quantity, 8), 0xFF),
        bit.band(math.floor(bytes/2), 0xFF)
    )

    self.client:send(request)

    local response, err
    response, err = self.client:receive(9 + bytes)
    if not response then
        print("Marstek: Fehler beim Empfangen der Antwort: " .. err .. " Try to reconnect")
        -- reconnect
        self.client:close()
        self.client = socket.tcp()
        self.client:settimeout(5)
        self.client:setoption("keepalive", true)
        local success
        success, err = self.client:connect(ip, port)
        if not success then
            print("Marstek: Fehler beim Verbinden: " .. err)
            return nil
        end
        self.client:send(request)
        response, err = self.client:receive(9 + bytes)
    end
    if not response then
        print("Marstek: Fehler beim Empfangen der Antwort: " .. err)
        return nil
    end

    -- Antwort analysieren
    if #response < 9 then
        print("Marstek: Ungültige Antwortlänge")
        return nil
    end

    local functionCodeResponse = string.byte(response, 8)
    if functionCodeResponse ~= functionCode then
        print("Marstek: Fehlerhafter Funktionode in der Antwort")
        return nil
    end

    local byteCountResponse = string.byte(response, 9)
    if byteCountResponse ~= bytes then
        print("Marstek: Fehlerhafte Byteanzahl in der Antwort")
        return nil
    end

    local value = 0
    for i = 1, bytes do
        value = value * 256 + string.byte(response, 9 + i)
    end

    if signed then
        if size == 16 then
            if value >= (2^15) then
                value = value - (2^16)
            end
        elseif size == 32 then
            if value >= (2^31) then
                value = value - (2^32)
            end
        end
    end
    return value * reg.gain
end

function Marstek:readBatteryVoltage()
    return self:readHoldingRegisters(self.ip, self.port, self.slaveId, 1, registers.readBatteryVoltage),
    "Battery Voltage", registers.readBatteryVoltage.unit
end
function Marstek:readBatteryCurrent()
    return self:readHoldingRegisters(self.ip, self.port, self.slaveId, 1, registers.readBatteryCurrent),
    "Battery Current", registers.readBatteryCurrent.unit
end
-- negative meanse that the battery is discharching
function Marstek:readBatteryPower()
    return self:readHoldingRegisters(self.ip, self.port, self.slaveId, 1, registers.readBatteryPower),
    "Battery Power", registers.readBatteryPower.unit
end
function Marstek:readBatterySOC()
    return self:readHoldingRegisters(self.ip, self.port, self.slaveId, 1, registers.readBatterySOC),
    "Battery SOC", registers.readBatterySOC.unit
end
function Marstek:readBatteryTotalEnergy()
    return self:readHoldingRegisters(self.ip, self.port, self.slaveId, 1, registers.readBatteryTotalEnergy),
    "Battery TotalEnergy", registers.readBatteryTotalEnergy.unit
end

function Marstek:readACVoltage()
    return self:readHoldingRegisters(self.ip, self.port, self.slaveId, 1, registers.readACVoltage),
    "Battery Voltage", registers.readACVoltage.unit
end
function Marstek:readACCurrent()
    return self:readHoldingRegisters(self.ip, self.port, self.slaveId, 1, registers.readACCurrent),
    "Battery Current", registers.readACCurrent.unit
end
-- negative meanse that the battery is discharching
function Marstek:readACPower()
    return self:readHoldingRegisters(self.ip, self.port, self.slaveId, 1, registers.readACPower),
    "Battery Power", registers.readACPower.unit
end



return Marstek

--[[



local function printValue(value, name, unit)
    if value then
        print(string.format("%s: %s %s", name, tostring(value), unit))
    end
end


-- Beispielaufruf
local ip = "192.168.0.208" -- IP-Adresse des ELFIN WL11A
local port = 502 -- Modbus TCP Port
local slaveId = 1 -- Slave ID


local VenusE = Marstek:new({ip = ip, port=port, slaveId = slaveId})

printValue(VenusE:readBatterySOC())
printValue(VenusE:readBatteryVoltage())
printValue(VenusE:readBatteryCurrent())
printValue(VenusE:readBatteryPower())
printValue(VenusE:readBatteryTotalEnergy())

]]