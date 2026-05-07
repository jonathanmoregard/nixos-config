{ pkgs, ... }:
# Claude-related user services. Captured from live host on 2026-04-27 — these
# units were installed imperatively (~/.config/systemd/user/) and would be
# lost on a fresh rebuild without this declarative copy.
#
# All three depend on supporting state under ~/.claude (dev-container venv,
# GitHub App private key, homunculus, container-staging). On a fresh install
# the units will fail at first tick until that scaffolding is set up
# separately.
{
  # claude-cl-sync — vet container-captured CL-v2 observations and merge to
  # host homunculus. Pulls latest scanner from origin/main on every tick.
  systemd.user.services.claude-cl-sync = {
    Unit = {
      Description = "Vet container-captured CL-v2 observations and merge to host homunculus";
      After = [ "default.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStartPre = "${pkgs.uv}/bin/uv pip install --python %h/.claude/dev-container/.venv/bin/python3 --no-cache --quiet --upgrade --force-reinstall injection-scanner@git+https://github.com/jonathanmoregard/injection-scanner@main";
      ExecStart = "%h/.claude/dev-container/.venv/bin/python3 %h/.claude/dev-container/bin/claude-cl-sync";
      Nice = 10;
      Environment = "PYTHONDONTWRITEBYTECODE=1";
      # ANTHROPIC_API_KEY + OPENAI_API_KEY env-format files, decrypted
      # at activation. The injection-scanner honeypot probes Anthropic
      # + OpenAI on every cl-sync tick; smoke fails-closed without these.
      EnvironmentFile = [
        "/run/agenix/anthropic-api-key"
        "/run/agenix/openai-api-key"
      ];

      # Hardening
      NoNewPrivileges = "yes";
      PrivateTmp = "yes";
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      ReadWritePaths = "%h/.claude/homunculus %h/.claude/container-staging %h/.claude/dev-container/.venv";
      ProtectKernelTunables = "yes";
      ProtectKernelModules = "yes";
      ProtectControlGroups = "yes";
      RestrictSUIDSGID = "yes";
      LockPersonality = "yes";
      MemoryMax = "1G";
      TasksMax = 256;
    };
  };

  systemd.user.timers.claude-cl-sync = {
    Unit.Description = "Run claude-cl-sync every 6h";
    Timer = {
      OnBootSec = "5min";
      OnUnitActiveSec = "6h";
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
  };

  # gh-token — rotate GitHub App installation tokens for active sandboxes.
  systemd.user.services.gh-token = {
    Unit.Description = "Rotate GitHub App installation tokens for active Claude sandboxes";
    Service = {
      Type = "oneshot";
      ExecStart = "%h/.claude/dev-container/bin/mint-gh-token";
      Nice = 5;

      NoNewPrivileges = "yes";
      PrivateTmp = "yes";
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      ReadWritePaths = "%h/.cache/gh-tokens";
      ReadOnlyPaths = "%h/.config/github-app/app.pem";
      ProtectKernelTunables = "yes";
      ProtectKernelModules = "yes";
      ProtectControlGroups = "yes";
      RestrictSUIDSGID = "yes";
      LockPersonality = "yes";
      MemoryMax = "128M";
      TasksMax = 32;
    };
  };

  systemd.user.timers.gh-token = {
    Unit.Description = "Rotate GitHub App tokens every 50 minutes";
    Timer = {
      OnBootSec = "1min";
      OnUnitActiveSec = "50min";
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
  };

  # claude-sandbox-proxy — hostname-allowlisted HTTP/HTTPS proxy for Claude
  # sandboxes. Long-running service, started at session login.
  systemd.user.services.claude-sandbox-proxy = {
    Unit = {
      Description = "Hostname-allowlisted HTTP/HTTPS proxy for Claude sandboxes";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      Type = "simple";
      ExecStart = "%h/.claude/dev-container/bin/claude-sandbox-proxy";
      Restart = "on-failure";
      RestartSec = 3;
      Environment = "PROXY_PORT=8888";

      NoNewPrivileges = "yes";
      PrivateTmp = "yes";
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      ReadOnlyPaths = "%h/.claude/dev-container";
      ProtectKernelTunables = "yes";
      ProtectKernelModules = "yes";
      ProtectControlGroups = "yes";
      RestrictSUIDSGID = "yes";
      LockPersonality = "yes";
      MemoryMax = "256M";
      TasksMax = 512;
    };
    Install.WantedBy = [ "default.target" ];
  };
}
