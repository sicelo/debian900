#!/bin/sh
#
# install_debian.sh Installs Debian base system for N900
# Distributable under the terms of the GNU GPL version 3.

set -e
set -u

abort()
{
	echo ERROR: $1 >&2
	exit 1
}

clean_up()
{
	trap - 0 1 2 15
	
	for path in $MOUNTPOINT/dev/pts $MOUNTPOINT/dev $MOUNTPOINT/proc; do
		grep -q $path /proc/mounts && umount $path
	done
	
	echo "Installation failed" >&2
	exit 1
}

DIR=`dirname $0`

# Source configuration files
. $DIR/kernel.conf
test -r $DIR/kernel.conf.local && . $DIR/kernel.conf.local
. $DIR/debian.conf
test -r $DIR/debian.conf.local && . $DIR/debian.conf.local

${DEBUG:+set -x}

# Use "set -u" to ensure that all required variables are set
: $MOUNTPOINT
: $FSTYPE
: $UMASK
: $RELEASE
: $DEBARCH
: $MIRROR
: $HOSTNAME
: $CMDLINE
: $SWAPDEVICE
: $MOUNTFREMANTLE
: $HOMEDEVICE
: $MYDOCSDEVICE
: $BOOTSEQUENCE
: $KEYMAP_URL
: $XKB_URL
: $XKB_PATCHES
: $XKBLAYOUT
: $ESSENTIAL
: $NONFREE
: $INIT
: $USB_ADDRESS
: $USB_NETMASK
: $USB_GATEWAY
: $USERNAME
: $REALNAME

# Check user
test `id -u` -eq 0 || abort "Must be root"

# Check for presence of required utilities
UTILS="mount id cut chroot sed awk qemu-debootstrap qemu-arm-static update-binfmts wget fold"
for util in $UTILS; do
	command -pv $util > /dev/null || abort "$util not found"
done

# Use GIT_REPO_NAME as the relative path of the kernel source unless KERNELSOURCE was explicitly specified in config file
: ${KERNELSOURCE:=$GIT_REPO_NAME}

# Get kernel release name
KERNELRELEASE=`cat $KERNELSOURCE/include/config/kernel.release`
: ${KERNELRELEASE:?}

# Get kernel deb name
KERNELDEB=linux-image-"$KERNELRELEASE"_$KERNELRELEASE-`cat $KERNELSOURCE/.version`_armhf.deb

# Check that filesystem has been mounted and is of expected type
test x$FSTYPE = "x`awk '{ if ($2 == "'$MOUNTPOINT'") print $3 }' < /proc/mounts`" || abort "Unexpected filesystem or filesystem not mounted"

# Check that mounted filesystem contains nothing but lost+found
test xlost+found = "x`ls $MOUNTPOINT`" || abort "Filesystem already contains data or is not formatted correctly"

# Check that build system can execute ARM binaries
update-binfmts --display qemu-arm | grep -q enable || abort "ARM executable binary format not registered"

# Set up the root device name
SLICE=`awk '{ if ($2 == "'$MOUNTPOINT'") print substr($1, length($1), 1) }' < /proc/mounts`
ROOTDEVICE=/dev/mmcblk0p$SLICE

: ${SUPPRESS_DISCLAIMER:=}
if [ "x$SUPPRESS_DISCLAIMER" != xY ] && [ "x$SUPPRESS_DISCLAIMER" != xy ]; then
	# Print disclaimer
	echo "DISCLAIMER: Care has been taken to ensure that these scripts are safe to run however should they happen break something or mess anything up, the author takes no responsibility whatsoever.  Use at your own risk!" | fold -s
	printf "Continue? Y/[N]: "
	read disclaimer
	: ${disclaimer:=}
	test "x$disclaimer" = xY || test "x$disclaimer" = xy || exit 1
fi

