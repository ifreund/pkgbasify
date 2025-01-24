#!/bin/sh

# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2025 The FreeBSD Foundation
#
# This software was developed by Isaac Freund <ifreund@freebsdfoundation.org>
# under sponsorship from the FreeBSD Foundation.

# See also the pkgbase wiki page: https://wiki.freebsd.org/PkgBase

check_already_pkgbase() {
	# if pkg is not yet bootstrapped, the system cannot already be using pkgbase
	if ! pkg -N >/dev/null 2>&1; then
		return
	fi
	if pkg which /usr/bin/uname; then
		echo "The system is already using pkgbase"
		exit 1
	fi
}

confirm_risk() {
	echo "Running this tool will irreversibly modify your system to use pkgbase."
	echo "This tool and pkgbase are experimental and may result in a broken system."
	while read -p "Do you accept this risk and wish to continue? (y/n) " CONTINUE; do
		case "${CONTINUE}" in
		[yY])
			return
			;;
		[nN])
			exit 1
			;;
		esac
	done
}

# Sets $BASE_REPO_URL based on freebsd-version(1)
get_base_repo_url() {
	# e.g. 15.0-CURRENT, 14.2-STABLE, 14.1-RELEASE, 14.1-RELEASE-p6,
	local full=$(freebsd-version)
	local major_minor="${full%%-*}"
	local major="${major_minor%.*}"
	local minor="${major_minor#*.}"
	local branch_patchlevel="${full#*-}"
	local branch="${branch_patchlevel%%-*}"

	if [ "${major}" -lt 14 ]; then
		echo "Error: unsupported FreeBSD version '${full}'"
		exit 1
	fi

	case "${branch}" in
	"RELEASE")
		BASE_REPO_URL="pkg+https://pkg.FreeBSD.org/\${ABI}/base_release_${minor}"
		;;
	"CURRENT" | "STABLE")
		# TODO prompt the user to choose between latest and weekly?
		BASE_REPO_URL="pkg+https://pkg.FreeBSD.org/\${ABI}/base_latest"
		;;
	*)
		echo "Error: unsupported FreeBSD version '${full}'"
		exit 1
		;;
	esac
}

create_base_repo_conf() {
	# TODO add an option to specify an alternative directory for FreeBSD-base.conf
	CONF_DIR=/usr/local/etc/pkg/repos/
	if ! pkg config REPOS_DIR | grep "${CONF_DIR}"; then
		echo "Error: non-standard pkg REPOS_DIR config does not include ${CONF_DIR}"
		exit 1
	fi

	if [ -e "${CONF_DIR}/FreeBSD-base.conf" ]; then
		echo "Error: ${CONF_DIR}/FreeBSD-base.conf already exists"
		exit 1
	fi

	get_base_repo_url

	echo "Creating ${CONF_DIR}/FreeBSD-base.conf"
	mkdir -p "${CONF_DIR}" > /dev/null
	cat << EOF > "${CONF_DIR}/FreeBSD-base.conf"
FreeBSD-base: {
  url: "$BASE_REPO_URL",
  mirror_type: "srv",
  signature_type: "fingerprints",
  fingerprints: "/usr/share/keys/pkg",
  enabled: yes
}
EOF
}

not_dir_or_empty() {
	test -d $1 || return 0
	test -n "$(find $1 -maxdepth 0 -empty)" || return 0
	return 1
}

# Sets $PACKAGES to match the currently installed system components
# (e.g. base-dbg, lib32, lib32-dbg...)
select_packages() {
	PACKAGES=$(pkg rquery -r FreeBSD-base %n)

	# Only install FreeBSD-kernel-generic
	PACKAGES=$(echo "${PACKAGES}" | grep -vx 'FreeBSD-kernel-minimal(-dbg)?')
	PACKAGES=$(echo "${PACKAGES}" | grep -vx 'FreeBSD-kernel-generic-mmccam(-dbg)?')

	if not_dir_or_empty /usr/lib/debug/boot/kernel; then
		PACKAGES=$(echo "${PACKAGES}" | grep -vx 'FreeBSD-kernel-generic-dbg')
	fi

	# Determine if base-dbg is installed and filter accordingly
	if ! [ -e /usr/lib/debug/libexec/ld-elf.so.1.debug ]; then
		# The .*-dbg regex matches the kernel dbg package as well,
		# which we want to filter separately.
		local no_dbg=$(echo "${PACKAGES}" | grep -vx '.*-dbg')
		local kernel_dbg=$(echo "${PACKAGES}" | grep -x 'FreeBSD-kernel-generic-dbg')
		PACKAGES="${no_dbg}\n${kernel_dbg}"
	fi

	# Determine if lib32/lib32-dbg are installed and filter accordingly
	if ! [ -e /libexec/ld-elf32.so.1 ]; then
	    PACKAGES=$(echo "${PACKAGES}" | grep -vx '.*-lib32')
	elif ! [ -e /usr/lib/debug/libexec/ld-elf32.so.1.debug ]; then
	    PACKAGES=$(echo "${PACKAGES}" | grep -vx '.*dbg-lib32')
	fi

	if not_dir_or_empty /usr/src; then
		PACKAGES=$(echo "${PACKAGES}" | grep -vx 'FreeBSD-src')
	fi

	if not_dir_or_empty /usr/tests; then
		PACKAGES=$(echo "${PACKAGES}" | grep -vx '^FreeBSD-tests')
	fi
}

check_already_pkgbase
confirm_risk

if [ $(id -u) != 0 ]; then
	echo "You must be root to run this tool."
	exit 1
fi

pkg bootstrap

create_base_repo_conf

if [ $(pkg config BACKUP_LIBRARIES) != "yes" ]; then
	echo "Adding BACKUP_LIBRARIES=yes to /usr/local/etc/pkg.conf"
	echo "BACKUP_LIBRARIES=yes" >> /usr/local/etc/pkg.conf
fi

pkg update || exit 1

select_packages

pkg install -r FreeBSD-base $PACKAGES || exit 1

# XXX it may be necessary to preserve more .pkgsave files if the user has made
# extensive modifications to the base system.
# I think this should be handled in an interactive, non-destructive way and
# cover all .pkgsave files. It should also be possible to run this interactive
# part independently of this script.
#
# /etc/master.passwd and /etc/group should always be copied
# restaring the sshd service should be done only if the service is enabled/running
cp /etc/ssh/sshd_config.pkgsave /etc/ssh/sshd_config
cp /etc/master.passwd.pkgsave /etc/master.passwd
cp /etc/group.pkgsave /etc/group
pwd_mkdb -p /etc/master.passwd
service sshd restart
cp /etc/sysctl.conf.pkgsave /etc/sysctl.conf

# From https://wiki.freebsd.org/PkgBase:
# linker.hints was recreated at kernel install time, when we had .pkgsave files
# of previous modules. A new linker.hints file will be created during the next
# boot of the OS.
rm /boot/kernel/linker.hints
