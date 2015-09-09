#!/bin/bash

# Copyright (c) 2009-2015, NVIDIA CORPORATION.  All rights reserved.
# See LICENSE file for details.

set -e

MIRROR="http://gentoo.cites.uiuc.edu/pub/gentoo/"
PORTAGEPKG="portage-latest.tar.bz2"
STAGE3ARCH="amd64"
DISTFILESPKG="distfiles.tar.bz2"
BUILDROOT="buildroot"
BUILDSCRIPTS="/buildscripts"
NEWROOT="/newroot"
INSTALL="/install"
SQUASHFS="/tiny/squash.bin"
MAKECONF="/etc/portage/make.conf"
NICE="ionice -c 3 nice -n 19"

# Inherit TEGRAABI from parent process
TEGRAABI="${TEGRAABI:-aarch64-unknown-linux-gnu}"
TEGRAABI32="armv7a-softfp-linux-gnueabi"

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
    echo "  -v VER  Put specified version name in the README file"
    echo "  -r      Rebuild entire target filesystem"
    echo "  -i      Run interactive shell within the build environment"
    echo "  -k      Force rebuilding the kernel"
    echo "  -q      Force recompressing squashfs"
    echo "  -m      Launch kernel menuconfig before compiling the kernel"
    echo "  -d DEV  Deploy installation to device (e.g. /dev/sdx)"
    exit
fi

# Auto-detect number of CPUs
JOBS="${JOBS:-$(grep processor /proc/cpuinfo | wc -l)}"

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
                      arm|armv7) TEGRAABI="$TEGRAABI32" ;;
                      armv8|arm64|aarch64|amd64|x86_64) ;;
                      *) die "Unrecognized arch - $ARCH" ;;
                  esac
                  ;;
        --rc-kernel) RCKERNEL=1 ;;
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
STAGE3PKG="${STAGE3PKG:-$(find ./ -maxdepth 1 -name stage3-$STAGE3ARCH-*.tar.bz2 | head -n 1)}"

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
    curl -O "$URL"
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

    FILELIST=`curl "$URL" | sed "$PARSEFILELIST"`
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
        GREPSTAGE="^stage3-$STAGE3ARCH-[0-9].*\.tar\.bz2$"
        boldecho "Downloading stage3 file list from the server"
        STAGE3PATH="$MIRROR/releases/${STAGE3ARCH/i?86/x86}/autobuilds/current-stage3-$STAGE3ARCH/"
        STAGE3PKG=`find_stage3 "$GREPSTAGE" "$STAGE3PATH"`
        download "$STAGE3PKG"
        STAGE3PKG=`basename "$STAGE3PKG"`
    fi
}

tar_bz2()
{
    if which lbzip2 >/dev/null 2>&1; then
        $NICE tar -I lbzip2 "$@"
    else
        $NICE tar -j "$@"
    fi
}

unpack_packages()
{
    local SCRIPTSDIR

    # Don't do anything if we are inside the host tree already
    [[ -d ./$BUILDSCRIPTS ]] && return 0

    # Don't do anything if the host tree already exists
    [[ -d $BUILDROOT ]] && return 0

    # Unpack the root
    boldecho "Unpacking stage3 package"
    mkdir "$BUILDROOT"
    tar_bz2 -xpf "$STAGE3PKG" -C "$BUILDROOT"

    # Unpack portage tree
    boldecho "Unpacking portage tree"
    tar_bz2 -xpf "$PORTAGEPKG" -C "$BUILDROOT/usr"

    # Unpack distfiles if available
    if [[ -f $DISTFILESPKG ]]; then
        boldecho "Unpacking distfiles"
        tar_bz2 -xpf "$DISTFILESPKG" -C "$BUILDROOT/usr/portage"
    fi
}

copy_scripts()
{
    # Don't do anything if we are inside the host tree already
    [[ -d ./$BUILDSCRIPTS ]] && return 0

    # Delete stale build scripts
    rm -rf "$BUILDROOT/$BUILDSCRIPTS"

    boldecho "Copying scripts to build environment"

    # Check access to the scripts
    SCRIPTSDIR=`dirname $0`
    [[ -f $SCRIPTSDIR/scripts/etc/inittab ]] || die "TinyLinux scripts are not available"
    [[ -d $SCRIPTSDIR/profiles/$PROFILE   ]] || die "Selected profile $PROFILE is not available"

    # Copy TinyLinux scripts
    mkdir -p "$BUILDROOT/$BUILDSCRIPTS"
    find "$SCRIPTSDIR"/ -maxdepth 1 -type f -exec cp '{}' "$BUILDROOT/$BUILDSCRIPTS" \;
    cp -r "$SCRIPTSDIR"/profiles "$BUILDROOT/$BUILDSCRIPTS"
    cp -r "$SCRIPTSDIR"/mods     "$BUILDROOT/$BUILDSCRIPTS"
    cp -r "$SCRIPTSDIR"/scripts  "$BUILDROOT/$BUILDSCRIPTS"
    cp -r "$SCRIPTSDIR"/extra    "$BUILDROOT/$BUILDSCRIPTS"
    [[ -z $TEGRABUILD ]] || cp -r "$SCRIPTSDIR"/tegra "$BUILDROOT/$BUILDSCRIPTS"
}

