/* netstat.c — the panel's answer to "am I on the network, and how well".
 *
 * RFC 0009 shipped WiFi and left a line on its own roadmap: "A network
 * applet in novi-panel. The desktop's status bar icons were generated
 * and left unwired precisely for want of real WiFi data." This is that
 * data source. It is deliberately a separate file from main.c: one
 * answers what the network is doing, the other draws pixels, and the
 * only thing that crosses between them is a struct net_status.
 *
 * WHICH INTERFACE IS READ, AND WHY IT IS NOT DISCOVERED HERE.
 * /run/novi/network.device and /run/novi/network.wifi.device are
 * written by the network and wifi services at start -- the resolved
 * name each one actually chose, not the `auto` spec it was asked for
 * (that is network.interface / network.wifi.interface, a different
 * file for a different question). Reading them is the whole of the
 * interface lookup.
 *
 * Walking /sys/class/net here instead would be a SECOND answer to a
 * question that already has one, and the two can disagree: RFC 0009's
 * pick_interface() prefers wired over wireless and identifies a radio
 * by the phy80211 link under /sys/class/net rather than by a name
 * starting with "wl", and RFC 0007 records what happens to code that
 * guesses -- a
 * kernel with CONFIG_IPV6_SIT creates sit0, which sorts before eth0.
 * A panel that disagreed with the service about which interface is
 * "the" interface would be worse than one with no indicator: it would
 * be confidently wrong.
 *
 * WHY NL80211 AND NOT /proc/net/wireless. That file is created by
 * cfg80211's wireless-extensions compatibility layer, and this kernel
 * sets CONFIG_CFG80211_WEXT off -- checked in kernel/config-x86_64,
 * not assumed, because the failure mode is an indicator that silently
 * shows no signal on every machine. nl80211 is the interface that
 * actually exists; libnl is already in the base image for
 * wpa_supplicant, so this adds a link, not a dependency.
 */
#include <errno.h>
#include <net/if.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>

#include <netlink/genl/genl.h>
#include <netlink/genl/ctrl.h>
#include <linux/nl80211.h>

#include "netstat.h"

#define RUN_WIRED "/run/novi/network.device"
#define RUN_WIFI  "/run/novi/network.wifi.device"

/* Reads one line, newline stripped. Returns false for anything that is
 * not a plausible interface name -- this value is about to be pasted
 * into a /sys path, and while both files are root-written, a reader
 * that validates cannot be the thing that breaks if that ever stops
 * being true. */
