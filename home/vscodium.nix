# Editor: VSCodium, with extensions, settings and keybindings all declared.
#
# Extensions come from the nixpkgs extension set rather than VSCodium's Open
# VSX marketplace: Open VSX does not carry GitLens at all, and a nix-baked set
# means the editor a rebuild produces is the editor every rebuild produces.
#
# settings.json / keybindings.json are generated from the Nix attrsets below,
# so a typo fails evaluation instead of silently disabling one line inside the
# editor (VSCodium reads these as JSONC and ignores what it cannot parse).
# The consequence is that both files land as read-only store symlinks: the
# Settings UI and any "don't show this again" checkbox cannot write them, and
# changing a setting is a PR like every other dotfile on this host.
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
{ pkgs, ... }:
let
  jsonFormat = pkgs.formats.json { };

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
in
{
  home.packages = [
    (pkgs.vscode-with-extensions.override {
      vscode = pkgs.vscodium;
      vscodeExtensions = with pkgs.vscode-extensions; [
        rust-lang.rust-analyzer
        tamasfe.even-better-toml
        eamodio.gitlens
        jnoortheen.nix-ide
        editorconfig.editorconfig
        alefragnani.project-manager
        zhuangtongfa.material-theme
        vscode-icons-team.vscode-icons
        esbenp.prettier-vscode
      ];
    })
  ];

  home.file.".config/VSCodium/User/settings.json".source =
    jsonFormat.generate "vscodium-settings.json" settings;
  home.file.".config/VSCodium/User/keybindings.json".source =
    jsonFormat.generate "vscodium-keybindings.json" keybindings;
}
