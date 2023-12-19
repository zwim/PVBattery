-- loads the HTTP module and any libraries it requires
local http = require("socket.http")
-- json module
local json = require ("dkjson")

local config = require("configuration")
local util = require("util")

local decode_unchecked = json.decode
function json.decode(data)
    if data then
        return decode_unchecked(data)
    else
        return {}
    end
end

local Switch = {
    timeOfLastRequiredData = 0, -- no data requiered yet
    host = nil,
    body = nil,
    status = nil,
    headers = nil,
    code = nil,
    max_power = 0,
    power_state = 0,
    }

function Switch:new(o)
    o = o or {}   -- create object if user does not provide one
    setmetatable(o, self)
    self.__index = self
    return o
end

function Switch:getDataAge()
    return util.getCurrentTime() - self.timeOfLastRequiredData
end

local getstat = 1
function Switch:_getStatus()
    print("xxx getstat:", getstat, "host", self.host)
    if not self.host then
        return false
    end
    if self:getDataAge() < config.update_interval then
        return true
    end

    getstat = getstat + 1

    local url = string.format("http://%s/cm?cmnd=status%%200", self.host)
    self.body, self.code, self.headers, self.status = http.request(url)
    self.decoded = json.decode(self.body)

    self.timeOfLastRequiredData = util.getCurrentTime()
    return true
end

function Switch:getEnergyTotal()
    if not self:_getStatus() then
        return (0/0)
    end

    local Energy = self.decoded and self.decoded.StatusSNS and
        self.decoded.StatusSNS.ENERGY and self.decoded.StatusSNS.ENERGY.Total or (0/0)
    return Energy
end

function Switch:getEnergyToday()
    if not self:_getStatus() then
        return (0/0)
    end

    local Energy = self.decoded and self.decoded.StatusSNS and
        self.decoded.StatusSNS.ENERGY and self.decoded.StatusSNS.ENERGY.Today or (0/0)
    return Energy
end

function Switch:getEnergyYesterday()
    if not self:_getStatus() then
        return (0/0)
    end

    local Energy = self.decoded and self.decoded.StatusSNS and
        self.decoded.StatusSNS.ENERGY and self.decoded.StatusSNS.ENERGY.Yesterday or (0/0)
    return Energy
end

function Switch:getPower()
    if not self:_getStatus() then
        return (0/0)
    end

    local Power = self.decoded and self.decoded.StatusSNS and
        self.decoded.StatusSNS.ENERGY and self.decoded.StatusSNS.ENERGY.Power or (0/0)

    if Power and Power > 50 then
        local weight = 0.1
        self.max_power = self.max_power * ( 1 - weight) + Power * weight
    end
--[[    if Power > self.max_power then
        self.max_power = Power
    end ]]
    return Power
end

function Switch:getMaxPower()
    return self.max_power
end

function Switch:getPowerState()
    if not self:_getStatus() then
        return ""
    end

    if self:getDataAge() > config.update_interval then
        self:getPower() -- update max_power
    end

    self.power_state = self.decoded and self.decoded.Status and self.decoded.Status.Power
--    util:log(self.power_state)
    if self.power_state == 0 then
        return "off"
    elseif self.power_state == 1 then
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
