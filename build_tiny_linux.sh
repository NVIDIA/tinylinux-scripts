#!/bin/bash

# SPDX-License-Identifier: BSD-3-Clause
# SPDX-FileCopyrightText: Copyright (c) 2009-2023, NVIDIA CORPORATION.  All rights reserved.
# See LICENSE file for details.

set -e

MIRROR="http://gentoo.osuosl.org"
PORTAGEPKG="portage-latest.tar.bz2"
DISTFILESPKG="distfiles.tar.bz2"
PORTAGE="/var/db/repos/gentoo"
BUILDROOT="buildroot"
BUILDSCRIPTS="/buildscripts"
NEWROOT="/newroot"
INSTALL="/install"
SQUASHFS="/tiny/squash.bin"
MAKECONF="/etc/portage/make.conf"
NICE="ionice -c 3 nice -n 19"
PYTHON_VER=3.11

# Inherit TEGRAABI from parent process
TEGRAABI="${TEGRAABI:-aarch64-unknown-linux-gnu}"

die()
{
    echo "$@"
    exit 1
}

if [[ $# -eq 0 || $1 = "-h" || $1 = "--help" ]]; then
    echo "Usage:"
    echo "sudo `basename $0` [OPTIONS] <PROFILE>"
    echo
    echo "Options:"
    echo "  -j N    Launch N jobs simultaneously"
    echo "  -v VER  Use specified version number"
    echo "  -r      Rebuild entire target filesystem"
    echo "  -i      Run interactive shell within the build environment"
    echo "  -k      Force rebuilding the kernel"
    echo "  -q      Force recompressing squashfs"
    echo "  -m      Launch kernel menuconfig before compiling the kernel"
    echo "  -d DEV  Deploy installation to device (e.g. /dev/sdx)"
    exit
fi

# Auto-detect number of CPUs
JOBS="${JOBS:-$(grep -c ^processor /proc/cpuinfo)}"

# Auto-detect architecture
case "$(uname -m)" in
    x86_64)  STAGE3ARCH="amd64" ;;
    aarch64) STAGE3ARCH="arm64" ;;
    *)       die "Unrecognized arch - $(uname -m)"
esac

# Parse options
while [[ $# -gt 1 ]]; do
    OPT=$1
    shift
    case "$OPT" in
        -j) JOBS="$1" ; shift ;;
        -v) VERSION="$1" ; shift ;;
        -r) REBUILDNEWROOT="1" ;;
        -i) INTERACTIVE="1" ;;
        -k) REBUILDKERNEL="1" ;;
        -q) REBUILDSQUASHFS="1" ;;
        -m) KERNELMENUCONFIG="1" ; REBUILDKERNEL="1" ;;
        -d) DEPLOY="$1" ; shift ;;
        --arch=*) ARCH="${OPT#--arch=}"
                  case "$ARCH" in
                      amd64|x86_64) [[ $STAGE3ARCH = amd64 ]] || die "Cannot cross-compile x86_64 from ARM" ;;
                      armv8|arm64|aarch64) STAGE3ARCH="arm64" ;;
                      *) die "Unrecognized arch - $ARCH" ;;
                  esac
                  ;;
        --grub) USEGRUB=1 ;;
        --rc-kernel) RCKERNEL=1 ;;
        --custom-kernel)
            CUSTOMKERNEL="$1"
            REBUILDKERNEL="1"
            [[ -d $CUSTOMKERNEL ]] || die "Kernel directory $CUSTOMKERNEL does not exist"
            [[ -f $CUSTOMKERNEL/Makefile ]] || die "File $CUSTOMKERNEL/Makefile does not exist"
            shift
            ;;
        *) die "Unrecognized option - $OPT" ;;
    esac
done

# Set profile
if [[ $1 = "-i" ]]; then
    if [[ -f $BUILDROOT/var/lib/misc/extra ]]; then
        PROFILE=`cat "$BUILDROOT/var/lib/misc/extra"`
    else
        die "No profile selected"
    fi
    INTERACTIVE="1"
