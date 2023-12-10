#!/bin/bash
#
#

mkdir /opt/PVBattery

rsync *.lua /opt/PVBattery/
rsync -a suntime /opt/PVBattery/

cp PVBattery /etc/init.d/
rc-update add PVBattery

ln -sf /tmp/index.html /var/www/localhost/htdocs/index.html
