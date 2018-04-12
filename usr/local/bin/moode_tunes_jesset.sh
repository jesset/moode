#!/bin/bash
# Disable LED if intended to (touch /boot/NOLED)
# Diable ALL USB(Devices) if intended to (touch /boot/NOUSB),also unload *usb* modules
# Diable ALL USB(Devices) if eth0 AND usb-dac not set
# unbind Ethernet(eth0) if not in use (determined by Up/Down status, and addr)

# set -x

export SQLDB=/var/local/www/db/moode-sqlite3.db
export usb_flag=/boot/NOUSB
export led_flag=/boot/NOLED


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

  # unbind USB devices, then USB hub ...
  if [[ x$$usbdev_unbind != "x" ]];then
    usbdev_unbind_r=$(echo $usbdev_unbind | tr ' ' '\n' | tac | tr '\n' ' ')
    for usbid in $usbdev_unbind_r ;do
      echo  $usbid > /sys/bus/usb/drivers/usb/unbind
    done
  fi

  ( cd /sys/bus/usb/drivers/hub/; ls -1 )| grep -Po '\d+-[\d\.:]+' | \
  while read usbhubid;do
    [[ -n "$usbhubid" ]] && echo "$usbhubid" > /sys/bus/usb/drivers/hub/unbind || true
  done

  # unload **USB** modules
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
echo "# Disable LEDs if defined $led_flag ..."
if test -e $led_flag; then
  echo none | tee /sys/class/leds/*/trigger
fi


eth0chk=$(sqlite3 $SQLDB "select value from cfg_system where param='eth0chk'")
i2sdev=$(sqlite3 $SQLDB "select value from cfg_system where param='i2sdevice'")

for (( i = 0; i < 1; i++ )); do

  # Disable All USB Port, if any:
  # 1. using i2c dac && eth0 not enabled
  # 2. /boot/NOUSB touched
  if ( [[ ${eth0chk} -eq 0  ]] && [[ ${i2sdev} != none  ]] ) || test -e $usb_flag ; then
    unload_all_usbdev
    break
  fi

  if [[ ${eth0chk} -eq 0  ]];then
    unload_eth0
  fi

  # Disable All USB Port (except Ethernet) if using i2c dac
  if [[ ${i2sdev} != none  ]];then
    echo "# You chosed I2S DAC."
    for port in 2 3 4 5;do
      /usr/local/bin/hub-ctrl -b 1 -d 2 -P $port -p 0
      sleep 0.3
    done
  fi

done

#/boot/cmdline.txt
# nohz_full=1,2,3
#
if grep -q nohz_full /boot/cmdline.txt ;then
  for i in `pgrep rcu[^c]` ; do taskset -pc 0 $i ; done
  echo 1 | tee /sys/bus/workqueue/devices/writeback/cpumask
fi

# Finally, unbind Ethernet(eth0) if not in use (determined by Up/Down status, and addr)
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
