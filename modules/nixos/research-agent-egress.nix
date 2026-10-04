{ config, lib, ... }:
# research-agent GUEST egress policy: an IP allowlist that DNS fills in.
#
# Imported by the guest config in research-agent-microvm.nix, and by the
# `agent` node of tests/microvm.nix, which runs this exact module against
# a fake upstream to prove the runtime behaviour (see that file).
#
# How it works:
#
#   agent process ─getaddrinfo─▶ systemd-resolved stub (127.0.0.53)
#     ─▶ dnsmasq (127.0.0.1:53) ─▶ upstream (SLIRP resolver 10.0.2.3)
#
# dnsmasq's `nftset=` directive inserts every IPv4 address in the answer
# to a query for an allowlisted name into `inet filter research_allowed`
# BEFORE it hands the answer back. So an address becomes connectable at
# the exact moment the agent learns it, whatever the CDN did since boot.
#
# Why (2026-10-02): api.ebay.com (then allowlisted here; since 2026-10
# reached through the host broker instead) is a CNAME chain onto Akamai
# (e333426.a.akamaiedge.net) with 8-29 s A-record TTLs; the whole answer
# set turned over inside 30 s. The previous design resolved the
# allowlist with getent at boot (egress-init) and every 10 min
# (egress-refresh), so the agent was almost always handed an address the
# set had never seen — policy=drop blackholed it and `ebay_search` died
# with `network error: TimeoutError`. No refresh interval fixes that;
# only resolving and allowing in the same step does.
#
# Load-bearing details:
#
#   - CNAME chains: dnsmasq picks the set by the QUESTION name, then adds
#     every A record in the answer, including the ones owned by the CNAME
#     targets (forward.c process_reply → rfc1035.c extract_addresses).
#     So only the name the agent asks for has to be listed. Matching is
#     suffix-wise: `api.anthropic.com` also covers `*.api.anthropic.com` — names
#     under the same owner, and much narrower than what any CDN IP
#     allowlist already implies (an Akamai edge IP serves every Akamai
#     customer by SNI).
#   - No caching anywhere on the path (dnsmasq cache-size=0, resolved
#     Cache=no). dnsmasq only touches the set on an UPSTREAM reply, never
#     on a cache hit; with caching, a set emptied by an nftables reload
#     would stay empty for any name still cached. Uncached, every lookup
#     re-inserts, so the set heals itself on the next lookup however it
#     got emptied. The lookups are loopback + one SLIRP hop to the host,
#     whose own resolver caches.
#   - No element timeouts. Measured on this kernel (6.18): `add element`
#     on an existing element does NOT refresh its timeout, and dnsmasq
#     only ever issues plain `add element`. With a timeout, an address in
#     continuous use would expire on schedule while clients still hold it
#     (libcurl caches DNS for 60 s) — the same silent drop this design
#     removes. The set therefore only grows, bounded by guest uptime and
#     holding only addresses an allowlisted name actually resolved to;
#     it resets on every VM boot.
#   - Every lookup must go through dnsmasq. resolved's only server is
#     127.0.0.1; the guest's uplink must not hand resolved a per-link DNS
#     server (research-agent-microvm.nix sets UseDNS=false), or resolved
#     would also ask 10.0.2.3 directly and its answers would never reach
#     the set. Fail-closed if it ever happens: the address is simply not
#     allowed. resolved stays (rather than pointing resolv.conf straight
#     at dnsmasq) because the agent jail (research-agent
#     scripts/run-agent.sh) bind-mounts /run/systemd/resolve.
#   - DNS is allowlisted too (2026-10-02). dnsmasq forwards a query
#     upstream ONLY if its name is under an allowlisted domain (one
#     `server=/<domain>/<upstream>` per entry, rendered from the same
#     list as nftset); every other name (`address=/#/`, the catch-all
#     that the longer `server=` matches beat) is answered NXDOMAIN
#     locally and never leaves the guest. Before, any name was
#     forwarded, so data encoded in query labels (`<secret>.attacker.
#     tld`) reached whatever nameserver was authoritative for a name the
#     agent invented. AAAA and PTR follow the same rule: forwarded only
#     for allowlisted names, NXDOMAIN otherwise. Residual: labels UNDER
#     an allowlisted domain (`x.api.anthropic.com`) are still forwarded,
#     because matching is suffix-wise (as for nftset) — they reach only
#     that domain owner's own nameservers, not an attacker's.
#   - Only dnsmasq may talk to the upstream resolver. The port-53 rule
#     is pinned to dnsmasq's uid (`meta skuid`), so a guest process
#     cannot skip the filter above by sending its query to the upstream
#     directly.
#   - IPv4 only, as before: the set is ipv4_addr, nftset is tagged `4#`,
#     and research-agent-microvm.nix disables IPv6 in the guest.
let
  cfg = config.researchAgent.egress;

  # Egress allowlist — SINGLE SOURCE OF TRUTH. Rendered into dnsmasq's
  # per-domain `server=` forwards and its nftset directive below; nothing
  # else consumes it.
  egressAllowlist = [
    "api.anthropic.com"
    # Codex fallback endpoints: ChatGPT sessions call chatgpt.com and
    # refresh managed OAuth tokens through auth.openai.com. The host
    # loader also accepts Codex's OPENAI_API_KEY auth shape, whose
    # responses endpoint is api.openai.com.
    "chatgpt.com"
    "auth.openai.com"
    "api.openai.com"
    # Keyless bulk open-data sources. Neither takes a model-authored URL
    # or query (the shims fetch fixed bulk files) and neither holds a
    # key, so they stay direct rather than going through the broker
    # (research-agent docs/egress-broker.md §0.2).
    # Bolagsverket open-data bulk file (CC-BY, weekly refresh):
    "vardefulla-datamangder.bolagsverket.se"
    # PRV open-data FTP (Swedish national trademark register;
    # sanctioned bulk channel used by prv_shim).
    "opendata.prv.se"
    # NOT here, on purpose (2026-10, egress broker): the keyed APIs —
    # api.exa.ai, mcp.exa.ai, api.tavily.com, mcp.tavily.com, the EUIPO
    # hosts, api.ebay.com, api.tradera.com. The guest holds none of
    # their keys any more; the host's research-broker calls them and
    # the guest reaches it at 10.0.2.2:8124 (output chain below).
  ];
