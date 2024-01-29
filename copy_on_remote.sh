#!/bin/bash

if [[ "$1" == "" ]]
then
    echo "no host given "
    echo "call: copy_to_remote.sh host [firmware|filesystem]"
    exit -1
fi

if [[ "$2" == "" ]]
then
    echo "no action given"
    echo "call: copy_to_remote.sh host [firmware|filesystem]"
    exit -1
fi

HOST=$1

rsync -a .pio/build/esp32/*.bin root@${HOST}:/tmp
rsync -a flash_on_remote.sh root@${HOST}:/tmp
rsync -a filesystem_on_remote.sh root@${HOST}:/tmp


if [[ "$2" == "firmware" ]]
then
    ssh root@${HOST} "killall minicom"
    ssh root@${HOST} "cd /tmp; bash ./flash_on_remote.sh"
else
    ssh root@${HOST} "killall minicom"
    ssh root@${HOST} "cd /tmp; bash ./filesystem_on_remote.sh"
fi

date
