#!/bin/bash


bthelper hci0
sleep 6
hciconfig -a
/etc/init.d/bluetooth restart
bluetoothctl power on

sdptool add --channel 1 SP
rfcomm  bind  0 AA:BB:CC:D0:06:66 1
