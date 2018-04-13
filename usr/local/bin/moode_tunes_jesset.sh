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
  eth0_usbid=$(cd /sys/bus/usb/drivers/smsc95xx/ && ls -d 1-* )
  echo "$eth0_usbid" > /sys/bus/usb/drivers/smsc95xx/unbind
  echo "# eth0 unbinded."
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
  for mod in snd_usb_audio usbhid hid_generic ;do
    lsmod | grep -qi $mod && modprobe -r $mod
  done
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
    # Find out USB DAC port id AND disable other USB ports
    #  for card in /proc/asound/card* ;do
    #    test -d $card || continue
    #    test -e $card/usbid || continue
    #    usbdac_dev_id=$(cat $card/usbid)
    #    usbdac_dev_name=$(cat $card/id)
    #    usbdac_port_id=$(lsusb -t -d ${usbdac_dev_id} | grep -Pi 'Driver=snd-usb-audio' | grep -Po 'Port \d+' | tail -1 | awk '{print $2}')
    #  
    #    if [[ -n $usbdac_dev_id ]]&&[[ -n $usbdac_port_id ]];then
    #      echo "# Found USB DAC: name:${usbdac_dev_name}, id:${usbdac_dev_id}, port:${usbdac_port_id}"
    #    fi
    #  done
    #  
    #  for port in 2 3 4 5;do
    #    if [[ ${port} -ne ${usbdac_port_id} ]] ;then
    #      echo "# Disable USB Hub port $port (exclude USB-DAC port ${usbdac_port_id})..."
    #      /usr/local/bin/hub-ctrl -b 1 -d 2 -P $port -p 0 && sleep 0.2
    #    fi
    #  done
    #
  else
    echo "# You chosed I2S DAC."
    for port in 2 3 4 5;do
      echo "# Disable USB Hub port $port ..."
      /usr/local/bin/hub-ctrl -b 1 -d 2 -P $port -p 0
      sleep 0.3
    done
  fi
done


echo "# MMC0/1 (SDcard/WiFI) tunning..."
echo "# Adjust mmc0/1 cpu affinity/rtprio ..."
pgrep 'irq/7.*mmc' | while read tid;do
  taskset -p --cpu-list 0-1 $tid
  chrt --fifo -p 33 $tid
done
sleep 0.3
ps -q $(pgrep -d, 'irq/7.*mmc')  -eL -o class,pid,lwp,psr,rtprio,pri,nice,sched,comm,args


echo "# Adjust DMA irq affinity ..."
pgrep 'DMA' | while read tid;do
  taskset -p --cpu-list 0-1 $tid
done
sleep 0.3
ps -q $(pgrep -d, 'DMA')  -eL -o class,pid,lwp,psr,rtprio,pri,nice,sched,comm,args


#/boot/cmdline.txt
# nohz_full=1,2,3
#
if grep -q nohz_full /boot/cmdline.txt ;then
  echo "# adjusting rcu_sched/rcu_preempt ..."
  for i in `pgrep rcu[^c]` ; do taskset -pc 0 $i ; done
  echo 1 | tee /sys/bus/workqueue/devices/writeback/cpumask
fi

echo '# Finally, unbind Ethernet(eth0) if it is not ACTULLY in use (determined by Up/Down status, and addr)'
if ip link show eth0 >/dev/null 2>&1 ;then
  for c in {1..60};do
    echo "# Waiting for moOde fully startup for $c time."
    if grep -q Ready /var/log/moode.log ;then
      echo "# moOde fully ready, beginning detect eth0 ..."
      eth0_stat=$(ip addr show dev eth0 | grep -Po 'state \S+' | cut -d ' ' -f 2)
      eth0_addr=$(ip addr show dev eth0 | grep -Po 'inet [\d\./]+' | cut -d ' ' -f 2)
      if [[ "${eth0_stat}" == "UP" ]]||[[ x${eth0_addr} != "x" ]];then
        echo "# eth0 is in use, skipped."
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