exit_chroot()
{
    sleep 1
    sync
    umount -l "$BUILDROOT"/{sys,run/shm,dev/pts,dev,proc} || boldecho "Unmount failed!"
}

run_in_chroot()
{
    local LINUX32

    # Don't do anything if we are inside the host tree already
    [[ -d ./$BUILDSCRIPTS ]] && return 0

    boldecho "Entering build environment"

    cp "$0" "$BUILDROOT/$BUILDSCRIPTS"/
    cp /etc/resolv.conf "$BUILDROOT/etc"/
    mount -t proc none "$BUILDROOT/proc"
    trap exit_chroot EXIT
    mount --bind /dev "$BUILDROOT/dev"
    mount --bind /dev/pts "$BUILDROOT/dev/pts"
    mount -t sysfs none "$BUILDROOT/sys"
    mkdir -p "$BUILDROOT/run/shm"
    mount -t tmpfs -o mode=1777,nodev none "$BUILDROOT/run/shm"

    LINUX32=""
    [[ `uname -m` = "x86_64" && ${STAGE3ARCH/i?86/x86} = "x86" ]] && LINUX32="linux32"

    $NICE $LINUX32 chroot "$BUILDROOT" "$BUILDSCRIPTS/`basename $0`" "$PROFILE"

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
    eselect news read > /dev/null
}

prepare_portage()
{
    sed -i -e "/^MAKEOPTS/d ; /^PORTAGE_NICENESS/d ; /^USE/d" "$MAKECONF"

    (
        [[ $JOBS ]] && echo "MAKEOPTS=\"-j$JOBS\""
        echo "PORTAGE_NICENESS=\"15\""
        echo "USE=\"-* ipv6 syslog python_targets_python2_7\""
    ) >> "$MAKECONF"

    local KEYWORDS="/etc/portage/package.keywords/tinylinux"
    mkdir -p /etc/portage/package.keywords
    mkdir -p /etc/portage/package.use
    mkdir -p /etc/portage/package.mask
    if [[ ! -f $KEYWORDS ]]; then
        (
            echo "sys-kernel/gentoo-sources ~*"
            echo "sys-kernel/git-sources ~*"
            echo "net-misc/r8168 ~*"
            echo "net-misc/ipsvd ~*"
            echo "=sys-devel/crossdev-20141030 ~*"
            echo "=dev-lang/perl-5.16.3 ~*"
            echo "=sys-devel/patch-2.7.1-r3 ~*"
            echo "=sys-boot/syslinux-6.03 ~*"
            echo "=sys-boot/gnu-efi-3.0u ~*"
        ) > $KEYWORDS
    fi
    echo "sys-fs/squashfs-tools xz" >> /etc/portage/package.use/tinylinux
    echo "app-arch/xz-utils threads" >> /etc/portage/package.use/tinylinux
    echo "sys-apps/hwids net pci usb" >> /etc/portage/package.use/tinylinux

    # Broken nano dependency
    echo "=app-editors/nano-2.3.3" >> /etc/portage/package.mask/tinylinux

    # Enable the latest iasl tool
    echo "sys-power/iasl ~*" >> $KEYWORDS

    # Mask newer busybox due to problems with less
    echo ">sys-apps/busybox-1.21.0" >> /etc/portage/package.mask/tinylinux

    # Broken strace build
    echo "=dev-util/strace-4.10" >> /etc/portage/package.mask/tegra

    # Enable some packages on 64-bit ARM (temporary, until enabled in Gentoo)
    if [[ $TEGRABUILD ]]; then
        mkdir -p /etc/portage/package.accept_keywords
        local PKG
        for PKG in sys-apps/busybox-1.21.0 \
                   dev-libs/libtommath-0.42.0-r1 \
                   net-fs/autofs-5.0.8-r1 \
                   net-nds/ypbind-1.37.2 \
                   net-nds/yp-tools-2.12-r1 \
                   net-nds/portmap-6.0 \
                   net-dialup/lrzsz-0.12.20-r3 \
                   dev-util/valgrind-3.10.1 \
                   cross-aarch64-unknown-linux-gnu/gcc-4.9.2 \
                   ; do
            echo "=${PKG} **" >> /etc/portage/package.accept_keywords/tegra
        done

        # binutils-2.24 is needed for arm64 to avoid ld.so crash
        echo "=cross-aarch64-unknown-linux-gnu/binutils-2.24* ~*" >> $KEYWORDS

        # Stick to the kernel we're officially using
        local KERNELVER="3.10"
        echo ">=cross-aarch64-unknown-linux-gnu/linux-headers-$KERNELVER" >> /etc/portage/package.mask/tegra
        echo ">=cross-armv7a-softfp-linux-gnueabi/linux-headers-$KERNELVER" >> /etc/portage/package.mask/tegra
    fi

    # Lock on to dropbear version which we have a fix for
    echo "=net-misc/dropbear-2013.62 ~*" >> $KEYWORDS
    echo ">net-misc/dropbear-2013.62" >> /etc/portage/package.mask/tinylinux

    # Fix valgrind build
    local EBUILD=/usr/portage/dev-util/valgrind/valgrind-3.10.1.ebuild
    if [[ -f $EBUILD && $TEGRABUILD ]] && ! grep -q "valgrind-arm64.patch" "$EBUILD"; then
        boldecho "Patching $EBUILD"
        cp "$BUILDSCRIPTS/tegra/valgrind-arm64.patch" /usr/portage/dev-util/valgrind/files/
        sed -i "/epatch.*glibc/ a\
epatch \"\${FILESDIR}\"/valgrind-arm64.patch" "$EBUILD"
        ebuild "$EBUILD" digest
    fi

    # Install dropbear patch for pubkey authentication
    local EBUILD=/usr/portage/net-misc/dropbear/dropbear-2013.62.ebuild
    if [[ -f $EBUILD ]] && ! grep -q "pubkey\.patch" "$EBUILD"; then
        boldecho "Patching $EBUILD"
        cp "$BUILDSCRIPTS/dropbear-pubkey.patch" /usr/portage/net-misc/dropbear/files/
        sed -i "0,/epatch/ s//epatch \"\${FILESDIR}\"\/\${PN}-pubkey.patch\nepatch/" "$EBUILD"
        ebuild "$EBUILD" digest
    fi

    # Install r8168 patch for kernel 3.16
    local EBUILD=/usr/portage/net-misc/r8168/r8168-8.038.00.ebuild
    if [[ -f $EBUILD ]] && ! grep -q "ethtool-ops" "$EBUILD"; then
        boldecho "Patching $EBUILD"
        mkdir -p /usr/portage/net-misc/r8168/files
        cp "$BUILDSCRIPTS/extra/r8168-8.038.00-ethtool-ops.patch" /usr/portage/net-misc/r8168/files/
        echo -e "src_prepare() {\n\tepatch \"\${FILESDIR}/\${P}-ethtool-ops.patch\"\n}" >> "$EBUILD"
        ebuild "$EBUILD" digest
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
    # Skip if the packages were already installed
    [ ! -e /usr/src/linux ] || return 0

    boldecho "Compiling basic host packages"

    if ! emerge --quiet squashfs-tools zip pkgconfig dropbear dosfstools reiserfsprogs genkernel bc less libtirpc rpcbind; then
        boldecho "Failed to emerge some packages"
        boldecho "Please complete installation manually"
        bash
    fi
    local KERNELPKG=gentoo-sources
    [[ $RCKERNEL = 1 ]] && KERNELPKG=git-sources
    if [[ -z $TEGRABUILD ]] && ! emerge --quiet $KERNELPKG syslinux; then
        boldecho "Failed to emerge some packages"
        boldecho "Please complete installation manually"
        bash
    fi
}

