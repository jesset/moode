#!/bin/bash

# set -x

export SQLDB=/var/local/www/db/moode-sqlite3.db
export nousb_flag=/boot/NOUSB
export noled_flag=/boot/NOLED

export usb_mounted=/tmp/usb_mounted.lock
export mount_opts="ro,noexec,nodev,noatime,nodiratime"

export sdcard_mounted=/tmp/sdcard_mounted.lock
export sdcard_mountopts="noexec,nodev,noatime,nodiratime"


unload_eth0(){
  # Pi 3B
  if test -d /sys/bus/usb/drivers/smsc95xx/;then
    eth0_usbid=$(cd /sys/bus/usb/drivers/smsc95xx/ && ls -d 1-* )
    [[ -n $eth0_usbid ]] && echo "$eth0_usbid" > /sys/bus/usb/drivers/smsc95xx/unbind \
      && echo "# eth0 unbinded."
  fi
  # Pi 3B Plus
  if test -d /sys/bus/usb/drivers/lan78xx/;then
    eth0_usbid_plus=$(cd /sys/bus/usb/drivers/lan78xx/ && ls -d 1-* )
    [[ -n $eth0_usbid_plus ]] && echo "$eth0_usbid_plus" > /sys/bus/usb/drivers/lan78xx/unbind \
      && echo "# eth0 unbinded."
    modprobe -r microchip lan78xx libphy
  fi
}

unload_all_usbdev(){
  usbdev_unbind=''
  # Find all usb dev ids ...
  for usbdev in  /sys/bus/usb/drivers/usb/* ;do
    usbid=$(basename $usbdev)
    if echo $usbid | grep -Piq '\d+-[\d\.:]+' ;then
      echo "# USB device to unbind: $usbid"
      usbdev_unbind="${usbdev_unbind} $usbid"
    fi
  done

  echo "# unbind USB devices ..."
  if [[ x$$usbdev_unbind != "x" ]];then
    usbdev_unbind_r=$(echo $usbdev_unbind | tr ' ' '\n' | tac | tr '\n' ' ')
    for usbid in $usbdev_unbind_r ;do
      echo  $usbid > /sys/bus/usb/drivers/usb/unbind
    done
  fi
  echo "# unbind USB hub..."
  ( cd /sys/bus/usb/drivers/hub/; ls -1 )| grep -Po '\d+-[\d\.:]+' | \
  while read usbhubid;do
    [[ -n "$usbhubid" ]] && echo "$usbhubid" > /sys/bus/usb/drivers/hub/unbind || true
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
  # Condition : Disable All USB Port, if any:
  # 1. using i2c dac && eth0 not enabled
  # 2. /boot/NOUSB touched
  if ( [[ ${eth0chk} -eq 0  ]] && [[ "${i2sdev}" != none  ]] ) || test -e $nousb_flag ; then
    if ! grep -q usb_storage /proc/modules; then
      echo "# unload all usb port, eth0chk=${eth0chk}, i2sdev=${i2sdev}"
      unload_all_usbdev
      break
    fi
  fi

  if [[ ${eth0chk} -eq 0  ]];then
    echo "# 'wait for eth0' not set in moode webui"
    unload_eth0
  fi

  if [[ "${i2sdev}" == none  ]];then
    echo "# You use USB DAC maybe,"
    echo "# Re-Schedule dwc_otg .... to CPU 0-1"
    ps -e -o pid,psr,comm,args | grep -Pi -- '-dwc_otg' | grep -v grep | awk '{print $1}' | while read pid;
    do
      taskset -p --cpu-list 0-1 $pid
    done
  else
    echo "# You chosed I2S DAC."
    if ! grep -q usb_storage /proc/modules; then
      for port in 2 3 4 5;do
        echo "#   Disable USB Hub port $port ..."
        /usr/local/bin/hub-ctrl -b 1 -d 2 -P $port -p 0
        sleep 0.3
      done
    fi
  fi
done


if ip link show wlan0 >/dev/null 2>&1 ;then
  iwconfig wlan0 frag 512
  iwconfig wlan0 rts 250
  iwconfig wlan0 retry short 6
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
         mount_opts+=",dmask=0000,fmask=0000,umask=0000"
       ;;
       ntfs)
         mount_opts+=",dmask=0022,fmask=0022"
       ;;
     esac
     echo "mount -o $mount_opts $NAME \"$target\"" > /dev/shm/mount.sh
     mount -o $mount_opts $NAME "$target" && \
     touch $usb_mounted && \
     echo "INFO: mounted $NAME to '$target'"
     echo $NAME >> $mounted_srcs
   fi
 fi
 unset RM TYPE LABEL UUID
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
         sdcard_mountopts+=",dmask=0000,fmask=0000,umask=0000"
       ;;
       ntfs)
         sdcard_mountopts+=",dmask=0022,fmask=0022"
       ;;
     esac
     echo "mount -o $sdcard_mountopts $NAME \"$target\"" >> /dev/shm/mount.sh
     mount -o $sdcard_mountopts $NAME "$target" && \
       touch $sdcard_mounted && \
       echo "INFO: mounted $NAME to '$target'"
     echo $NAME >> $mounted_srcs
   fi
 fi
 unset RM TYPE LABEL UUID
done


# Double check mounts
if test -e $mounted_srcs ;then
for c in {10..1};do
  echo "INFO: recheck usb/sdcard mount $c ..."
  while read src;do
     if ! findmnt -nl --source $src >/dev/null;then
       echo "WARN: $src mounted failed, remount..."
       source /dev/shm/mount.sh
     fi
  done < $mounted_srcs
  sleep 5
done
fi


echo "Finished."

