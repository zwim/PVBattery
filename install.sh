#!/bin/bash
#
#

mkdir -p /opt/PVBattery > /dev/null

rsync -a *.lua /opt/PVBattery/
rsync -a *.html /opt/PVBattery/
rsync -a suntime /opt/PVBattery/

rsync -a battery.html /var/www/localhost/htdocs/index.html 

cp PVBattery /etc/init.d/
rc-update add PVBattery

