
Introduction
============

NVIDIA TinyLinux is a minimal Linux distribution, based on Gentoo Linux.  It is
characterized by:
* Small footprint
* Fast boot time
* Can boot from FAT or FAT32 - interoperable with other Operating Systems
* Can boot over NFS (supports PXE boot)

NVIDIA TinyLinux provides a simple environment for diagnostic software.


Profiles
========

The following profiles are available, each of them packaged individually:
* full      - basic release of NVIDIA TinyLinux
* pxeserver - only suitable for hosting a PXE server


Installation
============

From Linux - UEFI boot
---------------------------------

This method can be performed from another Linux distribution or from within
NVIDIA TinyLinux after it is already booted.

After determining the location of the target drive, run:

    installtiny /dev/sdx

Replace /dev/sdx with the actual drive where you want to install
NVIDIA TinyLinux.

The new partitions created this way are only accessible from Linux.

The `installtiny` script formats the target drive with GUID partition table
(GPT) and creates two partitions.  The first, boot partition is formatted with
FAT32 and contains the syslinux bootloader, kernel and initrd.  The second
partition is formatted with F2FS by default (or ReiserFS if selected with
the optional -r argument) and contains the `tiny` folder.


From Windows - UEFI boot on a USB stick
---------------------------------------

1. Format the target drive using FAT32 filesystem.  Right click the drive icon
   and choose "Format...".

2. Unpack the contents of the chosen profile package (e.g. full.zip) directly
   to the root directory of the formatted drive.

   - For example, right click on the zip file in Explorer, choose
     "Extract all..." and enter drive letter (e.g. e:) as the destination.

3. When booting NVIDIA TinyLinux, make sure the "Secure boot" option is
   disabled in UEFI setup.

From Windows - UEFI boot on a HDD
---------------------------------

