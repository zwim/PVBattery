local bit = require("bit")
local socket = require("socket")

local Marstek = {
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
registers.readBatteryVoltage     = {adr = 32100, typ = "u16", gain = 0.01, unit = "V"}
registers.readBatteryCurrent     = {adr = 32101, typ = "s16", gain = 0.01, unit = "A"}
registers.readBatteryPower       = {adr = 32102, typ = "s32", gain = 1, unit = "W"}
registers.readBatterySOC         = {adr = 32104, typ = "u16", gain = 1, unit = "%"}
registers.readBatteryTotalEnergy = {adr = 32105, typ = "u16", gain = 0.001, unit = "kWh"}

-- Modbus TCP Funktion zum Lesen von Holding Registers
local function readHoldingRegisters(ip, port, slaveId, quantity, reg)

    local client = socket.tcp()
    client:settimeout(5) -- Timeout auf 10 Sekunden setzen

    local success, err = client:connect(ip, port)
    if not success then
        print("Fehler beim Verbinden: " .. err)
        return nil
    end

    local startAddress = reg.adr
    local size, signed

    if reg.typ:sub(1,1) == "s" then
        signed = true
    end

    size = tonumber(reg.typ:sub(2))
    local bytes = math.floor(size / 8)

    -- Modbus TCP Anfrage erstellen
    local transactionId = 0x0001
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

    client:send(request)

    local response
    response, err = client:receive(9 + bytes)
    if not response then
        print("Fehler beim Empfangen der Antwort: " .. err)
        return nil
    end

    client:close()

    -- Antwort analysieren
    if #response < 9 then
        print("Ungültige Antwortlänge")
        return nil
    end

    local functionCodeResponse = string.byte(response, 8)
    if functionCodeResponse ~= functionCode then
        print("Fehlerhafter Funktionode in der Antwort")
        return nil
    end

    local byteCountResponse = string.byte(response, 9)
    if byteCountResponse ~= bytes then
        print("Fehlerhafte Byteanzahl in der Antwort")
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
    return readHoldingRegisters(self.ip, self.port, self.slaveId, 1, registers.readBatteryVoltage),
    "Battery Voltage", registers.readBatteryVoltage.unit
end

function Marstek:readBatteryCurrent()
    return readHoldingRegisters(self.ip, self.port, self.slaveId, 1, registers.readBatteryCurrent),
    "Battery Current", registers.readBatteryCurrent.unit
end

-- negative meanse that the battery is discharching
function Marstek:readBatteryPower()
    return readHoldingRegisters(self.ip, self.port, self.slaveId, 1, registers.readBatteryPower),
    "Battery Power", registers.readBatteryPower.unit
end
function Marstek:readBatterySOC()
    return readHoldingRegisters(self.ip, self.port, self.slaveId, 1, registers.readBatterySOC),
    "Battery SOC", registers.readBatterySOC.unit
end
function Marstek:readBatteryTotalEnergy()
    return readHoldingRegisters(self.ip, self.port, self.slaveId, 1, registers.readBatteryTotalEnergy),
    "Battery TotalEnergy", registers.readBatteryTotalEnergy.unit
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