static bool read_ifname(const char *path, char *out, size_t n) {
	FILE *f = fopen(path, "re");
	if (f == NULL) {
		return false;
	}
	char *got = fgets(out, (int)n, f);
	fclose(f);
	if (got == NULL) {
		return false;
	}
	out[strcspn(out, "\r\n")] = '\0';
	if (out[0] == '\0') {
		return false;
	}
	for (const char *p = out; *p != '\0'; p++) {
		bool ok = (*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
			(*p >= '0' && *p <= '9') || *p == '.' || *p == '_' || *p == '-';
		if (!ok) {
			return false;
		}
	}
	return true;
}

/* /sys/class/net/<dev>/carrier, which is the kernel saying the link is
 * actually up -- 1 when an ethernet cable is in and the peer answers,
 * and for mac80211 when the interface has associated.
 *
 * Not operstate, which reports "unknown" for plenty of working
 * interfaces, and not "does the directory exist", which is true of a
 * radio nobody has connected. Reading carrier on an administratively
 * down interface fails with EINVAL rather than returning 0 -- that is
 * the kernel refusing to guess, and it lands here as "no link", which
 * is the right answer either way. */
static bool iface_has_carrier(const char *dev) {
	char path[128];
	snprintf(path, sizeof(path), "/sys/class/net/%s/carrier", dev);
	FILE *f = fopen(path, "re");
	if (f == NULL) {
		return false;
	}
	int c = fgetc(f);
	fclose(f);
	return c == '1';
}

/* ── nl80211 ──────────────────────────────────────────────────────── */

static struct nl_sock *nl_sock;
static int nl80211_id = -1;

/* Every callback below follows iw's own shape, because the dump
 * protocol has exactly one correct shape: a valid-message handler that
 * keeps the payload, and finish/error/ack handlers that clear the
 * "still running" flag so nl_recvmsgs() stops rather than waiting for
 * a message that is not coming. */
static int cb_finish(struct nl_msg *msg, void *arg) {
	(void)msg;
	*(int *)arg = 0;
	return NL_SKIP;
}

static int cb_error(struct sockaddr_nl *nla, struct nlmsgerr *err, void *arg) {
	(void)nla;
	*(int *)arg = err->error;
	return NL_STOP;
}

static int cb_ack(struct nl_msg *msg, void *arg) {
	(void)msg;
	*(int *)arg = 0;
	return NL_STOP;
}

/* NL80211_STA_INFO_SIGNAL is a signed dBm value carried in a u8, which
 * is why it is fetched as u8 and cast -- nla_get_u8 is the right
 * accessor for the attribute's width, int8_t is the right
 * interpretation of the bits. */
static int cb_station(struct nl_msg *msg, void *arg) {
	struct nlattr *tb[NL80211_ATTR_MAX + 1];
	struct nlattr *si[NL80211_STA_INFO_MAX + 1];
	static struct nla_policy policy[NL80211_STA_INFO_MAX + 1] = {
		[NL80211_STA_INFO_SIGNAL] = { .type = NLA_U8 },
	};
	struct genlmsghdr *gnlh = nlmsg_data(nlmsg_hdr(msg));

	if (nla_parse(tb, NL80211_ATTR_MAX, genlmsg_attrdata(gnlh, 0),
			genlmsg_attrlen(gnlh, 0), NULL) != 0) {
		return NL_SKIP;
	}
	if (tb[NL80211_ATTR_STA_INFO] == NULL) {
		return NL_SKIP;
	}
	if (nla_parse_nested(si, NL80211_STA_INFO_MAX,
			tb[NL80211_ATTR_STA_INFO], policy) != 0) {
		return NL_SKIP;
	}
	if (si[NL80211_STA_INFO_SIGNAL] == NULL) {
		return NL_SKIP;
	}
	*(int *)arg = (int8_t)nla_get_u8(si[NL80211_STA_INFO_SIGNAL]);
	return NL_SKIP;
}

/* Opened once and kept. genl_ctrl_resolve() fails when nl80211 is not
 * loaded, which is the ordinary state of a machine with no radio -- so
 * the resolve is retried on later calls rather than latched as a
 * permanent failure. It is only ever reached when a wireless interface
 * has already been found, so a machine without one never retries at
 * all. */
static bool nl_ready(void) {
	if (nl_sock == NULL) {
		nl_sock = nl_socket_alloc();
		if (nl_sock == NULL) {
			return false;
		}
		if (genl_connect(nl_sock) != 0) {
			nl_socket_free(nl_sock);
			nl_sock = NULL;
			return false;
		}
		/* A receive timeout, because this call sits on the Wayland
		 * event loop. A netlink dump answered by the local kernel
		 * returns in microseconds and there is no reason for it to
		 * hang -- but "no reason to hang" is not a guarantee, and the
		 * cost of being wrong is every window on the screen freezing
		 * (RFC 0017's lesson, from the other direction: there the
		 * blocking read was a pipe to a child process). 200 ms, then
		 * the indicator simply reports an unknown signal for a tick.
		 */
		struct timeval tv = { .tv_sec = 0, .tv_usec = 200000 };
		setsockopt(nl_socket_get_fd(nl_sock), SOL_SOCKET, SO_RCVTIMEO,
			&tv, sizeof(tv));
	}
	if (nl80211_id < 0) {
		nl80211_id = genl_ctrl_resolve(nl_sock, "nl80211");
	}
	return nl80211_id >= 0;
}

/* The AP's signal as seen by this station, in dBm, or 0 if unknown.
 * GET_STATION on a station-mode interface dumps exactly one station:
 * the access point. */
static int wifi_signal_dbm(const char *dev) {
	unsigned int ifindex = if_nametoindex(dev);
	if (ifindex == 0 || !nl_ready()) {
		return 0;
	}

	struct nl_msg *msg = nlmsg_alloc();
	if (msg == NULL) {
		return 0;
	}
	struct nl_cb *cb = nl_cb_alloc(NL_CB_DEFAULT);
	if (cb == NULL) {
		nlmsg_free(msg);
		return 0;
	}

	int signal = 0;
	int running = 1;
	genlmsg_put(msg, 0, 0, nl80211_id, 0, NLM_F_DUMP,
		NL80211_CMD_GET_STATION, 0);
	if (nla_put_u32(msg, NL80211_ATTR_IFINDEX, ifindex) != 0) {
		nl_cb_put(cb);
		nlmsg_free(msg);
		return 0;
	}

	nl_cb_set(cb, NL_CB_VALID, NL_CB_CUSTOM, cb_station, &signal);
	nl_cb_set(cb, NL_CB_FINISH, NL_CB_CUSTOM, cb_finish, &running);
	nl_cb_set(cb, NL_CB_ACK, NL_CB_CUSTOM, cb_ack, &running);
	nl_cb_err(cb, NL_CB_CUSTOM, cb_error, &running);

	if (nl_send_auto(nl_sock, msg) >= 0) {
		while (running > 0) {
			if (nl_recvmsgs(nl_sock, cb) < 0) {
				break; /* timeout, or a socket error -- unknown signal */
			}
		}
	}

	nl_cb_put(cb);
	nlmsg_free(msg);
	return signal;
}

/* dBm to bars. The thresholds are the ones every desktop uses because
 * they match how the link actually behaves rather than being an even
 * split of the range: -55 and better is as good as it gets, below -85
 * is a link that is about to stop working. An associated station never
 * reports zero bars -- "connected, badly" and "not connected" are
 * different states and the icon says so differently. */
static int dbm_to_bars(int dbm) {
	if (dbm == 0) {
		return 0;
	}
	if (dbm >= -55) {
		return 4;
	}
	if (dbm >= -67) {
		return 3;
	}
	if (dbm >= -75) {
		return 2;
	}
	return 1;
}

void novi_netstat_read(struct net_status *out) {
	char dev[IF_NAMESIZE + 1];

	out->kind = NET_OFFLINE;
	out->bars = 0;

	/* Wired first, matching pick_interface()'s own preference: a
	 * machine with a cable in it is using the cable, and an indicator
	 * that said otherwise would be describing a different machine. */
	if (read_ifname(RUN_WIRED, dev, sizeof(dev)) && iface_has_carrier(dev)) {
		out->kind = NET_WIRED;
		return;
	}
	if (read_ifname(RUN_WIFI, dev, sizeof(dev)) && iface_has_carrier(dev)) {
		out->kind = NET_WIFI;
		out->bars = dbm_to_bars(wifi_signal_dbm(dev));
		return;
	}
}

void novi_netstat_finish(void) {
	if (nl_sock != NULL) {
		nl_socket_free(nl_sock);
		nl_sock = NULL;
	}
	nl80211_id = -1;
}
