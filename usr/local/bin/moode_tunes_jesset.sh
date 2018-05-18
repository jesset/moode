#!/bin/bash
# Disable LED if intended to (touch /boot/NOLED)
# Diable ALL USB(Devices) if intended to (touch /boot/NOUSB),also unload *usb* modules
# Diable ALL USB(Devices) if eth0 AND usb-dac not set
# unbind Ethernet(eth0) if not in use (determined by Up/Down status, and addr)

# set -x

export SQLDB=/var/local/www/db/moode-sqlite3.db
export nousb_flag=/boot/NOUSB
export noled_flag=/boot/NOLED


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

###

if ! test -e /etc/ssh/ssh_host_rsa_key ;then
  echo "Regenerating OpenSSH server Host keys ..."
  dpkg-reconfigure openssh-server
fi

# Disable LED on demand ...
if test -e $noled_flag; then
  echo "# Disable LEDs, defined $noled_flag ..."
  echo none | tee /sys/class/leds/*/trigger
fi

# sysctl ...
echo 1 > /proc/sys/kernel/sched_nr_migrate



eth0chk=$(sqlite3 $SQLDB "PRAGMA query_only=1; PRAGMA busy_timeout=5000; select value from cfg_system where param='eth0chk'" | tail -1)
 i2sdev=$(sqlite3 $SQLDB "PRAGMA query_only=1; PRAGMA busy_timeout=5000; select value from cfg_system where param='i2sdevice'" | tail -1)

echo "# USB tunning..."
for (( i = 0; i < 1; i++ )); do
  # Condition 1: Disable All USB Port, if any:
  # 1. using i2c dac && eth0 not enabled
  # 2. /boot/NOUSB touched
  if ( [[ ${eth0chk} -eq 0  ]] && [[ "${i2sdev}" != none  ]] ) || test -e $nousb_flag ; then
    echo "# unload all usb port, eth0chk=${eth0chk}, i2sdev=${i2sdev}"
    unload_all_usbdev
    break
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
    for port in 2 3 4 5;do
      echo "#   Disable USB Hub port $port ..."
      /usr/local/bin/hub-ctrl -b 1 -d 2 -P $port -p 0
      sleep 0.3
    done
  fi
done

#if [[ "${i2sdev}" != none  ]];then
#  echo "# I2S DAC used, further tunning..."
#  echo "#   MMC0/1 (SDcard/WiFI), Adjust mmc0/1 cpu affinity/rtprio ..."
#  echo "#   Adjust DMA irq affinity ..."
#  pgrep 'mmc|DMA|kblockd' | while read tid;do
#    taskset -p --cpu-list 0-1 $tid
#    #chrt --fifo -p 33 $tid
#  done
#  sleep 0.3
#  
#  ps -q $(pgrep -d, 'mmc|DMA|kblockd')  -eL -o class,pid,lwp,psr,rtprio,pri,nice,sched,comm,args
#
#fi


# Reduce OS jitter
echo "# adjusting rcu_sched/rcu_preempt ..."
for i in `pgrep rcu[^c]` ; do taskset -pc 0,1 $i ; done
echo 3 | tee /sys/bus/workqueue/devices/writeback/cpumask

# To keep all CPUs with the same rt_runtime, disable the NO_RT_RUNTIME_SHARE logic
# https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux_for_real_time/7/html/tuning_guide/real_time_throttling
# echo NO_RT_RUNTIME_SHARE > /sys/kernel/debug/sched_features

#echo 0 > /proc/sys/kernel/watchdog
#echo 60 > /proc/sys/kernel/watchdog_thresh
sysctl -w vm.stat_interval=120
sysctl -w kernel.softlockup_all_cpu_backtrace=1

echo '# Finally, unbind Ethernet(eth0) if it is not ACTULLY in use (determined by Up/Down status, and addr)'
if ip link show eth0 >/dev/null 2>&1 ;then
  for c in {1..60};do
    echo "# Waiting for moOde fully startup for $c time."
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
fi

if ip link show wlan0 >/dev/null 2>&1 ;then
  iwconfig wlan0 frag 512
  iwconfig wlan0 rts 250
  iwconfig wlan0 retry short 6
fi


# Automatic mount USB Storage
export usb_mount=/tmp/usb_mount.lock
export mount_opts="ro,noexec,nodev,noatime,nodiratime"

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
     mount -o $mount_opts $NAME "$target" && \
       touch $usb_mount && \
       echo "INFO: mounted $NAME to '$target'"
   fi
 fi
 unset RM TYPE LABEL UUID
done

test -e $usb_mount && mpc update USB && rm -f $usb_mount 


# Automatic mount SDcard partitions
export sdcard_mount=/tmp/sdcard_mount.lock
export sdcard_mountopts="noexec,nodev,noatime,nodiratime"

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
     mount -o $sdcard_mountopts $NAME "$target" && \
       touch $sdcard_mount && \
       echo "INFO: mounted $NAME to '$target'"
   fi
 fi
 unset RM TYPE LABEL UUID
done

test -e $sdcard_mount && mpc update SDCARD && rm -f $sdcard_mount 



echo "Finished."

