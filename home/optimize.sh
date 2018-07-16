#!/bin/bash

systemctl disable bthelper.service
systemctl disable syslog.service
systemctl disable phpsessionclean.timer

for i in 20-exif.ini 20-ftp.ini 20-calendar.ini 20-shmop.ini 20-sysvshm.ini 20-sysvsem.ini 20-sysvmsg.ini
do
  test -e /etc/php/7.0/fpm/conf.d/$i && rm -fv  /etc/php/7.0/fpm/conf.d/$i
done

test -e /usr/sbin/ntpdate-debian || apt install ntpdate


