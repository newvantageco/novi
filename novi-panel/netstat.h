/* netstat.h — what the network is doing, for novi-panel's indicator.
 *
 * Data only: no pixels, no Wayland. main.c turns a struct net_status
 * into an icon.
 */
#ifndef NOVI_PANEL_NETSTAT_H
#define NOVI_PANEL_NETSTAT_H

enum net_kind {
	NET_OFFLINE = 0, /* nothing carrying, or nothing to carry */
	NET_WIRED,
	NET_WIFI,
};

#define NET_BARS_MAX 4

struct net_status {
	enum net_kind kind;
	/* 1..NET_BARS_MAX for NET_WIFI. 0 means associated but the signal
	 * could not be read -- a real state (nl80211 unavailable, the
	 * station gone between the two reads) and deliberately not folded
	 * into 1, which would claim a measurement that was not made. */
	int bars;
};

/* Cheap enough to call on a 1 Hz redraw: two small reads from /run and
 * /sys, plus one netlink round trip to the local kernel when there is
 * a wireless interface to ask about. */
void novi_netstat_read(struct net_status *out);
void novi_netstat_finish(void);

#endif
