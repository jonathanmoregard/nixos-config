# A Claude Code config directory used only by sessions VSCodium starts.
#
# WHY A SEPARATE CONFIG DIRECTORY
#
# The ask was Codium-scoped skills and a Codium-scoped CLAUDE.md. Neither is
# expressible in the one shared `~/.claude`: skills are discovered from a
# directory, not selected per session, and CLAUDE.md is global. A SessionStart
# hook injecting markdown as `additionalContext` gets the prose half and never
# the skills, and buries an editor concern in a hook.
#
# `CLAUDE_CONFIG_DIR` is the real seam, and it is the extension's own. Every
# entry of `claudeCode.environmentVariables` is copied into the spawned
# process's environment EXCEPT that one, which the extension pulls out, checks
# is an absolute path, and applies separately (`$91`/`e71` in extension.js,
# 2.1.311). home/vscodium.nix declares it, so it is as permanent as the rest
# of the editor's settings.
#
# WHAT THAT COSTS, AND WHAT IS LINKED BACK
#
# Claude reads EVERYTHING from the config directory, so relocating it silently
# drops whatever is not re-provided. Measured on this host rather than assumed
# (a probe run of `claude -p` against a hand-built directory):
#
#   - the ~110 user-scope skills in ~/.claude/skills are NOT inherited. A
#     relocated directory saw only plugin and built-in skills.
#   - the 8 local MCP servers are NOT inherited: `.claude.json` is the config
#     directory's, so a relocated one started with only the account-level
#     claude.ai servers and none of aggregator, github, research-agent,
#     git_broker, gdocs-review, klaffat-app-runner, home-assistant, reddit.
#   - permissions and hooks ARE kept by linking settings.json, and they keep
#     working: the hook commands are $HOME-anchored absolute paths, so they do
#     not move with the config directory. A denied command was refused by
#     deny-hints in the relocated directory exactly as in a terminal session.
#     That is the "global security still applies" requirement, and it holds by
#     linking one file.
#   - a CLAUDE.md there loads, and its `@`-imports resolve, which is what lets
#     the Codium file extend the global rules instead of replacing them.
#
# WHY THE DIRECTORY IS WRITABLE AND NOT A STORE PATH
#
# Claude writes `.claude.json`, `projects/`, `sessions/`, `session-env/`,
# `backups/`, `plugins/` and `.last-cleanup` into it. A store symlink farm
# would be read-only at exactly the paths it needs to write, so this is an
# activation script over a real directory under $XDG_STATE_HOME — whose
# semantics are the durability spec here, the same reading home/vscodium.nix
# already relies on: survives reboot, survives deploy, gone on a fresh
# install.
#
# The writability is also the point, not a concession. A real directory
# dropped into `skills/` is left alone by activation, so a skill written
# mid-session outlives every deploy and can be promoted into
# home/claude-codium/skills later. Two layers, and the difference between
# them is only durability: declared here is reviewed and survives a
# reinstall, written live is immediate and survives everything short of one.
#
# `nixos-drift-analyzer` reports the live layer (home/drift-analyzer.nix), so
# a skill or a note left here surfaces as a promotion queue rather than
# becoming permanent by going unnoticed.
{ config, pkgs, lib, ... }:

let
  live = "${config.home.homeDirectory}/.claude";
  codiumDir = "${config.home.homeDirectory}/.local/state/claude-codium";

  # Where skills come from, in precedence order: the shared ~/.claude/skills,
  # then the Codium-only ones declared in this repo, which therefore shadow a
  # same-named global skill. Declaring one here is a deliberate act, so it is
  # the one that should win.
  #
  # Both are scanned by the SAME loop at activation rather than one list being
  # expanded at evaluation. The evaluation-time version read this directory
  # with builtins.readDir and emitted a second, near-identical loop over the
  # names it found — and since no Codium-only skill is declared yet, that
  # second loop was unreachable, so the first skill ever added here would have
  # been the first thing to run it.
  # Named separately because the sweep needs to tell THIS generation's
  # declared source from an older one's: the store path changes whenever the
  # directory's contents do, so "a child of this path" means "declared now".
  declaredSkills = ./claude-codium/skills;

  skillSources = [ "${live}/skills" declaredSkills ];

  codiumClaudeMd = ./claude-codium/CLAUDE.md;

  # A real file rather than an inline writeText because home/drift-analyzer.nix
  # compares local.md against it to decide whether there are notes worth
  # promoting. Two copies of this text would make an edit here read as drift
  # on every host until the analyzer's copy caught up.
  codiumLocalSeed = ./claude-codium/local-seed.md;

  # Entries linked straight back at ~/.claude, with the reason each one has to
  # be. `settings.json` carries permissions and every hook; `.credentials.json`
  # is the OAuth material; `agents` holds the pinned role agents the global
  # CLAUDE.md dispatches by name; `commands` the slash commands.
  linkedFromLive = [ "settings.json" ".credentials.json" "agents" "commands" ];
