#!/bin/bash
# Disable LED if intended to (touch /boot/NOLED)
# Diable USB(Devices) if intended to (touch /boot/NOUSB),also unload *usb* modules
# unbind Ethernet(eth0) if not in use (determined by Up/Down status, and addr)

echo "# Re-generating OpenSSH Host keys if necessary ..."
test -e /etc/ssh/ssh_host_rsa_key || dpkg-reconfigure openssh-server

# Disable LED on demand ...
export led_flag=/boot/NOLED
echo "# Disable LEDs if defined $led_flag ..."
if test -e $led_flag; then
  echo none | tee /sys/class/leds/*/trigger
fi

# unbind Ethernet(eth0) if not in use (determined by Up/Down status, and addr)
if ip link show eth0 >/dev/null 2>&1 ;then
  eth0_stat=$(ip addr show dev eth0 | grep -Po 'state \S+' | cut -d ' ' -f 2)
  eth0_addr=$(ip addr show dev eth0 | grep -Po 'inet [\d\./]+' | cut -d ' ' -f 2)

  if [[ "${eth0_stat}" == "UP" ]]||[[ x${eth0_addr} != "x" ]];then
    echo "# eth0 is in use, skipped."
  else
   eth0_usbid=$(cd /sys/bus/usb/drivers/smsc95xx/ && ls -d 1-* )
   echo "$eth0_usbid" > /sys/bus/usb/drivers/smsc95xx/unbind
   # dmesg | tail -3
  fi
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

else

  echo "# Re-Schedule dwc_otg ...."
  ps -e -o pid,psr,comm,args | grep -Pi -- '-dwc_otg' | grep -v grep | awk '{print $1}' | while read pid;
  do
    taskset -p --cpu-list 0-1 $pid
  done
  echo "# DONE."
  echo "# CPU Affinity for dwc_otg and mpd:"
  ps -eL -o class,pid,lwp,psr,rtprio,pri,nice,sched,comm,args | grep -Pi -- '-dwc_otg|mpd' | grep -v grep

fi

