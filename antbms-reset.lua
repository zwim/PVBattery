
-- command to hard reset a connected ESP32 device

-- quick and dirty, as the python-esptool interactin in gentoo as of 2024/06/26 seems broken
local RESET_COMMAND = "esptool.py"
local RESET_COMMAND_ARGS =
    " --chip esp32 --port /dev/ttyUSB0 --baud 460800 --before default_reset --after hard_reset run"
if os.execute(RESET_COMMAND .. " version 2> /dev/null") ~= 0 then
    RESET_COMMAND = "python /usr/lib/python-exec/python3.12/esptool.py"
    if os.execute(RESET_COMMAND .. " version 2> /dev/null") ~= 0 then
        RESET_COMMAND = "python /usr/share/esp-idf/components/esptool_py/esptool/esptool.py"
        if os.execute(RESET_COMMAND .. " version 2> /dev/null") ~= 0 then
            RESET_COMMAND = "uhubctl"
            RESET_COMMAND_ARGS = " -l 1-1 -d 10 -p 2 -a cycle"
        --                                   ^------------------ delay 10s
        end
    end
end

print("Reset command dedected: " .. RESET_COMMAND)

local ESP32_HARD_RESET_COMMAND = "killall minicom; killall tio; " .. RESET_COMMAND .. RESET_COMMAND_ARGS

if arg[0]:find("antbms[-]reset.lua") then
    print("execute: ", ESP32_HARD_RESET_COMMAND)
    os.execute(ESP32_HARD_RESET_COMMAND)
else
    return ESP32_HARD_RESET_COMMAND
end