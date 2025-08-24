
local util = require("util")

while true do

    -- This will just start it in background, but kills it if this script is stopped
    print("Execute PVBattery script")
    os.execute("lua PVBattery.lua")
    print("(OH NO) Crash happend at:")
    os.execute("date")

    util.sleepTime(1)
end
