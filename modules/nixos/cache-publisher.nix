{ config, lib, pkgs, ... }:
# cache-publisher: push locally built outputs of PUBLIC GitHub repos to the
# public jonathanmoregard Cachix cache. Replaces the global post-build-hook
# (removed in #311), which pushed every local build and leaked private
# Klaffat outputs.
#
# Provenance is established forwards, never by looking at store paths (the
# store records no repo of origin):
#   - the global git pre-push hook (home/cache-publisher-enqueue.nix) and an
#     hourly scan of ~/Repos + ~/worktrees only drop `owner/repo sha` lines
#     into a spool; jonathan can write the spool but not list or read it;
#   - the publisher (scripts/cache-publisher.py), running as the dedicated
#     cache-publisher user, re-derives everything from GitHub. Each gate
#     defaults to SKIP:
#       a. anonymous GET /repos/o/r: 200 + private=false + visibility=public
#          (a private repo answers 404 to anonymous callers, so this fails
#          closed even when misconfigured)
#       b. the commit is anonymously fetchable (else retry, expire in 48 h)
#       c. evaluation happens in a separate, initially empty Nix store
#          (/var/lib/cache-publisher/evalstore) with no access tokens, no
#          netrc, cache.nixos.org as the only substituter, pure + restricted
#          eval (allowed-uris: github:/GitHub/nixos.org only, so no file://
#          or path: import of host files), IFD off, and no route to
#          loopback/LAN/tailnet: it can only see what anyone can download.
#          `nix flake
#          metadata github:o/r/<sha>` there; every lock input must be a public github/https
#          GitHub input at a public rev, or an allowlisted tarball; path,
#          git+ssh, git+file, indirect and unlocked inputs reject. No
#          flake.nix → nothing to publish (also how plain JS/text repos drop
#          out).
#       d. output paths read from each candidate DERIVATION in the anonymous
#          store — never the outPath the flake's attrset stated. The two are
#          independent: a derivation-shaped attrset may pair a harmless
#          drvPath with any string as its outPath, and pure evaluation accepts
#          it (a literal instantiates nothing), which would leave gate (e)
#          auditing one recipe while a different path was uploaded. Of the
#          derivation's own outputs, those valid locally, built here, not
#          fixed-output, not on cache.nixos.org, with > 1 MiB of closure
#          cache.nixos.org lacks (the "compiled code" heuristic).
#          Input-addressed paths hash the whole recipe, so a local path equal
#          to one the anonymous derivation declares was built from exactly
#          that public recipe.
#          Nothing built locally yet is a "not yet", not a "no": the commit
#          stays queued for retry rather than being retired, because the
#          pre-push hook enqueues on push, which routinely beats the build.
#       e. build-graph audit in the anonymous store: every fixed-output
#          derivation is either served by cache.nixos.org or downloaded right
#          now, anonymously, into that store (Nix checks the hash). A URL is
#          never proof: downstream paths depend on a FOD's hash, not its URL,
#          so a hash of private bytes behind a public-looking URL would
#          otherwise pass. __noChroot/__impure derivations reject.
#       f. right before `cachix push --omit-deriver`: the repo, the commit
#          and every GitHub lock input at its locked rev, all re-asked of
#          GitHub uncached
#   - the Cachix token is readable only by cache-publisher (not jonathan,
#     not any agent running as jonathan).
#
# Queue mechanics (scripts/cache-publisher.py; the code names these
# invariants rather than restating the arguments):
#   - One boundary. The gates abort from depth with Skip/Retry/RateLimited;
#     `decide` converts every one of them into a single explicit Outcome
#     (finished / retry / published-but-incomplete) and the queue reads only
#     that. Nothing infers state from an exception type or a log line.
#   - One transition. Everything not finished counts an attempt, then either
#     expires or reschedules. Rate limiting is the same transition with its
#     own next-attempt time, plus a halt for the rest of the run; it had its
#     own branch once, which is how it came to skip the count and the expiry
#     and park an entry at the head of a sorted queue forever.
#   - Anything unexpected degrades to retry, never to publish: entries are
#     processed in sorted order, so one entry that always raises would starve
#     every entry behind it, and a repo owner may begin with a digit.
#   - Availability is not a verdict. "Not built locally yet" keeps an entry
#     queued; only a built-and-rejected answer retires it. `done` is consulted
#     before a spool entry becomes pending, so retiring early would discard
#     every later entry for that sha.
#   - The preliminary lock-input answers are cached (positives only) and
#     persist across runs, because 4+4n anonymous API requests per entry
#     against GitHub's 60/h cannot finish a many-input flake in one window.
#     Gate (f) never consults that cache.
#
# Residual risks (by design, documented rather than gated):
#   - a candidate drvPath naming a derivation left in the day-lived eval
#     store by an EARLIER entry is audited as that entry's repo, without
#     re-running its own gate (a)/(b)/(f). Bounded to bytes that were public
#     when evaluated — the same class as the flip-after-push item below. A
#     per-entry eval store would close it, at the cost of every eval and
#     fixed-output download being repeated;
#   - `allowed-uris` matches the `github:` input TYPE, so builtins.fetchTree
#     with a `host` attribute can issue one unauthenticated HTTPS GET from
#     this machine's IP. audit_lock rejects host != github.com for lock
#     inputs; the builtin path is not gated. CONFIRMED, not inferred: under
#     this module's own NIX_CONFIG_FRESH, `fetchTree { type = "github";
#     host = "gitlab.example.com"; }` reached DNS resolution of that host
#     rather than being refused by policy. A bare IP or host:port is rejected
#     by nix itself ("invalid instance host"), and IPAddressDeny still blocks
#     loopback/LAN/tailnet, so the reachable set is public hosts only;
#   - a bug in the audit code itself (tests/cache-publisher/*);
#   - secrets committed to a public repo end up in its outputs — repo
#     hygiene, not a cache problem;
#   - the local build's sandbox: a local output equals the anonymous
#     recipe's path, and the recipe consumed only public bytes, but the
#     bytes were produced by this host's builder. nix.settings.sandbox is
#     asserted on and only root may override it (trusted-users), so this
#     is down to a sandbox escape; rebuilding every output anonymously to
#     compare would close it at the cost of compiling everything twice;
#   - the publisher's own sandbox-paths/nix.conf beyond what
#     NIX_CONFIG_FRESH pins are inherited from this host's nix.conf;
#   - an output pushed while the repo was public stays fetchable after a
#     later public→private flip (clients also cache narinfos).
#
# Withdrawn from that list, because it was measured and found false: "'http
# error 403' is absent from TRANSIENT, so a rate-limited fetch inside nix
# retires a sha permanently". On nix 2.34.9 a `github:` archive fetch reports
# its status inside "Failed to open archive (Source threw exception: error:
# unable to download ...: HTTP error 403)", and the "unable to download"
# prefix already classifies that as transient — so the dominant 403 path, the
# one anonymous rate limiting actually takes, always retried. The shape that
# genuinely escaped carried no status at all ("Failed to fetch git
# repository") and is now in TRANSIENT. Both are pinned by tests. Recorded
# here because a plausible-sounding risk that prose alone would keep
# re-proposing is worth refuting once, in writing.
let
  cfg = config.services.cache-publisher;
  base = "/var/lib/cache-publisher";
  spool = "${base}/queue";
  py = "${pkgs.python3}/bin/python3";
  script = ../../scripts/cache-publisher.py;
  home = config.users.users.jonathan.home;
  # Public resolvers for the publisher's mount namespace: the host's DNS is
  # Tailscale's 100.100.100.100, an address inside a range the publisher
  # must not reach (see IPAddressDeny).
  publicResolv = pkgs.writeText "cache-publisher-resolv.conf" ''
    nameserver 9.9.9.9
    nameserver 149.112.112.112
    nameserver 2620:fe::fe
  '';
  common = {
    CP_SPOOL = spool;
    CP_STATE = "${base}/state";
    CP_CACHE = "jonathanmoregard";
    CP_SYSTEM = pkgs.stdenv.hostPlatform.system;
  };
  # No /proc- or /dev-masking options (PrivateDevices, ProtectKernel*,
  # ProtectControlGroups): the publisher realises fixed-output derivations
  # in its own store, and the Nix build sandbox then cannot mount /proc
  # ("Mount too revealing"). vm-cache-publisher builds a FOD under exactly
  # these settings.
  hardening = {
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    PrivateTmp = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" "AF_NETLINK" ];
  };
