# modules/nixos/claude-runtime-deploy.nix
#
# Continuous delivery for the tree that ~/.claude is SERVED FROM, kept
# deliberately separate from the tree it is DEVELOPED IN.
#
# WHY THIS EXISTS
#
# claude-runtime-mounts.nix projects a runtime subset of the claude-config
# repository into ~/.claude with read-only bind mounts. Until this module, the
# source of those mounts was ~/Repos/claude-config — a DEV checkout. Jonathan's
# objection, 2026-10-27, and it is correct: "In my mind, Repos/claude-config is
# the dev version, and .claude is the deployed artefact. Real weird for
# production to depend on dev." Concretely: a `git switch`, a half-finished
# edit or an interrupted `git submodule update` in that checkout changed what
# every running agent read, instantly, with no deploy step and nothing to roll
# back to.
#
# So the serving source moves here, to a clone that only this unit writes:
#
#   /var/lib/claude-runtime/checkout   the served tree, owned by claude-deploy
#   /var/lib/claude-runtime/state      claude-pull's health records, 0755 so
#                                      jonathan's SessionStart hook can read
#                                      them without reaching into a .git dir
#
# ~/Repos/claude-config goes back to being purely a development checkout: it is
# where worktrees are cut and PRs are made, and nothing reads it at runtime.
#
# WHY A DEDICATED SYSTEM USER RATHER THAN ROOT
#
# Against jonathan — and against the agents that run as him — root and
# claude-deploy are the SAME discretionary access control: neither is writable
# by him, both serve content he can only read. The difference is upstream: this
# unit fetches from the network and then runs `git submodule update`, and root
# is not the identity that should be doing that. Keeping the fetch unprivileged
# is ordinary systemd practice and costs nothing here, because the repository
# is PUBLIC and the deployer therefore needs no credentials at all.
#
# `DynamicUser` was considered and rejected: it can re-chown its StateDirectory
# on every start, and this tree is ~128 MB with two submodules.
#
# The precedent on this host points the other way — nixos-deploy.service
# fetches as root — and that is NOT a justification, per the directive Jonathan
# set the same day: measured empirics first, then researched best practice,
# then existing patterns in these repos, and "an existing pattern is NOT a
# justification; it is at most a data point, and may itself be the thing that
# needs changing". The same fetch/apply split is worth doing for /etc/nixos and
# is filed as its own issue; activation genuinely needs root, the fetch does
# not.
#
# WHY THE EXEC'D SCRIPT IS NOT %h/.claude/scripts/claude-pull.sh
#
# The user unit this replaces ran exactly that (home/claude-services.nix), and
# carrying it into a system unit would have been a privilege escalation with
# extra steps: `%h` expands to the SERVICE MANAGER's home and ignores `User=`,
# and ~/.claude/scripts is a jonathan-owned symlink. Retarget that symlink —
# an agent can, it is in his own home — and the deployer executes
# agent-authored code, which then has write access to the serving tree this
# module exists to protect. Found by review, 2026-10-27.
#
# What runs instead is a store-pinned wrapper that does the one thing the
# served tree cannot do for itself (bootstrap its own clone) and then execs
# the puller FROM THE DEPLOY TREE at an absolute path, after checking that the
# file is owned by this unit's own user and not group- or world-writable. That
# keeps the 400-line puller where it is maintained and tested — in
# claude-config, iterating on its own cadence without a rebuild per tweak,
# which is why it was never pinned into the store — while removing every path
# jonathan can influence from the exec chain.
#
# WHAT THIS IS NOT
#
# It is not enforcement against Jonathan, and nothing here should be read as
# claiming otherwise. ~/.claude stays his: he can move it aside (bind mounts
# travel with a rename), replace a per-entry symlink with a real directory (the
# links unit is non-clobbering by design and will report it, not fight it), and
# settings.json stays writable. Unprivileged user namespaces are available on
# this host (/proc/sys/user/max_user_namespaces = 253489, measured), so a
# process running as him can shadow any of these paths for its own children.
# What this module buys is that the SERVING TREE no longer moves by accident,
# by a mis-aimed agent, or by a dev-side git operation — which is the failure
# mode that actually happens. Closing the rest needs ~/.claude outside his DAC
# plus managed settings, which is deployment-channel work and explicitly out of
# scope.
{ config, lib, pkgs, ... }:

