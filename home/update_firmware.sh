#!/bin/bash
# update firmware to latest version
set -e

if [[ $(whoami) != 'root' ]];then
  echo "Error: Pls exec sudo -i "
  exit 1
fi

FW_FILES="bootcode.bin "
FW_FILES+="start.elf start_x.elf start_cd.elf start_db.elf "
FW_FILES+="fixup.dat fixup_x.dat fixup_cd.dat fixup_db.dat "
FW_FILES+="COPYING.linux LICENCE.broadcom "


git clone --depth 1  https://github.com/raspberrypi/firmware.git /dev/shm/firmware

if cd /dev/shm/firmware ;then
  for file in ${FW_FILES};do
    cp -v boot/${file} /boot/
  done
fi

sync

echo Done.