in
{
  # Not home.file: every one of these lands inside a directory Claude also
  # writes to, and home.file would fight it over ownership of the parent.
  # entryAfter writeBoundary per the home-manager convention for anything
  # that mutates $HOME.
  #
  # The skills loop reads ~/.claude/skills, which on this host is populated
  # by claude-runtime-links.service — a separate unit, so the DAG does not
  # order against it. A run where that mount is absent loses the inherited
  # links, whose targets went with it, and the next activation re-links them;
  # what such a run cannot lose is the live or the declared half, because a
  # link is only ever swept on the evidence of its own target. See the sweep
  # below.
  home.activation.claudeCodiumConfig =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      codium=${lib.escapeShellArg codiumDir}
      live=${lib.escapeShellArg live}

      $DRY_RUN_CMD mkdir -p "$codium/skills"

      # One symlink per inherited entry, and only ever onto an empty slot or
      # an existing symlink. Never onto something real, for two reasons that
      # are both about silence rather than theory:
      #
      #   - `ln -sfn X some-real-dir` does NOT replace the directory. It
      #     creates some-real-dir/X and exits 0. -n only covers a symlink TO
      #     a directory, not a real one. So a real `agents/` turning up here
      #     would quietly stop that entry being inherited, and the only
      #     evidence would be an `agents/agents` nobody looks at.
      #   - `.claude.json` is a link to a file Claude WRITES. 2.1.311 writes
      #     through the symlink — measured, it was still a symlink after
      #     three real sessions had created backups/, projects/ and
      #     .last-cleanup in here — but a version that wrote to a temp file
      #     and renamed would leave a real file holding its own MCP set and
      #     project state, and the next deploy's `ln -sfn` would delete it.
      #
      # So: refuse, say so on stderr, and carry on. Refusing costs the
      # entry; failing activation costs the whole deploy, and a poisoned
      # nixos-deploy is the more expensive failure.
      link_inherited() {
        if [ -e "$2" ] && [ ! -L "$2" ]; then
          echo "claude-codium: $2 exists and is not a symlink; leaving it" \
               "alone and NOT inheriting $1. Move it aside to restore the" \
               "link." >&2
          return 0
        fi
        # -T so that the nesting case above is an error, not a surprise.
        $DRY_RUN_CMD ln -sfnT "$1" "$2"
      }

      for entry in ${lib.escapeShellArgs linkedFromLive}; do
        link_inherited "$live/$entry" "$codium/$entry"
      done

      # The local MCP servers are registered in $HOME/.claude.json, not under
      # ~/.claude. Shared with terminal sessions on purpose: a copy would
      # drift, and both ends want the same server set.
      #
      # Only the server set and that file's contents are shared. Transcripts
      # live in projects/ INSIDE each config directory, so editor sessions
      # and terminal sessions do not see each other's history or --resume
      # list. That is a consequence of relocating the directory, not a
      # choice made here.
      link_inherited ${
        lib.escapeShellArg "${config.home.homeDirectory}/.claude.json"
      } "$codium/.claude.json"

      # CLAUDE.md is declared, so unlike the entries above it DOES overwrite
      # a stray file: the whole point is that the editor's rules cannot be
      # edited into something else between deploys, and local.md is the
      # channel for anything a session wants to add. -T keeps a directory in
      # the way from turning into a nested link, and the failure is reported
      # rather than fatal for the same reason as above.
      if ! $DRY_RUN_CMD ln -sfnT ${codiumClaudeMd} "$codium/CLAUDE.md"; then
        echo "claude-codium: could not write $codium/CLAUDE.md; an editor" \
             "session will fall back to the global rules only." >&2
      fi

      # The writable prose layer. Created only when absent — this file is the
      # user's, and activation must never flatten what a session wrote into
      # it. It exists at all because CLAUDE.md imports it and a missing import
      # target is not worth finding out about mid-session.
      if [ ! -e "$codium/local.md" ]; then
        $DRY_RUN_CMD install -m 0644 ${codiumLocalSeed} "$codium/local.md"
      fi

      # skills/ is assembled, not replaced. A link is swept when its own
      # target says it is finished: either the target is gone, or it sits in
      # a store path this generation does not declare. The second case is
      # the one that is easy to miss — a skill deleted from
      # home/claude-codium/skills leaves a link whose store target stays
      # valid for as long as any generation retains it, so it never dangles,
      # and home/drift-analyzer.nix excludes store links from the report.
      #
      # Judging the target, rather than recording what we linked, leaves no
      # manifest that can fall out of step with the directory; and the store
      # source is in this script's own closure, so unlike the bind mount
      # below it cannot go missing and take the whole declared set with it.
      #
      # Judging each link rather than relinking from scratch is what spares a
      # symlink the user made by hand into one of their own repos — route 2
      # from the skills README — which a blanket sweep would remove silently
      # on the next deploy.
      #
      # It does NOT spare an inherited link while ~/.claude/skills is
      # unpopulated: that target went with the mount, so the link dangles and
      # is swept, leaving an editor session the live and declared skills only
      # until a later activation re-links the rest. Nothing re-runs
      # activation on a timer, so that window is a deploy long.
      #
      # Anything that is not a symlink at all — a real directory — is a skill
      # written in place and is never touched. That is the mutable half of
      # this directory and the reason it is not a store path.
      declaredStore=${lib.escapeShellArg "${declaredSkills}"}

      for link in "$codium/skills"/*; do
        [ -L "$link" ] || continue
        # readlink, not realpath: ~/.claude/skills entries are themselves
        # links into the store, so resolving would make every inherited
        # skill look like one of ours and sweep it.
        #
        # `|| true` because this runs under set -e and a failed read would
        # abort activation, which on this host poisons the deploy SHA. An
        # empty target falls through to the resolves-or-sweep rule below,
        # which keeps the link.
        target=$(readlink "$link" || true)
        case "$target" in
          # Declared now: an unchanged declaration keeps the same store path.
          "$declaredStore"/*) continue ;;
          # Ours, from a generation whose declared set still had it.
          /nix/store/*)
            $DRY_RUN_CMD rm -f "$link"
            continue
            ;;
        esac
        # Anything else is judged on whether it resolves, which is what
        # spares a hand-made link into one of the user's own repos.
        if [ -e "$link" ]; then continue; fi
        $DRY_RUN_CMD rm -f "$link"
      done

      for src in ${lib.escapeShellArgs skillSources}; do
        [ -d "$src" ] || continue
        for skill in "$src"/*; do
          # -d, not -e: a skill is a directory, and this also follows a
          # symlinked one (several entries in ~/.claude/skills are symlinks
          # into another repo or the store) while skipping a broken link
          # rather than relaying it. It is what ignores this directory's own
          # README.md too.
          [ -d "$skill" ] || continue
          name=$(basename "$skill")
          # A real directory of the same name wins: it is the live-authored
          # version of a skill being iterated on, and clobbering it would
          # throw away the work this layer exists to hold.
          if [ -e "$codium/skills/$name" ] && [ ! -L "$codium/skills/$name" ]; then
            continue
          fi
          # -T so that if the guard above is ever weakened, a real directory
          # in the way is an error rather than a silently nested link.
          $DRY_RUN_CMD ln -sfnT "$skill" "$codium/skills/$name"
        done
      done
    '';
}
