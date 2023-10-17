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

local util = require("util")

local Switch = {
    timeOfLastRequiredData = 0, -- no data requiered yet
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

function Switch:getDataAge()
    return util.getCurrentTime() - self.timeOfLastRequiredData
end

function Switch:_getStatus()
    if not self.host then
        return false
    end
    if self:getDataAge() < 1 then
        return true
    end
    local url = string.format("http://%s/cm?cmnd=Status%%200", self.host)
    self.body, self.code, self.headers, self.status = http.request(url)
    self.decoded = json.decode(self.body)

    self.timeOfLastRequiredData = util.getCurrentTime()
    return true
end

function Switch:getEnergyTotal()
    if not self:_getStatus() then
        return (0/0)
    end

    local Energy = self.decoded and self.decoded.StatusSNS and self.decoded.StatusSNS.ENERGY and self.decoded.StatusSNS.ENERGY.Total or (0/0)
    return Energy
end

function Switch:getEnergyToday()
    if not self:_getStatus() then
        return (0/0)
    end

    local Energy = self.decoded and self.decoded.StatusSNS and self.decoded.StatusSNS.ENERGY and self.decoded.StatusSNS.ENERGY.Today or (0/0)
    return Energy
end

function Switch:getEnergyYesterday()
    if not self:_getStatus() then
        return (0/0)
    end

    local Energy = self.decoded and self.decoded.StatusSNS and self.decoded.StatusSNS.ENERGY and self.decoded.StatusSNS.ENERGY.Yesterday or (0/0)
    return Energy
end

function Switch:getPower()
    if not self:_getStatus() then
        return (0/0)
    end

    local Power = self.decoded and self.decoded.StatusSNS and self.decoded.StatusSNS.ENERGY and self.decoded.StatusSNS.ENERGY.Power or (0/0)
    return Power
end

function Switch:getPowerState()
    if not self:_getStatus() then
        return ""
    end

    local Power = self.decoded and self.decoded.Status and self.decoded.Status.Power
    util:log(Power)
    if Power == 0 then
        return "off"
    elseif Power == 1 then
        return "on"
    else
        return ""
    end
end

function Switch:toggle(on)
    if not self.host then return end

    if not on then
        on = "2"
    end
    util:log(self.host)
    local url = string.format("http://%s/cm?cmnd=Power0%%20%s", self.host, tostring(on))
    self.body, self.code, self.headers, self.status = http.request(url)
    local decoded = json.decode(self.body)
    self.Result = decoded.POWER
    return self.Result or ""
end

return Switch