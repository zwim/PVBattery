local bit = require("bit")
local socket = require("socket")
local util = require("util")

local Modbus = {
    __name = "Modbus",

    ip = nil,
    port = nil,
    slave_id = nil,

    client = nil,
    transaction_id = nil,
}

function Modbus:log(level, ...)
    local loglevel = self.__loglevel or 3
    if config and config.loglevel then
        loglevel = math.min(loglevel, config.loglevel)
    end
    if level <= loglevel then
        print(os.date("%Y/%m/%d-%H:%M:%S ["..(getmetatable(self).__name or "???").."]"), ...)
    end
end


function Modbus:extend(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function Modbus:new(o)
    o = self:extend(o)
    if o.init then
        o:init()
    end
    return o
end

function Modbus:init()
    self.transaction_id = 0 -- will increment before first use
    self:ensureConnection()
end

function Modbus:ensureConnection()
    if self.client then return true end

    self.client = socket.tcp()
    self.client:settimeout(5)
    self.client:setoption("keepalive", true)
    local success, err = self.client:connect(self.ip, self.port)
    if not success then
        self:log(0, "Error on connecting to host: " .. self.ip .. "    " .. tostring(err))
        self.client = nil
        return false
    end
    return true
end

function Modbus:sendRequest(request, expectedLen)
    local response, err, bytes_sent
    bytes_sent, err = self.client:send(request)
    if not bytes_sent then
        self:log(0, "Error on send:", err)
        -- Hier kannst du auf err reagieren, z.B. reconnect versuchen
    elseif bytes_sent ~= #request then
        self:log(0, "Error wrong number of bytes sent:", bytes_sent, #request)
    end


    response, err = self.client:receive(expectedLen)
    if not response then
        return nil, "Receive incorrect: " .. tostring(err)
    end
    return response, nil
end

-- luacheck: ignore self
function Modbus:checkResponse(request, response, err)
    if not response then
        self:log(0, "Error in response: " .. tostring(err))
        return false
    end

    if response:byte(1) ~= request:byte(1) or response:byte(2) ~= request:byte(2) then
        self:log(0, "wrong transactionscode in response")
        return false
    end
    if response:byte(3) ~= request:byte(3) or response:byte(4) ~= request:byte(4) then
        self:log(0, "wrong protocoll id in in response")
        return false
    end

    if response:byte(7) ~= request:byte(7) then
        self:log(0, "wrong unit id in response")
        return false
    end

    if response:byte(8) ~= request:byte(8) then
        self:log(0, "wrong function-code in response")
        return false
    end

    return true
end

-- second_try should be nil for the first call, after an error it is set
function Modbus:readHoldingRegisters(quantity, reg, _second_try)
    if not self:ensureConnection() then return nil end

    local startAddress = reg.adr
    local signed = reg.typ:sub(1,1) == "s"
    local float = reg.typ:sub(1,1) == "f"
    local size = tonumber(reg.typ:sub(2,3))
    local little_endian = reg.typ:sub(4,4) == "l"
    local bytes = math.floor(size / 8)

    self.transaction_id = (self.transaction_id + 1) % 0xFFFF
    local protocolId = 0x0000
    local length = 6
    local functionCode = 0x03

    local request = string.char(
        bit.rshift(self.transaction_id, 8), bit.band(self.transaction_id, 0xFF),
        bit.rshift(protocolId, 8), bit.band(protocolId, 0xFF),
        bit.rshift(length, 8), bit.band(length, 0xFF),
        self.slave_id,
        functionCode,
        bit.rshift(startAddress, 8), bit.band(startAddress, 0xFF),
        bit.rshift(quantity, 8), bit.band(math.floor(bytes/2), 0xFF)
    )

    local response, err = self:sendRequest(request, 9 + bytes)

    if not self:checkResponse(request, response, err) then
        if _second_try then
            return
        else
            self.client:close()
            self.client = nil
            util.sleepTime(1.0)
            self:ensureConnection()
            return self:readHoldingRegisters(quantity, reg, true)
        end
    end

    if #response < 9 then
        self:log(0, "wrong length of response")
        return
    end

    if response:byte(9) ~= bytes then
        self:log(0, "wrong number of bytes in response")
        return
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
    elseif float then
        if size == 16 then
            self:log(0, "modbus float size 16 not implemented yet")
        elseif size == 32 then
            value = util.int32_to_float(value, little_endian)
        end
    end

    return value * reg.gain
end

-- second_try should be nil for the first call, after an error it is set
function Modbus:writeHoldingRegisters(quant, reg, value, _second_try)
    if not self:ensureConnection() then return false end
    if quant ~= 1 then return false end

    local startAddress = reg.adr
    local size = tonumber(reg.typ:sub(2,3))
    local bytes = math.floor(size / 8)

    local intValue = math.floor(value / reg.gain + 0.5)

    local valueBytes = {}
    for i = bytes, 1, -1 do
        valueBytes[i] = bit.band(intValue, 0xFF)
        intValue = bit.rshift(intValue, 8)
    end

    self.transaction_id = (self.transaction_id + 1) % 0xFFFF
    local protocolId = 0x0000
    local quantity = bytes / 2
    local byteCount = bytes
    local functionCode = 0x10

    local request = string.char(
        bit.rshift(self.transaction_id, 8), bit.band(self.transaction_id, 0xFF),
        bit.rshift(protocolId, 8), bit.band(protocolId, 0xFF),
        bit.rshift(7 + byteCount, 8), bit.band(7 + byteCount, 0xFF),
        self.slave_id,
        functionCode,
        bit.rshift(startAddress, 8), bit.band(startAddress, 0xFF),
        bit.rshift(quantity, 8), bit.band(quantity, 0xFF),
        byteCount
    )

    for i = 1, byteCount do
        request = request .. string.char(valueBytes[i])
    end

    local response, err = self:sendRequest(request, #request)

    if not self:checkResponse(request, response, err) then
        if _second_try then
            return nil
        else
            self.client:close()
            self.client = nil
            util.sleepTime(1.0)
            self:ensureConnection()
            return self:writeHoldingRegisters(quant, reg, value, true)
        end
    end

    return true
end

return Modbus
