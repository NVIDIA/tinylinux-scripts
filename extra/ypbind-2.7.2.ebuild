# Copyright 1999-2020 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2

EAPI=8
inherit systemd

MY_P=${PN}-mt-${PV}
S="${WORKDIR}/${MY_P}"

DESCRIPTION="Multithreaded NIS bind service (ypbind-mt)"
HOMEPAGE="http://github.com/thkukuk/ypbind-mt"
SRC_URI="http://github.com/thkukuk/ypbind-mt/releases/download/v${PV}/${MY_P}.tar.xz"

LICENSE="GPL-2"
SLOT="0"
KEYWORDS="amd64 arm64"
IUSE="debug dbus nls slp systemd"

RDEPEND="
	debug? ( dev-libs/dmalloc )
	dbus? ( dev-libs/dbus-glib )
	slp? ( net-libs/openslp )
	systemd? (
		net-nds/rpcbind
		>=net-nds/yp-tools-2.12-r1
		sys-apps/systemd )
	!systemd? (
		net-nds/yp-tools
		|| ( net-nds/portmap net-nds/rpcbind ) )
"
DEPEND="${RDEPEND}
	nls? ( sys-devel/gettext )
"

DOC_CONTENTS="
	If you are using dhcpcd, be sure to add the -Y option to
	dhcpcd_eth0 (or eth1, etc.) to keep dhcpcd from clobbering
	/etc/yp.conf.
"

src_prepare() {
	default
	! use systemd && export ac_cv_header_systemd_sd_daemon_h=no
}

src_configure() {
	econf \
		$(use_enable nls) \
		$(use_enable slp) \
		$(use_with debug dmalloc) \
		$(use_enable dbus dbus-nm)
}

src_install() {
	default

	insinto /etc
	newins etc/yp.conf yp.conf.example

	#newconfd "${FILESDIR}/ypbind.confd-r1" ypbind
	#newinitd "${FILESDIR}/ypbind.initd" ypbind
	#use systemd && systemd_dounit "${FILESDIR}/ypbind.service"
}
