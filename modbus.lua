local bit = require("bit")
local socket = require("socket")

local Modbus = {}

local transactionId = 0x0000 -- we will increment before first use

function Modbus:ensureConnection(ip, port)
    if self.client then self.client:close() end

    self.client = socket.tcp()
    self.client:settimeout(5)
    self.client:setoption("keepalive", true)
    local success, err = self.client:connect(ip, port)
    if not success then
        print("Fehler beim Verbinden: " .. tostring(err))
        self.client = nil
        return false
    end
    return true
end

function Modbus:sendRequest(request, expectedLen)
    local response, err, bytes_sent
    bytes_sent, err = self.client:send(request)
    if not bytes_sent then
        print("Fehler beim Senden:", err)
        -- Hier kannst du auf err reagieren, z.B. reconnect versuchen
    elseif bytes_sent ~= #request then
        print("Fehler Bytes gesendet falsche Anzahl:", bytes_sent, #request)
    end


    response, err = self.client:receive(expectedLen)
    if not response then
        return nil, "Empfang fehlgeschlagen: " .. tostring(err)
    end
    return response, nil
end

-- luacheck: ignore self
function Modbus:checkResponse(request, response, err)
    if not response then
        print("Modbus: " .. tostring(err))
        return false
    end

    if response:byte(1) ~= request:byte(1) or response:byte(2) ~= request:byte(2) then
        print("Modbus: Falscher Transaktionscode in Antwort")
        return false
    end
    if response:byte(3) ~= request:byte(3) or response:byte(4) ~= request:byte(4) then
        print("Marstek: Falsche Protokoll-ID in Antwort")
        return false
    end

    if response:byte(7) ~= request:byte(7) then
        print("Modbus: Falsche Unit-ID in Antwort")
        return false
    end

    if response:byte(8) ~= request:byte(8) then
        print("Modbus: Fehlerhafter Funktionscode in Antwort")
        return false
    end

    return true
end

function Modbus:readHoldingRegisters(ip, port, slaveId, quantity, reg)
    if not self:ensureConnection(ip, port) then return nil end

    local startAddress = reg.adr
    local signed = reg.typ:sub(1,1) == "s"
    local size = tonumber(reg.typ:sub(2))
    local bytes = math.floor(size / 8)

    transactionId = (transactionId + 1) % 0xFFFF
    local protocolId = 0x0000
    local length = 6
    local functionCode = 0x03

    local request = string.char(
        bit.rshift(transactionId, 8), bit.band(transactionId, 0xFF),
        bit.rshift(protocolId, 8), bit.band(protocolId, 0xFF),
        bit.rshift(length, 8), bit.band(length, 0xFF),
        slaveId,
        functionCode,
        bit.rshift(startAddress, 8), bit.band(startAddress, 0xFF),
        bit.rshift(quantity, 8), bit.band(math.floor(bytes/2), 0xFF)
    )

    local response, err = self:sendRequest(request, 9 + bytes)

    self.client:close()
    self.client = nil

    if not self:checkResponse(request, response, err) then
        return false
    end

    if #response < 9 then
        print("Modbus: Ungültige Antwortlänge")
        return false
    end

    if response:byte(9) ~= bytes then
        print("Modbus: Fehlerhafte Byteanzahl in Antwort")
        return false
    end

    local value = 0
    for i = 1, bytes do
        value = value * 256 + response:byte(9 + i)
    end

    if signed then
        if size == 16 and value >= 0x8000 then
            value = value - 0x10000
        elseif size == 32 and value >= 0x80000000 then
            value = value - 0x100000000
        end
    end

    return value * reg.gain
end

function Modbus:writeHoldingRegisters(ip, port, slaveId, quant, reg, value)
    if not self:ensureConnection(ip, port) then return false end
    if quant ~= 1 then return false end

    local startAddress = reg.adr
    local size = tonumber(reg.typ:sub(2))
    local bytes = math.floor(size / 8)

    local intValue = math.floor(value / reg.gain + 0.5)

    local valueBytes = {}
    for i = bytes, 1, -1 do
        valueBytes[i] = bit.band(intValue, 0xFF)
        intValue = bit.rshift(intValue, 8)
    end

    transactionId = (transactionId + 1) % 0xFFFF
    local protocolId = 0x0000
    local quantity = bytes / 2
    local byteCount = bytes
    local functionCode = 0x10

    local request = string.char(
        bit.rshift(transactionId, 8), bit.band(transactionId, 0xFF),
        bit.rshift(protocolId, 8), bit.band(protocolId, 0xFF),
        bit.rshift(7 + byteCount, 8), bit.band(7 + byteCount, 0xFF),
        slaveId,
        functionCode,
        bit.rshift(startAddress, 8), bit.band(startAddress, 0xFF),
        bit.rshift(quantity, 8), bit.band(quantity, 0xFF),
        byteCount
    )

    for i = 1, byteCount do
        request = request .. string.char(valueBytes[i])
    end

    local response, err = self:sendRequest(request, #request)

    self.client:close()
    self.client = nil

    if not self:checkResponse(request, response, err) then
        return nil
    end

    return true
end

return Modbus
