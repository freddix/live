#!/usr/bin/sh

TMP_DIR="/tmp/livetmpfs"
FS_DIR="${TMP_DIR}/livefs"

IMAGE_DIR="${TMP_DIR}/image"
FS_IMAGE_DIR="${TMP_DIR}/fs"
MNT_DIR="${TMP_DIR}/mnt"
INITRD_DIR="${TMP_DIR}/initrd"

LIVECD_DIR=$(pwd)

KERNEL_FNAME="std_stats"
KERNEL_VERSION="3.10.10"
KERNEL_RELEASE="2"
KERNEL_UNAME="${KERNEL_VERSION}-${KERNEL_FNAME}-${KERNEL_RELEASE}"
KERNEL_ARCH="x86_64"
#KERNEL_ARCH="i686"

MODDIR="${INITRD_DIR}/usr/lib/modules/${KERNEL_UNAME}/kernel"

POLDEK_DIR="${LIVECD_DIR}/config/poldek"
RPM_LIST=$(cat ${LIVECD_DIR}/config/rpm-base.list)
#RPM_X_LIST=$(cat ${LIVECD_DIR}/config/rpm-x-gnome.list)

ED=

abort() {
    echo "aborted: $@"
    exit 1
}

clean_build () {
    rm -rf ${INITRD_DIR} ${IMAGE_DIR} ${FS_DIR} ${FS_IMAGE_DIR} ${MNT_DIR}
}

prepare() {
    clean_build
    rm -f ${LIVECD_DIR}/livecd.iso
    mkdir -p ${IMAGE_DIR}
    mkdir -p ${FS_IMAGE_DIR}
    mkdir -p ${MNT_DIR}
    mkdir -p ${MODDIR}
}

find_mod_deps() {
    local module="$1"

    /usr/sbin/modprobe -q \
	--ignore-install		\
	--set-version ${KERNEL_UNAME}	\
	--show-depends $module		\
	--dirname ${FS_DIR} |		\
	while read insmod modpath options; do
	    echo $modpath
	done
}

create_boot() {
    echo "preparing boot infrastucture"

    cp ${LIVECD_DIR}/config/menu.cfg ${IMAGE_DIR}/extlinux.conf
    cp ${LIVECD_DIR}/config/menu.cfg ${IMAGE_DIR}/isolinux.cfg
    cp ${LIVECD_DIR}/config/menu.cfg ${IMAGE_DIR}/syslinux.cfg
    cp ${LIVECD_DIR}/config/help.txt ${IMAGE_DIR}
    cp ${LIVECD_DIR}/config/version.txt ${IMAGE_DIR}
    cp ${FS_DIR}/usr/share/syslinux/isolinux.bin ${IMAGE_DIR}
    cp ${FS_DIR}/usr/share/syslinux/linux.c32 ${IMAGE_DIR}

    cp linuxrc ${INITRD_DIR}/linuxrc
    ln -sf linuxrc ${INITRD_DIR}/init

    chmod +x ${INITRD_DIR}/linuxrc ${INITRD_DIR}/init

    cp -a ${FS_DIR}/boot/System.map-${KERNEL_UNAME} ${IMAGE_DIR}/System.map
    cp -a ${FS_DIR}/boot/vmlinuz-${KERNEL_UNAME} ${IMAGE_DIR}/vmlinuz
}

create_image() {
    fs_modules="vfat isofs overlayfs squashfs"
    misc_modules="dm-snapshot loop nls_cp437 binfmt_misc crc32c crc32c-intel"
    usb_modules="ehci-hcd ehci-pci ohci-hcd uhci-hcd xhci-hcd usb-storage"

    for module in $misc_modules $fs_modules $usb_modules; do
	echo $(find_mod_deps $module)
	cp -aR $(find_mod_deps $module) ${MODDIR} || \
	    abort "copying of modules to ${MODDIR}"
    done

    /usr/sbin/depmod -aeb ${INITRD_DIR} -F ${IMAGE_DIR}/System.map \
	${KERNEL_UNAME} || abort "depomd failed"

    echo "creating basic initrd infrastructure"
    rpm --root ${INITRD_DIR} --initdb

    LC_ALL=C poldek --root="${INITRD_DIR}" --conf "${POLDEK_DIR}/poldek_$KERNEL_ARCH.conf" \
	-i util-linux kmod device-mapper mksh findutils filesystem coreutils

    find ${INITRD_DIR} -mindepth 3 -empty -type d -exec rmdir {} \;
    rm -rf ${INITRD_DIR}/usr/share/{doc,info,locale,man}

    cp ${FS_DIR}/usr/lib/systemd/systemd-timestamp ${INITRD_DIR}/usr/bin

    echo "generating initrd"
    cd ${INITRD_DIR}
    find . | cpio -o -H newc | xz --check=crc32 > ${IMAGE_DIR}/initrd.xz
    [ $? -eq 0 ] || abort "initrd image creation failed"

    cd ${LIVECD_DIR}
}

