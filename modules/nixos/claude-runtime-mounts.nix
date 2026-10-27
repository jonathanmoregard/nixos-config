# modules/nixos/claude-runtime-mounts.nix
#
# Projects the runtime subset of jonathanmoregard/claude-config into
# ~/.claude through read-only bind mounts, so that the repository's dev and
# test trees are not reachable as live agent code.
#
# The property this buys is **controlled runtime deployment, not filesystem
# isolation**. Everything the harness loads on its own initiative resolves
# under ~/.claude, and `tests/`, `docs/`, `experiments/`, `research/` and
# `improvements/` are not projected there. The checkout still exists at
# ~/Repos/claude-config, and anything naming that path reads `tests/` exactly
# as before. Do not describe this as a sandbox.
#
# Layout, after cutover:
#
#   ~/Repos/claude-config/          the repository, partitioned
#     runtime/                      the 52 projected entries
#     tests/ docs/ experiments/     dev trees, never projected
#     vendor/                       two submodules, only four subpaths projected
#   ~/.claude/                      what every agent path resolves to
#     runtime/                      <- bind, ro
#     <entry> -> runtime/<entry>    one symlink per projected entry
#     settings.json                 NOT projected — see unlinkedEntries
#     vendor/superpowers/hooks      <- bind, ro
#     vendor/superpowers/skills     <- bind, ro
#     vendor/superpowers/package.json -> the checkout (a symlink, never a bind)
#     vendor/everything-claude-code/skills <- bind, ro
#     projects/ plugins/ ...        untracked live state, projected by nothing
#                                   — and where the plugin clones, the
#                                   permission ledger and the per-tool
#                                   state.json have to land too
#
# `vendor/` cannot move into `runtime/` — it holds two submodules — so only
# the four subpaths the harness actually loads are projected, each its own
# mount. That is what keeps everything-claude-code's nested `.claude/`, both
# `tests/`, `examples/`, `src/` and ~455 further instruction files out of the
# namespace. It is the biggest single win here.
#
# Bind mounts, never symlinks: a symlink resolves `..` against its target and
# hands back the on-disk answer for both geometries, so a symlink-based rig
# passes while proving nothing about the real one.
#
# SECOND HARD PRECONDITION, also outside this repo: the claude-pull timer must
# stay stopped until cutover. It fast-forwards ~/.claude from origin/master
# every 10 minutes, and once claude-config's master carries the partitioned
# layout, that pull replaces the flat tree — settings.json, all 29 hook paths,
# every permission rule — with a runtime/ directory nothing yet projects.
# Measured in a VM: the session still starts, with no hooks and no deny rules.
# A hand-made drop-in (ExecCondition=/bin/false) currently holds it; see
# ~/.local/state/claude-tasks/dot-claude/pending_for_human.md.
#
# HARD PRECONDITION, and it is not enforceable from this repo:
# jonathanmoregard/claude-config#26 must be merged, and present in the backing
# checkout, before the CUTOVER MARKER is created — not before this module
# merges or deploys. It makes runtime/skills/nixos-{config-dev,
# automated-testing,agent-testing,agenix-secret,binary-debug} real directories
# in claude-config, so the projection itself carries those five skills.
# Enabling the projection without it replaces ~/.claude/skills with a
# projection that does not contain them, and they become undiscoverable.
# The marker is what sequences this; merge order between the two repositories
# does not matter.
#
# THIRD PRECONDITION, also claude-config's and also sequenced by the marker:
# `skills/`, `permission-ledger/` and `tools/` must hold no live state under
# ~/.claude when the marker is created. Each is a tracked directory that also
# accumulates writes in place — plugin clones, the ledger's .jsonl and
# decided.json, a per-tool state.json — so each is a real directory at
# ~/.claude/<entry>, and a real directory is reported blocked rather than
# clobbered.
#
# Moving those writes out is the fix; `unlinkedEntries` is not. Exempting an
# entry projects nothing in its place, so it would withhold the very content
# the projection exists to deliver. Everything this repo names under those
# three directories only reads, which a read-only mount serves unchanged.
#
# claude-config owns the skill content outright, so no home-manager target
# under ~/.claude has to stay writable on its behalf and this repo declares
# no home.file target there at all. That is what leaves this module with no
# standing collision to work around.
#
# Also ordered by the marker, not by a merge: runtime/dcg.toml. home/dcg.nix
# seeds ~/.claude/dcg.toml from a store fallback when that path is absent at
# activation, so the cutover must create the per-entry links (step 5) before
# the next home-manager activation — otherwise activation writes a real file
# where the link belongs, and claude-runtime-links then reports it blocked
# forever rather than clobbering it.
{ config, lib, pkgs, ... }:
let
  user = "jonathan";
  group = "users";
  home = "/home/${user}";

  # What every agent path resolves to, and where the repository actually is.
  live = "${home}/.claude";
  checkout = "${home}/Repos/claude-config";

  # The cutover gate. Nothing here mounts until this file exists, and it is
  # created by hand during cutover, with the operator present.
  #
  # This is not a feature flag hedging a risky change — it is the switch for
  # an inherently manual migration, and it exists because deploying the
  # projection early is NOT harmless. Before cutover, ~/.claude is still the
  # flat checkout with its own vendor/ submodules; binding the clone's four
  # vendor subpaths over it would couple ~/.claude to the clone's submodule
  # pins (identical today, free to diverge tomorrow) and make claude-pull's
  # submodule sync fail EROFS against a read-only mount. With the gate, this
  # module can land and auto-deploy whenever, change nothing, and still be
  # exercised by the lane, which creates the marker itself.
  marker = "${live}/.projection-enabled";

  # Each projection: where it lands under ~/.claude, what backs it, and
  # whether the mountpoint has to be a file rather than a directory.
  projections = [
    { at = "runtime"; from = "${checkout}/runtime"; }
    { at = "vendor/superpowers/hooks"; from = "${checkout}/vendor/superpowers/hooks"; }
    { at = "vendor/superpowers/skills"; from = "${checkout}/vendor/superpowers/skills"; }
    { at = "vendor/everything-claude-code/skills"; from = "${checkout}/vendor/everything-claude-code/skills"; }
  ];

  # Projected as a SYMLINK rather than a bind mount — the opposite call from
  # settings.json directly above, for the opposite reason, and not an
  # inconsistency.
  #
  # A file bind mount pins an INODE. Git replaces files by writing a new one
  # and renaming over the name, so a submodule update leaves a file bind
  # serving the old content indefinitely while `mountpoint -q` still reports
  # healthy. Measured: after the source goes 7.0.0 -> 8.0.0, the bind still
  # reads 7.0.0 and reports mounted; a symlink reads 8.0.0. The sibling
  # DIRECTORY mounts do not have this problem — they pin a directory inode and
  # look children up by name every time.
  #
  # Nothing writes package.json, so the silent-replacement risk that rules
  # symlinks out for settings.json does not apply, and staleness is the only
  # failure mode left. A file symlink also cannot be walked into, so none of
  # superpowers' tests/, src/ or nested .claude/ becomes reachable by it.
  # `at` is relative to the live config dir, `from` to the checkout, so both
  # ends stay parameterised — the harness can point the pair at a fixture
  # without this script growing a test-only branch, exactly as `live` already
  # allows.
  fileLinks = [
    {
      at = "vendor/superpowers/package.json";
      from = "vendor/superpowers/package.json";
    }
  ];

  mountPoint = p: "${live}/${p.at}";

  # Mountpoints must exist before the mount, and must be the right kind.
  # `f` creates an empty file when absent, which is all a file bind needs.
  #
  # The `-` suffix on each type (`d-`, `f-`) makes a failing line non-fatal,
  # and it is not cosmetic. `d` and `f` adjust mode and ownership on an item
  # that already exists, and after cutover these paths ARE the live read-only
  # binds: every `nixos-rebuild switch` runs systemd-tmpfiles over them, so any
  # mode in the checkout that differs from 0755/0644 would be an EROFS chmod
  # and would fail tmpfiles — on every switch, for as long as the projection is
  # up. Today a git checkout is 0755/0644 and nothing fails; `-` is what keeps
  # that from being load-bearing. The cost of ignoring the error is covered:
  # claude-runtime-links refuses, loudly, if any of the five is not a mount
  # point, so a mountpoint that genuinely could not be created is still caught.
  #
  # These rules are deliberately NOT marker-gated — tmpfiles has no conditions.
  # Before cutover they therefore create one empty ~/.claude/runtime directory
  # (invisible to git, which does not track empty directories) and normalise
  # the mode of ~/.claude plus the vendor directories, which already stand at
  # 0755. Measured in a VM, pre-marker: nothing else about the flat checkout
  # changes.
  mountpointRules =
    [
      "d- ${live} 0755 ${user} ${group} -"
      "d- ${live}/vendor 0755 ${user} ${group} -"
      "d- ${live}/vendor/superpowers 0755 ${user} ${group} -"
      "d- ${live}/vendor/everything-claude-code 0755 ${user} ${group} -"
    ]
    ++ map
      (p:
        if p.isFile or false
        then "f- ${mountPoint p} 0644 ${user} ${group} -"
        else "d- ${mountPoint p} 0755 ${user} ${group} -")
      projections;

  # One symlink per projected entry, reconciled at runtime rather than
  # declared, because the entry set lives in the claude-config repository and
  # Nix cannot read ~/Repos at eval time. Hard-coding 52 names here would
  # drift silently the first time that repo adds one.
  #
  # settings.json is deliberately NOT projected, by either shape, and the
  # reasoning changed enough to be worth recording.
  #
  # A read-only FILE BIND MOUNT was tried and reverted. It refuses both writer
  # strategies, but it pins an INODE, so once claude-pull replaced
  # runtime/settings.json the projection served the old content indefinitely
  # while `mountpoint -q` still reported healthy — the exact defect that moved
  # package.json off a file bind, re-created on the one file the repository
  # updates most often.
  #
  # A per-entry symlink into the read-only mount WOULD track updates, and
  # contrary to the generic case it would not be silently replaced: Claude
  # Code's user-settings writer resolves the link, writes its temp file beside
  # the TARGET and renames onto the target, keeping the link. The documented
  # consequence is that `/model` then fails with EROFS, because the target is
  # on a filesystem that refuses writes. That is a working `/model` traded for
  # a locked file, and `/model` is used daily here.
  #
  # So this file is owned through Claude Code's MANAGED SETTINGS layer instead
  # — the mechanism built for policy that users must not override — rather
  # than by making a path read-only. Tracked separately; until it lands,
  # ~/.claude/settings.json stays an ordinary writable file and simply does
  # not receive repository updates.
  #
  # Exempting a directory drops its whole projected tree, so a directory that
  # merely holds live state does not belong here — move the state out instead.
  # See the THIRD PRECONDITION at the top.
  unlinkedEntries = [ "settings.json" ];

  linkRuntime = pkgs.writeShellApplication {
    name = "claude-runtime-links";
    runtimeInputs = [ pkgs.coreutils pkgs.findutils pkgs.util-linux ];
    text = ''
      # Defaults to the real config directory; takes one optional argument so
      # the behaviour can be exercised against a fixture without a test-only
      # code path. The unit never passes one.
      live=''${1:-${lib.escapeShellArg live}}
      # Second optional argument, same purpose as the first: the backing
      # checkout, which the absolute-target symlinks below point into. The
      # unit never passes either one.
      checkout_dir=''${2:-${lib.escapeShellArg checkout}}
      runtime="$live/runtime"
      marker="$live/.projection-enabled"

      # Find the links this unit owns: maxdepth 1 symlinks whose target is a
      # relative runtime/ path. Same predicate as the stale sweep below.
      owned_links() {
        find "$live" -maxdepth 1 -type l -lname 'runtime/*' "$@"
      }

      # The cutover gate lives here rather than in a systemd condition,
      # because a condition can only skip, and skipping has to be right in
      # one case and wrong in the other:
      #
      #   no marker, no owned links   pre-cutover. Nothing to do; say so and
      #                               exit 0. This is the state in which this
      #                               module lands and auto-deploys.
      #   no marker, owned links      the marker was removed after cutover.
      #                               Every one of those links now dangles.
      #                               That is the silent-disarm failure this
      #                               whole migration exists to prevent, so
      #                               it must be loud.
      #   marker                      post-cutover. Require the projection.
      if ! first_owned=$(owned_links -print -quit); then
        echo "claude-runtime-links: cannot scan $live for owned links" >&2
        exit 75
      fi
      if [ ! -e "$marker" ]; then
        if [ -n "$first_owned" ]; then
          echo "claude-runtime-links: $marker is missing but $live still has links into runtime/ ($first_owned); refusing to leave them dangling" >&2
          exit 75
        fi
        echo "claude-runtime-links: no cutover marker at $marker; nothing to link"
        exit 0
      fi

      # Every projection must actually be mounted, not just runtime/. A
      # vendor mount skips on its own ConditionPathExists if that submodule is
      # uninitialised, and an unnoticed skip leaves an empty directory where
      # ~455 instruction files used to be — or an empty package.json. Linking
      # against an empty or unmounted projection would point entries at
      # nothing, and the next session would come up with no hooks and no
      # permission rules while looking entirely healthy. Refuse instead.
      for relative in ${lib.concatMapStringsSep " " (p: lib.escapeShellArg p.at) projections}; do
        if ! mountpoint -q "$live/$relative"; then
          echo "claude-runtime-links: $live/$relative is not a mount point; refusing to link" >&2
          exit 75
        fi
      done
      if [ -z "$(ls -A "$runtime" 2>/dev/null)" ]; then
        echo "claude-runtime-links: $runtime is empty; refusing to link" >&2
        exit 75
      fi

      blocked=0
      linked=0

      for target in "$runtime"/* "$runtime"/.[!.]*; do
        [ -e "$target" ] || continue
        entry=''${target##*/}

        # Generated from unlinkedEntries, so there is no word-splitting here
        # and no list to keep in sync by hand.
        case "$entry" in
        ${lib.concatMapStringsSep "\n        " (e: "${lib.escapeShellArg e}) continue ;;") unlinkedEntries}
        esac

        link="$live/$entry"
        want="runtime/$entry"

        if [ -L "$link" ]; then
          current=$(readlink "$link")
          [ "$current" = "$want" ] && continue
          # Only retarget a link this unit owns, i.e. one already pointing
          # into runtime/. Anything else is somebody's property — a
          # home-manager store link, or one the operator made — and
          # retargeting it would be exactly the clobber this unit promises
          # not to do. Report it like any other occupied path.
          case "$current" in
          runtime/*)
            ln -sfnT "$want" "$link"
            linked=$((linked + 1))
            ;;
          *)
            blocked=$((blocked + 1))
            [ "$blocked" -le 10 ] && echo "claude-runtime-links: $link is a symlink to $current, not into runtime/; left alone" >&2
            ;;
          esac
          continue
        fi

        # Never delete anything that is not already a symlink. The old flat
        # tracked files collide with these links, and clearing them is a
        # deliberate cutover step taken with the operator present, not
        # something an activation unit does to a live home directory.
        if [ -e "$link" ]; then
          blocked=$((blocked + 1))
          [ "$blocked" -le 10 ] && echo "claude-runtime-links: $link exists and is not a symlink; left alone" >&2
          continue
        fi

        # -T so that if $link became a real directory between the test above
        # and here, the link is not created *inside* it.
        ln -sT "$want" "$link"
        linked=$((linked + 1))
      done

      # Symlinks with absolute targets outside runtime/, reconciled under the
      # same don't-clobber discipline as the loop above: retarget only a link
      # already pointing where this unit puts them, never replace a real file
      # or somebody else's link.
      #
      # These are NOT covered by owned_links (maxdepth 1, relative runtime/
      # target), so the stale sweep below leaves them alone — correct while the
      # list is additive, but dropping an entry from fileLinks will need its
      # own removal step rather than being swept.
      link_file() {
        local link="$1" want="$2"

        # A dangling link is worse than none: the reader gets ENOENT from a
        # path that looks projected. If the source is missing the checkout is
        # half-built, which is the same condition the mount check refuses on.
        if [ ! -e "$want" ]; then
          echo "claude-runtime-links: $want is missing; refusing to link $link to it" >&2
          exit 75
        fi

        if [ -L "$link" ]; then
          local current
          current=$(readlink "$link")
          [ "$current" = "$want" ] && return 0
          # Owned == already pointing into the checkout. Anything else is
          # somebody's property and is reported, not retargeted.
          case "$current" in
          "$checkout_dir"/*)
            ln -sfnT "$want" "$link"
            linked=$((linked + 1))
            ;;
          *)
            blocked=$((blocked + 1))
            [ "$blocked" -le 10 ] && echo "claude-runtime-links: $link is a symlink to $current, not into the checkout; left alone" >&2
            ;;
          esac
          return 0
        fi

        if [ -e "$link" ]; then
          blocked=$((blocked + 1))
          [ "$blocked" -le 10 ] && echo "claude-runtime-links: $link exists and is not a symlink; left alone" >&2
          return 0
        fi

        ln -sT "$want" "$link"
        linked=$((linked + 1))
      }

      ${lib.concatMapStringsSep "\n      "
        (f: "link_file \"$live\"/${lib.escapeShellArg f.at} \"$checkout_dir\"/${lib.escapeShellArg f.from}")
        fileLinks}

      # Drop links this unit owns whose target has left the runtime set.
      # A broken symlink is `-type l -xtype l`: -xtype follows the link, and
      # reports `l` only when there is nothing at the other end.
      #
      # The listing goes through a file rather than a process substitution so
      # that a find failure is visible. Through `< <(find ...)` its exit
      # status is lost, and an unreadable directory would silently skip the
      # cleanup while reporting success.
      stale_list=$(mktemp)
      trap 'rm -f "$stale_list"' EXIT
      if ! owned_links -xtype l -print0 > "$stale_list"; then
        echo "claude-runtime-links: cannot scan $live for stale links" >&2
        exit 75
      fi

      # Re-check the mount immediately before acting on that listing. If the
      # projection went away mid-run — a restart of the mount unit, a failed
      # remount — then every runtime/* link is broken at once and this sweep
      # would cheerfully delete all ~52 of them and exit 0, which is the
      # silent-disarm outcome arrived at by a different road.
      if ! mountpoint -q "$runtime"; then
        echo "claude-runtime-links: $runtime vanished mid-run; not sweeping" >&2
        exit 75
      fi

      while IFS= read -r -d "" stale; do
        rm -- "$stale"
        echo "claude-runtime-links: removed stale $stale" >&2
      done < "$stale_list"

      echo "claude-runtime-links: $linked link(s) written, $blocked path(s) left alone"

      # A left-alone path is not a tidy-up note, it is stale live content: the
      # agent reading ~/.claude/<entry> gets the old real directory, or
      # somebody else's symlink, instead of the projection — while every other
      # signal says the migration is done. So exit non-zero once all the work
      # is finished, which lands the unit in `failed` and puts it in
      # `systemctl --failed` and the SessionStart report.
      #
      # A true signal rather than a permanent alarm: nothing here is blocked
      # once ~/.claude holds no real entries of its own, and settings.json is
      # exempt by name rather than counted. While anything IS blocked the unit
      # sits in `failed`, which is the intended report — the projection is
      # genuinely incomplete until then.
      #
      # Leaving a blocked path alone is also what keeps home-manager clear of
      # the read-only mount: a path stays real for as long as it is blocked, so
      # anything home-manager still owns there it can still remove, and the
      # path only becomes a symlink into the projection once nothing is left.
      if [ "$blocked" -gt 0 ]; then
        echo "claude-runtime-links: cutover is incomplete — $blocked path(s) left alone, and agents still read the old content there" >&2
        exit 75
      fi
    '';
  };
in
{
  systemd.tmpfiles.rules = mountpointRules;

  # systemd.mounts rather than fileSystems: a mount unit that cannot be
  # satisfied is skipped, where a fileSystems entry becomes a dependency of
  # local-fs.target and a bad one can hold up boot.
  #
  # ConditionPathExists is what makes a missing or half-built checkout a
  # no-op: the unit logs that it was skipped and the machine boots normally.
  # `ro` on a bind is applied by systemd as a second remount; the generator
  # handles it.
  systemd.mounts = map
    (p: {
      what = p.from;
      where = mountPoint p;
      type = "none";
      options = "bind,ro";
      wantedBy = [ "multi-user.target" ];

      # These mounts belong to the LATE set, after local-fs.target, because
      # their mountpoints are created by systemd-tmpfiles-setup.service, which
      # itself runs After=local-fs.target.
      #
      # DefaultDependencies = "no" is load-bearing, and dropping it is an
      # ordering cycle, not a simplification: a mount unit's default
      # dependencies include Before=local-fs.target, so
      # local-fs.target -> this mount -> systemd-tmpfiles-setup.service ->
      # local-fs.target closes a loop. systemd breaks such a loop by deleting
      # one job from it, and the job it picked was
      # systemd-tmpfiles-setup.service — after which nix-daemon, nscd and
      # home-manager activation all failed at boot. Measured in the vm-base
      # lane, which now asserts against it directly.
      #
      # Switching default dependencies off costs the shutdown wiring, so that
      # is restored by hand below; Conflicts=/Before=umount.target is exactly
      # what the default set would have added.
      unitConfig = {
        DefaultDependencies = "no";
        # Both conditions must hold: the backing path has to exist, and the
        # cutover marker has to be in place. A failed condition skips the unit
        # cleanly and logs it, which is what keeps a missing or half-built
        # checkout from being a boot problem.
        ConditionPathExists = [ p.from marker ];
        # The filesystem holding the backing tree — home.mount on tuxedo, the
        # root mount in a VM where /home is not separate. Resolved by systemd
        # at runtime rather than named here, so this is correct on both.
        RequiresMountsFor = p.from;
      };
      after = [ "local-fs.target" "systemd-tmpfiles-setup.service" ];
      # Before home-manager activation, not merely before the links unit.
      # Activation reads and validates files under ~/.claude — dcg.toml is
      # checked by home/dcg.nix — and any such file that has become a link
      # into runtime/ is dangling until this mount is up. Ordering it after
      # the mount makes that race impossible instead of unlikely.
      before = [ "umount.target" "home-manager-${user}.service" ];
      conflicts = [ "umount.target" ];
    })
    projections;

  # A system unit running as jonathan, rather than a user unit, for one
  # reason: a user manager cannot order itself against a system mount unit,
  # so a user unit has no way to say "after the projection is mounted". As a
  # system unit, RequiresMountsFor resolves to the runtime mount and systemd
  # both orders and requires it.
  #
  # There is deliberately NO ConditionPathIsMountPoint here. A condition makes
  # the unit *skip*, and skipping is silent. If the projection is not mounted
  # and this unit quietly does nothing, every per-entry symlink dangles and
  # the next session comes up with no hooks, no permission rules and no MCP
  # servers while looking entirely healthy — measured, not hypothesised: with
  # the mount stopped, `cat ~/.claude/skills/<entry>` is ENOENT. So the script
  # runs unconditionally and exits 75, the unit lands in `failed`, and that
  # shows up in `systemctl --failed` and in the SessionStart unit-failure
  # report. A loud failure is the whole point.
  #
  # For the same reason there is no ConditionPathExists on the marker either.
  # The pre-cutover case does need to do nothing, but "no marker" and "marker
  # deleted after cutover, every link now dangling" are the same condition to
  # systemd and opposite outcomes in fact, so the script decides between them
  # and only the first one is quiet.
  systemd.services.claude-runtime-links = {
    description = "Link ~/.claude entries to the claude-config runtime projection";
    wantedBy = [ "multi-user.target" ];
    after = [ "home-manager-${user}.service" "systemd-tmpfiles-resetup.service" ];
    unitConfig = {
      # Every projection, not just runtime/: this unit refuses unless all of
      # them are mounted, so it should pull up and order against each one.
      RequiresMountsFor = map mountPoint projections;
      # No start limit at all, and this is deliberate rather than careless. A
      # start-limit hit on a path-triggered service PROPAGATES to the .path
      # unit: measured with transient units, the path unit goes `failed` with
      # Result=unit-start-limit-hit and never fires again, so the watcher dies
      # silently and permanently. A rate limit here would convert a burst of
      # git activity into a dead reconciler — strictly worse than the
      # rate-limiting it was meant to prevent. The timer below is what keeps a
      # missed or raced event bounded; the reconcile itself is idempotent and
      # cheap, so repeated runs cost nothing worth protecting against.
      StartLimitIntervalSec = 0;
    };
    serviceConfig = {
      Type = "oneshot";
      # NOT RemainAfterExit. It used to be, and combined with the path unit
      # below that is a silent half-failure: a .path issues a `start` job, and
      # `start` on an already-active unit is a no-op, so the watcher would fire
      # exactly once and then never again. Measured with transient units:
      #
      #   oneshot, non-remaining     new entry RETRIGGERED, removal RETRIGGERED
      #   oneshot, RemainAfterExit   new entry RETRIGGERED, removal NO RE-TRIGGER
      #
      # A test that only added an entry would have passed either way, which is
      # why the lane asserts the removal too. Nothing requires this unit to
      # stay `active (exited)`; the ordering edges are After=, not Requires=.
      User = user;
      Group = group;
      ExecStart = "${linkRuntime}/bin/claude-runtime-links";
    };
  };

  # What closes the update loop. The links unit reconciles the whole entry set
  # when it runs, but nothing re-ran it after claude-pull landed new commits,
  # so a newly added TOP-LEVEL runtime entry stayed unlinked — present in the
  # repository, absent from ~/.claude — until someone noticed by hand.
  #
  # An inotify watch on a directory reports its DIRECT entries, which is
  # exactly the set that needs symlinks: a new skill under runtime/skills/
  # already resolves through the existing runtime/skills link and needs
  # nothing from this.
  #
  # System-level rather than a user path unit, because the unit it starts is a
  # system unit; going the other way would need a polkit rule granting
  # jonathan the right to restart it. Pre-cutover the watched directory does
  # not exist yet, which is inert: systemd watches the nearest existing parent
  # and waits.
  systemd.paths.claude-runtime-links = {
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = "${checkout}/runtime";
      Unit = "claude-runtime-links.service";
    };
  };

  # The level-triggered half, and the watcher above is not sufficient without
  # it. PathChanged is edge-triggered and the directory is NOT watched while
  # the service it triggered is running, so an entry that appears after the
  # reconcile has already globbed runtime/* is missed until some later
  # top-level event — which may never come. inotify also drops events under
  # pressure and does not survive a watch being re-established.
  #
  # So the path unit is for latency and this is for correctness: any state the
  # watcher missed is repaired within the interval. Ten minutes matches
  # claude-pull's own cadence, which is what lands new entries in the first
  # place; the offset keeps the reconcile just after a pull rather than
  # racing it.
  systemd.timers.claude-runtime-links = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:02,12,22,32,42,52";
      Persistent = true;
      Unit = "claude-runtime-links.service";
    };
  };
}
