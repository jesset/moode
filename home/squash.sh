#!/bin/bash
set -e
# SQUASH /var/www


test -e /var/local/moode.sqsh && \
    sudo mv -v /var/local/moode.sqsh /var/local/moode.sqsh-backup-$(date '+%Y%m%d%H%M%S')

sudo mksquashfs /var/www /var/local/moode.sqsh

sudo rm -rf /var/www/*

sync
sync
sync

sudo sed -i.bak '/moode.sqsh/s,^#,,g' /etc/fstab

echo "Squashed, DONE~"