istegra64()
{
    [[ $TEGRABUILD ]] || return 1
    [[ ${TEGRAABI%%-*} = "aarch64" ]]
}

install_tegra_toolchain()
{
    [[ $TEGRABUILD ]] || return 0

    # Skip if the toolchains already exist
    local INDICATOR="/var/db/$TEGRAABI"
    [[ ! -f $INDICATOR ]] || return 0

    boldecho "Building Tegra toolchain - $TEGRAABI"

    # Build tools needed by the cross toolchain
    if ! emerge --quiet --usepkg --buildpkg crossdev; then
        boldecho "Failed to emerge some packages"
        boldecho "Please complete installation manually"
        bash
    fi

    # Hack for gcc or crossdev bug
    grep -q "USE.*cxx" "$MAKECONF" || sed -i "/USE/s/\"$/ cxx\"/" "$MAKECONF"

    # Hack for crossdev awk script bug
    sed -i "/cross_init$/ s:cross_init:MAIN_REPO_PATH=/usr/portage ; cross_init:" /usr/bin/emerge-wrapper

    # Build cross toolchain
    grep -q "PORTDIR_OVERLAY" "$MAKECONF" || echo "PORTDIR_OVERLAY=\"/usr/local/portage\"" >> "$MAKECONF"
    sed -i "s/ -march=i.86//" "$MAKECONF"
    mkdir -p "/usr/local/portage"
    crossdev -S "$TEGRAABI"
    emerge-wrapper --target "TEGRAABI" --init

    # Install portage configuration
    local CFGROOT="/usr/$TEGRAABI"
    local PORTAGECFG="$CFGROOT/etc/portage"
    (
        [[ $JOBS ]] && echo "MAKEOPTS=\"-j$JOBS\""
        echo "PORTAGE_NICENESS=\"15\""
        echo "USE=\"-* ipv6 syslog \${ARCH}\""
    ) >> "$CFGROOT/$MAKECONF"
    for FILE in package.use package.keywords package.mask package.accept_keywords savedconfig; do
        rm -f "$PORTAGECFG/$FILE"
        ln -s "/etc/portage/$FILE" "$PORTAGECFG/$FILE"
    done
    [ -e "$CFGROOT/tmp" ] || ln -s /tmp "$CFGROOT/tmp"
    rm -f "$PORTAGECFG/make.profile"
    local PROFILE_ARCH=arm
    istegra64 && PROFILE_ARCH=arm64
    local PROFILE=13.0
    ln -s "/usr/portage/profiles/default/linux/$PROFILE_ARCH/$PROFILE" "$PORTAGECFG/make.profile"

    # Fix lib directory (make a symlink to lib64)
    if istegra64 && [[ `ls "$CFGROOT/usr/lib" | wc -l` = 0 ]]; then
        rmdir "$CFGROOT/usr/lib"
        ln -s lib64 "$CFGROOT/usr/lib"
    fi

    # WAR for Cortex-A53 errata 835769
    ! istegra64 || sed -i "/CFLAGS=/s/\"$/ -mfix-cortex-a53-835769\"/" "$CFGROOT/$MAKECONF"

    # Setup split glibc symbols for valgrind and remote debugging
    mkdir -p "$PORTAGECFG/package.env"
    echo "sys-libs/glibc debug.conf"    > "$PORTAGECFG/package.env/glibc"
    echo "dev-util/valgrind debug.conf" > "$PORTAGECFG/package.env/valgrind"
    mkdir -p "$PORTAGECFG/env"
    echo 'CFLAGS="${CFLAGS} -ggdb"'        >  "$PORTAGECFG/env/debug.conf"
    echo 'CXXFLAGS="${CXXFLAGS} -ggdb"'    >> "$PORTAGECFG/env/debug.conf"
    echo 'FEATURES="$FEATURES splitdebug"' >> "$PORTAGECFG/env/debug.conf"

    touch "$INDICATOR"
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
    [ ! -f /boot/kernel-genkernel-* ] || [[ $REBUILDKERNEL = 1 ]] || return 0

    # Delete old kernel
    rm -rf /boot/kernel-genkernel-*
    rm -rf /boot/initramfs-genkernel-*
    rm -f "$INSTALL/tiny/kernel"
    rm -f "$INSTALL/tiny/initrd"

    # Force regeneration of squashfs
    rm -f "$INSTALL/$SQUASHFS"

    # Remove disklabel (blkid) from genkernel configuration
    sed -i "/^DISKLABEL/s/yes/no/" /etc/genkernel.conf

    boldecho "Preparing kernel"
    [[ $JOBS ]] && MAKEOPTS="--makeopts=-j$JOBS"
    rm -rf /lib/modules /lib/firmware
    mkdir /lib/firmware # Due to kernel bug with builtin firmware
    cp "$BUILDSCRIPTS/kernel-config" /usr/src/linux/.config

    if [[ $KERNELMENUCONFIG = 1 ]]; then
        boldecho "Configuring kernel"
        make -C /usr/src/linux menuconfig
    fi

    boldecho "Compiling kernel"
    genkernel --oldconfig --linuxrc="$BUILDSCRIPTS/linuxrc" --no-mountboot "$MAKEOPTS" kernel

    emerge --quiet r8168

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
    genkernel --oldconfig --linuxrc="$BUILDSCRIPTS/linuxrc" --no-mountboot "$MAKEOPTS" --all-ramdisk-modules --busybox-config="$BBCFG" ramdisk
}