: ${SUPPRESS_WARNING:=}
if [ "x$SUPPRESS_WARNING" != xY ] && [ "x$SUPPRESS_WARNING" != xy ]; then
	# Print non-free package warning
	echo "WARNING: This script enables non-free repositories in order to install the wireless network adapter." | fold -s
	printf "Continue? Y/[N]: "
	read warning
	: ${warning:=}
	test "x$warning" = xY || test "x$warning" = xy || exit 1
fi

# Set umask
umask $UMASK

# Set signal traps
trap clean_up 0 1 2 15

# Bootstrap Debian system
qemu-debootstrap ${DEBUG:+--verbose} --arch=$DEBARCH --variant=minbase --include=$ESSENTIAL${RECOMMENDED:+,$RECOMMENDED}${EXTRA:+,$EXTRA} $RELEASE $MOUNTPOINT $MIRROR

# Configure APT data sources
echo "deb $MIRROR $RELEASE main contrib non-free" > $MOUNTPOINT/etc/apt/sources.list

if [ $RELEASE != "unstable" ]; then
	printf "deb %s %s-updates main contrib non-free\ndeb http://security.debian.org/ %s/updates main contrib non-free\n" $MIRROR $RELEASE $RELEASE >> $MOUNTPOINT/etc/apt/sources.list
fi

# Set up hostname
echo $HOSTNAME > $MOUNTPOINT/etc/hostname
sed -i 's/127\.0\.0\.1.*$/& '$HOSTNAME'/' $MOUNTPOINT/etc/hosts

# Create filesystem table
cat << EOF > $MOUNTPOINT/etc/fstab
# /etc/fstab: static file system information.
#
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
$ROOTDEVICE	/	$FSTYPE	errors=remount-ro,noatime	0	1
proc	/proc	proc	nodev,noexec,nosuid	0	0
none	/tmp	tmpfs	noatime	0	0
$SWAPDEVICE	none	swap	sw	0	0
EOF

if [ "x$MOUNTFREMANTLE" = xY ] || [ "x$MOUNTFREMANTLE" = xy ]; then
	mkdir -p $MOUNTPOINT/srv/fremantle
	cat << EOF >> $MOUNTPOINT/etc/fstab
/dev/ubi0_0	/srv/fremantle	ubifs	defaults,noatime	0	0
$HOMEDEVICE	/srv/fremantle/home	ext3	noatime,errors=continue,commit=1,data=writeback	0	0
/srv/fremantle/home/opt	/srv/fremantle/opt	none	bind	0	0
$MYDOCSDEVICE	/srv/fremantle/home/user/MyDocs	vfat	nodev,noexec,nosuid,noatime,nodiratime,utf8,uid=29999,shortname=mixed,dmask=000,fmask=0133,rodir	0	0
EOF
fi

if [ x$ENABLE_LXC = xY ] || [ x$ENABLE_LXC = xy ]; then
	echo "cgroup	/sys/fs/cgroup	cgroup	defaults	0	0" >> $MOUNTPOINT/etc/fstab
fi

# Change power button behaviour
if [ x${POWER_BUTTON_ACTION:-} != x ]; then
	sed -i 's/\(action=\).*$/\1'$POWER_BUTTON_ACTION'/' $MOUNTPOINT/etc/acpi/events/powerbtn-acpi-support
fi

# Create network interface configuration
# TODO: Fix USB networking
cat << EOF > $MOUNTPOINT/etc/network/interfaces
# interfaces(5) file used by ifup(8) and ifdown(8)
# Include files from /etc/network/interfaces.d:
source-directory /etc/network/interfaces.d

auto lo
iface lo inet loopback

auto wlan0
iface wlan0 inet dhcp
${WLAN0_HWADDRESS:+	hwaddress $WLAN0_HWADDRESS}

auto usb0
iface usb0 inet static
	address $USB_ADDRESS
	netmask $USB_NETMASK
	gateway $USB_GATEWAY
EOF

