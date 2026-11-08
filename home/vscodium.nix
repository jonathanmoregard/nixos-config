# Editor: VSCodium, with extensions and keybindings declared, and settings
# declared-but-extensible.
#
# Extensions come from the nixpkgs extension set rather than VSCodium's Open
# VSX marketplace: Open VSX does not carry GitLens at all, and a nix-baked set
# means the editor a rebuild produces is the editor every rebuild produces.
#
# SETTINGS ARE A TWO-TIER FILE, AND THAT IS NEW
#
# Until 2026-11-06 settings.json and keybindings.json were both
# `home.file … force = true`: read-only store symlinks that the Settings UI
# could not write and that every deploy overwrote. That made the file
# trustworthy and the workflow unimprovable — tuning one setting while
# reasoning about a session in the editor meant a worktree, a PR, CI and a
# deploy, and any change made in the UI meanwhile was destroyed without a
# word. The same argument home/dcg.nix makes for mkOutOfStoreSymlink applies
# here, for the same reason: the file is edited while thinking.
#
# So settings.json is now home-manager's `mutableUserSettings`: a REAL file
# that upstream re-merges at each activation as `$dynamic * $static`. Two
# consequences, and both matter:
#
#   DECLARED WINS. Everything in `settings` below is re-asserted on every
#   deploy, so the curated set cannot rot and a fresh install still gets all
#   of it. Nothing was undeclared to buy mutability.
#
#   UNDECLARED SURVIVES. Any key NOT below — one added through the Settings
#   UI, or by an extension's own `update(…, Global)` — is preserved across
#   reboot and deploy, and lost only on a fresh install. That is the drift
#   layer: the place a setting lives while it is still being tried, before it
#   earns a line in this file.
#
# The cost of "declared wins" is that editing a DECLARED key in the UI is
# silently reverted at the next deploy. home/vscodium-drift-tool.py records
# exactly that, pre-merge, because afterwards the evidence is gone — the
# hourly drift analyzer then reports it and the promotion is a normal PR.
# Undeclared keys are reported too, as the promotion queue.
#
# Two things this file can no longer carry: comments and formatting inside
# settings.json (the merge writes jq output, so both are destroyed on every
# deploy — rationale belongs here in the Nix, or in the collaboration notes),
# and a reliable guarantee that an unlisted key keeps VSCodium's default,
# since the UI can now set one and it will stick. Settings worth pinning
# against that are declared explicitly below even when the declared value
# equals the upstream default.
#
# Provenance: ported 2026-10-27 from the 2023-era settings-sync gist of the
# pre-NixOS VSCode install. Deliberately NOT carried over: the Haskell / Elm /
# PureScript language blocks and their snippets (hardcoded old-employer paths),
# the cSpell word list (same vintage), bracket-pair-colorizer-2 (colorization
# is built in since 1.67), code-settings-sync (this file replaces it),
# indent-rainbow, clangd/clang-format (their paths were a Flatpak prefix and
# /usr/bin — neither exists here), macros / block-travel / bookmarks bindings
# (their extensions are not in the nixpkgs set), and
# security.workspace.trust.untrustedFiles = "open" (the trust prompt is a real
# guard now that agents write into these repos).
{ config, lib, modulesPath, pkgs, ... }:
let
  jsonFormat = pkgs.formats.json { };

  # The same script home/claude-egress-slice.nix hands the interactive
  # zsh `claude()`. Imported, not transcribed: a second copy of the
  # systemd-run invocation would drift toward "looks observed, isn't".
  claudeEgressLaunch = import ./claude-egress-launch.nix { inherit pkgs; };

  # Same shape, same reason as claudeEgressLaunch: a binary the extension
  # spawns, kept in its own file so the check lane can drive the exact
  # derivation the editor runs.
  rustAnalyzerDevshell = import ./rust-analyzer-devshell.nix { inherit pkgs; };

  # Shared with home/drift-analyzer.nix's probe, same reason again: the
  # recorder and the reporter must agree about what counts as drift.
  driftTool = import ./vscodium-drift-tool.nix { inherit pkgs; };

  settings = {
    # ── Editor ──────────────────────────────────────────────────────────
    "editor.formatOnSave" = true;
    "editor.multiCursorModifier" = "ctrlCmd";
    "editor.mouseWheelZoom" = true;
    "editor.cursorBlinking" = "smooth";
    # Keep a peek window open until dismissed instead of on first navigation.
    "editor.stablePeek" = true;
    # Markup and prose get formatted on demand, not on every save.
    "[html]" = {
      "editor.formatOnSave" = false;
      "editor.defaultFormatter" = "esbenp.prettier-vscode";
    };
    "[xml]" = { "editor.formatOnSave" = false; };
    "[plaintext]" = { "editor.formatOnSave" = false; };
    "[json]" = { "editor.defaultFormatter" = "vscode.json-language-features"; };
    "[jsonc]" = { "editor.defaultFormatter" = "esbenp.prettier-vscode"; };
    "[javascript]" = { "editor.defaultFormatter" = "esbenp.prettier-vscode"; };

    # ── Workbench ───────────────────────────────────────────────────────
    # Preview tabs replace themselves on the next click, which loses the file
    # you were reading; open everything as a real tab instead.
    "workbench.editor.enablePreview" = false;
    "workbench.editor.enablePreviewFromQuickOpen" = false;
    # With ~70 worktrees checked out, the window title has to name the repo.
    "window.title" = "\${activeEditorMedium}\${separator}\${rootName}";
    "workbench.colorTheme" = "One Dark Pro";
    "oneDarkPro.vivid" = false;
    "workbench.iconTheme" = "vscode-icons";
    "vsicons.dontShowNewVersionMessage" = true;
    "editor.tokenColorCustomizations" = {
      "[One Dark Pro]" = {
        textMateRules = [
          {
            scope = [ "keyword.operator" ];
            # https://coolors.co/ab9df2-495867-fc6a67-78e8c6-fee440
            settings.foreground = "#dcb97d";
          }
        ];
      };
    };
    # Diff colours: the stock green/red pair is hard to separate at a glance.
    "workbench.colorCustomizations" = {
      "diffEditor.removedTextBackground" = "#ff000066";
      "diffEditor.insertedTextBackground" = "#00809b66";
    };

    # ── Files, explorer, diff ───────────────────────────────────────────
    "files.trimFinalNewlines" = true;
    "explorer.confirmDelete" = false;
    "explorer.confirmDragAndDrop" = false;
    # Whitespace-only changes are real changes when reviewing a diff.
    "diffEditor.ignoreTrimWhitespace" = false;

    # ── Terminal ────────────────────────────────────────────────────────
    "terminal.integrated.defaultProfile.linux" = "zsh";

    # ── Git and GitLens ─────────────────────────────────────────────────
    "git.autofetch" = true;
    "git.confirmSync" = false;
    "git.enableSmartCommit" = true;
    # GitLens earns its place in the sidebar, not as inline noise on the
    # current line or a code lens above every symbol.
    "gitlens.currentLine.enabled" = false;
    "gitlens.currentLine.format" = "\${author}, \${agoOrDate} ";
    "gitlens.codeLens.authors.enabled" = false;
    "gitlens.codeLens.recentChange.enabled" = false;

    # ── Security ────────────────────────────────────────────────────────
    # Keys whose wrong value silently removes a guard, declared so the merge
    # re-asserts them. Until settings.json became mutable an unlisted key was
    # pinned to its default by the force-written file; now the UI can set one
    # and it STICKS across deploys, because the merge preserves undeclared
    # keys — including from a "Don't ask again" checkbox on the very dialog
    # whose guard it disarms. So the drift layer is scoped deliberately:
    # cosmetic keys stay mutable, which is what it is for, and these are
    # pinned, where declared wins on every deploy and a live edit is reverted
    # and reported rather than becoming the new configuration.
    #
    # Values were read out of the DEPLOYED editor build rather than from
    # memory or docs (workbench.desktop.main.js and the built-in git
    # extension's package.json in
    # /nix/store/…-vscodium-1.143.17183). All but the two marked below are
    # that build's own default, so pinning them changes nothing today and
    # only refuses a later change.
    #
    # Workspace trust is the guard that stops a cloned repo's tasks, debug
    # configs and extension code from running on open — worth more here than
    # on a normal desktop, because agents clone and write into these repos.
    # `startupPrompt` is deliberately NOT declared: its default is "never"
    # and the other values only prompt MORE, so there is nothing to weaken,
    # and declaring a non-default would quietly add a dialog nobody asked
    # for. `security.` is in the drift tool's sensitive prefixes, so a live
    # change to it is still reported.
    "security.workspace.trust.enabled" = true;
    "security.workspace.trust.untrustedFiles" = "prompt";
    "security.workspace.trust.emptyWindow" = true;
    # Opening a file:// or a remote-protocol URL is a code path, not a
    # navigation; keep the confirmation.
    "security.promptForLocalFileProtocolHandling" = true;
    "security.promptForRemoteFileProtocolHandling" = true;
    # A folder that auto-runs a task on open is arbitrary code execution from
    # a `git clone`. "off" is the build's default, and `restricted: true` in
    # its schema, so a workspace cannot set it either.
    "task.allowAutomaticTasks" = "off";
    # The two deliberate NON-defaults ("on" and true upstream). Extensions
    # come from the read-only nix store — mutableExtensionsDir is false — so
    # an update check cannot succeed: at best it is noise, at worst a prompt
    # that invites installing a second, unmanaged copy outside the store.
    # `autoUpdate` is a string enum, not a boolean.
    "extensions.autoUpdate" = "off";
    "extensions.autoCheckUpdates" = false;
    # Spelled here rather than via the module's `enableUpdateCheck` /
    # `enableExtensionUpdateCheck` options, which inject these same two keys
    # (mkVscodeModule.nix `mergedUserSettings`, and only when explicitly
    # false). Setting those options would be silently INERT, not merely
    # redundant: the mkForce'd activation entry below merges
    # ${declaredSettings} — generated from this attrset — so the module's
    # own effectiveUserSettings path never reaches the live file. That is
    # also what keeps declared.json and the merged result identical by
    # construction rather than by coincidence.
    #
    # Nothing should get past the pre-commit hooks from a GUI button: the
    # gitleaks hook is what stands between a secret and this public repo's
    # history, and --no-verify from a checkbox would skip it.
    "git.allowNoVerifyCommit" = false;
    "git.confirmNoVerifyCommit" = true;
    "git.allowForcePush" = false;
    "git.confirmForcePush" = true;
    # Never let the editor be the thing that stops verifying TLS.
    "http.proxyStrictSSL" = true;
    # "off" is already VSCodium's default, unlike upstream VS Code's "all".
    "telemetry.telemetryLevel" = "off";
    # The Claude Code extension's own permission switch. `bypassPermissions`
    # is one of claudeCode.initialPermissionMode's enum values and this is
    # the setting that admits it, so a live `true` would hand an
    # editor-started session blanket tool approval and survive every deploy.
    # environmentVariables sets the env of the spawned claude process, which
    # is how the egress wrapper below could be worked around; it is declared
    # under Claude Code below, where its own value needs explaining.
    #
    # initialPermissionMode itself is left undeclared on purpose: unset means
    # "defer to the CLI's resolved default for the session", and pinning a
    # value here would override that. It is in the drift tool's sensitive
    # prefixes instead, so a live value is reported within the hour.
    "claudeCode.allowDangerouslySkipPermissions" = false;

    # ── Claude Code ─────────────────────────────────────────────────────
    # Launch through the egress wrapper, so an editor-spawned session
    # lands in claude-egress.slice exactly like a terminal one. Without
    # this the extension spawns the CLI directly and its traffic is
    # invisible to the nftables rule bound to that cgroup.
    "claudeCode.claudeProcessWrapper" = "${claudeEgressLaunch}/bin/claude-egress-launch";
    # Point editor-started sessions at their own config directory, which is
    # what gives Codium its own CLAUDE.md and its own skills/ — see
    # home/claude-codium-config.nix for what that directory contains and what
    # had to be linked back into it.
    #
    # CLAUDE_CONFIG_DIR is special inside this list: the extension copies
    # every OTHER entry into the spawned process's environment, but pulls this
    # one out, requires an absolute path, and applies it on its own
    # (extension.js 2.1.311). An entry here with a relative path is silently
    # ignored, so the path is built from homeDirectory rather than written
    # with a `~`.
    #
    # Declared, which is what makes it safe to depend on: the activation
    # merge is `$dynamic * $static`, so a declared key's value wins over
    # whatever the Settings UI wrote, and the recorder files the discarded
    # value as an override before the merge runs. jq's `*` replaces an array
    # wholesale rather than unioning it, so an appended entry goes too.
    # That matters more for this key than for the rest of them — it is where
    # an edit could point the editor's Claude at an attacker-chosen config
    # directory, or inject environment into the process it spawns.
    "claudeCode.environmentVariables" = [
      {
        name = "CLAUDE_CONFIG_DIR";
        value = "${config.home.homeDirectory}/.local/state/claude-codium";
      }
    ];

    # ── Rust ────────────────────────────────────────────────────────────
    # Same desktop-menu PATH problem as nix.serverPath below, one layer
    # deeper: rust-analyzer needs more than its own binary. It runs cargo,
    # cargo runs every build script, and a build script links — so on a host
    # with no global compiler the editor reported `linker cc not found` for
    # half the dependency graph while the project's own `nix develop` had cc,
    # pkg-config and OPENSSL_* all along. The wrapper enters the workspace's
    # devShell first and execs the pinned server inside it.
    "rust-analyzer.server.path" = "${rustAnalyzerDevshell}/bin/rust-analyzer-devshell";

    # ── Nix ─────────────────────────────────────────────────────────────
    # nix-ide shells out to the language server by name, and a VSCodium
    # started from the desktop menu does not inherit the interactive PATH,
    # so point it at the store path directly.
    "nix.enableLanguageServer" = true;
    "nix.serverPath" = "${pkgs.nil}/bin/nil";
    # No nix formatter is declared here on purpose: this repo has no
    # formatting convention, so formatOnSave stays a no-op for .nix.
  };

  keybindings = [
    # Quick-open moves to ctrl+t; symbol search gives up the key.
    { key = "ctrl+t"; command = "-workbench.action.showAllSymbols"; }
    { key = "ctrl+t"; command = "workbench.action.quickOpen"; }
    {
      key = "ctrl+t";
      command = "workbench.action.quickOpenNavigateNextInFilePicker";
      when = "inFilesPicker && inQuickOpen";
    }

    # Fold / unfold the whole file, collapse the explorer tree.
    { key = "ctrl+m ctrl+o"; command = "editor.foldAll"; when = "editorTextFocus && foldingEnabled"; }
    { key = "ctrl+o ctrl+m"; command = "editor.unfoldAll"; when = "editorTextFocus && foldingEnabled"; }
    {
      key = "ctrl+shift+k";
      command = "workbench.files.action.collapseExplorerFolders";
      when = "explorerViewletVisible";
    }

    # Close every editor; save every editor.
    { key = "ctrl+shift+w"; command = "-workbench.action.closeWindow"; }
    { key = "ctrl+shift+w"; command = "workbench.action.closeAllEditors"; }
    { key = "ctrl+shift+s"; command = "-workbench.action.files.saveAs"; }
    { key = "ctrl+shift+s"; command = "-workbench.action.files.saveLocalFile"; when = "remoteFileDialogVisible"; }
    { key = "ctrl+shift+s"; command = "workbench.action.files.saveAll"; }

    # Rename on a ctrl+r chord, which means ctrl+r's own defaults have to go.
    { key = "ctrl+r"; command = "-workbench.action.openRecent"; }
    { key = "ctrl+r"; command = "-workbench.action.reloadWindow"; when = "isDevelopment"; }
    {
      key = "ctrl+r ctrl+r";
      command = "editor.action.rename";
      when = "editorHasRenameProvider && editorTextFocus && !editorReadonly";
    }
    {
      key = "f2";
      command = "-editor.action.rename";
      when = "editorHasRenameProvider && editorTextFocus && !editorReadonly";
    }

    # Back through the navigation history.
    { key = "ctrl+shift+backspace"; command = "workbench.action.navigateBack"; }
    { key = "ctrl+alt+-"; command = "-workbench.action.navigateBack"; }

    { key = "ctrl+shift+g"; command = "git.sync"; }

    { key = "enter"; command = "jumpToNextSnippetPlaceholder"; when = "editorTextFocus && hasNextTabstop && inSnippetMode"; }

    # Zoom is mouse-wheel only (editor.mouseWheelZoom above), so the keyboard
    # zoom bindings stop stealing ctrl+- and ctrl++.
    { key = "ctrl+numpad_subtract"; command = "-workbench.action.zoomOut"; }
    { key = "ctrl+-"; command = "-workbench.action.zoomOut"; }
    { key = "ctrl+numpad_add"; command = "-workbench.action.zoomIn"; }
    { key = "ctrl+[Minus]"; command = "-workbench.action.zoomIn"; }
    { key = "ctrl+shift+0"; command = "-workbench.action.zoomIn"; }
  ];

  # Byte-identical to what the module hands its own merge, which is what lets
  # the recorder diff against the same thing the merge applies. Upstream's
  # `mergedUserSettings` only injects `update.mode` / `extensions.
  # autoCheckUpdates` when `enableUpdateCheck` / `enableExtensionUpdateCheck`
  # are explicitly `false`; both are left unset below, so it is the identity
  # here. If a future home-manager injects more, those keys surface in the
  # drift report as undeclared rather than going unnoticed.
  declaredSettings =
    jsonFormat.generate "vscodium-declared-settings.json" settings;

  # Spelled exactly as mkVscodeModule spells them, so the `force` override
  # below lands on the module's own attribute rather than a near-miss.
  userDir = "${config.xdg.configHome}/VSCodium/User";
  settingsPath = "${userDir}/settings.json";
  keybindingsPath = "${userDir}/keybindings.json";

  # $XDG_STATE_HOME semantics are the durability spec: state that persists
  # between restarts but is not important or portable enough to preserve.
  # Survives reboot, survives deploy because nothing declares it, gone on a
  # fresh install.
  driftDir = "${config.home.homeDirectory}/.local/state/vscodium-drift";
  mergeFailedMarker = "${driftDir}/merge-failed.json";

  # Upstream's merge, as a shell function, imported rather than reimplemented.
  # It JSON5-parses the live file so JSONC comments do not break it, resolves
  # a symlink and writes the target, and snapshots first so a file changed
  # mid-activation is detected instead of clobbered. None of that is worth
  # rewriting, and a rewrite would drift from what the module actually runs.
  mutableSettingsFn = import
    "${modulesPath}/programs/vscode/mutableSettings.nix"
    {
      inherit lib pkgs;
      name = "VSCodium";
    };

  # BOTH variables are tested, for the reason home/dcg.nix spells out:
  # home-manager's own CLI exports DRY_RUN and tests `[[ -v DRY_RUN ]]`,
  # while DRY_RUN_CMD is derived from it and marked deprecated in the
  # generated activate script. Keying on the deprecated one alone means the
  # day home-manager drops it, a dry-activate starts writing records for
  # real; keying on the live one alone breaks in the mirror-image case.
  notDryRun = ''[[ ! -v DRY_RUN && -z "''${DRY_RUN_CMD:-}" ]]'';
