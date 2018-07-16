#!/bin/bash

# systemctl list-unit-files | grep enabled
systemctl disable nmbd.service
systemctl disable smbd.service
systemctl disable 'getty@.service'
systemctl disable 'autovt@.service'
systemctl disable console-setup.service
systemctl disable rpi-display-backlight.service
systemctl disable keyboard-setup.service
systemctl disable rsync.service
systemctl disable apt-daily-upgrade.timer
systemctl disable apt-daily.timer
systemctl disable phpsessionclean.timer
systemctl disable systemd-timesyncd.service
systemctl disable sysstat.service
systemctl disable bthelper.service
systemctl disable syslog.service
systemctl disable phpsessionclean.timer

# 禁用 rsyslog ，只用 journald
systemctl mask rsyslog.service
systemctl mask rsyslogd.service
systemctl mask syslog.service
systemctl stop syslog.socket
systemctl stop rsyslog.service

for i in 20-exif.ini 20-ftp.ini 20-calendar.ini 20-shmop.ini 20-sysvshm.ini 20-sysvsem.ini 20-sysvmsg.ini
do
  test -e /etc/php/7.0/fpm/conf.d/$i && rm -fv  /etc/php/7.0/fpm/conf.d/$i
done

test -e /usr/sbin/ntpdate-debian || apt install ntpdate


