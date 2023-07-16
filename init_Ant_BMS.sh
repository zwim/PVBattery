#!/bin/bash

echo [`date`] checking for rfcomm0
if rfcomm show 0 ; then
    echo "rfcomm0 already up"
    exit
fi

bthelper hci0
sleep 5s
hciconfig -a
/etc/init.d/bluetooth restart
bluetoothctl power on

sdptool add --channel 1 SP
rfcomm  bind  0 AA:BB:CC:D0:06:66 1

sleep 0.5s

if rfcomm show 0 ; then
    echo "setting STTY"
    # set correct config for BT "serial port" connection
    stty -F /dev/rfcomm0 1:0:18b2:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0
else
    echo "/dev/rfcomm0 missing"
    exit -1
fi