1. Format the target drive with GPT (GUID partition table) and add a FAT32
   partition.  For USB drives, this can be done with
   [Rufus](http://rufus.akeo.ie).

   - When formatting a drive with Rufus, select `GPT partition scheme for UEFI
     computer` and leave the `Create a bootable disk` option unchecked.  Also
     choose FAT32 file system type.

2. Unpack the contents of the chosen profile package (e.g. full.zip) directly
   to the root directory of the formatted drive.

   - For example, right click on the zip file in Explorer, choose
     "Extract all..." and enter drive letter (e.g. e:) as the destination.

3. When booting NVIDIA TinyLinux, make sure the "Secure boot" option is
   disabled in UEFI setup.

From Windows - legacy boot (SBIOS)
----------------------------------

1. Format the target drive using FAT32 filesystem.

   - For USB sticks, right click the drive icon and choose "Format...".
   - For non-removable drives (such as SATA), go to Control Panel ->
     Administrative Tools -> Computer Management -> Storage -> Disk Management
     and create a partition smaller than 32GB (which is the maximum size for
     FAT32), then format it.

2. Unpack the contents of the chosen profile package (e.g. full.zip) directly
   to the root directory of the formatted drive.

   - For example, right click on the zip file in Explorer, choose
     "Extract all..." and enter drive letter (e.g. e:) as the destination.

3. Open command prompt with *Administrator privileges*.

   - On Windows Vista and Windows 7, click on the Start button, then in
     a small box in the lower-left corner type `cmd<CTRL+SHIFT+ENTER>`.
   - On Windows 10, just start typing the `cmd` command after clicking on
     the Start button.
   - It is important to press ENTER when holding both CTRL and SHIFT.
     It will ask you to confirm, click Yes.  CTRL+SHIFT+ENTER runs the cmd shell
     in Administrative mode.

4. Go to the target drive by typing drive letter of the target drive and
   pressing ENTER (e.g. `e:<ENTER>`).

5. Install the boot loader.  The example below assumes that e: is the target
   drive.  Make sure to use the proper drive letter!  For non-removable drives,
   also add the -f switch.

        E:\> syslinux -m -a e:

From Linux - GRUB 1
-------------------

If you have an existing Linux installation and want to add NVIDIA TinyLinux as
a boot option, edit GRUB config file (typically `menu.lst`) and add the
following section:

    title TinyLinux
    root (hd0,0)
    kernel /tiny/kernel
    initrd /tiny/initrd

Replace `(hd0,0)` with the hard drive and partition numbers corresponding to
the partition where you unpack the NVIDIA TinyLinux package.

For GRUB 2, follow GRUB 2 manual from your Linux distribution.

It is recommended to unpack NVIDIA TinyLinux into its own partition.

It is also recommended to have only one copy of NVIDIA TinyLinux in the system,
otherwise the boot script may become confused and problems with booting will
occur.

Disk contents
=============

Path                   | Description
-----------------------|-------------------------------------------------------
/ldlinux.sys           | Bootloader file used for legacy boot (SBIOS).
/syslinux.exe          | Legacy bootloader installer for Windows.
/syslinux/syslinux.cfg | Syslinux bootloader configuration file.
/EFI/BOOT/bootx64.efi  | Bootloader file used by UEFI boot.
/EFI/BOOT/ldlinux.e64  | Bootloader file used by UEFI boot.
/tiny/kernel           | Compressed Linux kernel image.
/tiny/initrd           | Compressed initial ramdisk.
/tiny/squash.bin       | Compressed Linux filesystem.
/tiny/config           | File containing persistent system configuration.
/tiny/config.new       | Default (empty) system configuration fallback.
/tiny/commands         | User-editable script, executed on startup.


Filesystem structure after boot
===============================

The following table outlines the most notable directories visible after booting
NVIDIA TinyLinux.

Path                 | Description
---------------------|---------------------------------------------------------
/                    | The root filesystem is in a ramdisk (tmpfs).
/mnt/nv              | Mount point of the boot disk, non-volatile.
/mnt/squash          | Mount point of the compressed Linux filesystem.
/mnt/etc             | Mount point of configuration from /mnt/nv/tiny/config.
/media               | This is where all other partitions are automounted.
/home                | Symbolic link to /mnt/nv/home.
/bin /lib /sbin /usr | Symbolic links to the compressed Linux filesystem.
/root                | Root user's home directory (in ramdisk).
/etc                 | Runtime configuration.  Copied from /mnt/squash/etc.
/commands            | The commands script, copied from /mnt/nv/tiny/.


Configuration
=============

Editing configuration files
---------------------------

There are two editors available in NVIDIA TinyLinux:
* nano - a simple editor, with usage familiar to most users.
* vi - a simplified version of the vi editor, which comes with busybox.

The configuration files in /etc can be edited and will be preserved across
reboots as long as file buffers are flushed properly.  File buffers are
normally flushed when gracefully rebooting (via `reboot`) or shutting down
(via `poweroff`) the system.  File buffers can be flushed manually with
the `sync` command.

*Note:* /etc is mounted using overlayfs, which combines /mnt/etc and
/mnt/squash/etc (read-only).  Under no circumstances should the user
edit files under /mnt/etc directly.  Editing files in /mnt/etc can result
in corruption of configuration files.

Bootloader
----------

The syslinux bootloader configuration resides in /syslinux/syslinux.cfg file.
Further settings can be added in it on a single line and will be passed
directly to the kernel and can later be recognized by boot scripts.

The following options are currently used by the boot scripts:

* /tiny/kernel - this is the first option.  It specifies the location of the
  Linux kernel.  If the kernel is stored elsewhere, this path has to be
  adjusted.

* initrd=/tiny/initrd - this is the location of the initial ramdisk.
  Typically, the initial ramdisk is stored in the same directory as the kernel.
  This option must always be specified and it is interpreted by the Linux
  kernel itself.

* squash=tiny/squash.bin - this optional parameter specifies the location of
  the compressed filesystem containing all the programs and libraries.  This
  parameter is optional, but it can be adjusted if the squash.bin file is moved
  to a different directory or renamed.  The boot script, which resides inside
  the initial ramdisk, will use this parameter to automatically find the
  NVIDIA TinyLinux installation.

* partno=0 - this optional parameter tells the NVIDIA TinyLinux boot script to
  look for squash.bin only on the given partition number.  If this parameter is
  not specified, the NVIDIA TinyLinux boot script will try to mount every
  partition it can find in search of squash.bin, until it finds it.  If this
  causes problems during boot, or if the booting is slow, it is recommended to
  set the `partno` parameter to the index of the partition to restrict the
  search.

* ovrcfg=0 - this optional parameter disables mounting /etc with overlayfs.
  When this option is specified, configuration files will be copied from
  /mnt/squash/etc to /etc.  User configuration will be ignored and
  configuration will not be preserved across reboots.

* nfsshare=1.2.3.4:/path - setting this optional parameter will make the boot
  script mount an NFS share and attempt to boot NVIDIA TinyLinux from that
  share.  The share must contain the squash.bin file (exact location can be
  adjusted with the `squash` parameter).  This allows NVIDIA TinyLinux to boot
  over NFS.

* net=eth0 - this optional parameter allows overriding the Ethernet device
  used for mounting NFS share for booting over NFS.  By default, the boot
  script will only attempt to obtain IP from DHCP on eth0.

* nocoldplug - this optional parameter will disable coldplugging.  Coldplugging
  is used to automount all fixed drives on the system in the /media directory.
  If there are partitions on the system which cause problems when mounting,
  coldplugging can be disabled with this parameter.

Services
--------

There are multiple services available in NVIDIA TinyLinux.  The configuration
files for each service live in `/etc/conf.d` directory.

There is also a special configuration file `/etc/conf.d/boot`, which specifies
the boot order of services.  If more services need to be started at boot, they
need to be listed there.

To list all the services and their status (started/stopped), use the following
command:

    rc status

To query status of an individual service, run (replace SERVICE with the actual
service name):

    rc SERVICE status

To start a service and enable it to be started at boot, run:

    rc enable SERVICE

To stop a service and disable it so that it is not started at boot, run:

    rc disable SERVICE

To start a service once (but not enable it at boot), run:

    rc start SERVICE

To stop a service once (but not disable it at boot), run:

    rc stop SERVICE

To restart a running service or start it once if it's stopped, run:

    rc restart SERVICE

If a service has crashed but TinyLinux still thinks it is running, you can
reset its status using the following command:

    rc zap SERVICE

Networking
----------

To set up networking, perform the following steps:

1. Stop the networking service, if it is currently started:

        rc stop net

2. Configure networking in `/etc/conf.d/net`

3. Enable networking and preserve its state across reboots:

        rc enable net

The networking configuration file `/etc/conf.d/net` contains the following
settings:

* `net=auto` - specifies which Ethernet interface should be configured.  `auto`
  indicates that the networking service will look for the first interface
  which has cable connected.  This can be changed to a specific interface,
  such as `eth0`, so that only this interface is used.

* `staticip=192.168.0.1/255.255.255.0` - IP and netmask for static IP.  If it is
  not specified (empty), DHCP is used.

* `gateway=192.168.0.1` - default gateway (esp. useful with static IP).

* `dns=192.168.0.154,1.2.3.4` - list of DNS servers (comma-separated).

* `dnsdomain=somedomain.com` - the DNS search domain.

SSH daemon
----------

To set up the SSH daemon, perform the following steps:

1. Set up user password.  By default, NVIDIA TinyLinux only has one user -
   root.  The root user does not have a password set, so it is not possible
   to log in as root.  Either create a local user, or set the root user's
   password, for example:

        passwd root

2. Enable the ssh daemon (it will also be started on boot):

        rc enable sshd

Running random scripts on boot
------------------------------

The commands script, which resides in the tiny folder, is normally run on boot,
unless it is disabled in the boot order file.

The commands script is editable on Windows.  The DOS-style line endings in this
file are automatically converted to UNIX-style before the script is run.

Further commands can be added to this script when needed.

The commands boot service, which runs the commands script, does not hook into
a tty, therefore it is not possible to run interactive scripts which require
user input from keyboard in the commands script.


Troubleshooting
===============

When trying to diagnose boot issues, edit `syslinux/syslinux.cfg` file which
resides in the main directory of the installation drive, and remove the `quiet`
option.  This will enable printing of all kernel messages during boot.
