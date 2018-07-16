#!/bin/bash

mydir=~/RT-Tests/$(date +%Y%m%d-%H%M)
mkdir -pv $mydir 

if cd $mydir;then
  cp -v /boot/cmdline.txt ./
  cp -v /boot/config.txt  ./
  ( cat /sys/firmware/devicetree/base/model;
    uname -a ;
    lsusb;
    dmesg | grep -i firmware; ) > info.txt
  
  sudo killall -s 9 watchdog.sh || true
  sudo systemctl stop nginx
  sudo systemctl stop php7.0-fpm
  sudo systemctl stop mpd
  
  sleep 30
  
  ~/mklatencyplot.bash

fi
