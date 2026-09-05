{ pkgs, ... }:
{
  home.username = "jonathan";
  home.homeDirectory = "/home/jonathan";
  home.stateVersion = "25.11";

  programs.home-manager.enable = true;

  home.packages = with pkgs; [
    zsh-powerlevel10k
    nodejs_22
    pnpm
    gitleaks
    gh
    direnv
    jq
    # Fonts
    nerd-fonts.jetbrains-mono
    # Dev toolchains
    rustc
    cargo
    python3
    uv
    # Intentionally NOT included (drift-scan 2026-04-19):
    # - terraform: not used for now
    # - yt-dlp: not wanted
    # - virt-manager / libvirtd stack: not needed on this host
  ];

  programs.git = {
    enable = true;
    settings = {
      user.name = "jonathanmoregard";
      user.email = "jonathan.more@hotmail.com";
      init.defaultBranch = "main";
      pull.rebase = true;
      credential."https://github.com".helper = "!/run/current-system/sw/bin/gh auth git-credential";
      core.hooksPath = "~/.config/git/hooks";
      core.excludesfile = "~/.config/git/ignore";

      # ── Hardening ──────────────────────────────────────────────────
      # Agents author branches on this machine and clone third-party
      # repos into it, so a repo-local git setting is attacker-supplied
      # input. Everything below is either an integrity check or a
      # default-deny; none of it changes how a normal fetch/commit/push
      # behaves. Behaviour-changing items (pull.ff only, commit signing)
      # deliberately stay out.

      # Object integrity. These are three separate code paths — clone
      # and fetch (transfer/fetch) and push (receive) — so setting one
      # does not cover the others.
      transfer.fsckObjects = true;
      fetch.fsckObjects = true;
      receive.fsckObjects = true;
      # Bundle-URI lets a server redirect a clone to fetch part of the
      # history from an arbitrary URL it names. Nothing here needs it.
      transfer.bundleURI = false;
      fetch.prune = true;

      # Transport: default-deny, then re-allow only what is used.
      # git:// is unauthenticated and unencrypted; ext:: executes a
      # command named in the remote URL. `file` stays at `user` so
      # direct local clones and worktree operations still work while
      # submodule/recursive contexts cannot reach it.
      protocol.version = 2;
      protocol.allow = "never";
      protocol.https.allow = "always";
      protocol.ssh.allow = "always";
      protocol.file.allow = "user";
      protocol.git.allow = "never";
      protocol.ext.allow = "never";
      http.sslVerify = true;

      # core.fsmonitor names a command git runs during ordinary status
      # and diff. A cloned repo can set it repo-locally, which turns
      # `git status` in that tree into code execution. Nothing here uses
      # fsmonitor, so pin it off instead of leaving it settable.
      core.fsmonitor = false;
      core.protectNTFS = true;
      core.protectHFS = true;

      # CVE-2024-32002: a crafted submodule can write into .git/hooks
      # during a recursive clone. No repo here uses submodules.
      submodule.recurse = false;
      # Refuse to treat a directory as a bare repo unless GIT_DIR names it.
      # Stops the embedded-bare-repo trick: a hostile repo commits a bare
      # repo directory inside itself, git discovery picks it up, and an
      # ordinary `git status` in that tree runs the attacker's hooks,
      # core.fsmonitor and diff.external.
      #
      # The cost is that `git -C ~/Repos/nixos-config ...` is refused, and
      # that is how this repo's own change flow used to start. #184 shipped
      # the setting without moving the callers and broke every worktree
      # operation, which also turned the daily nixos-worktree-sweep into a
      # silent no-op. The callers now anchor on the `main` worktree instead:
      # same refs, same worktree list, no discovery of a bare repo requested.
      # See the `ncfg` helper below, CLAUDE.md, and the nixos-config-dev
      # skill. The bare repo itself is unchanged and is still the shared
      # object store.
      #
      # `git worktree add` from a linked worktree is the supported path;
      # GIT_DIR=<bare> remains the escape hatch for the one bootstrap case
      # (recreating the `main` worktree itself). tests/base.nix asserts the
      # workflow rather than the setting, so a future change that breaks the
      # flow fails the gate whatever it is called.
      safe.bareRepository = "explicit";

      # Never guess an identity from hostname/username. An agent commit
      # carries the configured author or it fails loudly, rather than
      # landing as jonathan@dellan.
      user.useConfigOnly = true;

      # Forensics. reflogExpireUnreachable governs entries orphaned by
      # force-push, reset and rebase — the exact history that answers
      # "what did that get overwritten with" — and defaults to 30 days.
      gc.reflogExpire = "180.days";
      gc.reflogExpireUnreachable = "90.days";
    };
  };

  # Global gitignore. Second line of defence behind the gitleaks
  # pre-commit hook below: gitleaks catches secrets by content, this
  # catches the well-known filenames by shape, in every repo on this
  # machine including ones an agent clones and commits into.
  #
  # Deliberately NOT ignored: .npmrc — pnpm workspaces legitimately
  # commit one, and silently dropping it from `git add -A` would be a
  # confusing failure. The gitleaks hook covers the `_authToken=` case.
  home.file.".config/git/ignore".text = ''
    **/.claude/settings.local.json

    # Environment files (negations must follow the glob that catches them)
    .env
    .env.*
    !.env.example
    !.env.sample
    !.env.template

    # Keys and certificates
    *.pem
    *.key
    *.p12
    *.pfx
    *.jks

    # Credential stores
    .git-credentials
    .netrc
    .authinfo
    .pypirc
    credentials.json
    service-account*.json

    # Terraform state (contains resolved secret values in plaintext)
    *.tfstate
    *.tfstate.backup
  '';

  # Husky pre-commit hook helper — loads nvm so node-based hooks find the
  # right binary regardless of which shell the commit was made from.
  home.file.".huskyrc".text = ''
    # Load nvm for husky hooks
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
  '';

  # gitleaks pre-commit hook — blocks commits containing secrets
  home.file.".config/git/hooks/pre-commit" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      ${pkgs.gitleaks}/bin/gitleaks git --staged --redact --no-banner
      if [ $? -ne 0 ]; then
        echo ""
        echo "gitleaks: potential secret detected — commit blocked."
        echo "To bypass (only if you're sure): git commit --no-verify"
        exit 1
      fi
    '';
  };

  programs.zsh = {
    enable = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;

    oh-my-zsh = {
      enable = true;
      plugins = [ "git" ];
    };

    shellAliases = {
      ll = "ls -la";
      rebuild = "sudo nixos-rebuild switch --flake /etc/nixos#vm";
      update = "sudo nix flake update /etc/nixos && sudo nixos-rebuild switch --flake /etc/nixos#vm";
      drift = "cat ~/.local/share/nixos-drift-analyzer/latest.md 2>/dev/null || echo 'No drift report yet.'";
    };

    loginExtra = ''
      # NixOS drift check — runs once on login
      _nixos_drift_check() {
        # Only nag on interactive logins. A scripted `su - jonathan -c
        # '…'` runs a non-interactive login shell and must get clean
        # stdout — a banner here pollutes command output and breaks
        # anything parsing it (e.g. tests/automation reading an env var).
        [[ -o interactive ]] || return 0

        local warnings=()

        # Imperatively installed packages (nix-env) — outside the flake, lost on rebuild
        local imperative
        imperative=$(nix-env --query 2>/dev/null | grep -v '^$')
        if [[ -n "$imperative" ]]; then
          warnings+=("Imperative nix-env installs (not in flake, lost on rebuild):\n$(echo "$imperative" | sed 's/^/    /')")
        fi

        # Packages in PATH not traceable to /nix/store (rough heuristic)
        if [[ -d "$HOME/.local/bin" ]] && [[ -n "$(ls -A "$HOME/.local/bin" 2>/dev/null)" ]]; then
          warnings+=("~/.local/bin has files — check if these should be in home.packages")
        fi

        # Surface latest drift report if it exists
        local report="$HOME/.local/share/nixos-drift-analyzer/latest.md"
        if [[ -f "$report" ]]; then
          warnings+=("Drift report available: $report")
        fi

        if [[ ''${#warnings[@]} -gt 0 ]]; then
          echo ""
          echo "  NixOS drift warning — the following may be lost on rebuild:"
          for w in "''${warnings[@]}"; do
            echo "  * $w"
          done
          echo "  Encode these in your flake: /home/jonathan/Repos/nixos-config"
          echo ""
        fi
      }
      _nixos_drift_check
    '';

    initContent = ''
      # Powerlevel10k
      source ${pkgs.zsh-powerlevel10k}/share/zsh-powerlevel10k/powerlevel10k.zsh-theme
      [[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh

      # gh wrapper: ensure auth before gh commands
      gh() {
        if ! command gh auth status &>/dev/null 2>&1; then
          command gh auth login
        fi
        command gh "$@"
      }

      # claude wrapper: clear + resume most recent session by default.
      # Use `claudee` to start a fresh session.
      #
      # `--continue` is injected ONLY when the caller selected no session
      # themselves. `--continue` means "the most recent conversation in
      # this directory" and it OVERRIDES an explicit `--resume <sid>`, so
      # the old unconditional prepend silently opened the wrong transcript.
      # Observed 2026-09-04 during an incident recovery: two
      # `claude --resume <sid>` invocations both reattached to the session
      # already running, and ~/.cache/kitty-session/pane-sessions.tsv ended
      # up with three distinct kitty window ids mapped to one session id.
      #
      # The flag set was read off `claude --help` (v2.1.260), not guessed:
      # -c/--continue, -r/--resume, --session-id, -p/--print, plus the
      # three whose help text literally says "Resume …"/"attach to an
      # existing" — --from-pr, --teleport, --cloud. -p/--print counts
      # because it is non-interactive: silently continuing a prior
      # conversation changes what a scripted call means.
      #
      # MODIFIERS are deliberately absent, however session-ish they read.
      # A modifier shapes a session the caller selected some other way; it
      # cannot select one itself, so suppressing --continue for it leaves
      # the caller with nothing selected at all.
      #   --fork-session — help: "When resuming, create a new session ID
      #     instead of reusing the original (use with --resume or
      #     --continue)". Listing it here made bare `claude --fork-session`
      #     expand to itself, which by that same help text has nothing to
      #     fork and silently opens a fresh session instead. Absent, it
      #     expands to `--continue --fork-session` — fork the most recent
      #     conversation, which is the workflow. `--fork-session --resume
      #     <sid>` and `--fork-session -r <sid>` are unaffected either
      #     way: --resume/-r already trip the predicate.
      #   --bg/--background — starts the session in the background;
      #     `--continue --bg` reads as "continue the most recent one in
      #     the background", so the default still applies.
      #
      # Two argument shapes a naive scan misses, both verified against the
      # real binary rather than assumed:
      #   claude --resume=<sid>   commander accepts --long=VALUE
      #   claude -r<sid> / -cv    attached short values, and clustered
      #                           short booleans (-cv behaves as -c -v)
      # so any word starting with a single `-` that contains c, r or p
      # counts. A cluster like `-dp` (debug filter "p") false-positives;
      # the cost is a fresh session instead of a resumed one, which is the
      # harmless direction. The reverse — resuming a session the user did
      # not ask for — is the bug being fixed, so the scan deliberately
      # fails toward "do not inject".
      #
      # `--` ends the option list: everything after it is prompt text and
      # must not be scanned, so `claude -- --resume x` still gets
      # --continue and passes "--resume x" through as the prompt.
      #
      # Kept as a standalone helper because home/claude-egress-slice.nix
      # redefines claude() through `programs.zsh.initContent = mkAfter`
      # (its later definition wins) and calls this same predicate, so the
      # two wrappers cannot drift apart.
      _claude_selects_session() {
        local arg
        for arg in "$@"; do
          case "$arg" in
            --)                                             return 1 ;;
            --continue|--print)                             return 0 ;;
            --resume|--resume=*|--session-id|--session-id=*) return 0 ;;
            --from-pr|--from-pr=*|--teleport|--teleport=*)   return 0 ;;
            --cloud|--cloud=*)                               return 0 ;;
            --*)                                                      ;;
            -*[crp]*)                                        return 0 ;;
          esac
        done
        return 1
      }

      claude() {
        clear
        if _claude_selects_session "$@"; then
          command claude "$@"
        else
          command claude --continue "$@"
        fi
      }
      claudee() { clear; command claude "$@"; }

      # nixos-config git anchor. safe.bareRepository = explicit means
      # `git -C ~/Repos/nixos-config ...` is refused, so worktree operations
      # address the `main` browse worktree instead — same refs, same
      # worktree list. Here so the long path is not muscle memory:
      #   ncfg worktree add ~/Repos/nixos-config-worktrees/foo -b feat/foo main
      #   ncfg worktree remove ~/Repos/nixos-config-worktrees/foo
      #   ncfg worktree list
      ncfg() { git -C "$HOME/Repos/nixos-config-worktrees/main" "$@"; }
    '';

    envExtra = ''
      export ANDROID_HOME="$HOME/Android/Sdk"
      export PATH="$PATH:$ANDROID_HOME/emulator:$ANDROID_HOME/platform-tools"
      # Prepend so user-installed binaries (e.g. claude-code native
      # installer at ~/.local/share/claude/versions/) win over nix-pkg
      # fallbacks. Required for picking up self-updating tools.
      export PATH="$HOME/.local/bin:$PATH"
    '';
  };

  home.file.".p10k.zsh".source = ../dotfiles/p10k.zsh;
}