in
{
  programs.vscodium = {
    enable = true;

    # DEFAULTS TO TRUE whenever only the default profile is set, which is
    # exactly this configuration. Left alone, VSCodium may install and update
    # extensions into the data dir itself and the header's claim that a
    # rebuild reproduces the editor becomes false. Mutability is wanted for
    # settings, deliberately not for the extension set.
    mutableExtensionsDir = false;

    profiles.default = {
      mutableUserSettings = true;
      userSettings = settings;
      inherit keybindings;

      extensions = with pkgs.vscode-extensions; [
        rust-lang.rust-analyzer
        tamasfe.even-better-toml
        eamodio.gitlens
        jnoortheen.nix-ide
        editorconfig.editorconfig
        alefragnani.project-manager
        zhuangtongfa.material-theme
        vscode-icons-team.vscode-icons
        esbenp.prettier-vscode
        # Caddyfile syntax: a grammar, brace/comment rules and a bundled
        # language server (directive and global-option diagnostics) for the
        # `Caddyfile` filename and *.caddyfile — an otherwise-plaintext
        # buffer. In the nixpkgs set, so the header's claim that a rebuild
        # reproduces the editor still holds.
        #
        # Its formatter is the one part that needs more than the extension:
        # it spawns `caddy fmt -` from $PATH (or `caddyfile.executable`, when
        # that is set to an absolute path), and caddy is not declared on this
        # host. With editor.formatOnSave on, saving such a buffer therefore
        # shows "Caddy was not found in your $PATH" and leaves the text
        # alone. Declaring caddy is a separate decision, not a dependency of
        # the highlighting this extension is here for.
        matthewpi.caddyfile-support
        # PR review inside the editor: inline diff against the base, the PR
        # description as a tab, and review comments on a selection. Needs an
        # editor >= 1.129 (overlays/vscodium.nix bumps it there).
        github.vscode-pull-request-github
        # Claude in the editor: alt+k sends the selection to a conversation,
        # and proposed diffs land as accept/reject. The CLI is the system
        # one from nixpkgs; this extension cannot update itself from a
        # read-only store path, which is the point.
        anthropic.claude-code
      ];
    };
  };

  # keybindings.json stays an immutable store symlink — there is no
  # `mutableKeybindings`, and a chord set is not something to tune by
  # accident. `force` because the module declares only `.source`, and
  # home-manager otherwise ABORTS activation when a real file occupies the
  # path, which a failed activation turns into a poisoned deploy SHA. The
  # window is not hypothetical: VSCodium writes keybindings.json itself the
  # first time the keyboard-shortcuts editor saves. The trade is deliberate —
  # a file written between two deploys is overwritten rather than stopping
  # the deploy, and this path is declared here in full, so there is nothing
  # in it worth preserving that is not already above.
  home.file.${keybindingsPath}.force = true;

  # Exempts the path from the collision check, which covers a stray file or
  # foreign symlink there. It does not cover a directory: linkGeneration
  # places the link with `ln -Tsf`, which refuses one.
  #
  # Keyed relative, unlike the paths above: the module derives this entry
  # from its own dataFolderName, and the absolute spelling would be a second,
  # sourceless entry rather than an override of that one.
  home.file.".vscode-oss/extensions".force = true;

  # VSCodium creates ~/.vscode-oss/extensions itself on first run, and
  # mutableExtensionsDir = false puts that path under home-manager, where a
  # real directory stops the linker. A failed activation on this host latches
  # the deploy SHA as poisoned and never re-attempts it.
  #
  # Moved aside rather than deleted: the declared set is the whole set, so
  # nothing there is needed, but a sideloaded extension is the user's. Placed
  # after the write boundary so the rename happens only once activation is
  # past the checks that can still abort it, and before linkGeneration
  # because that is what needs the path free.
  home.activation.vscodiumExtensionsDirMigration =
    lib.hm.dag.entryBetween [ "linkGeneration" ] [ "writeBoundary" ] ''
      extDir="$HOME/.vscode-oss/extensions"
      if [ -d "$extDir" ] && [ ! -L "$extDir" ]; then
        moved="$extDir.pre-nix-$(date -u +%Y%m%dT%H%M%SZ)"
        echo "vscodium: $extDir is an unmanaged directory and the declared" \
             "extension set belongs at that path; moving it to $moved" >&2
        run mv "$extDir" "$moved"
      fi
    '';

  # What the hourly probe diffs the live file against. A store symlink, so it
  # is exactly what this file declares and cannot be edited into agreement.
  home.file."${driftDir}/declared.json".source = declaredSettings;

  # Replaces the module's own `vscodiumMutableUserSettings` entry. `dagOf` is
  # `attrsOf (dagEntryOf …)`, so mkForce on one entry overrides just that
  # entry and leaves the rest of the module's activation alone.
  #
  # WHY REPLACE IT: the module's entry ends `vscodeMutableSettings … ||
  # exit 1`. On this host a failed home-manager activation poisons the deploy
  # SHA and nixos-deploy refuses to re-attempt it until someone clears the
  # poison by hand, so any of that function's nine failure paths — an
  # unparseable live file, an unreadable one, the snapshot/cmp race when
  # VSCodium writes during activation — would wedge auto-deploy over a
  # settings file. The function body is a `()` subshell, so those `exit 1`s
  # only set its status: calling it without `|| exit 1` keeps every bit of
  # its behaviour and makes the failure reportable instead of fatal.
  #
  # The deliberate consequence is that a failed merge leaves the live file
  # untouched and the declared settings unapplied for that deploy. That is
  # the right direction — the alternative was moving the user's file aside
  # mid-edit during an unattended webhook deploy — and it is not silent:
  # the marker below becomes a drift finding within the hour.
  #
  # If a future home-manager renames this entry, mkForce creates ours as a
  # second entry and upstream's `|| exit 1` returns. tests/base.nix asserts
  # that a malformed settings.json leaves the activation unit active, so that
  # rename fails the gate rather than reaching the daily driver.
  home.activation.vscodiumMutableUserSettings = lib.mkForce (
    lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      ${mutableSettingsFn}

      # Pre-merge, because afterwards live == declared for every overlapping
      # key and the evidence that one was overridden is gone. Never allowed
      # to fail the activation: it is a reporting aid, not a gate.
      if ${notDryRun}; then
        ${driftTool}/bin/vscodium-drift-tool record \
          --live ${lib.escapeShellArg settingsPath} \
          --declared ${declaredSettings} \
          --state-dir ${lib.escapeShellArg driftDir} || true
      fi

      if vscodeMutableSettings ${lib.escapeShellArg settingsPath} ${declaredSettings}; then
        ${pkgs.coreutils}/bin/rm -f ${lib.escapeShellArg mergeFailedMarker} || true
      else
        vscodiumMergeStatus=$?
        if ${notDryRun}; then
          ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg driftDir} || true
          ${pkgs.coreutils}/bin/printf \
            '{\n  "failed_at": "%s",\n  "status": %s\n}\n' \
            "$(${pkgs.coreutils}/bin/date -Iseconds)" \
            "$vscodiumMergeStatus" \
            > ${lib.escapeShellArg mergeFailedMarker} || true
        fi
        errorEcho "VSCodium settings merge failed (status $vscodiumMergeStatus); declared settings not applied this activation, live file left as it was. Reported by nixos-drift-analyzer."
        ${pkgs.libnotify}/bin/notify-send --urgency=normal \
          "VSCodium settings not applied" \
          "The declared settings could not be merged; your live file was left alone. Inspect: journalctl --user -u home-manager-${config.home.username}.service" \
          || true
      fi
    ''
  );
}
