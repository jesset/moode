#!/bin/bash
set -e

# UNSQUASH /var/www

sudo killall -s 9 watchdog.sh || true
sudo killall -s 9 watchdog.sh || true
sudo systemctl stop nginx
sudo systemctl stop php7.0-fpm

sudo umount /var/www

sudo rmdir /var/www
sudo unsquashfs -d /var/www /var/local/moode.sqsh
sync
sync
sync

sudo sed -i.bak '/moode.sqsh/s,^,#,g' /etc/fstab
sudo mv -v /var/local/moode.sqsh /var/local/moode.sqsh-backup-$(date '+%Y%m%d%H%M%S')

echo "UnSquashed, DONE~"
