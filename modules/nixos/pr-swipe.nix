# pr-swipe — human-gated PR triage (github:jonathanmoregard/pr-swipe).
#
# Split of power, enforced by uid rather than by convention:
#
#   collector  runs as ${cfg.user} (where the agents also run). Holds only the
#              user's own gh token; writes cards to inbox/, consumes outbox/.
#   gui        runs as the `prswipe` system user on the user's X display. Reads
#              inbox/, writes outbox/, talks to the executor socket. No network.
#   executor   runs as `prswipe`. The only process that ever sees the merge-gate
#              GitHub App key (agenix, host keys only → LoadCredential). Socket
#              /run/pr-swipe/executor.sock lives in a 0700 prswipe directory, so
#              nothing running as ${cfg.user} can connect to it.
#
# GitHub-side rulesets (only the merge-gate App may update a default branch)
# turn this split into the actual merge gate; see pr-swipe-apply-rulesets.
#
# Known residual, accepted in the pr-swipe spec §10: X11 has no inter-client
# isolation, so a process running as ${cfg.user} can inject keystrokes into the
# GUI window. The launcher grants `prswipe` display access with a server-side
# `xhost +SI:localuser:prswipe` entry instead of a cookie file, so no
# user-writable file decides which display the GUI connects to.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.prSwipe;
  root = "/var/lib/pr-swipe";
  keyFile = if cfg.keyFile != null then cfg.keyFile else config.age.secrets.pr-swipe-merge-gate.path;

  commonEnv = {
    PR_SWIPE_ROOT = root;
    PR_SWIPE_USER = cfg.githubLogin;
    PR_SWIPE_AGENT_LOGINS = lib.concatStringsSep "," cfg.agentLogins;
    SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
  };

  hardening = {
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    CapabilityBoundingSet = "";
    SystemCallArchitectures = "native";
    SystemCallFilter = [ "@system-service" ];
    UMask = "0077";
  };

  launcher = pkgs.writeShellApplication {
    name = "pr-swipe";
    runtimeInputs = [ pkgs.xhost pkgs.systemd ];
    text = ''
      # Server-side grant: only the prswipe uid, only on this display.
      xhost +SI:localuser:prswipe >/dev/null
      exec systemctl start pr-swipe-gui.service
    '';
  };
