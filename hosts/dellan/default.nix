{ config, ... }:
{
  imports = [
    ./hardware-configuration.nix

    # Composable profiles. profiles/* hold feature slices that tests
    # can pull in independently of the rest of the host (so a test
    # only depends on what it actually exercises).
    ../../profiles/base.nix
    ../../profiles/keyring.nix
    ../../modules/nixos/agenix-rekey-common.nix

    ../../modules/nixos/desktop.nix
    ../../modules/nixos/laptop.nix
    ../../modules/nixos/tailscale.nix
    ../../modules/nixos/kindle.nix

    # CI/CD workflow modules. CI itself runs on GitHub-hosted runners
    # (ubuntu-latest); see .github/workflows/. The modules below cover
    # only the pieces that MUST live on dellan: pull-based deploy +
    # webhook latency optimization.
    ../../modules/nixos/nixos-auto-deploy.nix
    ../../modules/nixos/build-coordination.nix
    ../../modules/nixos/cachix-push.nix
    ../../modules/nixos/claude-agent-users.nix

    # research-agent microvm. The MCP server spawned by Claude Code
    # (via home/research-agent-mcp.nix) ssh's into the long-running
    # research-agent microvm for every research() call. The microvm is
    # synthesized as microvm@research-agent.service by microvm.nix.
    #
    # docker.nix kept for now (no remaining Nix consumer after this PR,
    # but interactive use is out of scope — removing it host-wide is a
    # separate audit).
    ../../modules/nixos/docker.nix
    ../../modules/nixos/research-agent-microvm.nix
    ../../modules/nixos/research-agent-microvm-healthcheck.nix

    # scraper microvm — sibling to research-agent for JS-rendering
    # crawls. See module header for the trust-boundary rationale.
    ../../modules/nixos/scraper-microvm.nix
    ../../modules/nixos/scraper-microvm-healthcheck.nix

    # Host-level Android dev tooling. Provides adb on PATH + JDK17 for
    # the AGP 8.x gradle builds in ~/Repos/intender-app and pairs with
    # the docker-android emulator the project ships in
    # infra/emulator/docker-compose.yml.
    ../../modules/nixos/android-dev.nix

    # Feature VM overrides — no-op for prod toplevel, only activates
    # under `config.system.build.vm`. See module header for usage.
    ../../modules/nixos/feature-vm.nix

    # `substack-url-tool` + `tts-tool` — Substack-article-to-MP3 CLI
    # pipeline. Both live in standalone flakes; this module installs
    # them and wraps tts-tool to inject FISH_AUDIO_API_KEY_FILE from
    # the agenix secret at runtime.
    ../../modules/nixos/listen-tools.nix
  ];

  # ---------------------------------------------------------------------
  # agenix-rekey per-host config.
  # hostPubkey = dellan's SSH ed25519 host key. Each .age secret's source
  # is encrypted to the master identity (see modules/nixos/agenix-rekey-common.nix);
  # `nix run .#agenix -- rekey` produces a copy in secrets/rekeyed/dellan/
  # encrypted to this hostPubkey, which is what the running system decrypts
  # against /etc/ssh/ssh_host_ed25519_key.
  # ---------------------------------------------------------------------
  age.rekey.hostPubkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJNvaYqBU7k/iTKPHcfVGYz5WJNVWnf0t26SX6Y7SZ0e root@dellan";
  age.rekey.localStorageDir = ../../secrets/rekeyed/dellan;

  # ---------------------------------------------------------------------
  # CI/CD workflow — agenix secret declarations (now rekey-managed).
  # ---------------------------------------------------------------------

  age.secrets.deploy-ssh-key.rekeyFile        = ../../secrets/deploy-ssh-key.age;
  age.secrets.github-webhook-secret.rekeyFile = ../../secrets/github-webhook-secret.age;
  age.secrets.gh-janitor-token.rekeyFile      = ../../secrets/gh-janitor-token.age;

  # LLM provider + research-agent secrets consumed by claude-cl-sync.service
  # and the research-agent-mcp wrapper. Both read raw key values with
  # `$(< file)` and export the matching env var themselves — `.age` files
  # contain the raw key only (no `KEY=` prefix). owner=jonathan + mode=0400
  # because the consumers run as the user, not root.
  age.secrets.anthropic-api-key = {
    rekeyFile = ../../secrets/anthropic-api-key.age;
    owner = "jonathan";
    group = "users";
    mode = "0400";
  };
  age.secrets.openai-api-key = {
    rekeyFile = ../../secrets/openai-api-key.age;
    owner = "jonathan";
    group = "users";
    mode = "0400";
  };
  age.secrets.exa-api-key = {
    rekeyFile = ../../secrets/exa-api-key.age;
    owner = "jonathan";
    group = "users";
    mode = "0400";
  };
  age.secrets.tavily-api-key = {
    rekeyFile = ../../secrets/tavily-api-key.age;
    owner = "jonathan";
    group = "users";
    mode = "0400";
  };
  age.secrets.claude-token = {
    rekeyFile = ../../secrets/claude-token.age;
    owner = "jonathan";
    group = "users";
    mode = "0400";
  };

  # Private half of the SSH keypair the MCP server uses to ssh into the
  # research-agent microvm. Matching public key is plaintext inside
  # modules/nixos/research-agent-microvm.nix as authorized_keys.
  age.secrets.research-agent-host-key = {
    rekeyFile = ../../secrets/research-agent-host-key.age;
    owner = "jonathan";
    group = "users";
    mode = "0400";
  };

  # jhanas-maxxing voice AI server secrets (Pipecat). User-space server
  # reads /run/agenix/jhanas-maxxing-env via python-dotenv; the env file's
  # GOOGLE_APPLICATION_CREDENTIALS line points at the GCP credentials secret
  # below in the same agenix runtime directory.
  age.secrets.jhanas-maxxing-env = {
    rekeyFile = ../../secrets/jhanas-maxxing-env.age;
    owner = "jonathan";
    group = "users";
    mode = "0400";
  };
  age.secrets.jhanas-maxxing-gcp-credentials = {
    rekeyFile = ../../secrets/jhanas-maxxing-gcp-credentials.age;
    owner = "jonathan";
    group = "users";
    mode = "0400";
  };

  # ---------------------------------------------------------------------
  # research-agent microvm — persisted state.
  #
  # The VM's SSH host keys live on this virtiofs RW share so the
  # host-side `known_hosts` pin (StrictHostKeyChecking=accept-new in
  # the MCP server's ssh command — pinned on first connect, then
  # verified strictly) remains valid across VM reboots. The dir must
  # exist before the microvm boots, otherwise virtiofsd mounts an
  # empty source and services.openssh fails to write its hostKey path.
  #
  # /var/lib (not /home/jonathan/.local/) because systemd-tmpfiles
  # refuses to canonicalize across an ownership boundary
  # (jonathan → root → jonathan) — fails with "unsafe path transition".
  # /var/lib has no such hop and is the conventional spot for daemon
  # state anyway.
  # ---------------------------------------------------------------------
  systemd.tmpfiles.rules = [
    "d /var/lib/research-agent 0700 root root -"
    "d /var/lib/research-agent/vm-ssh 0700 root root -"
  ];

  # ---------------------------------------------------------------------
  # CI/CD workflow — service options.
  # ---------------------------------------------------------------------

  services.buildCoordination.enable = true;   # nix max-jobs/cores caps

  services.nixos-auto-deploy = {              # Pull-based deploy + webhook
    enable = true;
    sshKeyFile = config.age.secrets.deploy-ssh-key.path;
    webhook = {
      enable = true;
      secretFile = config.age.secrets.github-webhook-secret.path;
    };
  };

  services.claudeAgentUsers.enable = true;    # claude-agent-N users
}