target_emerge()
{
    local EMERGE
    if [[ $TEGRABUILD ]]; then
        ROOT="$NEWROOT" "$TEGRAABI-emerge" "$@"
    else
        ROOT="$NEWROOT" emerge "$@"
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

propagate_ncurses()
{
    [[ $TEGRABUILD ]] || return 0

    [[ -e /usr/$TEGRAABI/usr/include/curses.h ]] && return 0

    ( cd "$NEWROOT" && list_package_files "sys-libs/ncurses" | \
        grep "^usr/lib\|^lib\|^usr/include" | grep -v "terminfo" | \
        xargs tar c | tar x -C "/usr/$TEGRAABI/" )
}

install_syslinux()
{
    [[ $TEGRABUILD ]] && return 0

    local DESTDIR
    local SAVEROOT

    DESTDIR="/tmp/syslinux"

    SAVEROOT="$NEWROOT"
    NEWROOT="$DESTDIR" target_emerge --quiet --nodeps --usepkg --buildpkg syslinux
    NEWROOT="$SAVEROOT"

    cp -p "$DESTDIR/sbin/extlinux" "$NEWROOT/sbin/extlinux"
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

    boldecho "Building TinyLinux root filesystem"

    mkdir -p "$NEWROOT"
    mkdir -p "$NEWROOT/var/lib/gentoo/news"

    # Prepare build configuration for Tegra target
    if [[ $TEGRABUILD ]]; then
        mkdir -p "$NEWROOT/etc/portage"
        istegra64 || sed -e "s/^CHOST=.*/CHOST=$TEGRAABI/ ; /^CFLAGS=/s/\"$/ -mcpu=cortex-a9 -mfpu=vfpv3-d16 -mfloat-abi=softfp\"/" <"$MAKECONF"  >"${NEWROOT}${MAKECONF}"
    fi

    # Create symlink to lib64 on Tegra
    if istegra64; then
        mkdir -p "$NEWROOT/usr/lib64"
        ln -s lib64 "$NEWROOT/usr/lib"
    fi

    # Restore busybox config file
    local BUSYBOXCFG="$BUILDSCRIPTS/busybox-1.21.0"
    local HOSTBUSYBOXCFGDIR=/etc/portage/savedconfig/sys-apps
    [[ $TEGRABUILD ]] && HOSTBUSYBOXCFGDIR="/usr/$TEGRAABI/$HOSTBUSYBOXCFGDIR"
    mkdir -p "$HOSTBUSYBOXCFGDIR"
    cp "$BUSYBOXCFG" "$HOSTBUSYBOXCFGDIR"
    local TARGETBUSYBOXCFGDIR="$NEWROOT/etc/portage/savedconfig/sys-apps"
    mkdir -p "$TARGETBUSYBOXCFGDIR"
    cp "$BUSYBOXCFG" "$TARGETBUSYBOXCFGDIR"

    # Setup directories for valgrind and for debug symbols
    local NEWUSRLIB="$NEWROOT/usr/lib"
    istegra64 && NEWUSRLIB="$NEWROOT/usr/lib64"
    rm -rf /tiny/debug /tiny/valgrind
    mkdir -p /tiny/debug/mnt
    mkdir -p /tiny/valgrind
    mkdir -p "$NEWUSRLIB"
    mkdir -p "$NEWROOT/usr/share"
    ln -s /tiny/debug    "$NEWUSRLIB/debug"
    ln -s /tiny/valgrind "$NEWUSRLIB/valgrind"

    # Prepare lib directory for 64-bit builds
    if [[ -z $TEGRABUILD ]]; then
        mkdir -p "$NEWROOT"/lib64
        ln -s lib64 "$NEWROOT"/lib
    fi

    # Install basic system packages
    install_package sys-libs/glibc
    rm -rf "$NEWROOT"/lib/gentoo # Remove Gentoo scripts
    if istegra64 || [[ -z $TEGRABUILD ]]; then
        rm -rf "$NEWROOT"/lib32 # Remove 32-bit glibc in 64-bit builds
    fi
    if istegra64; then
        rm -rf "$NEWROOT/lib"
        ln -s lib64 "$NEWROOT/lib"
    fi
    ROOT="$NEWROOT" eselect news read > /dev/null
    install_package ncurses
    propagate_ncurses
    install_package pciutils
    rm -f "$NEWROOT/usr/share/misc"/*.gz # Remove compressed version of hwids
    install_package busybox "make-symlinks mdev nfs savedconfig"
    rm -f "$NEWROOT"/etc/portage/savedconfig/sys-apps/._cfg* # Avoid excess of portage messages
    install_package dropbear "multicall"

    if [[ -z $TEGRABUILD ]]; then
        install_package efibootmgr
    fi

    # Cross-installation of libtirpc is broken, do it manually
    install_package net-libs/libtirpc
    if [[ $TEGRABUILD ]]; then
        local CFGROOT="/usr/$TEGRAABI"
        local LIB=lib
        istegra64 && LIB=lib64
        local ITEM
        for ITEM in /usr/include/tirpc        \
                    /usr/$LIB/libtirpc.so    \
                    /$LIB/libtirpc.so.1.0.10 \
                    /usr/$LIB/pkgconfig/libtirpc.pc; do
            rm -rf "$CFGROOT/$ITEM"
            cp -r "$NEWROOT/$ITEM" "$CFGROOT/$ITEM"
        done
        rm -f "$CFGROOT/$LIB/libtirpc.so.1"
        ln -s libtirpc.so.1.0.10 "$CFGROOT/$LIB/libtirpc.so.1"
        [ -e /usr/include/tirpc ] || ln -s "$NEWROOT/usr/include/tirpc" /usr/include/tirpc
    fi

    # Install NFS utils
    install_package rpcbind
    install_package nfs-utils "" "--nodeps"
    remove_gentoo_services nfs nfsmount rpcbind rpc.statd

    # Additional x86-specific packages
    if [[ -z $TEGRABUILD ]]; then
        install_package libusb-compat
        install_package numactl
    fi

    # Add symlink to /bin/env in /usr/bin/env where most apps expect it
    [[ -f $NEWROOT/usr/bin/env ]] || [[ ! -f $NEWROOT/bin/env ]] || ln -s /bin/env "$NEWROOT"/usr/bin/env

    # Remove link to busybox's lspci so that lspci from pciutils is used
    rm "$NEWROOT/bin/lspci"

    # Finish installing dropbear
    mkdir "$NEWROOT/etc/dropbear"
    dropbearkey -t dss -f "$NEWROOT/etc/dropbear/dropbear_dss_host_key"
    dropbearkey -t rsa -f "$NEWROOT/etc/dropbear/dropbear_rsa_host_key"
    dropbearkey -t ecdsa -f "$NEWROOT/etc/dropbear/dropbear_ecdsa_host_key"
    ( cd "$NEWROOT/usr/bin" && ln -s dbclient ssh )
    ( cd "$NEWROOT/usr/bin" && ln -s dbscp scp )

    # Copy libgcc needed by bash
    if [[ $TEGRABUILD ]]; then
        local NEWLIB="$NEWROOT/lib"
        istegra64 && NEWLIB="$NEWROOT/lib64"
        cp /usr/lib/gcc/"$TEGRAABI"/*/libgcc_s.so.1 "$NEWLIB"/
    else
        cp /usr/lib/gcc/*/*/libgcc_s.so.1 "$NEWROOT/lib"/
    fi

    # Remove linuxrc script from busybox
    rm -rf "$NEWROOT/linuxrc"

    # Update ns switch
    sed -i "s/compat/db files nis/" "$NEWROOT/etc/nsswitch.conf"

    # Remove unneeded scripts
    remove_gentoo_services autofs dropbear mdev nscd pciparm ypbind
    rm -f "$NEWROOT/etc"/{init.d,conf.d}/busybox-*
    rm -rf "$NEWROOT/etc/systemd"

    # Build setdomainname tool
    if [[ $TEGRABUILD ]]; then
        "$TEGRAABI-gcc" -o "$NEWROOT/usr/sbin/setdomainname" "$BUILDSCRIPTS/extra/setdomainname.c"
    fi

    # Copy TinyLinux scripts
    ( cd "$BUILDSCRIPTS/scripts" && find ./ ! -type d ) | while read FILE; do
        local SRC
        local DEST
        SRC="$BUILDSCRIPTS/scripts/$FILE"
        DEST="$NEWROOT/$FILE"
        mkdir -p `dirname "$NEWROOT/$FILE"`
        cp -P "$SRC" "$DEST"
        if [[ ${FILE:2:11} = etc/init.d/ ]]; then
            chmod 755 "$DEST"
        elif [[ ${FILE:2:4} = etc/ ]]; then
            chmod 644 "$DEST"
        else
            chmod 755 "$DEST"
        fi
    done

    # Install syslinux so TinyLinux can reinstall itself
    install_syslinux

    # Create /etc/passwd and /etc/group
    echo "root:x:0:0:root:/:/bin/bash" > "$NEWROOT/etc/passwd"
    echo "root::0:root" > "$NEWROOT/etc/group"
    echo "dhcp:x:101:101:dhcp:/:/bin/false" >> "$NEWROOT/etc/passwd"
    echo "dhcp::101:" >> "$NEWROOT/etc/group"
    echo "tftp:x:102:102:tftp:/:/bin/false" >> "$NEWROOT/etc/passwd"
    echo "tftp::102:" >> "$NEWROOT/etc/group"
    echo "tty::5:" >> "$NEWROOT/etc/group"
    echo "disk::6:root" >> "$NEWROOT/etc/group"
    echo "kmem::9:" >> "$NEWROOT/etc/group"
    echo "users::100:" >> "$NEWROOT/etc/group"
    echo "audio::107:" >> "$NEWROOT/etc/group"

    # Create /etc/shells so that root can log in remotely using bash
    echo "/bin/bash" > "$NEWROOT"/etc/shells

    # Copy /etc/services
    [[ -f $NEWROOT/etc/services ]] || cp /etc/services "$NEWROOT"/etc/
    
    # Install udhcpc scripts
    cp /usr/share/genkernel/defaults/udhcpc.scripts "$NEWROOT/etc"/
    chmod a+x "$NEWROOT/etc/udhcpc.scripts"

    # Create hosts file
    echo "127.0.0.1   tinylinux localhost" > "$NEWROOT/etc/hosts"
    echo "::1         localhost" >> "$NEWROOT/etc/hosts"

    # Create syslog.conf
    touch "$NEWROOT/etc/syslog.conf"
}

prepare_installation()
{
    # Skip if the install directory already exists
    local INSTALLEXISTED
    [[ -d $INSTALL ]] && INSTALLEXISTED=1

    mkdir -p "$INSTALL/home"
    mkdir -p "$INSTALL/tiny"
    if [[ ! -f $INSTALL/tiny/kernel && -z $TEGRABUILD ]] ; then
        cp /boot/kernel-genkernel-* "$INSTALL/tiny/kernel"
        cp /boot/initramfs-genkernel-* "$INSTALL/tiny/initrd"
    fi

    [[ $INSTALLEXISTED = 1 ]] && return 0

    if [[ -z $TEGRABUILD ]]; then
        mkdir -p "$INSTALL/syslinux"
        echo "default /tiny/kernel initrd=/tiny/initrd" > "$INSTALL/syslinux/syslinux.cfg"
        cp /usr/share/syslinux/syslinux.exe "$INSTALL"/

        local EFI_BOOT="$INSTALL/EFI/BOOT"
        mkdir -p "$EFI_BOOT"
        cp /usr/share/syslinux/efi64/syslinux.efi "$EFI_BOOT/bootx64.efi"
        cp /usr/share/syslinux/efi64/ldlinux.e64  "$EFI_BOOT"/
    fi

    local COMMANDSFILE
    COMMANDSFILE="$BUILDSCRIPTS/profiles/$PROFILE/commands"
    [[ ! -f $COMMANDSFILE ]] || cp "$COMMANDSFILE" "$INSTALL/tiny/commands"

    cp "$BUILDSCRIPTS"/README "$INSTALL"/
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
        local MAKEOPTS
        [[ $JOBS ]] && MAKEOPTS="-j$JOBS"
        local MAKE=make
        ( cd "$TMPMODS"/driver && $MAKE -C /usr/src/linux M="$TMPMODS"/driver $MAKEOPTS modules )
        ( cd "$TMPMODS"/driver && $MAKE -C /usr/src/linux M="$TMPMODS"/driver $MAKEOPTS modules_install )
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

get_mods_driver_version()
{
    rm -rf /tmp/driver
    tar xzf "$BUILDSCRIPTS/mods/driver.tgz" -C /tmp/
    local MAJOR
    local MINOR
    MAJOR=`grep "define MODS_DRIVER_VERSION_MAJOR" /tmp/driver/mods.h | cut -f 3 -d ' '`
    MINOR=`grep "define MODS_DRIVER_VERSION_MINOR" /tmp/driver/mods.h | cut -f 3 -d ' '`
    rm -rf /tmp/driver
    echo "${MAJOR}.${MINOR}"
}

make_squashfs()
{
    local MSQJOBS
    local EXCLUDE

    # Skip if squashfs already exists or if kernel hasn't been rebuilt
    [[ ! -f $INSTALL/$SQUASHFS || $REBUILDSQUASHFS = 1 || $REBUILDKERNEL = 1 ]] || return 0

    # Install kernel modules and firmware
    boldecho "Copying kernel modules"
    rm -rf "$NEWROOT/lib/modules"
    rm -rf "$NEWROOT/lib/firmware"
    [[ $TEGRABUILD ]] || tar cp -C /lib modules | tar xp -C "$NEWROOT/lib"/
    if [[ -d /lib/firmware ]]; then
        tar cp -C /lib firmware | tar xp -C "$NEWROOT/lib"/
    else
        mkdir "$NEWROOT/lib/firmware"
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
        rm -rf "$NEWROOT/lib/modules" "$NEWROOT/lib/firmware"
        mkdir -p "$INSTALL/tiny/modules"
        mkdir -p "$INSTALL/tiny/firmware"
        mkdir -p "$INSTALL/tiny/debug"
        mkdir -p "$INSTALL/tiny/valgrind"
        ln -s /tiny/modules  "$NEWROOT/lib/modules"
        ln -s /tiny/firmware "$NEWROOT/lib/firmware"
    fi

    # Emit version information
    (
        local CLASSDIR
        CLASSDIR="sys-devel"
        [[ $TEGRABUILD ]] && CLASSDIR="cross-$TEGRAABI"
        echo "TinyLinux version $VERSION"
        echo "Profile $PROFILE"
        echo "Built with "`find /var/db/pkg/"$CLASSDIR"/ -maxdepth 1 -name gcc-[0-9]* | sed "s/.*\/var\/db\/pkg\/$CLASSDIR\///"`
        echo ""
        echo "Installed packages:"
        [[ $TEGRABUILD ]] || echo "MODS kernel driver `get_mods_driver_version`"
        [[ $TEGRABUILD ]] || find /var/db/pkg/sys-kernel/ -maxdepth 1 -name gentoo-sources-* -o -name git-sources-* | sed "s/.*\/var\/db\/pkg\///"
        find "$NEWROOT"/var/db/pkg/ -mindepth 2 -maxdepth 2 | sed "s/.*\/var\/db\/pkg\///" | sort
    ) > "$NEWROOT/etc/release"

    # Copy release notes
    cp "$BUILDSCRIPTS"/{release-notes,LICENSE} "$NEWROOT"/etc/

    # Make squashfs
    boldecho "Compressing squashfs"
    MSQJOBS="1"
    [[ $JOBS ]] && MSQJOBS="$JOBS"
    cat >/tmp/excludelist <<-EOF
        etc/env.d
	etc/portage
        etc/systemd
	mnt
        run
	tmp
        usr/lib*/*.a
        usr/lib*/*.o
        usr/lib*/pkgconfig
        usr/lib*/systemd
	usr/share/doc
	usr/share/i18n
        usr/share/locale/*
	usr/share/man
	var
	EOF
    find "$NEWROOT"/usr/include/ -mindepth 1 -maxdepth 1 | sed "s/^\/newroot\/// ; /^usr\/include\/python/d" >> /tmp/excludelist
    [[ $TEGRABUILD ]] && echo "etc" >> /tmp/excludelist
    mksquashfs "$NEWROOT"/ "$INSTALL/$SQUASHFS" -noappend -processors "$MSQJOBS" -comp xz -ef /tmp/excludelist -wildcards

    # Compress distfiles for future use
    if [[ ! -f /$DISTFILESPKG ]] || \
            find /usr/portage/distfiles -type f -newer "/$DISTFILESPKG" | grep -q . || \
            find "/usr/$TEGRAABI/packages"/ -type f -newer "/$DISTFILESPKG" 2>/dev/null | grep -q . || \
            find /usr/portage/packages -type f -newer "/$DISTFILESPKG" | grep -q .; then
        boldecho "Compressing distfiles"
        ( cd "/usr/portage" && tar_bz2 -cf "/$DISTFILESPKG" distfiles packages )
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
    BUSYBOX_PKG="/usr/portage/distfiles/$BUSYBOX.tar.bz2"
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
    sed -i "/CONFIG_CROSS_COMPILER_PREFIX/s/=.*/=\"${TEGRAABI}-\"/" "$BUILDDIR/$BUSYBOX"/.config

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
    local OUTDIR=/armv7
    istegra64 && OUTDIR=/aarch64
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
    rm -rf "$FILESYSTEM/etc/env.d" "$FILESYSTEM/etc/portage" "$FILESYSTEM/etc/profile.env"

    # Create mtab
    ln -s /proc/mounts "$FILESYSTEM"/etc/mtab

    # Create directories
    for DIR in dev proc sys tmp var var/tmp var/log mnt mnt/squash; do
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
    for DIR in bin sbin lib usr; do
        ln -s mnt/squash/"$DIR" "$FILESYSTEM/$DIR"
    done
    ! istegra64 || ln -s mnt/squash/lib64 "$FILESYSTEM/lib64"

    # Create symlink to /sys/kernel/debug
    ln -s sys/kernel/debug "$FILESYSTEM/d"

    # Ensure the lib/firmware/modules directories are empty
    rm -rf "$FILESYSTEM"/tiny/lib/* "$FILESYSTEM"/tiny/firmware/* "$FILESYSTEM"/tiny/modules/*

    # Copy files for simulation
    mkdir -p "$PACKAGE"/simrd
    cp "$NEWROOT"/tmp/busybox "$PACKAGE"/simrd/
    cp "$BUILDSCRIPTS"/tegra/linuxrc-sim "$PACKAGE"/simrd/linuxrc
    cp "$BUILDSCRIPTS"/profiles/tegra/simrd/commands "$PACKAGE"/simrd/
    cp "$BUILDSCRIPTS"/profiles/tegra/simrd/runmods "$PACKAGE"/simrd/
    cp "$BUILDSCRIPTS"/profiles/tegra/simrd/rungdb "$PACKAGE"/simrd/

    # Package filesystem image
    ( cd "$PACKAGE" && tar_bz2 -cpf "$OUTDIR/package.tar.bz2" * )
    rm -rf "$PACKAGE"
    unset PACKAGE

    # Clean up debug directory - leave only files we need
    local LIBDIR=lib
    istegra64 && LIBDIR=lib64
    local DEBUG_FILES=(
        ld-*.so.debug
        libc-*.so.debug
        libdl-*.so.debug
        libm-*.so.debug
        libpthread-*.so.debug
        librt-*.so.debug
    )
    rm -rf /tiny/debug.del
    mv /tiny/debug /tiny/debug.del
    mkdir -p /tiny/debug/$LIBDIR
    local DEBUG_FILE
    for DEBUG_FILE in "${DEBUG_FILES[@]}"; do
        DEBUG_FILE=`find /tiny/debug.del/$LIBDIR/ -name "$DEBUG_FILE"`
        mv "$DEBUG_FILE" "${DEBUG_FILE/debug.del/debug}"
    done
    rm -rf /tiny/debug.del
    mkdir -p /tiny/debug/mnt
    ln -s .. /tiny/debug/mnt/squash

    # Package optional directories
    ( cd /tiny && tar_bz2 -cpf "$OUTDIR/debug.tar.bz2"    debug    )
    ( cd /tiny && tar_bz2 -cpf "$OUTDIR/valgrind.tar.bz2" valgrind )
    ( cd "$NEWROOT" && tar_bz2 -cpf "$OUTDIR/lib.tar.bz2" $LIBDIR --exclude=mdev --exclude=firmware --exclude=modules --exclude=libnv*so )

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
    touch "$INITRD/etc/mtab"
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
            echo "default /$TINYDIR/kernel initrd=/$TINYDIR/initrd squash=$TINYDIR/squash.bin" > "$INSTALL/syslinux/syslinux.cfg"
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

# Check system
[[ `uname -m` = "x86_64" || $TEGRABUILD ]] || die "This script must be run on x86_64 architecture system"

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
install_tegra_toolchain     # [Tegra only] Install cross toolchain
compile_kernel              # Compile kernel. Can be forced with -k.
build_newroot               # Build newroot, which is the actual TinyLinux. Can be forced with -r.
prepare_installation        # Prepare /buildroot/install directory. Copy kernel, etc.
install_mods                # Install MODS kernel driver.
install_extra_packages      # Install additional profile-specific packages. Runs the custom script.
make_squashfs               # Create squashfs.bin from newroot. Can be forced with -q.
compile_busybox             # Compile busybox for startup.
make_tegra_image            # [Tegra only] Create initial ramdisk for Tegra.
compress_final_package      # [Not for Tegra] Build the zip package.
deploy                      # [Not for Tegra] Install on a USB stick
