#!/bin/bash
# set -x
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LANG=C
export LC_ALL=C

export SQLDB=/var/local/www/db/moode-sqlite3.db
export nousb_flag=/boot/NOUSB
export noled_flag=/boot/NOLED
export nosmb_flag=/boot/NOSMB

export usb_mounted=/tmp/usb_mounted.lock
export sdcard_mounted=/tmp/sdcard_mounted.lock
export mount_opts="ro,noexec,nodev,noatime,nodiratime"


unload_eth0(){
  # Pi 3B
  if test -d /sys/bus/usb/drivers/smsc95xx/;then
    eth0_usbid=$(cd /sys/bus/usb/drivers/smsc95xx/ && ls -d 1-* )
    if [[ -n $eth0_usbid ]] ;then
      uhubctl  -p 1 -a off
      echo "$eth0_usbid" |tee /sys/bus/usb/drivers/smsc95xx/unbind && echo "# eth0 unbinded."
    fi
  fi
  # Pi 3B Plus
  if test -d /sys/bus/usb/drivers/lan78xx/;then
    eth0_usbid_plus=$(cd /sys/bus/usb/drivers/lan78xx/ && ls -d 1-* )
    if [[ -n $eth0_usbid_plus ]] ;then
      uhubctl -l 1-1.1 -p 1 -a off
      echo "$eth0_usbid_plus" |tee /sys/bus/usb/drivers/lan78xx/unbind && echo "# eth0 unbinded."
    fi
    modprobe -r microchip lan78xx libphy
  fi
}

