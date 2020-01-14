#!/bin/bash

mpc clear

sudo killall -s 9 watchdog.sh 
sudo killall -s 9 watchdog.sh || true
sudo systemctl stop nginx
sudo systemctl stop php7.3-fpm

sudo apt-get clean && sudo rm -f /var/lib/apt/lists/*dists*

sudo systemctl stop mpd; 

findmnt -t nfs,nfs4,hfsplus,vfat,cifs -n -o TARGET | grep /mnt | xargs -n 1 -r --verbose sudo umount
sudo rmdir -v /mnt/NAS/*
sudo rm -fv /var/local/www/imagesw/thmcache/*

for dir in /mnt/SDCARD/* ;do
  [[ $(basename "$dir") != "Stereo Test" ]] && sudo rm -fv "$dir"
done
for pls in /var/lib/mpd/playlists/* ;do
  [[ $(basename "$pls") == "Default Playlist.m3u" ]] && continue
  [[ $(basename "$pls") == "Favorites.m3u" ]] &&  sudo truncate -s 0 "$pls" && continue
  sudo rm -fv "$pls"
done

sudo /var/www/command/util.sh clear-syslogs
sudo /var/www/command/util.sh clear-playhistory
sudo find -L /var/log/ \
	     /var/run/log \
	     /var/cache/upmpdcli -type f -print0 | xargs -0 -r --verbose -n 1  sudo truncate -s 0

sudo rm -fv /var/lib/dhcpcd5/* /etc/dhcpcd.duid /etc/dhcpcd.secret /var/lib/dhcp/* /var/run/wpa_supplicant/wlan0 /var/lib/misc/dnsmasq.leases
# sudo rm -fv /etc/network/interfaces.d/*
sudo find /var/lib/samba/private/msg.sock/ -type s | xargs sudo rm -fv

sudo cp -v /home/pi/moode/network/wpa_supplicant.conf.default /etc/wpa_supplicant/wpa_supplicant.conf
sudo cp -v /home/pi/moode/network/dhcpcd.conf.default /etc/dhcpcd.conf
sudo cp -v /home/pi/moode/network/hostapd.conf.default /etc/hostapd/hostapd.conf

sudo cp -v /var/local/www/db/moode-sqlite3.db.default /var/local/www/db/moode-sqlite3.db
sqlite3 /var/local/www/db/moode-sqlite3.db "update cfg_system set value=0 where param='p3bt'"
sqlite3 /var/local/www/db/moode-sqlite3.db "update cfg_system set value=0 where param='hdmiport'"
sqlite3 /var/local/www/db/moode-sqlite3.db "update cfg_system set value='Asia/Shanghai' where param='timezone'"
sqlite3 /var/local/www/db/moode-sqlite3.db "update cfg_system set value='performance' where param='cpugov'"

sqlite3 /var/local/www/db/moode-sqlite3.db "drop trigger if exists ro_columns"
sqlite3 /var/local/www/db/moode-sqlite3.db "update cfg_hash set action = 'warning'"
#sqlite3 /var/local/www/db/moode-sqlite3.db "update cfg_system set value='Emerald' where param='accent_color'"

# disable kernel selection (32bit/64bit)
sqlite3 /var/local/www/db/moode-sqlite3.db "select * from cfg_system where param = 'feat_bitmask'"  # 31679
sqlite3 /var/local/www/db/moode-sqlite3.db "update cfg_system set value = value - 1 where param = 'feat_bitmask'"
sqlite3 /var/local/www/db/moode-sqlite3.db "select * from cfg_system where param = 'feat_bitmask'"  # 31678

# if uname -v | grep -q RT ;then
#   sqlite3 /var/local/www/db/moode-sqlite3.db "update cfg_system set value='Advanced' where param='kernel'" # Standard
#   sqlite3 /var/local/www/db/moode-sqlite3.db "update cfg_system set value='FIFO' where param='mpdsched'"
# fi

sudo tune2fs -c 90 -i 90d  /dev/mmcblk0p2  # if ext4

sudo truncate -s 0 /var/lib/mpd/database /var/local/www/spscache.json /var/local/www/libcache.json
sudo systemctl enable regenerate_ssh_host_keys.service
sudo systemctl enable smbd.service
sudo systemctl enable nmbd.service
test -e /boot/NOSMB && sudo rm -fv /boot/NOSMB
test -e /boot/NAA   && sudo rm -fv /boot/NAA
sudo systemctl disable ssh.service

sudo timedatectl set-timezone "Asia/Shanghai"

sudo rm -fv /etc/ssh/ssh_host_* /home/pi/.bash_history  /root/.bash_history  /home/pi/.ssh/* /var/local/www/sysinfo.txt
sudo rm -rfv /root/.cache
history -c
sync