# Create X11 configuration file
# Touchscreen can be recalibrated with xinput-calibrator(5)
cat << EOF > $MOUNTPOINT/etc/X11/xorg.conf
Section "InputClass"
	Identifier "calibration"
	MatchProduct "TSC2005 touchscreen"
	Option "Calibration" "216 3910 3747 245"
	Option "EmulateThirdButton" "$EMULATETHIRDBUTTON"
	Option "EmulateThirdButtonTimeout" "$EMULATETHIRDBUTTONTIMEOUT"
	Option "EmulateThirdButtonMoveThreshold" "$EMULATETHIRDBUTTONMOVETHRESHOLD"
	Option "SwapAxes" "0"
EndSection
EOF

# This temporary workaround prevents udev from changing the wlan0 device name
echo "# Unknown net device (/devices/platform/68000000.ocp/480ba000.spi/spi_master/spi4/spi4.0/net/wlan0) (wl1251)" > $MOUNTPOINT/etc/udev/rules.d/70-persistent-net.rules
echo 'SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTR{address}=="?*", ATTR{dev_id}=="0x0", ATTR{type}=="1", KERNEL=="wlan*", NAME="wlan0"' >> $MOUNTPOINT/etc/udev/rules.d/70-persistent-net.rules

# Copy kernel deb to Debian
cp $KERNELSOURCE/../$KERNELDEB $MOUNTPOINT/var/tmp

# Set up initramfs modules
printf "omaplfb\nsd_mod\nomap_hsmmc\nmmc_block\nomap_wdt\ntwl4030_wdt\n" >> $MOUNTPOINT/etc/initramfs-tools/modules

# Create update-initramfs hook to update u-boot images
mkdir -p $MOUNTPOINT/etc/initramfs/post-update.d
cat << EOF > $MOUNTPOINT/etc/initramfs/post-update.d/update-u-boot
#!/bin/sh
#
# update-u-boot update-initramfs hook to update u-boot images
# Distributable under the terms of the GNU GPL version 3.

KERNELRELEASE=\$1
INITRAMFS=\$2

# Create uInitrd under /boot
mkimage -A arm -O linux -T ramdisk -C none -a 0 -e 0 -n initramfs -d \$INITRAMFS /boot/uInitrd-\$KERNELRELEASE

EOF
chmod +x $MOUNTPOINT/etc/initramfs/post-update.d/update-u-boot

# Create u-boot commands
cat << EOF > $MOUNTPOINT/boot/u-boot.cmd
setenv mmcnum 0
setenv mmcpart $SLICE
setenv mmctype $FSTYPE
setenv bootargs root=$ROOTDEVICE $CMDLINE
setenv setup_omap_atag
setenv mmckernfile /boot/uImage-$KERNELRELEASE
setenv mmcinitrdfile /boot/uInitrd-$KERNELRELEASE
setenv mmcscriptfile
run trymmckerninitrdboot
EOF

# Create script to be run inside Debian chroot
cat << EOF > $MOUNTPOINT/var/tmp/finalstage.sh
#!/bin/sh
#
# finalstage.sh Script to be run inside Debian chroot
# Distributable under the terms of the GNU GPL version 3.

set -e
set -u
${DEBUG:+set -x}

# Install kernel
dpkg -i --force-architecture /var/tmp/$KERNELDEB

# Create boot.scr
mkimage -A arm -O linux -T script -C none -a 0 -e 0 -n debian900 -d /boot/u-boot.cmd /boot.scr

# Install non-free packages and System V init
apt-get update
apt-get -y --no-install-recommends install $NONFREE $INIT

# Console keyboard set up
wget --no-check-certificate -O /var/tmp/rx51_us.map $KEYMAP_URL
sed -i -e '/^XKBMODEL/ s/".*"/"nokiarx51"/' \
	-e '/^XKBLAYOUT/ s/".*"/"$XKBLAYOUT"/' \
	-e '/^XKBVARIANT/ s/".*"/"${XKBVARIANT:-}"/' \
	-e '/^XKBOPTIONS/ s/".*"/"${XKBOPTIONS:-}"/' /etc/default/keyboard