unload_all_usbdev(){
  echo "# Power off USB hub..."
  uhubctl -l 1-1.1 -a off >/dev/null 2>&1
  uhubctl -l 1-1 -a off

  echo "# unbind USB hub..."
  ( cd /sys/bus/usb/drivers/hub/; ls -1 )| grep -Po '\d+-[\d\.:]+' | \
  while read usbhubid;do
    [[ -n "$usbhubid" ]] && echo "$usbhubid" |tee /sys/bus/usb/drivers/hub/unbind || true
  done

  echo "# unload usb relative modules"
  modules_unload=$(lsmod | sed 1d | awk '{print $3,$1}' | egrep -i 'usb|hid' | sort -n | awk '{print $2}' | tr '\n' ' ')
  modules_unload=($modules_unload)
  if [[ ${#modules_unload[@]} -gt 0 ]];then
    echo "# modules to be unload:  ${modules_unload[@]}"
    sleep 3
    for ((i=0; i<${#modules_unload[@]}; i++))
    do
      modprobe -r ${modules_unload[$i]}
    done
  fi
}






# Disable LED on demand ...
if test -e $noled_flag; then
  echo "# Disable LEDs, defined $noled_flag ..."
  echo none | tee /sys/class/leds/*/trigger
fi


# Double check config.txt (power failure data loss)
if [[ $(cat /boot/config.txt | sort -u | wc -l) -lt 20 ]];then
  echo "# Fatal: /boot/config.txt corrupted!!! Try to recover...."
  cp -av /boot/config.txt.bak /boot/config.txt && sync && systemctl reboot
else
  echo "# Info: /boot/config.txt seems OK."
fi


# Reduce OS jitter
echo "# adjusting rcu_sched/rcu_preempt ..."
for i in `pgrep rcu[^c]` ; do taskset -pc 0,1 $i ; done
echo 3 | tee /sys/bus/workqueue/devices/writeback/cpumask
echo 1 | tee /proc/sys/kernel/sched_nr_migrate

# To keep all CPUs with the same rt_runtime, disable the NO_RT_RUNTIME_SHARE logic
# https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux_for_real_time/7/html/tuning_guide/real_time_throttling
# echo NO_RT_RUNTIME_SHARE > /sys/kernel/debug/sched_features

#echo 0 > /proc/sys/kernel/watchdog
#echo 60 > /proc/sys/kernel/watchdog_thresh
sysctl -w vm.stat_interval=120
sysctl -w kernel.softlockup_all_cpu_backtrace=1




eth0chk=$(sqlite3 $SQLDB "PRAGMA query_only=1; PRAGMA busy_timeout=5000; select value from cfg_system where param='eth0chk'" | tail -1)
 i2sdev=$(sqlite3 $SQLDB "PRAGMA query_only=1; PRAGMA busy_timeout=5000; select value from cfg_system where param='i2sdevice'" | tail -1)

echo '# unbind Ethernet(eth0) if it is not ACTULLY in use (determined by Up/Down status, and addr)'
for c in {60..1};do
  echo "# Waiting for moOde fully startup for $c ."
  if grep -q Ready /var/log/moode.log ;then
    echo "# moOde fully ready, beginning detect eth0 ..."
    eth0_stat=$(ip addr show dev eth0 | grep -Po 'state \S+' | cut -d ' ' -f 2)
    eth0_addr=$(ip addr show dev eth0 | grep -Po 'inet [\d\./]+' | cut -d ' ' -f 2)
    if [[ "${eth0_stat}" == "UP" ]]||[[ x${eth0_addr} != "x" ]];then
      echo "# eth0 is in use, tunning..."
      ethtool --set-eee eth0  eee off
      break
    else
      unload_eth0
      break
    fi
  else
    sleep 1
    continue
  fi
done


echo "# USB tunning..."
for (( i = 0; i < 1; i++ )); do
  # Condition : Disable All USB Port, if any met:
  # A. using i2c dac && eth0 not enabled && no usb-storage plugged
  # B. /boot/NOUSB flag touched
  if ( [[ ${eth0chk} -eq 0  ]] && [[ "${i2sdev}" != none  ]] ) || test -e $nousb_flag ; then
    if ! lsusb -t | grep -q 'Driver=usb-storage'; then
      echo "# unload all usb port, eth0chk=${eth0chk}, i2sdev=${i2sdev}"
      unload_all_usbdev
      break
    fi
  fi

  if [[ "${i2sdev}" == none  ]];then
    echo "# You use USB DAC maybe,"
    echo "# Re-Schedule dwc_otg .... to CPU 0-1"
    ps -e -o pid,psr,comm,args | grep -Pi -- '-dwc_otg' | grep -v grep | awk '{print $1}' | while read pid;
    do
      taskset -p --cpu-list 0-1 $pid
    done
  fi
done


echo "# Power off un-used usb ports ..."
# uhub_num=$(uhubctl | grep 'Current status for hub'| wc -l)
# hub 2, RPi Model 3B Plus
# hub 1, RPi Model 3B
for hub in 1-1.1 1-1;
do
  uhubctl -l ${hub} | grep -P '^\s+Port' | tac | while read line
  do
    if echo "${line}" | grep -q 'enable connect';then
      break
    else
      port_num=$(echo "${line}" | awk '{print $2}'| sed 's,:,,')
      if [[ -n ${port_num} ]]; then
        [[ ${hub} == '1-1' && ${port_num} == 2 ]] && continue
        echo "#   Hub ${hub} , USB Port ${port_num} power off ..."
        uhubctl -l ${hub} -p ${port_num} -a off
      fi
    fi
  done
done


echo "# WiFi setting ..."
if ip link show wlan0 >/dev/null 2>&1 ;then
  iwconfig wlan0 frag 512
  iwconfig wlan0 rts 250
  iwconfig wlan0 retry short 6
fi


# disable samba sharing
if test -e $nosmb_flag ;then
  systemctl is-enabled smbd && systemctl disable smbd
  systemctl is-enabled nmbd && systemctl disable nmbd

  systemctl is-active smbd && systemctl stop smbd
  systemctl is-active nmbd && systemctl stop nmbd
fi



export mounted_srcs=/dev/shm/mount.src.list

# Automatic mount USB Storage

lsblk --pairs --noheadings --paths --bytes \
      --exclude 179,7 \
      --output name,size,type,rm,uuid,label,fstype | \
while read line ;do
 eval "$line"
 # only mount removable media and
 if [[ $TYPE != "disk" ]] && [[ "$LABEL" != "EFI" ]];then
   echo "INFO: new volume to mount: type=$TYPE name=$NAME uuid=$UUID label='$LABEL'"
   if findmnt -nl --source $NAME ;then
     echo "INFO: $NAME already mounted, skip."
   else
     [[ x$LABEL != x ]] && target=/media/"$LABEL" || target=/media/"$UUID"
     test -d "$target" || mkdir -v "$target"
     case "$FSTYPE" in
       vfat)
         usb_pmntopts="${mount_opts},dmask=0000,fmask=0000,umask=0000"
       ;;
       ntfs)
         usb_pmntopts="${mount_opts},dmask=0022,fmask=0022"
       ;;
       *)
         usb_pmntopts="${mount_opts}"
       ;;
     esac
     echo "mount -o $usb_pmntopts $NAME \"$target\"" > /dev/shm/mount.sh
     mount -o $usb_pmntopts $NAME "$target" && \
     touch $usb_mounted && \
     echo "INFO: mounted $NAME to '$target'"
     echo $NAME > $mounted_srcs
   fi
 fi
 unset RM TYPE LABEL UUID usb_pmntopts
done

test -e $usb_mounted && touch /media/empty && mpc update USB/empty


# Automatic mount SDcard partitions

lsblk --pairs --noheadings --paths --bytes \
      --include 179 \
      --output name,size,type,rm,uuid,label,fstype,mountpoint | \
while read line ;do
 eval "$line"
 # only mount removable media and
 if [[ $TYPE == "part" ]] && \
	 [[ "$LABEL" != "BOOT" ]] && \
	 [[ "$LABEL" != "ROOTFS" ]] && \
	 [[ -z "$MOUNTPOINT" ]] ;then
   echo "INFO: SDcard partition to mount: type=$TYPE name=$NAME uuid=$UUID label='$LABEL'"
   if findmnt -nl --source $NAME ;then
     echo "INFO: $NAME already mounted, skip."
   else
     [[ x$LABEL != x ]] && target=/mnt/SDCARD/"$LABEL" || target=/mnt/SDCARD/"$UUID"
     test -d "$target" || mkdir -v "$target"
     case "$FSTYPE" in
       vfat)
         sd_pmntopts="${mount_opts},dmask=0000,fmask=0000,umask=0000"
       ;;
       ntfs)
         sd_pmntopts="${mount_opts},dmask=0022,fmask=0022"
       ;;
       *)
         sd_pmntopts="${mount_opts}"
       ;;
     esac
     echo "mount -o $sd_pmntopts $NAME \"$target\"" >> /dev/shm/mount.sh
     mount -o $sd_pmntopts $NAME "$target" && \
       touch $sdcard_mounted && \
       echo "INFO: mounted $NAME to '$target'"
     echo $NAME >> $mounted_srcs
   fi
 fi
 unset RM TYPE LABEL UUID sd_pmntopts
done


# Double check mounts
if test -e $mounted_srcs ;then
for c in {3..1};do
  echo "INFO: recheck usb/sdcard mount $c ..."
  while read src;do
     if ! findmnt -nl --source $src >/dev/null;then
       echo "WARN: $src mounted failed, remount..."
       source /dev/shm/mount.sh
     fi
  done < $mounted_srcs
  sleep 2
done
fi


echo "Finished."

