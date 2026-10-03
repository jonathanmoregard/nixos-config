{ ... }:
# Scraper guest egress: everything public, nothing local.
#
# The scraper's chromium must reach arbitrary public URLs, so its output is
# open on purpose. But it sits behind QEMU SLIRP, where the gateway
# 10.0.2.2 IS THE HOST'S LOOPBACK: before this table, any page the scraper
# rendered (or a render_page URL pointing at 10.0.2.2:<port>) could talk to
# every service listening on the host's 127.0.0.1. The URL gate in
# research-agent scraper/netguard.py refuses those destinations too, but it
# cannot see redirect hops reliably, DNS rebinding, websockets or page JS;
# this chain can, so it is the hard boundary and the Python gate the
# early, explained refusal.
#
# Only NEW connections are refused: replies on connections that came IN
# (the host's hostfwd to :8000 and :22 arrives from 10.0.2.2) are
# established and pass. SLIRP's DNS (10.0.2.3) and DHCP (on 10.0.2.2) stay
# reachable. Output-only table with policy accept, so it cannot drop the
# inbound :8000 SYNs the way the 2026-07-11 custom input chain did.
#
# Imported by the scraper guest (scraper-microvm.nix) and by the vm-microvm
# test lane, which runs it on a node with SLIRP's addresses.
{
  networking.nftables.enable = true;
  networking.nftables.tables.scraper-egress = {
    # inet, not ip: the guest's SLIRP NIC carries IPv6 (fec0::/64 by RA)
    # even with networking.enableIPv6 = false, and SLIRP maps fec0::2 to
    # the HOST's ::1 just as 10.0.2.2 maps to 127.0.0.1.
    family = "inet";
    content = ''
      chain output {
        type filter hook output priority filter; policy accept;
        ct state established,related accept
        oifname "lo" accept
        ip daddr 10.0.2.3 meta l4proto { tcp, udp } th dport 53 accept
        ip daddr 10.0.2.2 udp dport 67 accept
        # SLIRP's v6 DNS: resolved lists it beside 10.0.2.3 on the link.
        ip6 daddr fec0::3 meta l4proto { tcp, udp } th dport 53 accept
        ip daddr {
          0.0.0.0/8,
          10.0.0.0/8,
          100.64.0.0/10,
          169.254.0.0/16,
          172.16.0.0/12,
          192.168.0.0/16
        } counter reject
        # IPv6: nothing new leaves the guest. It is meant to be IPv4-only,
        # and SLIRP's v6 reaches host-local ground (fec0::2 = host ::1,
        # the host's ULA and tailscale addresses). Public egress is
        # carried by IPv4; chromium falls back on the immediate reject.
        # TCP/UDP only, so ICMPv6 neighbour discovery is left alone.
        meta nfproto ipv6 meta l4proto { tcp, udp } counter reject
      }
    '';
  };
}