in
{
  options.researchAgent.egress.upstreamDns = lib.mkOption {
    type = lib.types.str;
    # qemu user-mode (SLIRP) networking's built-in resolver.
    default = "10.0.2.3";
    description = ''
      The DNS server dnsmasq forwards to. Every answer from it for an
      allowlisted name opens egress to the returned addresses.
    '';
  };

  config = {
    networking.nftables = {
      enable = true;
      ruleset = ''
        table inet filter {
          # Filled at resolution time by dnsmasq (nftset= below).
          set research_allowed {
            type ipv4_addr
            flags interval
          }

          chain input {
            type filter hook input priority 0; policy drop;
            iif lo accept
            ct state established,related accept
            tcp dport 22 accept
          }

          chain output {
            type filter hook output priority 0; policy drop;
            oif lo accept
            ct state established,related accept
            # DNS only to the one upstream, and only from dnsmasq
            # (everything local reaches dnsmasq over lo). A bare
            # `dport 53 accept` would be a raw TCP/UDP pipe to any
            # address on :53, around the allowlist entirely; without
            # skuid, any guest process could query the upstream directly
            # and skip dnsmasq's name allowlist (see header).
            ip daddr ${cfg.upstreamDns} udp dport 53 meta skuid "dnsmasq" accept
            ip daddr ${cfg.upstreamDns} tcp dport 53 meta skuid "dnsmasq" accept
            ip daddr @research_allowed tcp dport 443 accept
            # research-broker (modules/nixos/research-broker.nix).
            # 10.0.2.2 is the SLIRP host gateway from inside this VM
            # (qemu user-mode default) and maps to host loopback, where
            # research-broker.socket listens on 127.0.0.1:8124. This is
            # the guest's only path to the keyed APIs AND to the scraper:
            # the scraper's host port (8123) is deliberately not opened,
            # so every render goes through the broker's URL gate.
            ip daddr 10.0.2.2 tcp dport 8124 accept
          }
        }
      '';
      # The build-time ruleset check runs in a sandbox with no dnsmasq
      # user; check the same ruleset against one that exists there.
      preCheckRuleset = ''
        sed -i 's/skuid "dnsmasq"/skuid "root"/g' ruleset.conf
      '';
    };

    # resolved forwards to dnsmasq and nothing else, and never answers
    # from a cache (see header).
    networking.nameservers = [ "127.0.0.1" ];
    services.resolved = {
      enable = true;
      settings.Resolve = {
        Cache = "no";
        # An empty FallbackDNS disables systemd's compiled-in public
        # resolvers, which resolved would otherwise query directly —
        # bypassing dnsmasq — whenever it believes it has no DNS server.
        FallbackDNS = "";
      };
    };

    services.dnsmasq = {
      enable = true;
      # We wire resolv.conf/resolved ourselves; this option would route
      # dnsmasq's upstreams through resolvconf instead of `server` below.
      resolveLocalQueries = false;
      settings = {
        listen-address = "127.0.0.1";
        bind-interfaces = true;
        no-resolv = true;
        no-poll = true;
        # Forward ONLY allowlisted domains; answer every other name
        # NXDOMAIN without asking anyone (see header). dnsmasq picks the
        # longest matching domain, so each `server=` beats `/#/`.
        server = map (domain: "/${domain}/${cfg.upstreamDns}") egressAllowlist;
        address = [ "/#/" ];
        cache-size = 0;
        nftset = [
          "/${lib.concatStringsSep "/" egressAllowlist}/4#inet#filter#research_allowed"
        ];
        # One journal line per inserted address — the audit trail of what
        # egress was opened and for which allowlisted name.
        log-queries = true;
      };
    };

    # The set must exist before the first answer arrives, or the insert
    # fails (logged) and the agent is handed an address it can't reach.
    # Requires= also takes dnsmasq down with nftables: no resolver
    # answers while the ruleset is absent.
    systemd.services.dnsmasq = {
      after = [ "nftables.service" ];
      requires = [ "nftables.service" ];
    };
  };
}
