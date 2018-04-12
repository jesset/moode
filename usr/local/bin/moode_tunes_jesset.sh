#!/bin/bash
# Disable LED if intended to (touch /boot/NOLED)
# Diable USB(Devices) if intended to (touch /boot/NOUSB),also unload *usb* modules
# unbind Ethernet(eth0) if not in use (determined by Up/Down status, and addr)

# set -x

if ! test -e /etc/ssh/ssh_host_rsa_key ;then
  echo "Regenerating OpenSSH server Host keys ..."
  dpkg-reconfigure openssh-server
fi

# Disable LED on demand ...
export led_flag=/boot/NOLED
echo "# Disable LEDs if defined $led_flag ..."
if test -e $led_flag; then
  echo none | tee /sys/class/leds/*/trigger
fi

# unbind Ethernet(eth0) if not in use (determined by Up/Down status, and addr)
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
      eth0_usbid=$(cd /sys/bus/usb/drivers/smsc95xx/ && ls -d 1-* )
      echo "$eth0_usbid" > /sys/bus/usb/drivers/smsc95xx/unbind
      echo "# eth0 unbinded."
      break
      # dmesg | tail -3
    fi
  else
    sleep 1
    continue
  fi
done


# Disable All USB Port (except Ethernet) if using i2c dac
SQLDB=/var/local/www/db/moode-sqlite3.db
i2sdev=$(sqlite3 $SQLDB "select value from cfg_system where param='i2sdevice'")
if [[ ${i2sdev} == none  ]];then
  echo "# You are using USB DAC (maybe)."
else
  echo "# You chosed I2S DAC."
  for port in 2 3 4 5;do
    /usr/local/bin/hub-ctrl -b 1 -d 2 -P $port -p 0
    sleep 0.3
  done
fi

# Diable USB(Devices) on demand
export usb_flag=/boot/NOUSB
echo "# Disable USB devices if defined $usb_flag ..."

usbdev_unbind=''
if test -e $usb_flag; then
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

fi
