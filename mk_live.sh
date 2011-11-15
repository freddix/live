#!/bin/sh
#
TMP_DIR="/tmp/livetmpfs"
FS_DIR="${TMP_DIR}/livefs"

IMAGE_DIR="${TMP_DIR}/image"
INITRD_DIR="${TMP_DIR}/initrd"

LIVECD_DIR=$(pwd)
KERNEL=$(uname -r)
MODDIR="${INITRD_DIR}/lib/modules/${KERNEL}/kernel"

POLDEK_DIR="${LIVECD_DIR}/config/poldek"
RPM_LIST=$(cat ${LIVECD_DIR}/config/rpm-base.list)

abort() {
	echo "aborted: $@"
	exit 1
}

find_mod_deps() {
	local module="$1"

	modprobe --set-version ${KERNEL} --show-depends $module | \
		while read insmod modpath options; do
			echo $modpath
		done
}

prepare() {
    	rm -rf ${INITRD_DIR} ${IMAGE_DIR} ${FS_DIR}
    	rm -f ${LIVECD_DIR}/livecd.iso
	mkdir -p ${INITRD_DIR}/data ${INITRD_DIR}/live ${IMAGE_DIR}
	mkdir -p ${INITRD_DIR}/mnt/{live,fs,nroot,union}
	mkdir -p ${MODDIR}
	cp -rf /lib/initrd-utils/* ${INITRD_DIR}
}

create_boot() {
	echo "preparing boot infrastucture"

	cp ${LIVECD_DIR}/config/menu.cfg ${IMAGE_DIR}/extlinux.cfg
	cp ${LIVECD_DIR}/config/menu.cfg ${IMAGE_DIR}/isolinux.cfg
	cp ${LIVECD_DIR}/config/menu.cfg ${IMAGE_DIR}/syslinux.cfg
	cp ${LIVECD_DIR}/config/help.txt ${IMAGE_DIR}
	cp ${LIVECD_DIR}/config/version.txt ${IMAGE_DIR}
	cp /usr/share/syslinux/isolinux.bin ${IMAGE_DIR}
	cp /usr/share/syslinux/linux.c32 ${IMAGE_DIR}
	cp /usr/share/syslinux/menu.c32 ${IMAGE_DIR}

	cp linuxrc ${INITRD_DIR}/linuxrc
	ln -sf linuxrc ${INITRD_DIR}/init

	chmod +x ${INITRD_DIR}/linuxrc ${INITRD_DIR}/init

	cp -a /boot/System.map-${KERNEL} ${IMAGE_DIR}/System.map
	cp -a /boot/vmlinuz-${KERNEL} ${IMAGE_DIR}/vmlinuz

	for link in cat clear cttyhack insmod killall ls mdev mount sh; do
		ln -sf busybox ${INITRD_DIR}/bin/$link || abort "can't link $link binary"
	done
	ln -sf ../bin/busybox ${INITRD_DIR}/sbin/modprobe
}

create_image() {
    	echo "generating initrd"

	ata_modules=$(find /lib/modules/${KERNEL}/kernel/drivers/ata \
		-type f -name "*.ko.gz" -exec basename {} \; | sed "s|.ko.gz||")
	scsi_modules=$(find /lib/modules/${KERNEL}/kernel/drivers/scsi \
		-type f -name "*.ko.gz" -exec basename {} \; | sed "s|.ko.gz||")
	gpu_modules="i915 nouveau radeon intel-agp amd64-agp sis-agp via-agp"
	fs_modules="ext2 vfat isofs overlayfs squashfs"
	misc_modules="cdrom loop nls_iso8859-1 nls_cp437 crc-t10dif binfmt_misc"
	usb_modules="ehci-hcd ohci-hcd uhci-hcd xhci-hcd usb-storage uas"

	for module in $ata_modules $fs_modules $gpu_modules \
		$misc_modules $scsi_modules $usb_modules; do
		cp -aR $(find_mod_deps $module) ${MODDIR} || \
			abort "copying of modules to ${MODDIR}"
	done

	gunzip -f $(find ${MODDIR} -type f -name '*.gz') || abort "can't unzip modules"

	/sbin/depmod -aeb ${INITRD_DIR} -F ${IMAGE_DIR}/System.map \
		${KERNEL} || abort "depomd failed"

	cd ${INITRD_DIR}
	find . | cpio	\
	    --quiet			\
	    --dereference		\
	    -o -H newc | xz --check=crc32 > ${IMAGE_DIR}/initrd.xz
	[ $? -eq 0 ] || abort "initrd image creation failed"
	cd ${LIVECD_DIR}
}

create_iso() {
    	echo "generating iso image"
	genisoimage \
		-o ${LIVECD_DIR}/livecd.iso	\
		-b isolinux.bin			\
		-no-emul-boot			\
		-boot-load-size 4		\
		-boot-info-table		\
		-V "FX_LIVE"			\
		-input-charset utf-8		\
		-quiet				\
		-cache-inodes -r -J -l ${IMAGE_DIR}
	[ $? -eq 0 ] || abort "iso image creation failed"
	chmod 0644 ${LIVECD_DIR}/livecd.iso
}

create_tar() {
	cd ${IMAGE_DIR}
	tar -cf ${LIVECD_DIR}/livecd.tar .
	cd ${LIVECD_DIR}
}

create_system() {
	echo "generating live filesystem"

	mkdir -p ${FS_DIR}
	rpm --root "${FS_DIR}" --initdb

	poldek --upa --conf "${POLDEK_DIR}/poldek.conf"
	poldek --root="${FS_DIR}" --conf "${POLDEK_DIR}/poldek.conf" \
		-i ${RPM_LIST}
	[ $? -ne 0 ] && abort "packages installation failed"

	# add live user
	chroot ${FS_DIR} useradd \
		-m -G wheel,audio,video,cdrom,fsctrl,fuse,usb \
		-s "/bin/zsh" -c "Freddix user" live

	# standard password
	sed -i 's|root::|root:$2a$08$nsSd6BlyV6EHMRkLGDmrbuSvI0A6kh4hgjFuD7p2x4wt2Mq3KqW0m:|' ${FS_DIR}/etc/shadow
	sed -i 's|live:!:|live:$2a$08$r/4F0qYvXCK75MtI6GtCmeXFuDovvu/A/Pr8PLt79doQFjKRFet9W:|' ${FS_DIR}/etc/shadow

        echo 'PRETTY_HOSTNAME="Freddix Live"' > ${FS_DIR}/etc/machine-info
        echo 'ICON_NAME=' >> ${FS_DIR}/etc/machine-info
	echo "session required pam_systemd.so" >> ${FS_DIR}/etc/pam.d/system-auth

	ln -sf /proc/self/mounts ${FS_DIR}/etc/mtab
	mkdir -p ${FS_DIR}/etc/systemd/system/getty.target.wants
	ln -sf /lib/systemd/system/getty@.service \
	    ${FS_DIR}/etc/systemd/system/getty.target.wants/getty@tty1.service

	echo 'SUPPORTED_LOCALES="en_US.utf8 de_DE.utf8 pl_PL.utf8"' > ${FS_DIR}/etc/sysconfig/i18n
	echo > ${LIVECD_DIR}/config/fstab ${FS_DIR}/etc
	cp ${LIVECD_DIR}/config/hosts ${FS_DIR}/etc

	cp ${LIVECD_DIR}/config/modprobe-live.conf ${FS_DIR}/etc/modprobe.d/live.conf
	cp ${LIVECD_DIR}/config/nm-system-settings.conf ${FS_DIR}/etc/NetworkManager
	cp ${LIVECD_DIR}/config/ssh/* ${FS_DIR}/etc/ssh
	cp ${LIVECD_DIR}/config/sudoers ${FS_DIR}/etc

	mkdir -p ${FS_DIR}/root/install ${FS_DIR}/root/tmp ${FS_DIR}/mnt/livefs
	cp ${LIVECD_DIR}/config/poldek/poldek.conf ${FS_DIR}/root/install
	cp ${LIVECD_DIR}/config/*.list ${FS_DIR}/root/install
	cp -R ${LIVECD_DIR}/config/poldek/repos.d ${FS_DIR}/root/install

	chroot ${FS_DIR} localedb-gen

	#chroot ${FS_DIR} prelink -qav -mR

	chown 1000:users -R ${FS_DIR}/home/users/live
}

create_squashfs_img() {
	echo "generating squashfs image"
	mksquashfs ${FS_DIR} ${IMAGE_DIR}/fs.squashfs # -comp xz -Xbcj x86
}

if [ $(whoami) != root ]; then
    echo "use sudo Luke!"
    exit 1
fi

for package in busybox-initrd cdrkit cpio findutils gzip syslinux xz; do
	rpm -q $package > /dev/null 2>&1 || abort "$package not installed"
done

prepare
create_system
create_squashfs_img
create_boot
create_image
create_iso
create_tar