echo 'KMAP="/etc/console/boottime.kmap.gz"' >> /etc/default/keyboard

# Run interactive commands on boot along with install-keymap which cannot be run under a qemu chroot
cat > /etc/init.d/runonce << EOF2
#!/bin/sh
### BEGIN INIT INFO
# Provides:          runonce
# Required-Start:    \\\$remote_fs
# Required-Stop:
# X-Start-Before:    console-setup
# Default-Start:     S
# Default-Stop:
# X-Interactive:     true
### END INIT INFO
install-keymap /var/tmp/rx51_us.map

# Set root password
echo "Setting root user password..."
while ! passwd; do
	:
done

# Set unprivileged user password
echo "Setting $USERNAME user password..."
useradd -c "$REALNAME" -m -s /bin/bash $USERNAME
while ! passwd $USERNAME; do
	:
done

# Reconfigure locales and time zone
dpkg-reconfigure locales
dpkg-reconfigure tzdata

rm /etc/init.d/runonce
update-rc.d runonce remove
EOF2

chmod +x /etc/init.d/runonce
update-rc.d runonce defaults

# X11 keyboard set up
for patch in $XKB_PATCHES; do
	wget --no-check-certificate -O /var/tmp/\$patch $XKB_URL\$patch
	patch /usr/share/X11/xkb/symbols/nokia_vndr/rx-51 < /var/tmp/\$patch
done
EOF

# Make finalstage.sh executable
chmod +x $MOUNTPOINT/var/tmp/finalstage.sh

# Run finalstage.sh under chroot
mount -t proc proc $MOUNTPOINT/proc
mount -o bind /dev $MOUNTPOINT/dev
mount -o bind /dev/pts $MOUNTPOINT/dev/pts
ln -s /proc/mounts $MOUNTPOINT/etc/mtab
LC_ALL=C chroot $MOUNTPOINT /var/tmp/finalstage.sh

umount $MOUNTPOINT/dev/pts $MOUNTPOINT/dev $MOUNTPOINT/proc

# Create U-Boot configuration script
cat << EOF > configure_u-boot.sh
#!/bin/sh
#
# configure_u-boot.sh Configures U-Boot under Maemo

set -e
set -u
${DEBUG:+set -x}

abort()
{
	echo ERROR: \$1 >&2
	exit 1
}

# Hardware check
test x\$(awk '/product/ { print \$2 }' < /proc/component_version) = xRX-51 || abort "Must be executed on N900 under Maemo"

# Check that pali's U-Boot is installed
UBOOTVERSION=\$(dpkg -l u-boot-tools | grep ^ii | awk '{ print \$3 }' | cut -c 1-4)
test \$UBOOTVERSION -ge 2013 || abort "Compatible U-Boot version not found"

# Check user
test \$(id -u) -eq 0 || abort "Must be root"

# Ensure that bootmenu.d directory exists
mkdir -p /etc/bootmenu.d

# Create U-Boot configuration file
cat > /etc/bootmenu.d/$BOOTSEQUENCE-Debian_GNU_Linux-$RELEASE-$DEBARCH-$KERNELRELEASE.item << EOF2
ITEM_NAME="Debian GNU/Linux $RELEASE $DEBARCH $KERNELRELEASE"
ITEM_DEVICE="\\\${EXT_CARD}p${ROOTDEVICE##*p}"
ITEM_FSTYPE="$FSTYPE"
ITEM_KERNEL="/boot/uImage-$KERNELRELEASE"
ITEM_INITRD="/boot/uInitrd-$KERNELRELEASE"
ITEM_CMDLINE="root=$ROOTDEVICE $CMDLINE"
EOF2

# Update U-Boot Bootmenu
u-boot-update-bootmenu || abort "U-Boot Bootmenu update failed"
EOF

# Unset trap on exit
trap - 0

printf "\nStage 1 of installation complete.\nCopy configure_u-boot.sh to the N900 and execute it to complete installation.\n"
