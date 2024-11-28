
local config = require("configuration")
local json = require ("dkjson")
local util = require("util")

local http = {}
-- config.use_wget = nil
if config.use_wget then
    function http.request(url)
        return util.httpRequest(url)
    end
else
    -- loads the HTTP module and any libraries it requires
    http = require("socket.http")
    http.TIMEOUT=5
end

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
    if not o.timeOfLastRequiredData then
        o.timeOfLastRequiredData = 0
    end
    if not o.max_power then
        o.max_power = 0
    end
    setmetatable(o, self)
    self.__index = self
    return o
end

function Switch:getDataAge()
    return util.getCurrentTime() - self.timeOfLastRequiredData
end

function Switch:setDataAge()
    self.timeOfLastRequiredData = util.getCurrentTime()
end

function Switch:clearDataAge()
    self.timeOfLastRequiredData = 0
    self.decoded = nil
end

function Switch:_getStatus()
    if not self.host then
        return false
    end

    if self:getDataAge() < config.update_interval and self.decoded then
        return true
    end

    local url = string.format("http://%s/cm?cmnd=status%%200", self.host)
    local body, code = http.request(url)
    code = tonumber(code)
    if not code or code < 200 or code >= 300 then
        self.decoded = nil
        return false
    end
    self.decoded = json.decode(body)

    self:setDataAge()
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

    if Power and Power > 20 then
        local weight = 0.2
        self.max_power = (1-weight)*self.max_power + weight*Power
    end
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
    if self.power_state == 0 or self.power_state == "0" or self.power_state:find("^0.") then
        return "off"
    elseif self.power_state == 1 or self.power_state == "1" or self.power_state:find("^1.") then
        return "on"
    else
        return self.power_state
    end
end

--- toggles switch:
-- on: 0 ... off
-- on: 1 ... on
-- on: 2 ... toggle
function Switch:toggle(on)
    if not self.host then return end

    if not on then
        on = "2"
    end
    local url = string.format("http://%s/cm?cmnd=Power0%%20%s", self.host, tostring(on))
    http.request(url)
--[[
    local body, code = http.request(url)
    code = tonumber(code)
    if not code or code < 200 or code >= 300 then
        return
    end
    local decoded = json.decode(body)
    local Result =
    if decoded then
        Result = decoded.power
    end

    self:setDataAge()
    return Result ]]
end

return Switch
