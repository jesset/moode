#!/bin/bash
# Disable LED if intended to (touch /boot/NOLED)
# Diable USB(Devices) if intended to (touch /boot/NOUSB),also unload *usb* modules
# unbind Ethernet(eth0) if not in use (determined by Up/Down status, and addr)
# Auto set CPU affinity for dwc_otg/mpd/squeezelite

# set -x

waitfor(){
  proc=$1
  expect_lwp_num=${2:-1}
  timeout=${3:-15}
  for c in $(seq 1 ${timeout});do
    lwp_num=$(ps -eL -o pid,lwp,comm,args | grep -Pi -- ${proc} | grep -v grep | wc -l)
    if [[ ${lwp_num} -lt ${expect_lwp_num} ]] ;then
      echo "# Wait for ${proc} $c/$timeout"
      sleep 1 && continue
    else
      break
    fi
  done
}


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
  # if using USB DAC
  if cat /proc/asound/cards | grep -qi USB ;then
    echo "# USB DAC detected, we need to:"
    echo "#   1. Re-Schedule dwc_otg ...."
    ps -e -o pid,psr,comm,args | grep -Pi -- '-dwc_otg' | grep -v grep | awk '{print $1}' | while read pid;
    do
      taskset -p --cpu-list 0-1 $pid
    done
  
    echo "#   2. Re-Schedule mpd/squeezelite ...."
    squ_enabled=$(sqlite3 /var/local/www/db/moode-sqlite3.db  'select value from cfg_system where param="slsvc"')
    [[ ${squ_enabled} -ne 0 ]] && waitfor squeezelite 3
    waitfor mpd 4
    ps -eL -o lwp,psr,comm,args | grep -Pi -- 'mpd|squeezelite' | grep -v grep | awk '{print $1}' | while read tid;
    do
      taskset -p --cpu-list 2-3  $tid
    done
  
    echo "#   3. Final CPU Affinity for dwc_otg/mpd/squeezelite:"
    ps -eL -o class,pid,lwp,psr,rtprio,pri,nice,sched,comm,args | grep -Pi -- '-dwc_otg|mpd|squeezelite' | grep -v grep
  fi

fi