create_iso() {
    echo "generating iso image"
    if [ "$RPM_X_LIST" != "" ]; then
	ED="_X"
    fi
    genisoimage \
	-o ${LIVECD_DIR}/livecd_${KERNEL_VERSION}-${KERNEL_RELEASE}.${KERNEL_ARCH}${ED}.iso \
	-b isolinux.bin		\
	-no-emul-boot		\
	-boot-load-size 4	\
	-boot-info-table	\
	-V "FX_LIVE"		\
	-input-charset utf-8	\
	-quiet			\
	-cache-inodes -r -J -l ${IMAGE_DIR}
    [ $? -eq 0 ] || abort "iso image creation failed"
    chmod 0644 ${LIVECD_DIR}/livecd*.iso
}

create_tar() {
    cd ${IMAGE_DIR}
    tar -cf ${LIVECD_DIR}/livecd_${KERNEL_VERSION}-${KERNEL_RELEASE}.${KERNEL_ARCH}${ED}.tar .
    cd ${LIVECD_DIR}
}

create_system() {
    echo "generating live filesystem"

    mkdir -p ${FS_DIR}
    rpm --root "${FS_DIR}" --initdb

    LC_ALL=C poldek --upa --conf "${POLDEK_DIR}/poldek_$KERNEL_ARCH.conf"
    LC_ALL=C poldek --root="${FS_DIR}" --conf "${POLDEK_DIR}/poldek_$KERNEL_ARCH.conf" \
	-i ${RPM_LIST} ${RPM_X_LIST} \
	kernel-${KERNEL_FNAME}-${KERNEL_VERSION}-${KERNEL_RELEASE}.${KERNEL_ARCH}

    # test for userspace completness after packages installation
    [ -f ${FS_DIR}/usr/sbin/useradd ] || abort "packages installation not completed!"

    # add live user
    chroot ${FS_DIR} /usr/sbin/useradd \
	-m -G adm,wheel,audio,video,cdrom,usb,fuse,logs,systemd-journal \
	-s "/usr/bin/zsh" -c "Freddix" live

    # standard passwords
    echo live | chroot ${FS_DIR} passwd --stdin live
    echo live | chroot ${FS_DIR} passwd --stdin root

    echo 'PRETTY_HOSTNAME="Freddix Live"' > ${FS_DIR}/etc/machine-info
    echo 'ICON_NAME=' >> ${FS_DIR}/etc/machine-info

    # timezone
    ln -sf /usr/share/zoneinfo/Europe/Berlin \
	${FS_DIR}/etc/localtime
    [ $? -ne 0 ] && abort "can't link!"

    # disable Predictable Network Interface Names
    ln -sf /dev/null \
	${FS_DIR}/etc/udev/rules.d/80-net-name-slot.rules

    if [ "$RPM_X_LIST" == "" ]; then
	rm -f ${FS_DIR}/etc/systemd/system/getty.target.wants/getty*
	cp ${LIVECD_DIR}/config/autologin@.service \
	    ${FS_DIR}/etc/systemd/system
	[ $? -ne 0 ] && abort "can't copy!"

	ln -sf /etc/systemd/system/autologin@.service \
	    ${FS_DIR}/etc/systemd/system/getty.target.wants/autologin@tty1.service
	[ $? -ne 0 ] && abort "can't link!"

	#cp ${LIVECD_DIR}/config/dhcpcd.service \
	#    ${FS_DIR}/etc/systemd/system
	#ln -sf /etc/systemd/system/dhcpcd.serivce \
	#    ${FS_DIR}/etc/systemd/system/multi-user.target.wants/dhcpcd.service
	#[ $? -ne 0 ] && abort "can't link!"
    else
	rm -rf ${FS_DIR}/etc/systemd/system/getty.target.wants

	mkdir -p ${FS_DIR}/etc/systemd/system/graphical.target.wants
	ln -sf /usr/lib/systemd/system/graphical.target \
	    ${FS_DIR}/etc/systemd/system/default.target
	[ $? -ne 0 ] && abort "can't link!"

	#ln -sf /usr/lib/systemd/system/xsession@.service \
	#    ${FS_DIR}/etc/systemd/system/graphical.target.wants/xsession@1000.service
	#[ $? -ne 0 ] && abort "can't link!"

	#ln -sf /usr/lib/systemd/user/xfce4.target \
	#    ${FS_DIR}/usr/lib/systemd/user/default.target
	#[ $? -ne 0 ] && abort "can't link!"

	echo "[daemon]\nAutomaticLogin=live\nAutomaticLoginEnable=True\n" > ${FS_DIR}/etc/gdm/custom.conf
	#echo "CLUTTER_VBLANK=none" >> ${FS_DIR}/etc/environment

	mkdir ${FS_DIR}/etc/X11/xorg.conf.d
	cp ${LIVECD_DIR}/config/00-keyboard.conf \
	    ${FS_DIR}/etc/X11/xorg.conf.d
    fi

    cp ${LIVECD_DIR}/config/ssh/* ${FS_DIR}/etc/ssh
    cp ${LIVECD_DIR}/config/sudoers ${FS_DIR}/etc

    echo "Output=/var/log" >> ${FS_DIR}/etc/systemd/bootchart.conf
    echo "Init=/usr/bin/systemd" >> ${FS_DIR}/etc/systemd/bootchart.conf

    cp ${LIVECD_DIR}/config/90-pkexec.rules \
    	${FS_DIR}/etc/polkit-1/rules.d

    mkdir -p ${FS_DIR}/root/install ${FS_DIR}/root/tmp
    cp ${LIVECD_DIR}/config/poldek/poldek.conf ${FS_DIR}/root/install
    echo ${RPM_LIST} > ${FS_DIR}/root/install/packages.list
    cp -R ${LIVECD_DIR}/config/poldek/repos.d ${FS_DIR}/root/install

    #echo "DEFAULTWM=gnome" > ${FS_DIR}/etc/sysconfig/desktop
    #echo "default_user	live" >> ${FS_DIR}/etc/slim/slim.conf
    #echo "auto_login	yes" >> ${FS_DIR}/etc/slim/slim.conf

    chroot ${FS_DIR} localedb-gen
    chroot ${FS_DIR} prelink -qa -m

    rm -f ${FS_DIR}/var/lib/rpm/__*

    chown 1000:users -R ${FS_DIR}/home/users/live
    [ $? -ne 0 ] && abort "packages installation failed"
}

create_squashfs_img() {
    echo "generating squashfs image"
    /usr/sbin/mksquashfs ${FS_DIR} ${IMAGE_DIR}/fs.squashfs #-comp xz -Xbcj x86 -b 1048576 -Xdict-size 1048576 -no-recovery -noappend
}

create_fs () {
    ext_image="${FS_IMAGE_DIR}/freddix.fs"
    rm -f ${ext_image}

    fs_size=$(du -sxm "${FS_DIR}" | awk '{print $1}')
    # 10% overhead
    target_fs_size=$((fs_size * 110/100))

    echo "create fs image of ${target_fs_size} M size"
    truncate -s ${target_fs_size}M ${ext_image}

    mkfs.ext2 -m0 -F ${ext_image}
    tune2fs -c 0 -i 0 ${ext_image}

    mount ${ext_image} ${MNT_DIR}
    cp -aT ${FS_DIR}/ ${MNT_DIR}
    umount ${MNT_DIR}

    /usr/sbin/mksquashfs ${ext_image} ${IMAGE_DIR}/freddix.sfs -noappend -no-progress
}

if [ $(whoami) != root ]; then
    echo "use sudo Luke!"
    exit 1
fi

for package in cdrkit cpio findutils gzip squashfs syslinux xz; do
    rpm -q $package > /dev/null 2>&1 || abort "$package not installed"
done

set -x

clean_build
prepare
create_system
create_boot
create_image
create_fs
create_iso
#create_tar

