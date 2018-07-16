#!/bin/bash
set -e
#set -x

if [[ $(whoami) != 'root' ]];then
  echo "Error: Pls exec sudo -i "
  exit 1
fi

kerneltarb=$(readlink -f $1)

if [[ x == x$kerneltarb ]] || ! test -f $kerneltarb ;then
 echo "Usage: $0 /path/to/kernel.tarball"
 exit
fi

# echo "INFO: backuping old kernel...."
# kerver=`uname -r`
# tar czpPf oldkernel."${kerver}".tgz --  /boot/kernel8.img  /lib/modules/"${kerver}"

echo "INFO: extracting new kernel...."
cd / && tar --no-same-owner  -xf $kerneltarb

sync
sync

echo Done.