else
    [[ $1 && ${1#-} = $1 ]] || die "No profile selected"
    PROFILE="$1"
fi
shift

# Set Tegra build type for Tegra profile
TEGRATYPE="`dirname "$0"`/profiles/$PROFILE/tegra"
[[ -z $TEGRABUILD && -f $TEGRATYPE ]] && TEGRABUILD=`cat "$TEGRATYPE"`

# Find default stage3 package
STAGE3PKG="${STAGE3PKG:-$(find ./ -maxdepth 1 -name stage3-$STAGE3ARCH-*.tar.xz | head -n 1)}"

# Override package name with profile name
FINALPACKAGE="$PROFILE.zip"

# Set default version
VERSION="${VERSION:-$(date "+%y.%m.%d")}"

# Export user arguments
[[ $JOBS             ]] && export JOBS
[[ $PROFILE          ]] && export PROFILE
[[ $VERSION          ]] && export VERSION
[[ $REBUILDNEWROOT   ]] && export REBUILDNEWROOT
[[ $INTERACTIVE      ]] && export INTERACTIVE
[[ $REBUILDKERNEL    ]] && export REBUILDKERNEL
[[ $REBUILDSQUASHFS  ]] && export REBUILDSQUASHFS
[[ $KERNELMENUCONFIG ]] && export KERNELMENUCONFIG
[[ $DEPLOY           ]] && export DEPLOY
[[ $USEGRUB          ]] && export USEGRUB
[[ $RCKERNEL         ]] && export RCKERNEL
[[ $TEGRABUILD       ]] && export TEGRABUILD
[[ $TEGRAABI         ]] && export TEGRAABI

boldecho()
{
    echo -e "\033[1m$@\033[0m"
}

download()
{
    local URL
    local FILENAME
    local TYPE
    URL="$1"
    FILENAME=`basename $1`
    boldecho "Downloading $FILENAME"
    curl -f -O "$URL" || die "Unable to download $FILENAME"
    TYPE=`file "$FILENAME"`
    if echo "$TYPE" | grep -q HTML; then
        rm "$FILENAME"
        echo "Unable to download $FILENAME"
        exit 1
    fi
}

find_stage3()
{
    local STAGE3
    local URL
    local PARSEFILELIST
    local FILELIST
    local DIRLIST
    local DIR
    local LASTERROR

    STAGE3="$1"
    URL="$2"

    PARSEFILELIST="s/<[^>]*>/ /g ; s/^ *// ; s/ .*//"

    echo "Trying $URL" >&2
    FILELIST=$(curl -f "$URL" | sed "$PARSEFILELIST")
    if echo "$FILELIST" | grep -q "$GREPSTAGE"; then
        FILELIST=`echo "$FILELIST" | grep "$GREPSTAGE"`
        echo "${URL}$FILELIST"
        return 0
    fi

    DIRLIST=`echo "$FILELIST" | grep "/$"`
    while read DIR; do
        [[ -n $DIR ]] && find_stage3 "$STAGE3" "${URL}$DIR" && return 0
    done <<- EOF
$DIRLIST
EOF
    return 1
}

download_packages()
{
    # Don't do anything if we are inside the host tree already
    [[ -d ./$BUILDSCRIPTS ]] && return 0

    # Don't do anything if the host tree already exists
    [[ -d $BUILDROOT ]] && return 0

    # Download package database if needed
    [[ -f $PORTAGEPKG ]] || download "$MIRROR/snapshots/$PORTAGEPKG"

    # Download stage 3 image if needed
    if [[ ! -f $STAGE3PKG ]]; then
        local GREPSTAGE
        local STAGE3PATH
        local FLAVOR
        FLAVOR="openrc"
        GREPSTAGE="^stage3-$STAGE3ARCH-$FLAVOR-[0-9TZ].*\.tar\.xz$"
        boldecho "Downloading stage3 file list from the server"
        STAGE3PATH="$MIRROR/releases/$STAGE3ARCH/autobuilds/current-stage3-$STAGE3ARCH-$FLAVOR/"
        STAGE3PKG=`find_stage3 "$GREPSTAGE" "$STAGE3PATH"`
        download "$STAGE3PKG"
        STAGE3PKG=`basename "$STAGE3PKG"`
    fi
}

tar_bz2()
{
    local PROGRAM
    if [[ ${2##*.} = xz ]]; then
        PROGRAM=xz
    elif which lbzip2 >/dev/null 2>&1; then
        PROGRAM=lbzip2
    else
        PROGRAM=bzip2
    fi
    $NICE tar --use-compress-program "$PROGRAM" "$@"
}

unpack_packages()
{
    # Don't do anything if we are inside the host tree already
    [[ -d ./$BUILDSCRIPTS ]] && return 0

    # Don't do anything if the host tree already exists
    [[ -d $BUILDROOT ]] && return 0

    # Unpack the root
    boldecho "Unpacking stage3 package"
    mkdir "$BUILDROOT"
    tar_bz2 -xpf "$STAGE3PKG" --xattrs-include='*.*' --numeric-owner -C "$BUILDROOT"

    # Unpack portage tree
    boldecho "Unpacking portage tree"
    tar_bz2 -xpf "$PORTAGEPKG" -C "$BUILDROOT/var/db/repos"
    mv "$BUILDROOT/var/db/repos/portage" "${BUILDROOT}$PORTAGE"

    # Unpack distfiles if available
    if [[ -f $DISTFILESPKG ]]; then
        boldecho "Unpacking distfiles"
        tar_bz2 -xpf "$DISTFILESPKG" -C "$BUILDROOT"
    fi
}

copy_scripts()
{
    local SCRIPTSDIR="$(cd -P $(dirname "$0") && pwd)"

    # Don't do anything if we are inside the host tree already
    [[ -d ./$BUILDSCRIPTS ]] && return 0

    # Don't do anything if we are running the copy of build scripts already
    local DESTDIR="$BUILDROOT/$BUILDSCRIPTS"
    [[ -d $DESTDIR ]] && DESTDIR="$(cd -P "$DESTDIR" && pwd)"
    if [[ $DESTDIR != $SCRIPTSDIR ]]; then

        # Delete stale build scripts
        rm -rf "$DESTDIR"

        boldecho "Copying scripts to build environment"

        # Check access to the scripts
        [[ -f $SCRIPTSDIR/scripts/etc/inittab ]] || die "TinyLinux scripts are not available"
        [[ -d $SCRIPTSDIR/profiles/$PROFILE   ]] || die "Selected profile $PROFILE is not available"

        # Copy TinyLinux scripts
        mkdir -p "$DESTDIR"
        find "$SCRIPTSDIR"/ -maxdepth 1 -type f -exec cp '{}' "$DESTDIR" \;
        cp -r "$SCRIPTSDIR"/profiles "$DESTDIR"
        cp -r "$SCRIPTSDIR"/mods     "$DESTDIR"
        cp -r "$SCRIPTSDIR"/scripts  "$DESTDIR"
        cp -r "$SCRIPTSDIR"/extra    "$DESTDIR"
        [[ -z $TEGRABUILD ]] || cp -r "$SCRIPTSDIR"/tegra "$DESTDIR"
    fi

    # Copy custom kernel
    if [[ -n $CUSTOMKERNEL ]]; then
        boldecho "Copying custom kernel sources"
        mkdir -p "$BUILDROOT/usr/src/linux-custom"
        rsync -av --progress "$CUSTOMKERNEL"/ "$BUILDROOT/usr/src/linux-custom"
        rm -f "$BUILDROOT/usr/src/linux"
        ln -s linux-custom "$BUILDROOT/usr/src/linux"
    fi

    # Update TinyLinux version printed on boot
    sed -i "s/^VERSION=.*/VERSION=\"$VERSION\"/" "$DESTDIR/linuxrc"
}

exit_chroot()
{
    sleep 1
    sync
    umount -l "$BUILDROOT"/{sys,dev/shm,dev/pts,dev,proc} || boldecho "Unmount failed!"
}

run_in_chroot()
{
    local QEMUEXE

    # Don't do anything if we are inside the host tree already
    [[ -d ./$BUILDSCRIPTS ]] && return 0

    if [[ $(uname -m) = "x86_64" && $STAGE3ARCH = "arm64" ]]; then
        boldecho "Preparing qemu"

        QEMUEXE="qemu-aarch64-static"
        local QEMUPATH="$(which "$QEMUEXE" 2>/dev/null || true)"
        if [[ -z $QEMUPATH ]]; then
            [[ -f /etc/debian_version ]] && apt-get install qemu-user-static
            QEMUPATH="$(which "$QEMUEXE" 2>/dev/null || true)"
        fi

        [[ -n $QEMUPATH ]] || die "$QEMUEXE not found!"

        if [[ ! -f "$BUILDROOT/$QEMUEXE" ]]; then
            local QEMUDIR="$(dirname "$QEMUPATH")"
            mkdir -p "$BUILDROOT/$QEMUDIR"
            cp "$QEMUPATH" "$BUILDROOT/$QEMUEXE"
        fi
        QEMUEXE="./$QEMUEXE /bin/bash"
    fi

    boldecho "Entering build environment"

    local SRCDIR="$(cd -P "$(dirname "$0")" && pwd)"
    local DESTDIR="$(cd -P "$BUILDROOT/$BUILDSCRIPTS" && pwd)"
    [[ $SRCDIR = $DESTDIR ]] || cp "$0" "$DESTDIR"/

    cp /etc/resolv.conf "$BUILDROOT/etc"/
    mount -t proc none "$BUILDROOT/proc"
    trap exit_chroot EXIT
    mount --bind /dev "$BUILDROOT/dev"
    mount --bind /dev/pts "$BUILDROOT/dev/pts"
    mount -t sysfs none "$BUILDROOT/sys"
    mkdir -p "$BUILDROOT/dev/shm"
    mount -t tmpfs -o mode=1777,nodev none "$BUILDROOT/dev/shm"

    $NICE chroot "$BUILDROOT" $QEMUEXE "$BUILDSCRIPTS/`basename $0`" "$PROFILE"

    if [ -s "$BUILDROOT/$DISTFILESPKG" ]; then
        mv "$BUILDROOT/$DISTFILESPKG" ./
        touch -r ./"$DISTFILESPKG" "$BUILDROOT/$DISTFILESPKG"
    fi

    exit
}

check_env()
{
    if [[ -f /var/lib/misc/extra ]]; then
        local TARGET
        TARGET=`cat /var/lib/misc/extra`
        [[ $PROFILE = $TARGET || $REBUILDNEWROOT = 1 ]] || die "Invalid profile, target system was built with $TARGET profile"
    fi
    eselect news read
}

prepare_portage()
{
    sed -i -e "/^MAKEOPTS/d ; /^PORTAGE_NICENESS/d ; /^USE/d ; /^GRUB_PLATFORMS/d" "$MAKECONF"

    (
        [[ $JOBS ]] && echo "MAKEOPTS=\"-j$JOBS\""
        echo 'PORTAGE_NICENESS="15"'
        echo "USE=\"-* ipv6 multicall ncurses readline syslog threads unicode python_targets_python${PYTHON_VER/./_} python_single_target_python${PYTHON_VER/./_}\""
        echo 'GRUB_PLATFORMS="efi-64"'
    ) >> "$MAKECONF"

    # Needed in qemu
    if [[ $(uname -m) = aarch64 ]] && ! grep -q "pid-sandbox" "$MAKECONF"; then
        echo 'FEATURES="-pid-sandbox"' >> "$MAKECONF"
    fi

    local KEYWORDS="/etc/portage/package.accept_keywords/tinylinux"
    mkdir -p /etc/portage/package.accept_keywords
    mkdir -p /etc/portage/package.use
    mkdir -p /etc/portage/package.mask
    mkdir -p /etc/portage/package.unmask
    if [[ ! -f $KEYWORDS ]]; then
        local ACCEPT_PKGS
        ACCEPT_PKGS=(
            "sys-kernel/gentoo-sources"
            "sys-kernel/git-sources"
            "net-misc/ipsvd"
            "sys-apps/hwids"
            "=sys-devel/patch-2.7.1-r3"
            "=sys-boot/gnu-efi-3.0u"
            "=sys-auth/libnss-nis-3.1"
            )
        local PKG
        for PKG in ${ACCEPT_PKGS[*]}; do
            echo "${PKG} **" >> "$KEYWORDS"
        done
    fi

    local USE_FLAGS=(
        "app-alternatives/awk busybox"
        "app-alternatives/bc gnu"
        "app-alternatives/bzip2 lbzip2"
        "app-alternatives/cpio gnu"
        "app-alternatives/gzip pigz"
        "dev-lang/python xml ssl"
        "dev-libs/libtomcrypt libtommath"
        "dev-libs/libverto libev"
        "dev-libs/libxml2 python"
        "dev-libs/openssl asm bindist tls-heartbeat zlib"
        "dev-vcs/git curl"
        "media-libs/leptonica jpeg zlib"
        "media-libs/libv4l jpeg"
        "net-fs/autofs libtirpc"
        "net-misc/dropbear pam"
        "sys-apps/hwids net pci usb"
        "sys-auth/pambase pam_krb5 nullok"
        "sys-boot/syslinux bios efi"
        "sys-fs/quota rpc"
        "sys-fs/squashfs-tools lzma"
        "sys-libs/glibc crypt rpc"
        "sys-libs/pam nis"
    )

    touch /etc/portage/package.use/tinylinux
    local IDX
    for IDX in $(seq 0 $((${#USE_FLAGS[@]} - 1))); do
        grep -q "${USE_FLAGS[$IDX]}" /etc/portage/package.use/tinylinux || echo "${USE_FLAGS[$IDX]}" >> /etc/portage/package.use/tinylinux
    done

    # Mask systemd-tmpfiles pulled by virtual/tmpfiles, pulled e.g. by screen
    echo "sys-apps/systemd-tmpfiles" >> /etc/portage/package.mask/tinylinux

    # Enable the latest iasl tool
    echo "sys-power/iasl ~*" >> $KEYWORDS

    # Enable some packages on 64-bit ARM (temporary, until enabled in Gentoo)
    if [[ $STAGE3ARCH = arm64 ]]; then
        local ACCEPT_PKGS
        ACCEPT_PKGS=(
            dev-libs/libffi-3.2.1
            dev-util/valgrind-3.19.0
            net-dns/libidn2-2.0.5
            net-fs/autofs-5.1.8-r1
            net-libs/libtirpc-1.0.2-r1
            net-nds/portmap-6.0
            net-nds/rpcbind-0.2.4-r1
            net-nds/yp-tools-4.2.3-r1
            net-wireless/bluez-5.50-r2
            net-wireless/rfkill-0.5-r3
            sys-apps/kexec-tools-2.0.22
            sys-block/fio-3.27-r4
            sys-libs/glibc-2.36
            )
        local PKG
        for PKG in ${ACCEPT_PKGS[*]}; do
            echo "=${PKG} **" >> /etc/portage/package.accept_keywords/tegra
        done
    fi

    # Setup split glibc symbols for valgrind and remote debugging
    if [[ $TEGRABUILD ]]; then
        mkdir -p "/etc/portage/package.env"
        echo "sys-libs/glibc debug"         >  "/etc/portage/package.env/glibc"
        echo "dev-util/valgrind debug"      >  "/etc/portage/package.env/valgrind"
        mkdir -p "/etc/portage/env"
        echo 'CFLAGS="${CFLAGS} -ggdb"'     >  "/etc/portage/env/debug"
        echo 'CXXFLAGS="${CXXFLAGS} -ggdb"' >> "/etc/portage/env/debug"
        echo 'FEATURES="$FEATURES splitdebug compressdebug"' >> "/etc/portage/env/debug"
    fi

    # Patch uninitialized variable in syslinux
    local EBUILD=$PORTAGE/sys-boot/syslinux/syslinux-6.04_pre1-r5.ebuild
    if [[ -f $EBUILD ]] && ! grep -q "bios-free-mem" "$EBUILD"; then
        boldecho "Patching $EBUILD"
        mkdir -p $PORTAGE/sys-boot/syslinux/files
        cp "$BUILDSCRIPTS/extra/syslinux-bios-free-mem.patch" $PORTAGE/sys-boot/syslinux/files/
        sed -i "s/PATCHES=(/PATCHES=( \"\${FILESDIR}\"\/\${PN}-bios-free-mem.patch/" "$EBUILD"
        ebuild "$EBUILD" digest
    fi

    # Patch compilation failure in autofs
    local EBUILD=$PORTAGE/net-fs/autofs/autofs-5.1.6.ebuild
    if [[ -f $EBUILD ]] && ! grep -q "gcc=strip" "$EBUILD"; then
        boldecho "Patching $EBUILD"
        sed -i '/Makefile.rules/ a\\tsed -i -e "/^STRIP.*strip-debug/s/strip/\\$(CC:gcc=strip)/" Makefile.rules' "$EBUILD"
        ebuild "$EBUILD" digest
    fi

    # Install ypbind ebuild
    local SRC=ypbind-2.7.2.ebuild
    local EBUILD=$PORTAGE/net-nds/ypbind/$SRC
    if [[ ! -f $EBUILD ]]; then
        boldecho "Adding $EBUILD"
        mkdir -p $PORTAGE/net-nds/ypbind
        mkdir -p /var/cache/distfiles
        cp "$BUILDSCRIPTS/extra/$SRC" "$EBUILD"
        ebuild "$EBUILD" digest
    fi

    # Fix splitdebug feature in glibc
    local EBUILD=$PORTAGE/sys-libs/glibc/glibc-2.29-r2.ebuild
    if [[ $TEGRABUILD ]] && [[ -f $EBUILD ]] && ! grep -q src_strip "$EBUILD"; then
        boldecho "Patching $EBUILD"
        cd "$PORTAGE"
        patch -p0 < "$BUILDSCRIPTS/extra/glibc-splitdebug.patch"
        cd -
        ebuild "$EBUILD" digest
    fi

    # Patch busybox to avoid failing to copy symlinks
    if grep -q "die.*copying" "$PORTAGE"/sys-apps/busybox/busybox*.ebuild; then
        local EBUILD
        for EBUILD in $(grep -l "die.*copying" "$PORTAGE"/sys-apps/busybox/busybox*.ebuild); do
            boldecho "Patching $EBUILD"
            sed -i '/die.*copying/s/die/echo/' "$EBUILD"
            ebuild "$EBUILD" digest
        done
    fi
}

run_interactive()
{
    if [[ $INTERACTIVE = 1 ]]; then
        bash
        exit
    fi
}

emerge_basic_packages()
{
    boldecho "Compiling basic host packages"

    local SYSLINUX_PKG=""
    [[ $(uname -m) = x86_64 ]] && SYSLINUX_PKG="syslinux"

    local HOST_PKGS=(
        dev-libs/glib
        dosfstools
        dropbear
        genkernel
        grub
        lbzip2
        less
        libtirpc
        pkgconfig
        reiserfsprogs
        rpcbind
        rpcsvc-proto
        squashfs-tools
        sys-devel/bc
        $SYSLINUX_PKG
        zip
    )
    if ! emerge --quiet --noreplace ${HOST_PKGS[@]}; then
        boldecho "Failed to emerge some packages"
        boldecho "Please complete installation manually"
        bash
    fi

    USE="static-libs" emerge --quiet --noreplace sys-libs/libxcrypt

    # Skip the kernel on Tegra or if it is already installed
    if [[ -z $TEGRABUILD ]] && [ ! -e /usr/src/linux ]; then
        local KERNELPKG=gentoo-sources
        [[ $RCKERNEL = 1 ]] && KERNELPKG=git-sources

        if ! USE=symlink emerge --quiet $KERNELPKG; then
            boldecho "Failed to emerge some packages"
            boldecho "Please complete installation manually"
            bash
        fi

        # WAR for failure when loading drm module
        # The kernel wants to load 8KB for the drm module from the reserved
        # per-CPU chunk while the size of that chunk also defaults to 8KB,
        # but for some reason the block is not page-aligned.  Bump default
        # size of reserved chunk to to 16KB.
        sed -i '/^#define PERCPU_MODULE_RESERVE\>.*\<8\>/s/8/16/' /usr/src/linux/include/linux/percpu.h
    fi
}

compile_kernel()
{
    local MAKEOPTS
    local GKOPTS
    local CCPREFIX

    # Do not compile kernel for Tegra
    if [[ $TEGRABUILD ]]; then
        touch /usr/src/linux
        return 0
    fi

    # Skip compilation if kernel has already been built
    [ ! -f /boot/vmlinuz-* ] || [[ $REBUILDKERNEL = 1 ]] || return 0

    [ -e /usr/src/linux ] && [[ $(readlink /usr/src/linux) = linux-custom ]] && boldecho "Using custom kernel sources"

    # Delete old kernel
    rm -rf /boot/vmlinuz-*
    rm -rf /boot/initramfs-*
    rm -f "$INSTALL/tiny/kernel"
    rm -f "$INSTALL/tiny/initrd"

    # Force regeneration of squashfs
    rm -f "$INSTALL/$SQUASHFS"

    # Remove disklabel (blkid) from genkernel configuration
    sed -i "/^DISKLABEL/s/yes/no/" /etc/genkernel.conf

    boldecho "Preparing kernel"
    [[ $JOBS ]] && MAKEOPTS="--makeopts=-j$JOBS"
    rm -rf /lib/{modules,firmware}
    cp "$BUILDSCRIPTS/kernel-config" /usr/src/linux/.config

    if [[ $KERNELMENUCONFIG = 1 ]]; then
        boldecho "Configuring kernel"
        make -C /usr/src/linux menuconfig
    fi

    boldecho "Compiling kernel"
    genkernel --oldconfig --linuxrc="$BUILDSCRIPTS/linuxrc" --no-mountboot "$MAKEOPTS" kernel

    boldecho "Creating initial ramdisk"
    local BBCFG="/tmp/init-busy-config"
    cp /usr/share/genkernel/defaults/busy-config "$BBCFG"
    local BUSYBOX_OPTS=(
        "CONFIG_MODPROBE_SMALL=n"
        "CONFIG_FEATURE_MODPROBE_SMALL_OPTIONS_ON_CMDLINE=n"
        "CONFIG_FEATURE_MODPROBE_SMALL_CHECK_ALREADY_LOADED=n"
        "CONFIG_INSMOD=y"
        "CONFIG_RMMOD=y"
        "CONFIG_LSMOD=y"
        "CONFIG_MODPROBE=y"
        "CONFIG_FEATURE_MODUTILS_ALIAS=y"
        "CONFIG_FEATURE_MODUTILS_SYMBOLS=y"
        )
    local OPT
    for OPT in "${BUSYBOX_OPTS[@]}"; do
        sed -i -e "/\<${OPT%=*}\>/s/.*/$OPT/" "$BBCFG"
    done
    genkernel --oldconfig --linuxrc="$BUILDSCRIPTS/linuxrc" --no-mountboot --no-zfs --no-btrfs "$MAKEOPTS" --all-ramdisk-modules --busybox-config="$BBCFG" ramdisk

    trim_initrd_modules
}

trim_initrd_modules()
{
    boldecho "Trimming initrd"

    local NUM_INITRD="$(ls /boot | grep initramfs | wc -l)"
    [[ $NUM_INITRD -ge 1 ]] || die "Missing /boot/initramfs"
    [[ $NUM_INITRD -eq 1 ]] || die "Multiple /boot/initramfs files"

    # Unpack initrd
    local INITRD="$(ls /boot/initramfs*)"
    rm -rf /tmp/initrd
    mkdir /tmp/initrd
    cd /tmp/initrd
    unxz < "$INITRD" | cpio -i

    # Delete unwanted modules
    local MODULE_DIRS=(
        kernel/drivers/media
        kernel/drivers/net/wireless
        kernel/drivers/usb/serial
        kernel/net/wireless
        kernel/sound
    )
    local DIR
    for DIR in "${MODULE_DIRS[@]}"; do
        rm -rf lib/modules/*gentoo*/"$DIR"
    done

    # Compress initrd
    find . -print | cpio --create --format=newc | xz -v -e --check=none -z -f -9 -T 0 > "$INITRD"

    cd -
}

need_host_package()
{
    local HOST_PACKAGES=(
        sys-auth/libnss-nis
    )

    while [[ $# -gt 0 ]]; do
        local PKG

        for PKG in "${HOST_PACKAGES[@]}"; do
            [[ $1 = $PKG ]] && return 0
        done

        shift
    done

    return 1
}

target_emerge()
{
    ROOT="$NEWROOT" emerge "$@"

    local NEWS="var/lib/gentoo/news/news-gentoo.unread"
    if test -s "$NEWROOT/$NEWS"; then
        echo "Erasing news from $NEWROOT/$NEWS"
        echo -n > "$NEWROOT/$NEWS"
    fi
}

install_package()
{
    USE="$2" target_emerge --quiet --usepkg --buildpkg $3 "$1"
}

list_package_files()
{
    grep -v "^dir" "$NEWROOT"/var/db/pkg/$1-*/CONTENTS | \
        cut -f 2 -d ' ' | cut -c 1 --complement
}

install_syslinux()
{
    [[ $TEGRABUILD ]] && return 0
    [[ $(uname -m) = x86_64 ]] || return 0

    local DESTDIR
    local SAVEROOT

    DESTDIR="/tmp/syslinux"

    SAVEROOT="$NEWROOT"
    NEWROOT="$DESTDIR" target_emerge --quiet --nodeps --usepkg --buildpkg syslinux mtools
    NEWROOT="$SAVEROOT"

    cp -p "$DESTDIR/sbin/extlinux" "$NEWROOT/usr/bin/extlinux"
    local FILE
    for FILE in syslinux mcopy mattrib; do
        cp -p "$DESTDIR/usr/bin/$FILE" "$NEWROOT/usr/bin/$FILE"
    done
    rm -rf "$DESTDIR"

    mkdir -p "$NEWROOT/usr/share/syslinux"
    cp /usr/share/syslinux/mbr.bin "$NEWROOT/usr/share/syslinux"/
    cp /usr/share/syslinux/gptmbr.bin "$NEWROOT/usr/share/syslinux"/
    cp -r /usr/share/syslinux/efi64 "$NEWROOT/usr/share/syslinux"/
}

remove_gentoo_services()
{
    local DIR
    while [[ $# -gt 0 ]]; do
        for DIR in init.d conf.d; do
            rm -f "$NEWROOT/etc/$DIR/$1"
        done
        shift
    done
}

record_dir_symlinks()
{
    local SYMLINK
    for SYMLINK in /bin /sbin /lib /lib64 /usr/sbin; do
        record_symlink sys-libs/glibc "$SYMLINK"
    done
}

build_newroot()
{
    # Remove old build
    if [[ $REBUILDNEWROOT = 1 ]]; then
        rm -rf "$NEWROOT"
        rm -rf "$INSTALL"
        rm -f /var/lib/misc/extra
    fi

    # Skip if new root already exists
    [[ -d $NEWROOT ]] && return 0

    # Handle Gentoo news items
    eselect news read

    boldecho "Building TinyLinux root filesystem"

    mkdir -p "$NEWROOT"
    mkdir -p "$NEWROOT/var/lib/gentoo/news"

    # Prepare merged dirs
    # Note: this list is duplicated in record_dir_symlinks
    mkdir -p "$NEWROOT/usr/bin"
    mkdir -p "$NEWROOT/usr/lib"
    mkdir -p "$NEWROOT/usr/lib64"
    ln -sf usr/bin   "$NEWROOT/bin"
    ln -sf usr/bin   "$NEWROOT/sbin"
    ln -sf usr/lib   "$NEWROOT/lib"
    ln -sf usr/lib64 "$NEWROOT/lib64"
    ln -sf bin       "$NEWROOT/usr/sbin"

    # Restore busybox config file
    local BUSYBOXCFG="$BUILDSCRIPTS/busybox-config"
    local HOSTBUSYBOXCFGDIR=/etc/portage/savedconfig/sys-apps
    local TARGETBUSYBOXCFGDIR="$NEWROOT/etc/portage/savedconfig/sys-apps"
    local BUSYBOX_VER
    ls $PORTAGE/sys-apps/busybox/*ebuild | sed "s:.*/:: ; s:\.ebuild::" | while read BUSYBOX_VER; do
        mkdir -p "$HOSTBUSYBOXCFGDIR"
        cp "$BUSYBOXCFG" "$HOSTBUSYBOXCFGDIR/$BUSYBOX_VER"
        mkdir -p "$TARGETBUSYBOXCFGDIR"
        cp "$BUSYBOXCFG" "$TARGETBUSYBOXCFGDIR/$BUSYBOX_VER"
    done

    # Setup directories for valgrind and for debug symbols
    if [[ $TEGRABUILD ]]; then
        rm -rf /tiny/debug /tiny/valgrind
        mkdir -p /tiny/debug/mnt /tiny/valgrind
        mkdir -p "$NEWROOT/usr/libexec"
        mkdir -p "$NEWROOT/usr/share"
        ln -s /tiny/debug    "$NEWROOT/usr/lib64/debug"
        ln -s /tiny/debug    "$NEWROOT/usr/lib/debug"
        ln -s /tiny/valgrind "$NEWROOT/usr/libexec/valgrind"
    fi

    # Install basic system packages
    install_package sys-libs/glibc "" --nodeps # Latest glibc pulls deps!!!
    record_dir_symlinks # Record directory symlinks with glibc
    install_package sys-auth/libnss-nis
    rm -rf "$NEWROOT"/lib*/gentoo # Remove Gentoo scripts

    # Remove 32-bit glibc in 64-bit builds
    rm -rf "$NEWROOT"/lib
    rm -rf "$NEWROOT"/usr/lib
    mkdir -p "$NEWROOT"/usr/lib
    ln -s usr/lib "$NEWROOT/lib"
    ln -s /tiny/debug "$NEWROOT/usr/lib/debug"

    install_package ncurses
    ln -s libncurses.so.6  "$NEWROOT"/lib64/libncurses.so.5
    ln -s libncursesw.so.6 "$NEWROOT"/lib64/libncursesw.so.5
    install_package pciutils
    rm -f "$NEWROOT/usr/share/misc"/*.gz # Remove compressed version of hwids

    install_package busybox "make-symlinks mdev nfs pam savedconfig"
    rm -rf "${NEWROOT}-busybox"
    mkdir "${NEWROOT}-busybox" # workaround for busybox symlinks clashing with merged bin/sbin/lib
    NEWROOT="${NEWROOT}-busybox" install_package busybox "make-symlinks mdev nfs savedconfig" --nodeps
    rm -f "$NEWROOT"/etc/portage/savedconfig/sys-apps/._cfg* # Avoid excess of portage messages
    create_busybox_symlinks
    rm "$NEWROOT/usr/bin/env"
    ln -s busybox "$NEWROOT/usr/bin/env"

    install_package dropbear "multicall"
    ignore_busybox_symlinks /usr/bin/bc
    install_package sys-devel/bc
    install_package net-wireless/wireless-tools
    install_package dev-libs/openssl
    ROOT="$NEWROOT" emerge --unmerge -q debianutils # Remove package pulled by openssl

    # Install more basic packages
    install_package nano
    install_package bash "net"
    test -e "$NEWROOT/bin/bash" || ln -s $(ls "$NEWROOT"/bin/bash-* | head -n 1 | xargs basename) "$NEWROOT/bin/bash"

    # Install NFS utils
    install_package net-nds/rpcbind
    if [[ $TEGRABUILD ]]; then
        COLLISION_IGNORE="/bin /sbin /usr/bin /usr/sbin" install_package sys-apps/util-linux "" --nodeps
    fi
    emerge --quiet --noreplace dev-libs/libevent # nfs-utils dependency
    install_package nfs-utils "" --nodeps
    remove_gentoo_services nfs nfsmount rpcbind rpc.statd
    rm "$NEWROOT/usr/bin/fsidd" # Remove due to lack of libevent and libsqlite3

    # Additional x86-specific packages
    if [[ -z $TEGRABUILD ]]; then
        install_package libusb-compat
        install_package numactl
        install_package efibootmgr
        install_package ntfs3g "fuse mount-ntfs ntfsprogs xattr" --nodeps # nodeps to avoid util-linux
        remove_gentoo_services netmount
    fi

    # Finish installing dropbear
    mkdir "$NEWROOT/etc/dropbear"
    dropbearkey -t dss -f "$NEWROOT/etc/dropbear/dropbear_dss_host_key"
    dropbearkey -t rsa -f "$NEWROOT/etc/dropbear/dropbear_rsa_host_key"
    dropbearkey -t ecdsa -f "$NEWROOT/etc/dropbear/dropbear_ecdsa_host_key"
    dropbearkey -t ed25519 -f "$NEWROOT/etc/dropbear/dropbear_ed25519_host_key"
    ( cd "$NEWROOT/usr/bin" && ln -s dbclient ssh )
    ( cd "$NEWROOT/usr/bin" && ln -s dbscp scp )

    # Copy libgcc and libstdc++ needed by some tools
    cp /usr/lib/gcc/*/*/{libgcc_s.so.1,libstdc++.so.6} "$NEWROOT/lib64"/

    # Remove linuxrc script from busybox
    rm -rf "$NEWROOT/linuxrc"

    # Update ns switch
    sed -i "s/compat/db files nis/" "$NEWROOT/etc/nsswitch.conf"
    sed -i "/^[ #]*initgroups *:/s/^[ #]*//" "$NEWROOT/etc/nsswitch.conf"

    # Remove unneeded scripts
    remove_gentoo_services autofs dropbear fuse mdev mit-krb5kadmind mit-krb5kdc mit-krb5kpropd nfsclient nscd pciparm ypbind
    rm -f "$NEWROOT/etc"/{init.d,conf.d}/busybox-*
    rm -rf "$NEWROOT/etc/systemd"

    # Build extra tools
    local TOOL
    for TOOL in setdomainname modalias; do
        echo ">>> Compiling $TOOL"
        gcc -O3 -Wall -Wextra -Wl,-s -o "$NEWROOT/usr/bin/$TOOL" "$BUILDSCRIPTS/extra/$TOOL.c"
    done

    # Copy TinyLinux scripts
    local FILE
    ( cd "$BUILDSCRIPTS/scripts" && find ./ ! -type d && find ./ -type f -name ".*" ) | while read FILE; do
        local SRC
        local DEST
        SRC="$BUILDSCRIPTS/scripts/$FILE"
        DEST=$(sed 's:/lib/:/lib64/:' <<< "$NEWROOT/$FILE")
        mkdir -p $(dirname "$DEST")
        cp -P "$SRC" "$DEST"
        if [[ ! -h $DEST ]]; then
            if [[ ${FILE:2:11} = etc/init.d/ || $FILE =~ etc/acpi/actions || $FILE =~ etc/udhcpc.scripts ]]; then
                chmod 755 "$DEST"
            elif [[ ${FILE:2:4} = etc/ || $FILE =~ usr/share ]]; then
                chmod 644 "$DEST"
            else
                chmod 755 "$DEST"
            fi
        fi
    done

    # Remove additional terminals on ARM
    if [[ $TEGRABUILD ]] || [[ $(uname -m) = aarch64 ]]; then
        sed -i "/^tty.*getty/d" "$NEWROOT"/etc/inittab
    fi

    # Install syslinux so TinyLinux can reinstall itself
    install_syslinux

    # Create /etc/passwd and /etc/group
    echo "root:x:0:0:root:/root:/usr/bin/bash" > "$NEWROOT/etc/passwd"
    echo "root::0:root" > "$NEWROOT/etc/group"
    echo "dhcp:x:101:101:dhcp:/:/usr/bin/false" >> "$NEWROOT/etc/passwd"
    echo "dhcp::101:" >> "$NEWROOT/etc/group"
    echo "tftp:x:102:102:tftp:/:/usr/bin/false" >> "$NEWROOT/etc/passwd"
    echo "tftp::102:" >> "$NEWROOT/etc/group"
    echo "tty::5:" >> "$NEWROOT/etc/group"
    echo "disk::6:root" >> "$NEWROOT/etc/group"
    echo "kmem::9:" >> "$NEWROOT/etc/group"
    echo "users::100:" >> "$NEWROOT/etc/group"
    echo "audio::107:" >> "$NEWROOT/etc/group"

    # Create /etc/shells so that root can log in remotely using bash
    local ASHELL
    echo -n "" > "$NEWROOT"/etc/shells
    for ASHELL in sh ash bash; do
        echo "/bin/$ASHELL" >> "$NEWROOT"/etc/shells
        echo "/usr/bin/$ASHELL" >> "$NEWROOT"/etc/shells
    done

    # Copy /etc/services and /etc/protocols
    [[ -f $NEWROOT/etc/services  ]] || cp /etc/services  "$NEWROOT"/etc/
    [[ -f $NEWROOT/etc/protocols ]] || cp /etc/protocols "$NEWROOT"/etc/

    # Create /etc/mtab
    ln -s /proc/mounts "$NEWROOT"/etc/mtab

    # Create hosts file
    echo "127.0.0.1   localhost tinylinux" > "$NEWROOT/etc/hosts"
    echo "::1         localhost" >> "$NEWROOT/etc/hosts"

    # Create syslog.conf
    touch "$NEWROOT/etc/syslog.conf"
}

package_contents()
{
    ls "$NEWROOT"/var/db/pkg/$1-*/CONTENTS
}

record_symlink()
{
    local SYMLINK="$2"
    [ -h "$NEWROOT/$SYMLINK" ] || die "$SYMLINK is not a symlink!"

    local CONTENTS="$(package_contents "$1")"

    local TARGET="$(readlink "$NEWROOT/$SYMLINK")"
    local TIMESTAMP="$(stat -c "%Y" "$NEWROOT/$SYMLINK")"
    if ! grep -q "sym $(sed 's:\[:\\[:g' <<< "$SYMLINK") " "$CONTENTS"; then
        echo "sym $SYMLINK -> $TARGET $TIMESTAMP" >> "$CONTENTS"
    fi
}

create_busybox_symlinks()
{
    echo
    echo "*** Installing busybox symlinks"
    local SYMLINK
    for SYMLINK in "${NEWROOT}-busybox"/{bin,sbin}/*; do
        test -h "$SYMLINK" || continue
        local TARGET="$(readlink "$SYMLINK")"
        [[ $TARGET =~ busybox$ ]] || continue
        local NAME="${SYMLINK##*/}"
        SYMLINK="/usr/bin/$NAME"
        [ -h "$NEWROOT/$SYMLINK" ] && continue # Ignore duplicate busybox symlinks
        if [[ -f "$NEWROOT/$SYMLINK" ]]; then
            echo "Skipping overwriting of existing $SYMLINK ($(stat -c "%s" "$NEWROOT/$SYMLINK") bytes)"
            continue
        fi
        ln -s busybox "$NEWROOT/$SYMLINK"
        record_symlink sys-apps/busybox "$SYMLINK"
    done
    echo
}

ignore_busybox_symlinks()
{
    local CONTENTS="$(package_contents sys-apps/busybox)"
    while [[ $# -gt 0 ]]; do
        local FILE="$(sed 's:/:.:g' <<< "$1")"
        sed -i "/^sym $FILE/ d" "$CONTENTS"
        shift
    done
}

get_legacy_syslinux_installer()
{
    local INSTALLED_EXE="/usr/share/syslinux/syslinux.exe"
    local DIR=""
    if [[ ! -f $INSTALLED_EXE ]]; then

        local PKG="$(ls /var/cache/distfiles/syslinux*tar.xz 2>/dev/null | head -n 1 || true)"
        [[ -n $PKG ]] || die "Could not find /var/cache/distfiles/syslinux*tar.xz"
        [[ -f $PKG ]] || die "Could not find $PKG"

        tar xJf "$PKG" -C /tmp
        DIR="/tmp/$(basename "${PKG%.tar.xz}")"

        local ORIG_PATH="bios/win32/syslinux.exe"
        INSTALLED_EXE="$DIR/$ORIG_PATH"
        [[ -f $INSTALLED_EXE ]] || die "$ORIG_PATH not found in $PKG"
    fi

    echo "Using $INSTALLED_EXE"
    cp "$INSTALLED_EXE" "$1"/

    [[ -z $DIR ]] || rm -rf "$DIR"
}

prepare_installation()
{
    # Skip if the install directory already exists
    local INSTALLEXISTED
    [[ -d $INSTALL ]] && INSTALLEXISTED=1

    mkdir -p "$INSTALL/home"
    mkdir -p "$INSTALL/tiny"
    if [[ ! -f $INSTALL/tiny/kernel && -z $TEGRABUILD ]] ; then
        cp /boot/vmlinuz-* "$INSTALL/tiny/kernel"
        cp /boot/initramfs-* "$INSTALL/tiny/initrd"
    fi

    [[ $INSTALLEXISTED = 1 ]] && return 0

    # Install syslinux bootloader
    if [[ -z $TEGRABUILD ]] && [[ $(uname -m) = x86_64 ]] && [[ $USEGRUB != 1 ]]; then
        mkdir -p "$INSTALL/syslinux"
        echo "default /tiny/kernel initrd=/tiny/initrd quiet" > "$INSTALL/syslinux/syslinux.cfg"
        get_legacy_syslinux_installer "$INSTALL"

        local EFI_BOOT="$INSTALL/EFI/BOOT"
        mkdir -p "$EFI_BOOT"
        cp /usr/share/syslinux/efi64/syslinux.efi "$EFI_BOOT/bootx64.efi"
        cp /usr/share/syslinux/efi64/ldlinux.e64  "$EFI_BOOT"/
    fi

    # Prepare GRUB as an alternative
    if [[ -z $TEGRABUILD ]]; then
        local GRUB_MODULES=(
            part_gpt
            part_msdos
            ext2
            fat
            exfat
        )

        local GRUBARCH="$(uname -m)"
        if [[ $GRUBARCH = aarch64 ]]; then
            GRUBARCH=arm64
            USEGRUB=1
        fi

        local GRUBINSTALL="$INSTALL"
        if [[ "$USEGRUB" != "1" ]]; then
            GRUBINSTALL="/grub"
            rm -rf "$GRUBINSTALL"
        fi

        mkdir -p "$GRUBINSTALL/EFI/BOOT" "$GRUBINSTALL/grub/$GRUBARCH-efi"
        grub-mkimage --directory "/usr/lib/grub/$GRUBARCH-efi" --prefix '(hd0,1)/grub' --output "$GRUBINSTALL/EFI/BOOT/BOOTX64.EFI" --format "$GRUBARCH-efi" --compression 'auto' "${GRUB_MODULES[@]}"
        cp /usr/lib/grub/$GRUBARCH-efi/*.mod "$GRUBINSTALL/grub/$GRUBARCH-efi"

        cat > "$GRUBINSTALL/grub/grub.cfg" <<-EOF
		set timeout=0
		
		insmod efi_gop
		$(test "$GRUBARCH" = "x86_64" && echo "insmod efi_uga")
		
		menuentry "TinyLinux" {
		    insmod linux
		    linux /tiny/kernel quiet
		    initrd /tiny/initrd
		}
		EOF

        if [[ "$USEGRUB" != "1" ]]; then
            cd grub
            rm -f /grub.zip
            zip -9 -r -q /grub.zip *
            cd - >/dev/null
            rm -rf grub
        fi
    fi

    local COMMANDSFILE
    COMMANDSFILE="$BUILDSCRIPTS/profiles/$PROFILE/commands"
    [[ ! -f $COMMANDSFILE ]] || cp "$COMMANDSFILE" "$INSTALL/tiny/commands"

    cp "$BUILDSCRIPTS"/README.md "$INSTALL"/README
}

compile_driver()
{
    local DIR
    DIR="$1"

    local MAKEOPTS
    [[ $JOBS ]] && MAKEOPTS="-j$JOBS"

    cd "$DIR"
    make -C /usr/src/linux M="$DIR" $MAKEOPTS modules
    make -C /usr/src/linux M="$DIR" $MAKEOPTS modules_install
    cd - > /dev/null
}

install_mods()
{
    [[ $TEGRABUILD ]] && return 0

    local TMPMODS
    local DRVPKG

    # Skip if there is no driver package
    DRVPKG="$BUILDSCRIPTS/mods/driver.tgz"
    [[ -f $DRVPKG ]] || return 0

    # Install MODS kernel driver
    if [ ! -f /lib/modules/*/extra/mods.ko ]; then
        TMPMODS=/tmp/mods
        rm -rf "$TMPMODS"
        boldecho "Installing MODS kernel driver"
        mkdir "$TMPMODS"
        tar xzf "$DRVPKG" -C "$TMPMODS"
        [[ ! -f $BUILDSCRIPTS/mods.tgz ]] || tar xzf "$TMPMODS"/driver.tgz -C "$TMPMODS"
        compile_driver "$TMPMODS"/driver
        rm -rf "$TMPMODS"

        # Force regeneration of squashfs
        rm -f "$INSTALL/$SQUASHFS"
    fi
}

install_into()
{
    local DEST
    [[ $# -ge 2 ]] || die "Invalid use of install_into in custom script in profile $PROFILE"
    if echo "$1" | grep -q "^/"; then
        DEST="${NEWROOT}$1"
    else
        DEST="$INSTALL/$1"
    fi
    mkdir -p "$DEST"
    shift
    while [[ $# -gt 0 ]]; do
        cp "$BUILDSCRIPTS/profiles/$PROFILE/$1" "$DEST"
        shift
    done
}

install_config()
{
    local DEST="/mnt/etc/$1"
    mkdir -p "$DEST"
    shift
    while [[ $# -gt 0 ]]; do
        cp "$BUILDSCRIPTS/profiles/$PROFILE/$1" "$DEST"
        shift
    done
}

remove_syslinux()
{
    rm -f "$INSTALL/syslinux.exe"
    rm -rf "$INSTALL/syslinux"
}

install_grub_exe()
{
    cp "$BUILDSCRIPTS/grub.exe" "$INSTALL/tiny"/
}

install_extra_packages()
{
    local CUSTOMSCRIPT

    # Skip if extra packages have already been installed
    [[ -f /var/lib/misc/extra ]] && return 0

    # Remove old config
    rm -rf /mnt/etc

    # Proceed only if the current profile supports extra packages
    CUSTOMSCRIPT="$BUILDSCRIPTS/profiles/$PROFILE/custom"
    if [[ -f $CUSTOMSCRIPT ]]; then
        boldecho "Installing packages for profile $PROFILE"
        source "$CUSTOMSCRIPT"

        # Force regeneration of squashfs
        rm -f "$INSTALL/$SQUASHFS"
    fi

    # Indicate that extra packages have been installed
    # by setting profile name
    mkdir -p /var/lib/misc
    echo "$PROFILE" > /var/lib/misc/extra
}

pack_config()
{
    [[ -z $TEGRABUILD ]] || return 0

    local CONFIG_FILE="$INSTALL/tiny/config.new"

    dd if=/dev/zero of="$CONFIG_FILE" bs=1K count=512
    local ETCDEV=$(losetup --show -f "$CONFIG_FILE")
    mke2fs -L etc -b 1024 -i 1024 -j "$ETCDEV"
    losetup -d "$ETCDEV"

    local MNT="$(mktemp -d -t etc.XXXXXX)"
    mount -o loop "$CONFIG_FILE" $MNT
    mkdir "$MNT"/{etc,work}
    [[ -d /mnt/etc ]] && cp -a /mnt/etc/* $MNT/etc/
    umount $MNT
    rmdir $MNT
}

get_mods_driver_version()
{
    rm -rf /tmp/driver
    tar xzf "$BUILDSCRIPTS/mods/driver.tgz" -C /tmp/
    local MAJOR
    local MINOR
    MAJOR=`grep "define MODS_DRIVER_VERSION_MAJOR" /tmp/driver/mods.h | cut -f 3 -d ' '`
    MINOR=`grep "define MODS_DRIVER_VERSION_MINOR" /tmp/driver/mods.h | cut -f 3 -d ' '`
    rm -rf /tmp/driver
    printf "%d.%02d" "$MAJOR" "$MINOR"
}

restore_newroot()
{
    rm "$NEWROOT/lib"
    rm "$NEWROOT/usr/lib"
    mv "$NEWROOT/saved/usr_lib" "$NEWROOT/usr/lib"
    ln -s usr/lib "$NEWROOT/lib"
    local DIR
    for DIR in python-exec python${PYTHON_VER}; do
        [[ -d "$NEWROOT/usr/lib64/$DIR" ]] && mv "$NEWROOT/usr/lib64/$DIR" "$NEWROOT/usr/lib/$DIR"
    done
    rmdir "$NEWROOT"/saved
}

make_squashfs()
{
    local MSQJOBS
    local EXCLUDE

    # Skip if squashfs already exists or if kernel hasn't been rebuilt
    [[ ! -f $INSTALL/$SQUASHFS || $REBUILDSQUASHFS = 1 || $REBUILDKERNEL = 1 ]] || return 0

    # Install kernel modules and firmware
    boldecho "Copying kernel modules"
    local NEWROOT_LIB="$NEWROOT/lib64"
    rm -rf "$NEWROOT_LIB"/{modules,firmware}
    if [[ -z $TEGRABUILD ]]; then
        tar cp -C /lib modules | tar xp -C "$NEWROOT_LIB"/
        ln -s /var/firmware "$NEWROOT_LIB"/firmware
    fi

    boldecho "Preparing squashfs"

    # Skip any outstanding Gentoo changes
    yes | ROOT="$NEWROOT" etc-update --automode -7

    # Create directory for installable libraries
    if [[ $TEGRABUILD ]]; then
        mkdir -p "$INSTALL/tiny/lib"
    fi

    # Make the modules and firmware replaceable on Tegra
    if [[ $TEGRABUILD ]]; then
        rm -rf "$NEWROOT_LIB"/{modules,firmware}
        mkdir -p "$INSTALL/tiny/modules"
        mkdir -p "$INSTALL/tiny/firmware"
        mkdir -p "$INSTALL/tiny/debug"
        mkdir -p "$INSTALL/tiny/valgrind"
        ln -s /tiny/modules  "$NEWROOT_LIB/modules"
        ln -s /tiny/firmware "$NEWROOT_LIB/firmware"
    fi

    # Emit version information
    (
        echo "TinyLinux version $VERSION"
        echo "Profile $PROFILE"
        echo "Built with "`find /var/db/pkg/sys-devel/ -maxdepth 1 -name gcc-[0-9]* | sed "s/.*\/var\/db\/pkg\/sys-devel\///"`
        echo ""
        echo "Installed packages:"
        [[ $TEGRABUILD ]] || echo "MODS kernel driver `get_mods_driver_version`"
        [[ $TEGRABUILD ]] || find /var/db/pkg/sys-kernel/ -maxdepth 1 -name gentoo-sources-* -o -name git-sources-* | sed "s/.*\/var\/db\/pkg\///"
        find "$NEWROOT"/var/db/pkg/ -mindepth 2 -maxdepth 2 | sed "s/.*\/var\/db\/pkg\///" | sort
    ) > "$NEWROOT/etc/release"

    # Copy release notes
    cp "$BUILDSCRIPTS"/{release-notes,LICENSE} "$NEWROOT"/etc/

    # Prepare lib dirs
    # Unfortunately we can't just have a symlink lib -> lib64 in newroot,
    # because emerge will fail complaining about 17.1 profile requirements
    # not being satisified, because Gentoo now requires lib directory
    # to contain 32-bit libs and lib64 64-bit libs.  This is not really
    # true, stuff like python-exec is kept in /usr/lib for some reason.
    # We have no choice than to workaround, so that on the next run
    # emerge can still work correctly.
    trap restore_newroot EXIT
    rm -rf "$NEWROOT/saved"
    local DIR
    for DIR in python-exec python${PYTHON_VER}; do
        [[ -d $NEWROOT/usr/lib/$DIR ]] && mv "$NEWROOT/usr/lib/$DIR" "$NEWROOT/usr/lib64/$DIR"
    done
    mkdir "$NEWROOT/saved"
    mv "$NEWROOT/usr/lib" "$NEWROOT/saved/usr_lib"
    ln -s lib64 "$NEWROOT/usr/lib"
    test -h "$NEWROOT/lib" || die "$NEWROOT/lib is not a symlink!"
    rm "$NEWROOT/lib"
    ln -s usr/lib64 "$NEWROOT/lib"

    # Make squashfs
    boldecho "Compressing squashfs"
    MSQJOBS="1"
    [[ $JOBS ]] && MSQJOBS="$JOBS"
    cat >/tmp/excludelist <<-EOF
	etc/dbus-1
	etc/env.d
	etc/environment.d
	etc/portage
	etc/systemd
	lib*/systemd
	lib*/udev
	mnt
	run
	saved
	tmp
	usr/aarch64-unknown-linux-gnu
	usr/lib*/*.a
	usr/lib*/*.o
	usr/lib*/pkgconfig
	usr/lib*/systemd
	usr/lib*/valgrind/*.a
	usr/share/aclocal
	usr/share/doc
	usr/share/et
	usr/share/glib-2.0
	usr/share/gtk-doc
	usr/share/i18n
	usr/share/info
	usr/share/locale/*
	usr/share/man
	usr/share/sounds
	usr/share/ss
	usr/share/X11
	usr/share/zsh
	var
	EOF
    find "$NEWROOT"/usr/include/ -mindepth 1 -maxdepth 1 | sed "s/^\/newroot\/// ; /^usr\/include\/python/d" >> /tmp/excludelist
    [[ $TEGRABUILD ]] && echo "etc" >> /tmp/excludelist
    mksquashfs "$NEWROOT"/ "$INSTALL/$SQUASHFS" -noappend -processors "$MSQJOBS" -comp xz -ef /tmp/excludelist -wildcards

    # Compress distfiles for future use
    if [[ ! -f /$DISTFILESPKG ]] || \
            find /var/cache/distfiles -type f -newer "/$DISTFILESPKG" | grep -q . || \
            find "/usr/$TEGRAABI/cache/binpkgs"/ -type f -newer "/$DISTFILESPKG" 2>/dev/null | grep -q . || \
            find /var/cache/binpkgs -type f -newer "/$DISTFILESPKG" | grep -q .; then
        boldecho "Compressing distfiles"
        local DIRS=( /var/cache/distfiles /var/cache/binpkgs)
        [[ -d /usr/$TEGRAABI/cache/binpkgs ]] && DIRS+=( "/usr/$TEGRAABI/cache/binpkgs" )
        tar_bz2 -cf "$DISTFILESPKG" "${DIRS[@]}"
    fi
}

compile_busybox()
{
    local FINALEXEC
    local BUSYBOX
    local BUSYBOX_PKG
    local BUILDDIR
    local MAKEOPTS

    [[ $JOBS ]] && MAKEOPTS="-j$JOBS"

    # Only for Tegra
    [[ $TEGRABUILD ]] || return 0

    # Skip if already built
    FINALEXEC="$NEWROOT/tmp/busybox"
    [[ -f $FINALEXEC ]] && return 0

    boldecho "Compiling busybox"

    BUSYBOX=`ls -d "$NEWROOT"/var/db/pkg/sys-apps/busybox-*`
    BUSYBOX=`basename "$BUSYBOX"`
    BUSYBOX=${BUSYBOX%-r[0-9]}

    # Find package
    BUSYBOX_PKG="/var/cache/distfiles/$BUSYBOX.tar.bz2"
    if [[ ! -f $BUSYBOX_PKG ]]; then
        echo "Busybox package $BUSYBOX_PKG not found!"
        exit 1
    fi

    # Create build directory
    BUILDDIR="/tmp/busyboxbuild"
    rm -rf "$BUILDDIR"
    mkdir -p "$BUILDDIR"

    # Prepare busybox source
    tar_bz2 -xf "$BUSYBOX_PKG" -C "$BUILDDIR"
    cp "$BUILDSCRIPTS/tegra/busybox-config" "$BUILDDIR/$BUSYBOX"/.config

    # Compile busybox
    (
        cd "$BUILDDIR/$BUSYBOX"
        yes '' 2>/dev/null | make oldconfig > /var/log/busybox.make.log
        make $MAKEOPTS >> /var/log/busybox.make.log
    )
    cp "$BUILDDIR/$BUSYBOX/busybox" "$FINALEXEC"

    rm -rf "$BUILDDIR"
}

make_tegra_image()
{
    [[ $TEGRABUILD ]] || return 0

    boldecho "Creating Tegra filesystem image"

    # Delete stale image files
    rm -f "initrd"
    rm -f package.tar.bz2

    # Create output directory
    local OUTDIR=/aarch64
    rm -rf "$OUTDIR"
    mkdir "$OUTDIR"
     
    # Create directory where the image is assembled
    local PACKAGE="/mnt/root"
    local FILESYSTEM="$PACKAGE/filesystem"
    rm -rf "$PACKAGE"
    mkdir -p "$FILESYSTEM"

    # Copy files
    ( cd "$INSTALL" && tar cp * ) | tar xp -C "$FILESYSTEM"

    # Copy etc
    ( cd "$NEWROOT" && tar cp etc ) | tar xp -C "$FILESYSTEM"
    rm -rf "$FILESYSTEM/etc"/{env.d,environment.d,portage,profile.env,systemd}

    # Create directories
    for DIR in dev proc root sys tmp var var/tmp var/log mnt mnt/squash; do
        mkdir "$FILESYSTEM/$DIR"
    done
    chmod 1777 "$FILESYSTEM/tmp" "$FILESYSTEM/var/tmp"
    chmod 755 "$FILESYSTEM/var/log"

    # Create login log
    touch "$FILESYSTEM/var/log/wtmp"

    # Create basic device files
    mknod "$FILESYSTEM/dev/null"    c 1 3
    mknod "$FILESYSTEM/dev/console" c 5 1
    mknod "$FILESYSTEM/dev/tty1"    c 4 1
    mknod "$FILESYSTEM/dev/loop0"   b 7 0
    chmod 660 "$FILESYSTEM/dev/null"
    chmod 660 "$FILESYSTEM/dev/console"
    chmod 600 "$FILESYSTEM/dev/tty1"
    chmod 660 "$FILESYSTEM/dev/loop0"

    # Create symlinks
    ln -s mnt/squash/usr/bin   "$FILESYSTEM/bin"
    ln -s mnt/squash/usr/bin   "$FILESYSTEM/sbin"
    ln -s mnt/squash/usr/lib64 "$FILESYSTEM/lib"
    ln -s mnt/squash/usr/lib64 "$FILESYSTEM/lib64"
    ln -s mnt/squash/usr       "$FILESYSTEM/usr"

    # Create symlink to /sys/kernel/debug
    ln -s sys/kernel/debug "$FILESYSTEM/d"

    # Ensure the lib/firmware/modules directories are empty
    rm -rf "$FILESYSTEM"/tiny/lib/* "$FILESYSTEM"/tiny/firmware/* "$FILESYSTEM"/tiny/modules/*

    # Copy files for simulation
    mkdir -p "$PACKAGE"/simrd
    cp "$NEWROOT"/tmp/busybox "$PACKAGE"/simrd/
    cp "$BUILDSCRIPTS"/tegra/linuxrc-sim "$PACKAGE"/simrd/linuxrc

    # Package filesystem image
    ( cd "$PACKAGE" && tar_bz2 -cpf "$OUTDIR/package.tar.bz2" * )
    rm -rf "$PACKAGE"
    unset PACKAGE

    # Clean up debug directory - leave only files we need
    local DEBUG_FILES=(
        ld-linux-aarch64.so*.debug
        libc.so*.debug
        libdl.so*.debug
        libm.so*.debug
        libpthread.so*.debug
        librt.so*.debug
    )
    rm -rf /tiny/debug.del
    mv /tiny/debug /tiny/debug.del
    mkdir -p /tiny/debug/lib64
    if [ -e /tiny/debug.del/lib64 ]; then
        local DEBUG_FILE
        for DEBUG_FILE in "${DEBUG_FILES[@]}"; do
            DEBUG_FILE=`find /tiny/debug.del/lib64/ -name "$DEBUG_FILE"`
            [[ -z $DEBUG_FILE ]] || mv "$DEBUG_FILE" "${DEBUG_FILE/debug.del/debug}"
        done
    fi
    echo "Deleting files:" ; find /tiny/debug.del -type f
    rm -rf /tiny/debug.del
    mkdir -p /tiny/debug/mnt
    ln -s .. /tiny/debug/mnt/squash
    ln -s lib64 /tiny/debug/lib

    # Package optional directories
    ( cd /tiny && tar_bz2 -cpf "$OUTDIR/debug.tar.bz2"    debug    )
    ( cd /tiny && tar_bz2 -cpf "$OUTDIR/valgrind.tar.bz2" valgrind )
    ( cd "$NEWROOT" && tar_bz2 -cpf "$OUTDIR/lib.tar.bz2" --exclude=mdev --exclude=firmware --exclude=modules --exclude=libnv*so usr/lib64 )

    # Create initial ramdisk
    local INITRD
    INITRD="/mnt/initrd"
    mkdir -p "$INITRD/tiny"
    cp -p "$NEWROOT/tmp/busybox" "$INITRD/tiny"/
    cp "$BUILDSCRIPTS/tegra/linuxrc-silicon" "$INITRD/init"
    chmod 755 "$INITRD/init"
    mkdir "$INITRD/dev"
    mkdir "$INITRD/proc"
    mknod "$INITRD/dev/null"    c 1 3
    mknod "$INITRD/dev/console" c 5 1
    chmod 660 "$INITRD/dev/null"
    chmod 660 "$INITRD/dev/console"
    mkdir "$INITRD/etc"
    ln -s /proc/mounts "$INITRD/etc/mtab"
    ( cd "$INITRD" && find . | cpio --create --format=newc ) > "$OUTDIR/initrd"
    rm -rf "$INITRD"
    unset INITRD

    # Copy release notes
    cp "$NEWROOT/etc/release" "$OUTDIR"/

    boldecho "Files ready in ${BUILDROOT}${OUTDIR}"
}

compress_final_package()
{
    [[ $TEGRABUILD ]] && return 0

    local SRCDIR
    local SAVEDSYSLINUXCFG

    boldecho "Compressing final package"

    SRCDIR="$INSTALL"
    [[ -f $INSTALL/tiny/grub.exe ]] && SRCDIR="$INSTALL/tiny"
    rm -f "/$FINALPACKAGE"
    if [[ $TINYDIR ]]; then
        mv "$INSTALL/tiny" "$INSTALL/$TINYDIR"
        if [[ -f $INSTALL/syslinux/syslinux.cfg ]]; then
            SAVEDSYSLINUXCFG=`cat "$INSTALL/syslinux/syslinux.cfg"`
            echo "default /$TINYDIR/kernel initrd=/$TINYDIR/initrd squash=$TINYDIR/squash.bin quiet" > "$INSTALL/syslinux/syslinux.cfg"
        fi
    fi
    ( cd "$SRCDIR" && zip -9 -r -q "/$FINALPACKAGE" * )
    if [[ $TINYDIR ]]; then
        [[ -f $INSTALL/syslinux/syslinux.cfg ]] && echo "$SAVEDSYSLINUXCFG" > "$INSTALL/syslinux/syslinux.cfg"
        mv "$INSTALL/$TINYDIR" "$INSTALL/tiny"
    fi
    boldecho "${BUILDROOT}/$FINALPACKAGE is ready"
}

deploy()
{
    [[ $TEGRABUILD ]] && return 0
    [[ $DEPLOY     ]] || return 0

    boldecho "Installing TinyLinux on $DEPLOY"
    [ -b "$DEPLOY" ] || die "Block device $DEPLOY not found"
    echo
    fdisk -l "$DEPLOY"
    echo
    echo "Install? [y|n]"
    local CHOICE
    read CHOICE
    if [[ $CHOICE != y ]]; then
        echo "Installation skipped"
        return 0
    fi

    mkfs.vfat -I -n TinyLinux "$DEPLOY"
    sync
    local UEVENT
    ls /sys/bus/{pci,usb}/devices/*/uevent | while read UEVENT; do
        echo add > "$UEVENT"
    done
    sync
    sleep 1

    local DESTDIR
    DESTDIR=`mktemp -d`
    mount "$DEPLOY" "$DESTDIR"
    unzip -q "/$FINALPACKAGE" -d "$DESTDIR"
    sync
    syslinux "$DEPLOY"
    sync
    umount "$DESTDIR"
    rmdir "$DESTDIR"
}

# Check privileges
[[ `id -u` -eq 0 ]] || die "This script must be run with root privileges"

download_packages           # Download stage3/portage.
unpack_packages             # Unpack stage3/portage into buildroot.
copy_scripts                # Copy build_tiny_linux.sh and optionally other scripts into buildroot/buidscripts.
run_in_chroot               # chroot into buildroot (Gentoo image).
source /etc/profile         # Update environment of the root user.
check_env                   # Sanity check.
prepare_portage             # Configure portage (make.conf, use flags, keywords, unmask packages, etc.).
run_interactive             # [Optional] Enter interactive mode if -i was specified.
emerge_basic_packages       # Build additional packages in buildroot.
compile_kernel              # Compile kernel. Can be forced with -k.
build_newroot               # Build newroot, which is the actual TinyLinux. Can be forced with -r.
prepare_installation        # Prepare /buildroot/install directory. Copy kernel, etc.
install_mods                # Install MODS kernel driver.
install_extra_packages      # Install additional profile-specific packages. Runs the custom script.
pack_config                 # Create persistent configuration file
make_squashfs               # Create squashfs.bin from newroot. Can be forced with -q.
compile_busybox             # [Tegra only] Compile busybox for startup.
make_tegra_image            # [Tegra only] Create initial ramdisk for Tegra.
compress_final_package      # [Not for Tegra] Build the zip package.
deploy                      # [Not for Tegra] Install on a USB stick