in
{
  options.services.prSwipe = {
    enable = lib.mkEnableOption "pr-swipe: swipe-triage of PRs with a uid-separated merge executor";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.pr-swipe;
      defaultText = lib.literalExpression "pkgs.pr-swipe";
    };
    user = lib.mkOption {
      type = lib.types.str;
      default = "jonathan";
      description = "Local account that runs the collector and sits at the display.";
    };
    githubLogin = lib.mkOption {
      type = lib.types.str;
      default = "jonathanmoregard";
    };
    agentLogins = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "GitHub logins whose PRs count as the user's agents (AI review allowed).";
    };
    appId = lib.mkOption {
      type = lib.types.ints.positive;
      description = "Numeric ID of the merge-gate GitHub App (not secret).";
    };
    keyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Path to the merge-gate App private key, read by systemd via LoadCredential.
        null = decrypt secrets/pr-swipe-merge-gate.age with agenix (production).
        Tests point this at a throwaway key.
      '';
    };
    collectorInterval = lib.mkOption {
      type = lib.types.ints.positive;
      default = 600;
      description = "Seconds between collector passes.";
    };
  };

  config = lib.mkIf cfg.enable {
    # `file`, not `rekeyFile`: encrypted to host keys only, never to the
    # agenix-rekey master identity (the user key agents could reach).
    age.secrets = lib.mkIf (cfg.keyFile == null) {
      pr-swipe-merge-gate = {
        file = ../../secrets/pr-swipe-merge-gate.age;
        owner = "root";
        group = "root";
        mode = "0400";
      };
    };

    users.groups.prswipe = { };
    users.groups.prswipe-io = { };
    users.users.prswipe = {
      isSystemUser = true;
      group = "prswipe";
      extraGroups = [ "prswipe-io" ];
      home = "${root}/state";
    };
    users.users.${cfg.user}.extraGroups = [ "prswipe-io" ];

    # inbox:   collector (user) writes 0640 cards, gui reads via the group.
    # outbox:  gui writes 0660 requests, collector reads and deletes them.
    # returns: executor → gui notes. state: executor + gui private state.
    systemd.tmpfiles.rules = [
      "d ${root}         0755 root     root       -"
      "d ${root}/inbox   2750 ${cfg.user} prswipe-io -"
      "d ${root}/outbox  2770 prswipe  prswipe-io -"
      "d ${root}/returns 0750 prswipe  prswipe    -"
      "d ${root}/state   0700 prswipe  prswipe    -"
    ];

    systemd.services.pr-swipe-executor = {
      description = "pr-swipe executor (sole holder of the merge-gate key)";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" "systemd-tmpfiles-setup.service" ];
      environment = commonEnv // {
        PR_SWIPE_APP_ID = toString cfg.appId;
        PR_SWIPE_SOCKET = "/run/pr-swipe/executor.sock";
      };
      serviceConfig = hardening // {
        User = "prswipe";
        Group = "prswipe";
        ExecStart = "${cfg.package}/bin/pr-swipe-executor";
        LoadCredential = [ "merge-gate.pem:${keyFile}" ];
        RuntimeDirectory = "pr-swipe";
        RuntimeDirectoryMode = "0700";
        ReadWritePaths = [ "${root}/state" "${root}/returns" ];
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    systemd.services.pr-swipe-gui = {
      description = "pr-swipe swipe deck (runs as prswipe on the user's display)";
      after = [ "pr-swipe-executor.service" ];
      environment = commonEnv // {
        DISPLAY = ":0";
        QT_QPA_PLATFORM = "xcb";
        HOME = "${root}/state";
        XDG_RUNTIME_DIR = "/run/pr-swipe-gui";
        PR_SWIPE_SOCKET = "/run/pr-swipe/executor.sock";
      };
      serviceConfig = hardening // {
        User = "prswipe";
        Group = "prswipe";
        ExecStart = "${cfg.package}/bin/pr-swipe-gui";
        RuntimeDirectory = "pr-swipe-gui";
        ReadWritePaths = [ "${root}/state" "${root}/returns" "${root}/outbox" "-/run/pr-swipe" ];
        # The X server's socket in /tmp/.X11-unix must stay visible.
        PrivateTmp = false;
        # The deck needs no network: X11 and the executor are both unix sockets.
        RestrictAddressFamilies = [ "AF_UNIX" ];
        IPAddressDeny = "any";
        # Qt's JIT-free paths still map executable memory for fonts/shaders.
        MemoryDenyWriteExecute = false;
      };
    };

    # The user (and therefore any agent running as the user) may start or
    # stop the GUI unit and nothing else: starting it only opens a window
    # for the human, it confers no decision power.
    security.polkit.enable = true;
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" &&
            action.lookup("unit") == "pr-swipe-gui.service" &&
            subject.user == "${cfg.user}" &&
            ["start", "stop", "restart"].indexOf(action.lookup("verb")) >= 0) {
          return polkit.Result.YES;
        }
      });
    '';

    systemd.user.services.pr-swipe-collector = {
      description = "pr-swipe collector (cards for the swipe deck)";
      wantedBy = [ "default.target" ];
      unitConfig.ConditionUser = cfg.user;
      environment = commonEnv // {
        PR_SWIPE_CLAUDE = "%h/.local/bin/claude";
        PATH = lib.mkForce "%h/.local/bin:/etc/profiles/per-user/${cfg.user}/bin:/run/current-system/sw/bin";
      };
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/pr-swipe-collector --interval ${toString cfg.collectorInterval}";
        Restart = "on-failure";
        RestartSec = 60;
      };
    };

    environment.systemPackages = [ launcher ];
  };
}