let
  # The consumer of the projection. Named once: the state directory has to be
  # readable by this user, and the assertion below checks they exist.
  consumer = "jonathan";

  deployUser = "claude-deploy";

  runtimeRoot = "/var/lib/claude-runtime";
  checkout = "${runtimeRoot}/checkout";
  stateRoot = "${runtimeRoot}/state";

  # HTTPS rather than SSH precisely because the repository is public: an
  # unauthenticated fetch means this unit holds no credential, so there is no
  # key to leak and nothing to rotate. A fetch that suddenly needs auth is a
  # sign the remote changed, and should fail rather than silently find a key.
  remote = "https://github.com/jonathanmoregard/claude-config.git";

  # The puller inside the served tree. Relative so the path appears once.
  pullerRelative = "runtime/scripts/claude-pull.sh";

  deployScript = pkgs.writeShellApplication {
    name = "claude-runtime-deploy";
    # These are the PULLER's dependencies as much as this wrapper's, and the
    # list is not guesswork: a systemd SYSTEM service does not get
    # /run/current-system/sw/bin on PATH. Measured in the feature VM
    # 2026-10-27 — the inherited default is systemd's compiled-in set
    # (e2fsprogs, btrfs-progs, dosfstools, util-linux-MINIMAL, openssh,
    # systemd), and util-linux-minimal ships no `flock`. util-linux is here for
    # that one binary; gnused and gnugrep because the puller uses them on its
    # normal path; python3 because its settings-carry branch is otherwise
    # skipped by a `command -v` guard, which is a silent change in behaviour
    # rather than an error.
    runtimeInputs = with pkgs; [
      bash
      coreutils
      git
      openssh
      util-linux
      gnused
      gnugrep
      python3
      # getent is its own derivation, not part of coreutils or glibc's bin
      # output here. The puller's offline probe is `timeout 5 getent ahosts
      # github.com`, and a 127 from that reads as "this host is offline": the
      # tick exits 0 AND skips the counter behind the six-strike
      # fetch-failure alert, so a broken remote on an online host would be
      # unreportable. Found in review 2026-10-28, same shape as flock.
      getent
    ];
    text = ''
      # 0755/0644 on everything written here, and that is load-bearing rather
      # than tidy: claude-runtime-links.service runs as ${consumer} and its
      # `-e` tests traverse THIS path, so a 0750 directory anywhere under
      # ${runtimeRoot} makes the projection look half-built and the links unit
      # refuse with exit 75.
      umask 022

      # No global git config, no credential prompts, no reading jonathan's
      # ~/.gitconfig through some inherited HOME. The puller is generic over
      # its target; everything it needs is passed explicitly below.
      export GIT_CONFIG_GLOBAL=/dev/null
      export GIT_TERMINAL_PROMPT=0
      export HOME=${runtimeRoot}

      # NixOS puts no CA bundle in a service's environment, and git over HTTPS
      # needs one. Naming it explicitly is cheaper than the class of failure
      # where a fetch works interactively and fails under systemd — the shape
      # that broke every injection-scanner call site when stdlib urllib needed
      # SSL_CERT_FILE.
      export GIT_SSL_CAINFO=/etc/ssl/certs/ca-bundle.crt

      # Overridable so the vm-base lane can drive this script FOR REAL against
      # a local bare repository over file://, offline, instead of asserting on
      # its text. Same seam the links script already exposes (its own
      # positional-argument default), and
      # for the same reason: a test-only branch inside production code is worse
      # than a parameter. Production passes none of these.
      checkout=''${CLAUDE_RUNTIME_DEPLOY_CHECKOUT:-${lib.escapeShellArg checkout}}
      state_root=''${CLAUDE_RUNTIME_DEPLOY_STATE:-${lib.escapeShellArg stateRoot}}
      remote=''${CLAUDE_RUNTIME_DEPLOY_REMOTE:-${lib.escapeShellArg remote}}
      puller="$checkout"/${lib.escapeShellArg pullerRelative}

      log() { printf 'claude-runtime-deploy: %s\n' "$*"; }

      # ── Bootstrap ────────────────────────────────────────────────────────
      #
      # The one thing the served tree cannot do for itself. Everything after
      # this point is the tree's own puller.
      if [ ! -e "$checkout/.git" ]; then
        # A non-empty directory that is not a checkout is somebody else's
        # content, or the wreckage of a failed clone. Cloning "into" it would
        # either fail obscurely or, worse, succeed against a tree nobody
        # placed deliberately. Refuse and say which.
        #
        # This refusal cannot be triggered by an ordinary failed tick: git
        # removes a destination directory it created when the clone fails
        # (measured 2026-10-27, non-repo file:// remote → "dest exists: no"),
        # and the vm-base lane asserts it after the offline boot attempt. A
        # clone killed outright (SIGKILL, power loss) can still leave a partial
        # tree, which is why this says the path out loud: the fix is to remove
        # that tree, and the operator should not have to guess which one.
        if [ -e "$checkout" ] && [ -n "$(ls -A "$checkout" 2>/dev/null)" ]; then
          log "$checkout exists, is not a git checkout, and is not empty; refusing to clone over it"
          exit 75
        fi
        log "no checkout at $checkout; cloning $remote"
        # --recurse-submodules because vendor/superpowers and
        # vendor/everything-claude-code are part of the SERVED set: skills
        # resolve through them, so an un-initialised submodule is missing
        # skills rather than a cosmetic gap.
        git clone --recurse-submodules "$remote" "$checkout"
        log "clone complete: $(git -C "$checkout" rev-parse --short HEAD)"
      fi

      # ── Refuse to exec anything jonathan could have written ──────────────
      #
      # The whole point of this unit is that the serving tree is not
      # influenced by the user whose agents read it. Exec'ing a script out of
      # that tree is only safe while the tree's own ownership holds, so check
      # it rather than assume it. `-O` is "owned by the effective uid", which
      # under User=${deployUser} is exactly the question worth asking.
      if [ ! -f "$puller" ]; then
        log "$puller is missing — the checkout is half-built; refusing"
        exit 75
      fi
      if [ ! -O "$puller" ] || [ ! -O "$checkout" ]; then
        log "$puller or $checkout is not owned by this unit's user; refusing to execute it"
        exit 75
      fi
      # Octal rather than the symbolic `%A` string, which is easy to match
      # wrongly: 022 is exactly group-write plus other-write, whatever the
      # rest of the mode says.
      puller_mode=$(stat -c '%a' "$puller")
      if [ $((8#$puller_mode & 8#022)) -ne 0 ]; then
        log "$puller is group- or world-writable (mode $puller_mode); refusing to execute it"
        exit 75
      fi

      # ── Refuse to hand over into a PATH that cannot run the puller ───────
      #
      # Found by driving this for real in the feature VM, 2026-10-27, and the
      # shape of the failure is the reason this check exists rather than a
      # comment. With `flock` absent the puller logged
      #
      #   claude-pull.sh: line 164: flock: command not found
      #   claude-pull: another sync/pull run holds the lock; skipping tick
      #
      # and the unit reported SUCCESS. `flock -n` not found exits 127, the
      # puller treats any non-zero as "someone else holds the lock" and exits
      # 0, so every tick for the rest of time would have skipped while
      # systemd, the health record and `systemctl status` all said fine — the
      # exact wrong-content-served-while-green shape this whole split exists
      # to prevent, arrived at through a missing binary.
      #
      # Review then found the same shape a second time, in the puller's offline
      # probe: a missing `getent` makes `timeout 5 getent ahosts` fail, which
      # that branch reads as "the host is offline" — exit 0, and the
      # consecutive-failure counter behind the six-strike alert never written,
      # so a broken remote is unreportable. Two instances is why this is a
      # list rather than a flock special case.
      #
      # So the dependencies are pinned in runtimeInputs above, and a future
      # regression in that list fails LOUDLY here instead.
      for tool in flock getent git python3 sed grep; do
        command -v "$tool" >/dev/null 2>&1 || {
          log "$tool is not on PATH and the puller needs it; refusing rather than reporting a skipped tick"
          exit 75
        }
      done

      # ── Hand over to the tree's own puller ───────────────────────────────
      #
      # Fast-forward only, submodule-aware, and it writes the health record
      # the SessionStart hook reads. CLAUDE_PULL_UNIT names this unit so the
      # record points at the right journal.
      export CLAUDE_PULL_REPO="$checkout"
      export CLAUDE_PULL_STATE_ROOT="$state_root"
      export CLAUDE_PULL_UNIT=claude-runtime-deploy
      exec ${pkgs.bash}/bin/bash "$puller"
    '';
  };
in
{
  assertions = [
    {
      assertion = config.users.users.${consumer}.isNormalUser or false;
      message =
        "claude-runtime-deploy: ${consumer} must be a normal local user — the"
        + " state directory is published for that account to read";
    }
  ];

  users.groups.${deployUser} = { };
  users.users.${deployUser} = {
    isSystemUser = true;
    group = deployUser;
    # The deployer has no business having a home; HOME is set to the runtime
    # root inside the script so git cannot wander into a real one.
    home = "/var/empty";
  };

  # 0755 on both, so the read-only binds serve ${consumer} and the SessionStart
  # hook can read the health record. The checkout itself is created by the
  # clone under `umask 022`, which lands on the same modes.
  systemd.tmpfiles.rules = [
    "d ${runtimeRoot} 0755 ${deployUser} ${deployUser} -"
    "d ${stateRoot} 0755 ${deployUser} ${deployUser} -"
  ];

  systemd.services.claude-runtime-deploy = {
    description = "Fast-forward the claude-config deploy clone that ~/.claude is served from";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = deployUser;
      Group = deployUser;
      # Store-pinned, and no `%h` anywhere: see the header. This is the only
      # path in the exec chain, and it is immutable.
      ExecStart = "${deployScript}/bin/claude-runtime-deploy";

      # Background maintenance — never compete with an interactive session.
      Nice = 10;
      IOSchedulingClass = "idle";
      # The puller bounds its own fetch at 60s; this is the backstop for a
      # hang anywhere else, kept well under the 10-minute cadence so a wedged
      # tick cannot overlap the next one.
      TimeoutStartSec = 300;

      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ runtimeRoot ];
      PrivateTmp = true;
      NoNewPrivileges = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
      MemoryMax = "1G";
      TasksMax = 64;
    };
  };

  systemd.timers.claude-runtime-deploy = {
    description = "Poll origin for merged claude-config PRs every 10 minutes";
    timerConfig = {
      # Calendar rather than monotonic: the monotonic clock stops during
      # suspend, so a calendar elapse that passed while the laptop slept fires
      # on resume where OnUnitActiveSec would wait out its whole interval.
      # Persistent= covers the other gap — time this timer was inactive, i.e.
      # the machine powered off — and only applies to calendar timers.
      OnCalendar = "*:0/10";
      Persistent = true;
      AccuracySec = "1min";
      RandomizedDelaySec = "1min";
      Unit = "claude-runtime-deploy.service";
    };
    # Enabled from the start, unlike the user timer it replaces. That timer
    # had to be held off because it pulled the relocated runtime/ layout into
    # the LIVE ~/.claude before any mount existed; this one only ever writes
    # its own clone, which nothing reads until the cutover marker is created.
    # Having it running beforehand is in fact required: the clone must exist
    # and be verified before the marker goes in.
    wantedBy = [ "timers.target" ];
  };
}
