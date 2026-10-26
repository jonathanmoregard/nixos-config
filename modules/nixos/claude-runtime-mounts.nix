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
#     vendor/superpowers/hooks      <- bind, ro
#     vendor/superpowers/skills     <- bind, ro
#     vendor/superpowers/package.json <- bind, ro (a file)
#     vendor/everything-claude-code/skills <- bind, ro
#     projects/ plugins/ ...        untracked live state, projected by nothing
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
# HARD PRECONDITION, and it is not enforceable from this repo:
# jonathanmoregard/claude-config#25 must be merged before this deploys. It
# adds runtime/skills/nixos-{config-dev,automated-testing,agent-testing,
# agenix-secret} as absolute symlinks into ~/.claude/skills-hm, which is where
# home/claude-skills.nix writes them. Deploying this first replaces
# ~/.claude/skills with a projection that does not contain those four, and
# they become undiscoverable.
{ config, lib, pkgs, ... }:
let
  user = "jonathan";
  group = "users";
  home = "/home/${user}";

  # What every agent path resolves to, and where the repository actually is.
  live = "${home}/.claude";
  checkout = "${home}/Repos/claude-config";

  # Each projection: where it lands under ~/.claude, what backs it, and
  # whether the mountpoint has to be a file rather than a directory.
  projections = [
    { at = "runtime"; from = "${checkout}/runtime"; }
    { at = "vendor/superpowers/hooks"; from = "${checkout}/vendor/superpowers/hooks"; }
    { at = "vendor/superpowers/skills"; from = "${checkout}/vendor/superpowers/skills"; }
    { at = "vendor/superpowers/package.json"; from = "${checkout}/vendor/superpowers/package.json"; isFile = true; }
    { at = "vendor/everything-claude-code/skills"; from = "${checkout}/vendor/everything-claude-code/skills"; }
  ];

  mountPoint = p: "${live}/${p.at}";

  # Mountpoints must exist before the mount, and must be the right kind.
  # `f` creates an empty file when absent, which is all a file bind needs.
  mountpointRules =
    [
      "d ${live} 0755 ${user} ${group} -"
      "d ${live}/vendor 0755 ${user} ${group} -"
      "d ${live}/vendor/superpowers 0755 ${user} ${group} -"
      "d ${live}/vendor/everything-claude-code 0755 ${user} ${group} -"
    ]
    ++ map
      (p:
        if p.isFile or false
        then "f ${mountPoint p} 0644 ${user} ${group} -"
        else "d ${mountPoint p} 0755 ${user} ${group} -")
      projections;

  # One symlink per projected entry, reconciled at runtime rather than
  # declared, because the entry set lives in the claude-config repository and
  # Nix cannot read ~/Repos at eval time. Hard-coding 52 names here would
  # drift silently the first time that repo adds one.
  #
  # settings.json is deliberately NOT linked: Claude Code writes it (the model
  # pin is a live, tracked modification right now), and a read-only projection
  # would make that write fail. It stays a real file in ~/.claude. The cost is
  # that it no longer receives repository updates automatically — see the
  # reconciliation note in the PR.
  unlinkedEntries = [ "settings.json" ];

  linkRuntime = pkgs.writeShellApplication {
    name = "claude-runtime-links";
    runtimeInputs = [ pkgs.coreutils pkgs.findutils pkgs.util-linux ];
    text = ''
      # Defaults to the real config directory; takes one optional argument so
      # the behaviour can be exercised against a fixture without a test-only
      # code path. The unit never passes one.
      live=''${1:-${lib.escapeShellArg live}}
      runtime="$live/runtime"

      # The projection must actually be mounted. Linking against an empty or
      # unmounted directory would point every entry at nothing, and the next
      # session would come up with no hooks and no permission rules while
      # looking entirely healthy — the exact failure this migration exists to
      # avoid. Refuse instead.
      if ! mountpoint -q "$runtime"; then
        echo "claude-runtime-links: $runtime is not a mount point; refusing to link" >&2
        exit 75
      fi
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
          [ "$(readlink "$link")" = "$want" ] && continue
          ln -sfn "$want" "$link"
          linked=$((linked + 1))
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

        ln -s "$want" "$link"
        linked=$((linked + 1))
      done

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
      if ! find "$live" -maxdepth 1 -type l -lname 'runtime/*' -xtype l -print0 > "$stale_list"; then
        echo "claude-runtime-links: cannot scan $live for stale links" >&2
        exit 75
      fi
      while IFS= read -r -d "" stale; do
        rm -- "$stale"
        echo "claude-runtime-links: removed stale $stale" >&2
      done < "$stale_list"

      echo "claude-runtime-links: $linked link(s) written, $blocked path(s) left alone"
      if [ "$blocked" -gt 0 ]; then
        echo "claude-runtime-links: cutover is incomplete while any path is left alone" >&2
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
      after = [ "systemd-tmpfiles-setup.service" "home.mount" ];
      unitConfig = {
        ConditionPathExists = p.from;
        DefaultDependencies = "no";
      };
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
  systemd.services.claude-runtime-links = {
    description = "Link ~/.claude entries to the claude-config runtime projection";
    wantedBy = [ "multi-user.target" ];
    after = [ "home-manager-${user}.service" ];
    unitConfig.RequiresMountsFor = "${live}/runtime";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = user;
      Group = group;
      ExecStart = "${linkRuntime}/bin/claude-runtime-links";
    };
  };
}
