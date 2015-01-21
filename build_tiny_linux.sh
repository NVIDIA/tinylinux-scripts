#!/bin/bash

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

[[ "$TEGRAABI" ]] || TEGRAABI="aarch64-unknown-linux-gnu"
TEGRAABI32="armv7a-softfp-linux-gnueabi"

die()
{
    echo "$@"
    exit 1
}

if ( [ $# -eq 1 ] && [ "$1" = "-h" -o "$1" = "--help" ] ) || [ $# -eq 0 ]; then
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
[[ "$JOBS" ]] || JOBS=`grep processor /proc/cpuinfo | wc -l`

# Parse options
while [ $# -gt 1 ]; do
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
if [ "$1" = "-i" ]; then
    if [ -f "$BUILDROOT/var/lib/misc/extra" ]; then
        PROFILE=`cat "$BUILDROOT/var/lib/misc/extra"`
    else
        die "No profile selected"
    fi
    INTERACTIVE="1"
else
    [ "$1" -a "${1#-}" = "$1" ] || die "No profile selected"
    PROFILE="$1"
fi
shift

# Set Tegra build type for Tegra profile
TEGRATYPE="`dirname "$0"`/profiles/$PROFILE/tegra"
[[ -z "$TEGRABUILD" && -f "$TEGRATYPE" ]] && TEGRABUILD=`cat "$TEGRATYPE"`

# Find default stage3 package
[ "$STAGE3PKG" ] || STAGE3PKG=`find ./ -maxdepth 1 -name stage3-$STAGE3ARCH-*.tar.bz2 | head -n 1`

# Override package name with profile name
FINALPACKAGE="$PROFILE.zip"

# Set default version
[ "$VERSION" ] || VERSION=`date "+%y.%m.%d"`

# Export user arguments
[ "$JOBS" ]             && export JOBS
[ "$PROFILE" ]          && export PROFILE
[ "$VERSION" ]          && export VERSION
[ "$REBUILDNEWROOT" ]   && export REBUILDNEWROOT
[ "$INTERACTIVE" ]      && export INTERACTIVE
[ "$REBUILDKERNEL" ]    && export REBUILDKERNEL
[ "$REBUILDSQUASHFS" ]  && export REBUILDSQUASHFS
[ "$KERNELMENUCONFIG" ] && export KERNELMENUCONFIG
[ "$DEPLOY" ]           && export DEPLOY
[ "$RCKERNEL" ]         && export RCKERNEL
[ "$TEGRABUILD" ]       && export TEGRABUILD
[ "$TEGRAABI" ]         && export TEGRAABI

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
    curl -O "$URL" || exit $?
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
        [[ -n "$DIR" ]] && find_stage3 "$STAGE3" "${URL}$DIR" && return 0
    done <<- EOF
$DIRLIST
EOF
    return 1
}

download_packages()
{
    # Don't do anything if we are inside the host tree already
    [ -d "./$BUILDSCRIPTS" ] && return 0

    # Don't do anything if the host tree already exists
    [ -d "$BUILDROOT" ] && return 0

    # Download package database if needed
    if [ ! -f "$PORTAGEPKG" ]; then
        download "$MIRROR/snapshots/$PORTAGEPKG"
    fi

    # Download stage 3 image if needed
    if [ ! -f "$STAGE3PKG" ]; then
        local GREPSTAGE
        local STAGE3PATH
        local LASTERROR
        GREPSTAGE="^stage3-$STAGE3ARCH-[0-9].*\.tar\.bz2$"
        boldecho "Downloading stage3 file list from the server"
        STAGE3PATH="$MIRROR/releases/${STAGE3ARCH/i?86/x86}/autobuilds/current-stage3-$STAGE3ARCH/"
        STAGE3PKG=`find_stage3 "$GREPSTAGE" "$STAGE3PATH"`
        LASTERROR=$?
        [ $LASTERROR -ne 0 ] && exit $LASTERROR
        download "$STAGE3PKG"
        STAGE3PKG=`basename "$STAGE3PKG"`
    fi
}

unpack_packages()
{
    local SCRIPTSDIR

    # Don't do anything if we are inside the host tree already
    [ -d "./$BUILDSCRIPTS" ] && return 0

    # Don't do anything if the host tree already exists
    [ -d "$BUILDROOT" ] && return 0

    # Unpack the root
    boldecho "Unpacking stage3 package"
    mkdir "$BUILDROOT" || exit $?
    $NICE tar xjpf "$STAGE3PKG" -C "$BUILDROOT" || exit $?

    # Unpack portage tree
    boldecho "Unpacking portage tree"
    $NICE tar xjpf "$PORTAGEPKG" -C "$BUILDROOT/usr" || exit $?

    # Unpack distfiles if available
    if [ -f "$DISTFILESPKG" ]; then
        boldecho "Unpacking distfiles"
        $NICE tar xjpf "$DISTFILESPKG" -C "$BUILDROOT/usr/portage" || exit $?
    fi
}

copy_scripts()
{
    # Don't do anything if we are inside the host tree already
    [[ -d "./$BUILDSCRIPTS" ]] && return 0

    # Delete stale build scripts
    [[ ! -d "$BUILDROOT/$BUILDSCRIPTS" ]] && rm -rf "$BUILDROOT/$BUILDSCRIPTS"

    boldecho "Copying scripts to build environment"

    # Check access to the scripts
    SCRIPTSDIR=`dirname $0`
    [[ -f "$SCRIPTSDIR/scripts/etc/inittab" ]] || die "TinyLinux scripts are not available"
    [[ -d "$SCRIPTSDIR/profiles/$PROFILE" ]] ||  die "Selected profile $PROFILE is not available"

    # Copy TinyLinux scripts
    mkdir -p "$BUILDROOT/$BUILDSCRIPTS" || exit $?
    find "$SCRIPTSDIR"/ -maxdepth 1 -type f -exec cp '{}' "$BUILDROOT/$BUILDSCRIPTS" \; || exit $?
    cp -r "$SCRIPTSDIR"/profiles "$BUILDROOT/$BUILDSCRIPTS" || exit $?
    cp -r "$SCRIPTSDIR"/mods "$BUILDROOT/$BUILDSCRIPTS" || exit $?
    cp -r "$SCRIPTSDIR"/scripts "$BUILDROOT/$BUILDSCRIPTS" || exit $?
    cp -r "$SCRIPTSDIR"/extra "$BUILDROOT/$BUILDSCRIPTS" || exit $?
    [[ -z "$TEGRABUILD" ]] || cp -r "$SCRIPTSDIR"/tegra "$BUILDROOT/$BUILDSCRIPTS" || exit $?
}

run_in_chroot()
{
    local LASTERROR
    local LINUX32

    # Don't do anything if we are inside the host tree already
    [ -d "./$BUILDSCRIPTS" ] && return 0

    boldecho "Entering build environment"

    cp "$0" "$BUILDROOT/$BUILDSCRIPTS"/ || exit $?
    cp /etc/resolv.conf "$BUILDROOT/etc"/ || exit $?
    mount -t proc none "$BUILDROOT/proc" || exit $?
    mount --bind /dev "$BUILDROOT/dev" || exit $?
    mount --bind /dev/pts "$BUILDROOT/dev/pts" || exit $?
    mount -t sysfs none "$BUILDROOT/sys" || exit $?
    mkdir -p "$BUILDROOT/run/shm" || exit $?
    mount -t tmpfs -o mode=1777,nodev none "$BUILDROOT/run/shm" || exit $?

    LINUX32=""
    [ `uname -m` = "x86_64" ] && [ "${STAGE3ARCH/i?86/x86}" = "x86" ] && LINUX32="linux32"

    $NICE $LINUX32 chroot "$BUILDROOT" "$BUILDSCRIPTS/`basename $0`" "$PROFILE"
    LASTERROR=$?

    sync
    umount -l "$BUILDROOT"/{sys,run/shm,dev/pts,dev,proc}

    if [ -s "$BUILDROOT/$DISTFILESPKG" ]; then
        mv "$BUILDROOT/$DISTFILESPKG" ./
        touch -r ./"$DISTFILESPKG" "$BUILDROOT/$DISTFILESPKG"
    fi

    exit $LASTERROR
}

check_env()
{
    if [ -f "/var/lib/misc/extra" ]; then
        local TARGET
        TARGET=`cat /var/lib/misc/extra`
        [ "$PROFILE" = "$TARGET" ] || [ "$REBUILDNEWROOT" = "1" ] || die "Invalid profile, target system was built with $TARGET profile"
    fi
    eselect news read > /dev/null
}

prepare_portage()
{
    sed -i -e "/^MAKEOPTS/d ; /^PORTAGE_NICENESS/d ; /^USE/d" "$MAKECONF"

    (
        [ "$JOBS" ] && echo "MAKEOPTS=\"-j$JOBS\""
        echo "PORTAGE_NICENESS=\"15\""
        echo "USE=\"-* ipv6 syslog\""
    ) >> "$MAKECONF"

    local KEYWORDS="/etc/portage/package.keywords/tinylinux"
    [ -d /etc/portage/package.keywords ] || mkdir -p /etc/portage/package.keywords || exit $?
    [ -d /etc/portage/package.use ] || mkdir -p /etc/portage/package.use || exit $?
    [ -d /etc/portage/package.mask ] || mkdir -p /etc/portage/package.mask || exit $?
    if [ ! -f $KEYWORDS ]; then
        (
            echo "sys-kernel/gentoo-sources ~*"
            echo "sys-kernel/git-sources ~*"
            echo "net-misc/r8168 ~*"
            echo "net-misc/ipsvd ~*"
            echo "=sys-devel/crossdev-20140729 ~*"
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

    # gdb-7.7.1 is broken on ARM
    echo "=sys-devel/gdb-7.7.1" >> /etc/portage/package.mask/tegra

    # Enable some packages on 64-bit ARM (temporary, until enabled in Gentoo)
    if [[ "$TEGRABUILD" ]]; then
        [[ -d /etc/portage/package.accept_keywords ]] || mkdir -p /etc/portage/package.accept_keywords || exit $?
        local PKG
        for PKG in sys-apps/busybox-1.21.0 \
                   dev-libs/libtommath-0.42.0-r1 \
                   net-fs/autofs-5.0.8-r1 \
                   net-nds/ypbind-1.37.1 \
                   net-nds/yp-tools-2.12-r1 \
                   net-nds/portmap-6.0 \
                   net-dialup/lrzsz-0.12.20-r3 \
                   dev-util/valgrind-3.10.0 \
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
    local EBUILD=/usr/portage/dev-util/valgrind/valgrind-3.10.0.ebuild
    if [[ -f $EBUILD && $TEGRABUILD ]] && ! grep -q "valgrind-arm64.patch" "$EBUILD"; then
        boldecho "Patching $EBUILD"
        cp "$BUILDSCRIPTS/tegra/valgrind-arm64.patch" /usr/portage/dev-util/valgrind/files/ || exit $?
        sed -i "/epatch.*glibc/ a\
epatch \"\${FILESDIR}\"/valgrind-arm64.patch" "$EBUILD" || exit$?
        ebuild "$EBUILD" digest || exit $?
    fi

    # Install dropbear patch for pubkey authentication
    local EBUILD=/usr/portage/net-misc/dropbear/dropbear-2013.62.ebuild
    if [[ -f $EBUILD ]] && ! grep -q "pubkey\.patch" "$EBUILD"; then
        boldecho "Patching $EBUILD"
        cp "$BUILDSCRIPTS/dropbear-pubkey.patch" /usr/portage/net-misc/dropbear/files/ || exit $?
        sed -i "0,/epatch/ s//epatch \"\${FILESDIR}\"\/\${PN}-pubkey.patch\nepatch/" "$EBUILD" || exit $?
        ebuild "$EBUILD" digest || exit $?
    fi

    # Install r8168 patch for kernel 3.16
    local EBUILD=/usr/portage/net-misc/r8168/r8168-8.038.00.ebuild
    if [[ -f $EBUILD ]] && ! grep -q "ethtool-ops" "$EBUILD"; then
        boldecho "Patching $EBUILD"
        mkdir -p /usr/portage/net-misc/r8168/files || exit $?
        cp "$BUILDSCRIPTS/extra/r8168-8.038.00-ethtool-ops.patch" /usr/portage/net-misc/r8168/files/ || exit $?
        echo -e "src_prepare() {\n\tepatch \"\${FILESDIR}/\${P}-ethtool-ops.patch\"\n}" >> "$EBUILD" || exit $?
        ebuild "$EBUILD" digest || exit $?
    fi
}

run_interactive()
{
    if [ "$INTERACTIVE" = "1" ]; then
        bash
        exit
    fi
}

emerge_basic_packages()
{
    # Skip if the packages were already installed
    [ -e /usr/src/linux ] && return 0

    boldecho "Compiling basic host packages"

    if ! emerge --quiet squashfs-tools zip pkgconfig dropbear dosfstools reiserfsprogs genkernel bc less libtirpc rpcbind; then
        boldecho "Failed to emerge some packages"
        boldecho "Please complete installation manually"
        bash
    fi
    local KERNELPKG=gentoo-sources
    [[ $RCKERNEL = 1 ]] && KERNELPKG=git-sources
    if [[ -z "$TEGRABUILD" ]] && ! emerge --quiet $KERNELPKG syslinux; then
        boldecho "Failed to emerge some packages"
        boldecho "Please complete installation manually"
        bash
    fi
}

istegra64()
{
    [[ "$TEGRABUILD" ]] || return 1
    [[ "${TEGRAABI%%-*}" = "aarch64" ]]
}

install_tegra_toolchain()
{
    [[ "$TEGRABUILD" ]] || return 0

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
    grep -q "USE.*cxx" "$MAKECONF" || sed -i "/USE/s/\"$/ cxx\"/" "$MAKECONF" || exit $?

    # Build cross toolchain
    grep -q "PORTDIR_OVERLAY" "$MAKECONF" || echo "PORTDIR_OVERLAY=\"/usr/local/portage\"" >> "$MAKECONF" || exit $?
    sed -i "s/ -march=i.86//" "$MAKECONF" || exit $?
    [[ -d "/usr/local/portage" ]] || mkdir -p "/usr/local/portage" || exit $?
    crossdev -S "$TEGRAABI" || exit $?
    emerge-wrapper --target "TEGRAABI" --init || exit $?

    # Install portage configuration
    local CFGROOT="/usr/$TEGRAABI"
    local PORTAGECFG="$CFGROOT/etc/portage"
    (
        [[ "$JOBS" ]] && echo "MAKEOPTS=\"-j$JOBS\""
        echo "PORTAGE_NICENESS=\"15\""
        echo "USE=\"-* ipv6 syslog \${ARCH}\""
    ) >> "$CFGROOT/$MAKECONF"
    for FILE in package.use package.keywords package.mask package.accept_keywords savedconfig; do
        rm -f "$PORTAGECFG/$FILE"
        ln -s "/etc/portage/$FILE" "$PORTAGECFG/$FILE" || exit $?
    done
    [ -e "$CFGROOT/tmp" ] || ln -s /tmp "$CFGROOT/tmp" || exit $?
    [ ! -e "$PORTAGECFG/make.profile" ] || rm -f "$PORTAGECFG/make.profile" || exit $?
    local PROFILE_ARCH=arm
    istegra64 && PROFILE_ARCH=arm64
    local PROFILE=13.0
    ln -s "/usr/portage/profiles/default/linux/$PROFILE_ARCH/$PROFILE" "$PORTAGECFG/make.profile" || exit $?

    # Fix lib directory (make a symlink to lib64)
    if istegra64 && [[ `ls "$CFGROOT/usr/lib" | wc -l` = 0 ]]; then
        rmdir "$CFGROOT/usr/lib" || exit $?
        ln -s lib64 "$CFGROOT/usr/lib" || exit $?
    fi

    # Setup split glibc symbols for valgrind and remote debugging
    mkdir -p "$PORTAGECFG/package.env" || exit $?
    echo "sys-libs/glibc debug.conf"    > "$PORTAGECFG/package.env/glibc"    || exit $?
    echo "dev-util/valgrind debug.conf" > "$PORTAGECFG/package.env/valgrind" || exit $?
    mkdir -p "$PORTAGECFG/env"
    echo 'CFLAGS="${CFLAGS} -ggdb"'        >  "$PORTAGECFG/env/debug.conf" || exit $?
    echo 'CXXFLAGS="${CXXFLAGS} -ggdb"'    >> "$PORTAGECFG/env/debug.conf" || exit $?
    echo 'FEATURES="$FEATURES splitdebug"' >> "$PORTAGECFG/env/debug.conf" || exit $?

    touch "$INDICATOR"
}

compile_kernel()
{
    local MAKEOPTS
    local GKOPTS
    local CCPREFIX

    # Do not compile kernel for Tegra
    if [[ "$TEGRABUILD" ]]; then
        touch /usr/src/linux
        return 0
    fi

    # Skip compilation if kernel has already been built
    [ ! -f /boot/kernel-genkernel-* ] || [ "$REBUILDKERNEL" = "1" ] || return 0

    # Delete old kernel
    [ -f /boot/kernel-genkernel-* ] && rm -rf /boot/kernel-genkernel-*
    [ -f /boot/initramfs-genkernel-* ] && rm -rf /boot/initramfs-genkernel-*
    [ -f "$INSTALL/tiny/kernel" ] && rm "$INSTALL/tiny/kernel"
    [ -f "$INSTALL/tiny/initrd" ] && rm "$INSTALL/tiny/initrd"

    # Force regeneration of squashfs
    [ -f "$INSTALL/$SQUASHFS" ] && rm "$INSTALL/$SQUASHFS"

    # Remove disklabel (blkid) from genkernel configuration
    sed -i "/^DISKLABEL/s/yes/no/" /etc/genkernel.conf || exit $?

    boldecho "Preparing kernel"
    [ "$JOBS" ] && MAKEOPTS="--makeopts=-j$JOBS"
    rm -rf /lib/modules /lib/firmware || exit $?
    mkdir /lib/firmware || exit $? # Due to kernel bug with builtin firmware
    cp "$BUILDSCRIPTS/kernel-config" /usr/src/linux/.config || exit $?

    if [ "$KERNELMENUCONFIG" = "1" ]; then
        boldecho "Configuring kernel"
        make -C /usr/src/linux menuconfig || exit $?
    fi

    boldecho "Compiling kernel"
    genkernel --oldconfig --linuxrc="$BUILDSCRIPTS/linuxrc" --no-mountboot "$MAKEOPTS" kernel || exit $?

    emerge --quiet r8168 || exit $?

    boldecho "Creating initial ramdisk"
    local BBCFG="/tmp/init-busy-config"
    cp /usr/share/genkernel/defaults/busy-config "$BBCFG" || exit $?
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
        sed -i -e "/\<${OPT%=*}\>/s/.*/$OPT/" "$BBCFG" || exit $?
    done
    genkernel --oldconfig --linuxrc="$BUILDSCRIPTS/linuxrc" --no-mountboot "$MAKEOPTS" --all-ramdisk-modules --busybox-config="$BBCFG" ramdisk || exit $?
}

target_emerge()
{
    local EMERGE
    if [[ "$TEGRABUILD" ]]; then
        ROOT="$NEWROOT" "$TEGRAABI-emerge" "$@"
    else
        ROOT="$NEWROOT" emerge "$@"
    fi
}

install_package()
{
    USE="$2" target_emerge --quiet $3 "$1" || exit $?
}

list_package_files()
{
    grep -v "^dir" "$NEWROOT"/var/db/pkg/$1-*/CONTENTS | \
        cut -f 2 -d ' ' | cut -c 1 --complement
}

propagate_ncurses()
{
    [[ "$TEGRABUILD" ]] || return

    [ -e "/usr/$TEGRAABI/usr/include/curses.h" ] && return

    ( cd "$NEWROOT" && list_package_files "sys-libs/ncurses" | \
        grep "^usr/lib\|^lib\|^usr/include" | grep -v "terminfo" | \
        xargs tar c | tar x -C "/usr/$TEGRAABI/" ) || exit $?
}

install_syslinux()
{
    [[ "$TEGRABUILD" ]] && return

    local DESTDIR
    local SAVEROOT

    DESTDIR="/tmp/syslinux"

    SAVEROOT="$NEWROOT"
    NEWROOT="$DESTDIR" target_emerge --quiet --nodeps syslinux
    NEWROOT="$SAVEROOT"

    cp -p "$DESTDIR/sbin/extlinux" "$NEWROOT/sbin/extlinux" || exit $?
    rm -rf "$DESTDIR" || exit $?

    mkdir -p "$NEWROOT/usr/share/syslinux" || exit $?
    cp /usr/share/syslinux/mbr.bin "$NEWROOT/usr/share/syslinux"/ || exit $?
}

remove_gentoo_services()
{
    local DIR
    while [[ $# -gt 0 ]]; do
        for DIR in init.d conf.d; do
            [[ ! -f "$NEWROOT/etc/$DIR/$1" ]] || rm "$NEWROOT/etc/$DIR/$1" || exit $?
        done
        shift
    done
}

build_newroot()
{
    # Remove old build
    if [ "$REBUILDNEWROOT" = "1" ]; then
        [ ! -d "$NEWROOT" ] || rm -rf "$NEWROOT" || exit $?
        [ ! -d "$INSTALL" ] || rm -rf "$INSTALL" || exit $?
        [ ! -f /var/lib/misc/extra ] || rm -f /var/lib/misc/extra || exit $?
    fi

    # Skip if new root already exists
    [ -d "$NEWROOT" ] && return 0

    boldecho "Building TinyLinux root filesystem"

    mkdir -p "$NEWROOT" || exit $?
    mkdir -p "$NEWROOT/var/lib/gentoo/news" || exit $?

    # Prepare build configuration for Tegra target
    if [[ "$TEGRABUILD" ]]; then
        mkdir -p "$NEWROOT/etc/portage" || exit $?
        istegra64 || sed -e "s/^CHOST=.*/CHOST=$TEGRAABI/ ; /^CFLAGS=/s/\"$/ -mcpu=cortex-a9 -mfpu=vfpv3-d16 -mfloat-abi=softfp\"/" <"$MAKECONF"  >"${NEWROOT}${MAKECONF}" || exit $?
    fi

    # Create symlink to lib64 on Tegra
    if istegra64; then
        mkdir -p "$NEWROOT/usr/lib64" || exit $?
        ln -s lib64 "$NEWROOT/usr/lib" || exit $?
    fi

    # Restore busybox config file
    local BUSYBOXCFG="$BUILDSCRIPTS/busybox-1.21.0"
    local HOSTBUSYBOXCFGDIR=/etc/portage/savedconfig/sys-apps
    [[ "$TEGRABUILD" ]] && HOSTBUSYBOXCFGDIR="/usr/$TEGRAABI/$HOSTBUSYBOXCFGDIR"
    mkdir -p "$HOSTBUSYBOXCFGDIR" || exit $?
    cp "$BUSYBOXCFG" "$HOSTBUSYBOXCFGDIR" || exit $?
    local TARGETBUSYBOXCFGDIR="$NEWROOT/etc/portage/savedconfig/sys-apps"
    mkdir -p "$TARGETBUSYBOXCFGDIR" || exit $?
    cp "$BUSYBOXCFG" "$TARGETBUSYBOXCFGDIR" || exit $?

    # Setup directories for valgrind and for debug symbols
    local NEWUSRLIB="$NEWROOT/usr/lib"
    istegra64 && NEWUSRLIB="$NEWROOT/usr/lib64"
    rm -rf /tiny/debug /tiny/valgrind || exit $?
    mkdir -p /tiny/debug/mnt      || exit $?
    mkdir -p /tiny/valgrind       || exit $?
    mkdir -p "$NEWUSRLIB"         || exit $?
    mkdir -p "$NEWROOT/usr/share" || exit $?
    ln -s /tiny/debug    "$NEWUSRLIB/debug"        || exit $?
    ln -s /tiny/valgrind "$NEWUSRLIB/valgrind"     || exit $?

    # Install basic system packages
    install_package sys-libs/glibc "" "--usepkg --buildpkg"
    if istegra64; then
        # Fix glibc-created /lib dir - make /lib a symlink to lib64
        rm "$NEWROOT"/lib/ld-linux-aarch64.so.1 || exit $?
        rmdir "$NEWROOT"/lib || exit $?
        ln -s lib64 "$NEWROOT"/lib || exit $?
    fi
    ROOT="$NEWROOT" eselect news read > /dev/null
    install_package ncurses "" "--usepkg --buildpkg"
    propagate_ncurses
    install_package pciutils "" "--usepkg --buildpkg"
    rm -f "$NEWROOT/usr/share/misc"/*.gz || exit $? # Remove compressed version of hwids
    install_package busybox "make-symlinks mdev nfs savedconfig" "--usepkg --buildpkg"
    install_package dropbear "multicall" "--usepkg --buildpkg"
    install_package nano "" "--usepkg --buildpkg"
    install_package sys-libs/readline "" "--usepkg --buildpkg"
    if [[ $TEGRABUILD ]]; then
        ( cd "$NEWROOT" && list_package_files "sys-libs/readline" | \
            grep "^usr/lib\|^lib\|^usr/include" | \
            xargs tar c | tar x -C "/usr/$TEGRAABI/" ) \
        || exit $?
    fi
    install_package bash "readline net" "--usepkg --buildpkg"

    # Cross-installation of libtirpc is broken, do it manually
    install_package net-libs/libtirpc "" "--usepkg --buildpkg"
    if [[ "$TEGRABUILD" ]]; then
        local CFGROOT="/usr/$TEGRAABI"
        local LIB=lib
        istegra64 && LIB=lib64
        local ITEM
        for ITEM in /usr/include/tirpc        \
                    /usr/$LIB/libtirpc.so    \
                    /$LIB/libtirpc.so.1.0.10 \
                    /usr/$LIB/pkgconfig/libtirpc.pc; do
            rm -rf "$CFGROOT/$ITEM" || exit $?
            cp -r "$NEWROOT/$ITEM" "$CFGROOT/$ITEM" || exit $?
        done
        rm -f "$CFGROOT/$LIB/libtirpc.so.1" || exit $?
        ln -s libtirpc.so.1.0.10 "$CFGROOT/$LIB/libtirpc.so.1" || exit $?
        [ -e /usr/include/tirpc ] || ln -s "$NEWROOT/usr/include/tirpc" /usr/include/tirpc || exit $?
    fi

    # Install NFS utils
    install_package rpcbind "" "--usepkg --buildpkg"
    install_package nfs-utils "" "--usepkg --buildpkg --nodeps"
    remove_gentoo_services nfs nfsmount rpcbind rpc.statd

    # Additional x86-specific packages
    if [[ -z $TEGRABUILD ]]; then
        install_package libusb-compat "" "--usepkg --buildpkg"
        install_package numactl "" "--usepkg --buildpkg"
    fi

    # Add symlink to /bin/env in /usr/bin/env where most apps expect it
    [[ -f "$NEWROOT"/usr/bin/env ]] || [[ ! -f "$NEWROOT"/bin/env ]] || ln -s /bin/env "$NEWROOT"/usr/bin/env || exit $?

    # Remove link to busybox's lspci so that lspci from pciutils is used
    rm "$NEWROOT/bin/lspci"

    # Finish installing dropbear
    mkdir "$NEWROOT/etc/dropbear" || exit $?
    dropbearkey -t dss -f "$NEWROOT/etc/dropbear/dropbear_dss_host_key" || exit $?
    dropbearkey -t rsa -f "$NEWROOT/etc/dropbear/dropbear_rsa_host_key" || exit $?
    dropbearkey -t ecdsa -f "$NEWROOT/etc/dropbear/dropbear_ecdsa_host_key"
    ( cd "$NEWROOT/usr/bin" && ln -s dbclient ssh ) || exit $?
    ( cd "$NEWROOT/usr/bin" && ln -s dbscp scp ) || exit $?

    # Copy libgcc needed by bash
    if [[ "$TEGRABUILD" ]]; then
        local NEWLIB="$NEWROOT/lib"
        istegra64 && NEWLIB="$NEWROOT/lib64"
        cp /usr/lib/gcc/"$TEGRAABI"/*/libgcc_s.so.1 "$NEWLIB"/ || exit $?
    else
        cp /usr/lib/gcc/*/*/libgcc_s.so.1 "$NEWROOT/lib"/ || exit $?
    fi

    # Remove linuxrc script from busybox
    rm -rf "$NEWROOT/linuxrc"

    # Update ns switch
    sed -i "s/compat/db files nis/" "$NEWROOT/etc/nsswitch.conf" || exit $?

    # Remove unneeded scripts
    remove_gentoo_services autofs dropbear mdev nscd pciparm ypbind
    rm -f "$NEWROOT/etc"/{init.d,conf.d}/busybox-* || exit $?
    rm -rf "$NEWROOT/etc/systemd" || exit $?

    # Build setdomainname tool
    if [[ "$TEGRABUILD" ]]; then
        "$TEGRAABI-gcc" -o "$NEWROOT/usr/sbin/setdomainname" "$BUILDSCRIPTS/extra/setdomainname.c" || exit $?
    fi

    # Copy TinyLinux scripts
    ( cd "$BUILDSCRIPTS/scripts" && find ./ ! -type d ) | while read FILE; do
        local SRC
        local DEST
        SRC="$BUILDSCRIPTS/scripts/$FILE"
        DEST="$NEWROOT/$FILE"
        mkdir -p `dirname "$NEWROOT/$FILE"` || exit $?
        cp -P "$SRC" "$DEST" || exit $?
        if [ "${FILE:2:11}" = "etc/init.d/" ]; then
            chmod 755 "$DEST" || exit $?
        elif [ "${FILE:2:4}" = "etc/" ]; then
            chmod 644 "$DEST" || exit $?
        else
            chmod 755 "$DEST" || exit $?
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
    [ -f "$NEWROOT/etc/services" ] || cp /etc/services "$NEWROOT"/etc/
    
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
    [ -d "$INSTALL" ] && INSTALLEXISTED="1"

    [ -d "$INSTALL/tiny" ] || mkdir -p "$INSTALL/tiny" || exit $?
    if [[ ! -f "$INSTALL/tiny/kernel" && -z "$TEGRABUILD" ]] ; then
        cp /boot/kernel-genkernel-* "$INSTALL/tiny/kernel"  || exit $?
        cp /boot/initramfs-genkernel-* "$INSTALL/tiny/initrd" || exit $?
    fi

    [ "$INSTALLEXISTED" = "1" ] && return 0

    if [[ -z "$TEGRABUILD" ]]; then
        [[ -d "$INSTALL/syslinux" ]] || mkdir -p "$INSTALL/syslinux" || exit $?
        echo "default /tiny/kernel initrd=/tiny/initrd" > "$INSTALL/syslinux/syslinux.cfg"
        cp /usr/share/syslinux/syslinux.exe "$INSTALL"/ || exit $?

        [[ -d "$INSTALL/EFI/syslinux" ]] || mkdir -p "$INSTALL/EFI/syslinux" || exit $?
        cp /usr/share/syslinux/efi64/* "$INSTALL/EFI/syslinux"/ || exit $?
        cp "$INSTALL/syslinux/syslinux.cfg" "$INSTALL/EFI/syslinux"/ || exit $?
    fi

    local COMMANDSFILE
    COMMANDSFILE="$BUILDSCRIPTS/profiles/$PROFILE/commands"
    [ ! -f "$COMMANDSFILE" ] || cp "$COMMANDSFILE" "$INSTALL/tiny/commands" || exit $?
}

install_mods()
{
    if [[ "$TEGRABUILD" ]]; then
        mkdir -p "$INSTALL/mods"
        return 0
    fi

    local TMPMODS
    local DRVPKG

    # Skip if there is no MODS or driver package
    DRVPKG="$BUILDSCRIPTS/mods.tgz"
    if [ ! -f "$DRVPKG" ]; then
        DRVPKG="$BUILDSCRIPTS/mods/driver.tgz"
        [ -f "$DRVPKG" ] || return 0
    fi

    # Install MODS kernel driver
    if [[ ! -f /lib/modules/*/extra/mods.ko ]]; then
        TMPMODS=/tmp/mods
        [ ! -d "$TMPMODS" ] || rm -rf "$TMPMODS" || exit $?
        boldecho "Installing MODS kernel driver"
        mkdir "$TMPMODS" || exit $?
        tar xzf "$DRVPKG" -C "$TMPMODS" || exit $?
        [ ! -f "$BUILDSCRIPTS/mods.tgz" ] || tar xzf "$TMPMODS"/driver.tgz -C "$TMPMODS" || exit $?
        [ "$JOBS" ] && MAKEOPTS="-j$JOBS"
        local MAKE=make
        ( cd "$TMPMODS"/driver && $MAKE -C /usr/src/linux M="$TMPMODS"/driver $MAKEOPTS modules ) || exit $?
        ( cd "$TMPMODS"/driver && $MAKE -C /usr/src/linux M="$TMPMODS"/driver $MAKEOPTS modules_install ) || exit $?
        rm -rf "$TMPMODS" || exit $?

        # Force regeneration of squashfs
        [ -f "$INSTALL/$SQUASHFS" ] && rm "$INSTALL/$SQUASHFS"
    fi

    # Copy MODS args file
    [ -d "$INSTALL/mods" ] || mkdir -p "$INSTALL/mods" || exit $?
    local FILE
    for FILE in args pkgname runmods; do
        [ -f "$INSTALL/mods/$FILE" ] || cp "$BUILDSCRIPTS/mods/$FILE" "$INSTALL/mods/$FILE" || exit $?
    done

    # Skip further installation if only driver package was available, but no MODS package
    [ -f "$BUILDSCRIPTS/mods.tgz" ] || return 0

    # Install MODS
    if [ ! -f "$INSTALL/mods/mods.tgz" ]; then
        boldecho "Copying MODS"
        cp "$BUILDSCRIPTS/mods.tgz" "$INSTALL/mods"/ || exit $?
    fi
}

install_into()
{
    local DEST
    [ $# -ge 2 ] || die "Invalid use of install_into in custom script in profile $PROFILE"
    if echo "$1" | grep -q "^/"; then
        DEST="${NEWROOT}$1"
    else
        DEST="$INSTALL/$1"
    fi
    [ -d "$DEST" ] || mkdir -p "$DEST" || exit $?
    shift
    while [ $# -gt 0 ]; do
        cp "$BUILDSCRIPTS/profiles/$PROFILE/$1" "$DEST" || exit $?
        shift
    done
}

remove_syslinux()
{
    rm -f "$INSTALL/syslinux.exe" || exit $?
    rm -rf "$INSTALL/syslinux" || exit $?
}

install_grub_exe()
{
    cp "$BUILDSCRIPTS/grub.exe" "$INSTALL/tiny"/ || exit $?
}

install_extra_packages()
{
    local CUSTOMSCRIPT

    # Skip if extra packages have already been installed
    [ -f /var/lib/misc/extra ] && return 0

    # Proceed only if the current profile supports extra packages
    CUSTOMSCRIPT="$BUILDSCRIPTS/profiles/$PROFILE/custom"
    if [ -f "$CUSTOMSCRIPT" ]; then
        boldecho "Installing packages for profile $PROFILE"
        source "$CUSTOMSCRIPT"

        # Force regeneration of squashfs
        [ -f "$INSTALL/$SQUASHFS" ] && rm "$INSTALL/$SQUASHFS"
    fi

    # Indicate that extra packages have been installed
    # by setting profile name
    [ -d /var/lib/misc ] || mkdir -p /var/lib/misc
    echo "$PROFILE" > /var/lib/misc/extra
}

get_mods_driver_version()
{
    [ -d /tmp/driver ] && rm -rf /tmp/driver
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
    [[ ! -f "$INSTALL/$SQUASHFS" || $REBUILDSQUASHFS = 1 || $REBUILDKERNEL = 1 ]] || return 0

    # Install kernel modules and firmware
    boldecho "Copying kernel modules"
    rm -rf "$NEWROOT/lib/modules"
    rm -rf "$NEWROOT/lib/firmware"
    [[ "$TEGRABUILD" ]] || tar cp -C /lib modules | tar xp -C "$NEWROOT/lib"/ || exit $?
    if [[ -d /lib/firmware ]]; then
        tar cp -C /lib firmware | tar xp -C "$NEWROOT/lib"/ || exit $?
    else
        mkdir "$NEWROOT/lib/firmware" || exit $?
    fi

    boldecho "Preparing squashfs"

    # Skip any outstanding Gentoo changes
    yes | ROOT="$NEWROOT" etc-update --automode -7

    # Create directory for installable libraries
    if [[ "$TEGRABUILD" ]]; then
        [[ -d "$INSTALL/tiny/lib" ]] || mkdir -p "$INSTALL/tiny/lib" || exit $?
        for LIB in libnv{os,rm,rm_graphics,rm_gpu,dc}.so; do
            rm -rf "$NEWROOT/lib/$LIB" || exit $?
            ln -s "/tiny/lib/$LIB" "$NEWROOT/lib/$LIB" || exit $?
        done
    fi

    # Make the modules and firmware replaceable on Tegra
    if [[ "$TEGRABUILD" ]]; then
        rm -rf "$NEWROOT/lib/modules" "$NEWROOT/lib/firmware" || exit $?
        mkdir -p "$INSTALL/tiny/modules"  || exit $?
        mkdir -p "$INSTALL/tiny/firmware" || exit $?
        mkdir -p "$INSTALL/tiny/debug"    || exit $?
        mkdir -p "$INSTALL/tiny/valgrind" || exit $?
        ln -s /tiny/modules  "$NEWROOT/lib/modules" || exit $?
        ln -s /tiny/firmware "$NEWROOT/lib/firmware" || exit $?
    fi

    # Emit version information
    (
        local CLASSDIR
        CLASSDIR="sys-devel"
        [[ "$TEGRABUILD" ]] && CLASSDIR="cross-$TEGRAABI"
        echo "TinyLinux version $VERSION"
        echo "Profile $PROFILE"
        echo "Built with "`find /var/db/pkg/"$CLASSDIR"/ -maxdepth 1 -name gcc-[0-9]* | sed "s/.*\/var\/db\/pkg\/$CLASSDIR\///"`
        echo ""
        echo "Installed packages:"
        [[ "$TEGRABUILD" ]] || echo "MODS kernel driver `get_mods_driver_version`"
        [[ "$TEGRABUILD" ]] || find /var/db/pkg/sys-kernel/ -maxdepth 1 -name gentoo-sources-* -o -name git-sources-* | sed "s/.*\/var\/db\/pkg\///"
        find "$NEWROOT"/var/db/pkg/ -mindepth 2 -maxdepth 2 | sed "s/.*\/var\/db\/pkg\///" | sort
    ) > "$NEWROOT/etc/release"

    # Copy release notes
    cp "$BUILDSCRIPTS"/release-notes "$NEWROOT"/etc/release-notes || exit $?

    # Make squashfs
    boldecho "Compressing squashfs"
    MSQJOBS="1"
    [ "$JOBS" ] && MSQJOBS="$JOBS"
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
    [[ "$TEGRABUILD" ]] && echo "etc" >> /tmp/excludelist
    mksquashfs "$NEWROOT"/ "$INSTALL/$SQUASHFS" -noappend -processors "$MSQJOBS" -comp xz -ef /tmp/excludelist -wildcards || exit $?

    # Compress distfiles for future use
    if [ ! -f "/$DISTFILESPKG" ] || \
            find /usr/portage/distfiles -type f -newer "/$DISTFILESPKG" | grep -q . || \
            find "/usr/$TEGRAABI/packages"/ -type f -newer "/$DISTFILESPKG" 2>/dev/null | grep -q . || \
            find /usr/portage/packages -type f -newer "/$DISTFILESPKG" | grep -q .; then
        boldecho "Compressing distfiles"
        ( cd "/usr/portage" && tar cjf "/$DISTFILESPKG" distfiles packages ) || exit $?
    fi
}

compile_busybox()
{
    local FINALEXEC
    local BUSYBOX
    local BUSYBOX_PKG
    local BUILDDIR
    local MAKEOPTS

    [[ "$JOBS" ]] && MAKEOPTS="-j$JOBS"

    # Only for Tegra
    [[ "$TEGRABUILD" ]] || return

    # Skip if already built
    FINALEXEC="$NEWROOT/tmp/busybox"
    [[ -f "$FINALEXEC" ]] && return

    boldecho "Compiling busybox"

    BUSYBOX=`ls -d "$NEWROOT"/var/db/pkg/sys-apps/busybox-*`
    BUSYBOX=`basename "$BUSYBOX"`
    BUSYBOX=${BUSYBOX%-r[0-9]}

    # Find package
    BUSYBOX_PKG="/usr/portage/distfiles/$BUSYBOX.tar.bz2"
    if [[ ! -f "$BUSYBOX_PKG" ]]; then
        echo "Busybox package $BUSYBOX_PKG not found!"
        exit 1
    fi

    # Create build directory
    BUILDDIR="/tmp/busyboxbuild"
    [[ ! -d "$BUILDDIR" ]] || rm -rf "$BUILDDIR" || exit $?
    [[ -d "$BUILDDIR" ]] || mkdir "$BUILDDIR" || exit $?

    # Prepare busybox source
    tar xjf "$BUSYBOX_PKG" -C "$BUILDDIR" || exit $?
    cp "$BUILDSCRIPTS/tegra/busybox-config" "$BUILDDIR/$BUSYBOX"/.config || exit $?
    sed -i "/CONFIG_CROSS_COMPILER_PREFIX/s/=.*/=\"${TEGRAABI}-\"/" "$BUILDDIR/$BUSYBOX"/.config || exit $?

    # Compile busybox
    (
        cd "$BUILDDIR/$BUSYBOX" || exit $?
        yes '' 2>/dev/null | make oldconfig > /var/log/busybox.make.log || exit $?
        make $MAKEOPTS >> /var/log/busybox.make.log || exit $?
    )
    cp "$BUILDDIR/$BUSYBOX/busybox" "$FINALEXEC" || exit $?

    rm -rf "$BUILDDIR"
}

make_tegra_image()
{
    [[ "$TEGRABUILD" ]] || return

    boldecho "Creating Tegra filesystem image"

    # Delete stale image files
    [[ ! -f "initrd" ]] || rm "initrd" || exit $?
    [[ ! -f package.tar.bz2 ]] || rm package.tar.bz2 || exit $?

    # Create output directory
    local OUTDIR=/armv7
    istegra64 && OUTDIR=/aarch64
    rm -rf "$OUTDIR" || exit $?
    mkdir "$OUTDIR" || exit $?
     
    # Create directory where the image is assembled
    local PACKAGE="/mnt/root"
    local FILESYSTEM="$PACKAGE/filesystem"
    [[ -d "$PACKAGE" ]] || rm -rf "$PACKAGE" || exit $?
    mkdir -p "$FILESYSTEM" || exit $?

    # Copy files
    ( cd "$INSTALL" && tar cp * ) | tar xp -C "$FILESYSTEM" || exit $?

    # Copy etc
    ( cd "$NEWROOT" && tar cp etc ) | tar xp -C "$FILESYSTEM" || exit $?
    rm -rf "$FILESYSTEM/etc/env.d" "$FILESYSTEM/etc/portage" "$FILESYSTEM/etc/profile.env" || exit $?

    # Create mtab
    ln -s /proc/mounts "$FILESYSTEM"/etc/mtab || exit $?

    # Create directories
    for DIR in dev proc sys tmp var var/tmp var/log mnt mnt/squash; do
        mkdir "$FILESYSTEM/$DIR" || exit $?
    done
    chmod 1777 "$FILESYSTEM/tmp" "$FILESYSTEM/var/tmp" || exit $?
    chmod 755 "$FILESYSTEM/var/log" || exit $?

    # Create login log
    touch "$FILESYSTEM/var/log/wtmp" || exit $?

    # Create basic device files
    mknod "$FILESYSTEM/dev/null"    c 1 3 || exit $?
    mknod "$FILESYSTEM/dev/console" c 5 1 || exit $?
    mknod "$FILESYSTEM/dev/tty1"    c 4 1 || exit $?
    mknod "$FILESYSTEM/dev/loop0"   b 7 0 || exit $?
    chmod 660 "$FILESYSTEM/dev/null"    || exit $?
    chmod 660 "$FILESYSTEM/dev/console" || exit $?
    chmod 600 "$FILESYSTEM/dev/tty1"    || exit $?
    chmod 660 "$FILESYSTEM/dev/loop0"   || exit $?

    # Create symlinks
    for DIR in bin sbin lib usr; do
        ln -s mnt/squash/"$DIR" "$FILESYSTEM/$DIR" || exit $?
    done
    ! istegra64 || ln -s mnt/squash/lib64 "$FILESYSTEM/lib64" || exit $?

    # Create symlink to /sys/kernel/debug
    ln -s sys/kernel/debug "$FILESYSTEM/d" || exit $?

    # Ensure the lib/firmware/modules directories are empty
    rm -rf "$FILESYSTEM"/tiny/lib/* "$FILESYSTEM"/tiny/firmware/* "$FILESYSTEM"/tiny/modules/* || exit $?

    # Copy files for simulation
    mkdir -p "$PACKAGE"/simrd || exit $?
    cp "$NEWROOT"/tmp/busybox "$PACKAGE"/simrd/ || exit $?
    cp "$BUILDSCRIPTS"/tegra/linuxrc-sim "$PACKAGE"/simrd/linuxrc || exit $?
    cp "$BUILDSCRIPTS"/profiles/tegra/simrd/commands "$PACKAGE"/simrd/ || exit $?
    cp "$BUILDSCRIPTS"/profiles/tegra/simrd/runmods "$PACKAGE"/simrd/ || exit $?
    cp "$BUILDSCRIPTS"/profiles/tegra/simrd/rungdb "$PACKAGE"/simrd/ || exit $?

    # Package filesystem image
    ( cd "$PACKAGE" && tar cjpf "$OUTDIR/package.tar.bz2" * ) || exit $?
    rm -rf "$PACKAGE" || exit $?
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
    rm -rf /tiny/debug.del         || exit $?
    mv /tiny/debug /tiny/debug.del || exit $?
    mkdir -p /tiny/debug/$LIBDIR   || exit $?
    local DEBUG_FILE
    for DEBUG_FILE in "${DEBUG_FILES[@]}"; do
        DEBUG_FILE=`find /tiny/debug.del/$LIBDIR/ -name "$DEBUG_FILE"`
        mv "$DEBUG_FILE" "${DEBUG_FILE/debug.del/debug}" || exit $?
    done
    rm -rf /tiny/debug.del          || exit $?
    mkdir -p /tiny/debug/mnt        || exit $?
    ln -s .. /tiny/debug/mnt/squash || exit $?

    # Package optional directories
    ( cd /tiny && tar cjpf "$OUTDIR/debug.tar.bz2"    debug    ) || exit $?
    ( cd /tiny && tar cjpf "$OUTDIR/valgrind.tar.bz2" valgrind ) || exit $?
    ( cd "$NEWROOT" && tar cjpf "$OUTDIR/lib.tar.bz2" $LIBDIR --exclude=mdev --exclude=firmware --exclude=modules --exclude=libnv*so ) || exit $?

    # Create initial ramdisk
    local INITRD
    INITRD="/mnt/initrd"
    mkdir -p "$INITRD/tiny" || exit $?
    cp -p "$NEWROOT/tmp/busybox" "$INITRD/tiny"/ || exit $?
    cp "$BUILDSCRIPTS/tegra/linuxrc-silicon" "$INITRD/init" || exit $?
    chmod 755 "$INITRD/init" || exit $?
    mkdir "$INITRD/dev" || exit $?
    mkdir "$INITRD/proc" || exit $?
    mknod "$INITRD/dev/null"    c 1 3 || exit $?
    mknod "$INITRD/dev/console" c 5 1 || exit $?
    chmod 660 "$INITRD/dev/null"    || exit $?
    chmod 660 "$INITRD/dev/console" || exit $?
    mkdir "$INITRD/etc" || exit $?
    touch "$INITRD/etc/mtab" || exit $?
    ( cd "$INITRD" && find . | cpio --create --format=newc ) > "$OUTDIR/initrd" || exit $?
    rm -rf "$INITRD"
    unset INITRD

    # Copy release notes
    cp "$NEWROOT/etc/release" "$OUTDIR"/ || exit $?

    boldecho "Files ready in ${BUILDROOT}${OUTDIR}"
}

compress_final_package()
{
    [[ "$TEGRABUILD" ]] && return

    local SRCDIR
    local RC
    local SAVEDSYSLINUXCFG

    boldecho "Compressing final package"
    
    SRCDIR="$INSTALL"
    [ -f "$INSTALL/tiny/grub.exe" ] && SRCDIR="$INSTALL/tiny"
    rm -f "/$FINALPACKAGE" || exit $?
    if [ "$TINYDIR" ]; then
        mv "$INSTALL/tiny" "$INSTALL/$TINYDIR"
        if [ -f "$INSTALL/syslinux/syslinux.cfg" ]; then
            SAVEDSYSLINUXCFG=`cat "$INSTALL/syslinux/syslinux.cfg"`
            echo "default /$TINYDIR/kernel initrd=/$TINYDIR/initrd squash=$TINYDIR/squash.bin" > "$INSTALL/syslinux/syslinux.cfg"
        fi
    fi
    ( cd "$SRCDIR" && zip -9 -r -q "/$FINALPACKAGE" * )
    RC=$?
    if [ "$TINYDIR" ]; then
        [ -f "$INSTALL/syslinux/syslinux.cfg" ] && echo "$SAVEDSYSLINUXCFG" > "$INSTALL/syslinux/syslinux.cfg"
        mv "$INSTALL/$TINYDIR" "$INSTALL/tiny"
    fi
    [ $RC -eq 0 ] || exit $RC
    boldecho "${BUILDROOT}/$FINALPACKAGE is ready"
}

deploy()
{
    [[ "$TEGRABUILD" ]] && return
    [ "$DEPLOY" = "" ] && return

    boldecho "Installing TinyLinux on $DEPLOY"
    [ -b "$DEPLOY" ] || die "Block device $DEPLOY not found"
    echo
    fdisk -l "$DEPLOY"
    echo
    echo "Install? [y|n]"
    local CHOICE
    read CHOICE
    if [ "$CHOICE" != "y" ]; then
        echo "Installation skipped"
        return
    fi

    mkfs.vfat -I -n TinyLinux "$DEPLOY" || exit $?
    sync
    local UEVENT
    ls /sys/bus/{pci,usb}/devices/*/uevent | while read UEVENT; do
        echo add > "$UEVENT"
    done
    sync
    sleep 1

    local DESTDIR
    DESTDIR=`mktemp -d`
    mount "$DEPLOY" "$DESTDIR" || exit $?
    unzip -q "/$FINALPACKAGE" -d "$DESTDIR" || exit $?
    sync
    syslinux "$DEPLOY" || exit $?
    sync
    umount "$DESTDIR"
    rmdir "$DESTDIR"
}

# Check system
[[ `uname -m` = "x86_64" || "$TEGRABUILD" ]] || die "This script must be run on x86_64 architecture system"

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
install_tegra_toolchain     # [Tegra only] Install cross toolchain and download the kernel sources.
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
