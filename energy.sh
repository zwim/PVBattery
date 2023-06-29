#!/bin/bash

ENERGY_TMP="/tmp/energy.tmp"
ENERGY_PATH="/var/www/localhost/htdocs/energy-garage.csv"
POWER_PATH="/var/www/localhost/htdocs/power-garage.csv"

DATE_TIME=$(date +"%Y-%m-%d %H:%M:%S, ")
#curl http://192.168.1.30/cm?cmnd=EnergyTotal --silent | jq ".EnergyTotal.Total" >> ${OUTPUT_PATH}-$(date -I)
TOTAL_ENERGY=$(curl http://192.168.1.30/cm?cmnd=EnergyTotal --silent | jq ".EnergyTotal.Total")

if [[ ${TOTAL_ENERGY} != "" ]];
then
	echo "${DATE_TIME}${TOTAL_ENERGY}" >> ${ENERGY_PATH}
	tail -n2 ${ENERGY_PATH} > ${ENERGY_TMP}
	lua "opt/power.lua" ${ENERGY_TMP} >> ${POWER_PATH}
fi