in
{
  options.services.cache-publisher.tokenFile = lib.mkOption {
    type = lib.types.str;
    default = config.age.secrets.cachix-push-token.path;
    defaultText = lib.literalExpression "config.age.secrets.cachix-push-token.path";
    description = "Cachix write token for the cache, readable only by cache-publisher.";
  };

  config = {
    # Gate (d) trusts that a local output with the anonymous recipe's path
    # holds only what that recipe can produce. That needs every local build
    # sandboxed: no host files, no network outside fixed-output fetches.
    assertions = [{
      assertion = config.nix.settings.sandbox == true;
      message = "cache-publisher requires nix.settings.sandbox = true: unsandboxed local builds could embed host state in outputs it publishes.";
    }];

    users.groups.cache-publisher = { };
    users.groups.cache-spool = { };
    users.users.cache-publisher = {
      isSystemUser = true;
      group = "cache-publisher";
      extraGroups = [ "cache-spool" ];
      home = base;
    };
    users.users.jonathan.extraGroups = [ "cache-spool" ];

    # queue: setgid + sticky, group may create (w+x) but not list (no r).
    systemd.tmpfiles.rules = [
      "d ${base} 0711 cache-publisher cache-publisher -"
      "d ${spool} 3730 cache-publisher cache-spool -"
      "d ${base}/state 0700 cache-publisher cache-publisher -"
    ];

    systemd.services.cache-publisher = {
      description = "Push public GitHub repos' local Nix builds to the public Cachix cache";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = [ config.nix.package pkgs.cachix ];
      environment = common // {
        CP_TOKEN_FILE = cfg.tokenFile;
        HOME = base;
      };
      serviceConfig = hardening // {
        Type = "oneshot";
        User = "cache-publisher";
        # "Anonymous" must also mean "from outside": an evaluation-time fetch
        # or fixed-output build (they run in this cgroup) must not reach
        # loopback, the LAN or the tailnet, where unauthenticated private
        # artifacts could live. Only the public internet answers.
        IPAddressDeny = [
          "localhost" "link-local" "multicast"
          "0.0.0.0/8" "10.0.0.0/8" "100.64.0.0/10" "172.16.0.0/12" "192.168.0.0/16"
          "fc00::/7"
        ];
        BindReadOnlyPaths = [ "${publicResolv}:/etc/resolv.conf" ];
        Group = "cache-publisher";
        ExecStart = "${py} ${script} run";
        ProtectHome = true;
        ReadWritePaths = [ base ];
        MemoryMax = "2G";
        Nice = 10;
        IOSchedulingClass = "idle";
        TimeoutStartSec = "2h";
      };
    };

    # New spool entries start a run; the timer retries deferred entries.
    # PathChanged, not DirectoryNotEmpty: an entry the publisher cannot
    # remove (a directory jonathan made) must not re-trigger it forever.
    systemd.paths.cache-publisher = {
      wantedBy = [ "multi-user.target" ];
      pathConfig.PathChanged = spool;
    };
    systemd.timers.cache-publisher = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitInactiveSec = "15min";
      };
    };

    # Safety net for pushes that skipped the hook (--no-verify, GUI clients).
    systemd.services.cache-publisher-scan = {
      description = "Enqueue pushed HEADs of local GitHub checkouts for cache-publisher";
      path = [ pkgs.git ];
      environment = common // {
        CP_SCAN_ROOTS = "${home}/Repos ${home}/worktrees ${home}/Repos/nixos-config-worktrees";
      };
      serviceConfig = hardening // {
        Type = "oneshot";
        User = "jonathan";
        ExecStart = "${py} ${script} scan";
        ProtectHome = "read-only";
        ReadWritePaths = [ spool ];
        MemoryMax = "256M";
        Nice = 10;
      };
    };
    systemd.timers.cache-publisher-scan = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "15min";
        OnUnitActiveSec = "1h";
      };
    };
  };
}
