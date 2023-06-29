-- loads the HTTP module and any libraries it requires
local http = require("socket.http")

-- json module
local json = require ("dkjson")
local decode_unchecked = json.decode
function json.decode(data)
    if data then
        return decode_unchecked(data)
    else
        return {}
    end
end

local host = "192.168.0.149"

local Switch = {
    host = nil,
    body = nil,
    status = nil,
    headers = nil,
    code = nil,
}

function Switch:new(o)
    o = o or {}   -- create object if user does not provide one
    setmetatable(o, self)
    self.__index = self
    return o
end

function Switch:init(host_name)
    self.host = host_name
end

function Switch:getEnergy()
    if not host then return end
    local url = string.format("http://%s/cm?cmnd=EnergyTotal", self.host)
    self.body, self.code, self.headers, self.status = http.request(url)
    local decoded = json.decode(self.body)
    self.Energy = decoded and decoded.EnergyTotal or {}
    return self.Energy
end

function Switch:getPower()
    if not host then return end
    local url = string.format("http://%s/cm?cmnd=Status%%208", self.host)
    self.body, self.code, self.headers, self.status = http.request(url)
    local decoded = json.decode(self.body)
    self.Power = decoded and decoded.StatusSNS and decoded.StatusSNS.ENERGY and decoded.StatusSNS.ENERGY.Power or nil
    return self.Power
end

function Switch:toggle(on)
    if not host then return end

    if not on then
        on = "2"
    end
    print(self.host)
    local url = string.format("http://%s/cm?cmnd=Power0%%20%s", self.host, tostring(on))
    self.body, self.code, self.headers, self.status = http.request(url)
    local decoded = json.decode(self.body)
    self.Result = decoded.POWER
    return self.Result or ""
end

function Switch:getPowerState()
    local url = string.format("http://%s/cm?cmnd=Power0", self.host)
    self.body, self.code, self.headers, self.status = http.request(url)
    local decoded = json.decode(self.body)
    self.Result = decoded.POWER
    print(self.host, self.Result)
    return self.Result or ""
end

return Switch