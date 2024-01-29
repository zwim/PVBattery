#!/bin/bash
#
#

mkdir /opt/PVBattery

rsync -a *.lua /opt/PVBattery/
rsync -a *.html /opt/PVBattery/
rsync -a suntime /opt/PVBattery/

cp PVBattery /etc/init.d/
rc-update add PVBattery

