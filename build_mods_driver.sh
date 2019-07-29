#!/bin/bash

# Copyright (c) 2016, NVIDIA CORPORATION.  All rights reserved.
# See LICENSE file for details.

set -e

die()
{
    echo "$@"
    exit 1
}

[[ $(id -u) -eq 0 ]] || die "This script must be run with root privileges (e.g.  with sudo)"

if [[ $# -eq 1 && $1 != prepare && ! -f $1 ]]; then
    echo "Error: File $1 does not exist!"
    echo
    shift # Force info message
fi

if [[ $# -ne 1 ]]; then
    echo "Usage: $(basename "$0") driver.tgz    - Build mods.ko"
    echo "       $(basename "$0") prepare       - Create distributable build package"
    exit 1
fi

COMPRESS="-j"
type lbzip2 >/dev/null 2>&1 && COMPRESS="--use-compress-program lbzip2"

if [[ $1 = prepare ]]; then
    [[ -d buildroot ]] || die "Error: Directory buildroot not found!"
    rm -f buildroot/boot/kernel-genkernel-*
    ( cd buildroot/usr/src/linux && make clean )

    rm -rf build_mods_driver
    mkdir build_mods_driver

    SCRIPT="$0"
    [[ -f $SCRIPT ]] || SCRIPT=$(type "$0" | sed "s/.* is //")
    cp "$SCRIPT" build_mods_driver

    tar cpf build_mods_driver/buildroot.tar.bz2 $COMPRESS --exclude=newroot --exclude=var/db/repos --exclude=install --exclude=boot --exclude=var/db/pkg --exclude=usr/lib64/python2.7 --exclude=usr/lib64/python3.6 buildroot

    tar cf build_mods_driver.tar.bz2 $COMPRESS build_mods_driver
    rm -rf build_mods_driver
    echo "Package build_mods_driver.tar.bz2 ready"
    exit 0
fi

DIR="$(dirname "$0")"
PACKAGE="${DIR:-.}/buildroot.tar.bz2"

[[ -f $PACKAGE ]] || die "Error: File buildroot.tar.bz2 not found!"

wrapup()
{
    if [[ -d _work/buildroot ]]; then
        sleep 1
        sync
        umount -l _work/buildroot/{sys,run/shm,dev/pts,dev,proc} || die "Error: Unmounting failed!"
        sleep 2
    fi
    [[ ! -d _work ]] || rm -rf _work
}

trap wrapup EXIT

mkdir _work
tar xpf "$PACKAGE" $COMPRESS -C _work

mkdir -p _work/buildroot/driver
tar xzf "$1" -C _work/buildroot/driver/
[[ -d _work/buildroot/driver/driver ]] || die "MODS kernel driver sources not found in $1"
[[ -f _work/buildroot/driver/driver/Makefile ]] || die "MODS kernel driver sources not found in $1"

cat > _work/buildroot/driver/build.sh <<-EOF
	#!/bin/bash
	
	set -e
	
	cd /usr/src/linux
	make modules_prepare
	cd /driver/driver
	make -C /usr/src/linux M=/driver/driver modules
EOF
chmod 755 _work/buildroot/driver/build.sh

[[ -f /etc/resolv.conf ]] && cp /etc/resolv.conf _work/buildroot/etc/
mount -t proc none _work/buildroot/proc
mount --bind /dev _work/buildroot/dev
mount --bind /dev/pts _work/buildroot/dev/pts
mount -t sysfs none _work/buildroot/sys
mkdir -p _work/buildroot/run/shm
mount -t tmpfs -o mode=1777,nodev none _work/buildroot/run/shm

chroot _work/buildroot /driver/build.sh

cp _work/buildroot/driver/driver/mods.ko .

echo "mods.ko ready"

# vim:noet
