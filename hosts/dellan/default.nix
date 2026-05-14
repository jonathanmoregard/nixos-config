{ config, ... }:
{
  imports = [
    ./hardware-configuration.nix

    # Composable profiles. profiles/* hold feature slices that tests
    # can pull in independently of the rest of the host (so a test
    # only depends on what it actually exercises).
    ../../profiles/base.nix
    ../../profiles/keyring.nix

    ../../modules/nixos/desktop.nix
    ../../modules/nixos/laptop.nix
    ../../modules/nixos/tailscale.nix

    # CI/CD workflow modules. CI itself runs on GitHub-hosted runners
    # (ubuntu-latest); see .github/workflows/. The modules below cover
    # only the pieces that MUST live on dellan: pull-based deploy +
    # webhook latency optimization.
    ../../modules/nixos/nixos-auto-deploy.nix
    ../../modules/nixos/build-coordination.nix
    ../../modules/nixos/claude-agent-users.nix

    # Docker + research-agent dev container. The MCP server spawned by
    # Claude Code (via home/research-agent-mcp.nix) `docker exec`s into
    # the long-running `research-agent` container for every research()
    # call. Without these, the MCP server fails with
    # `docker not available: [Errno 2] No such file or directory: 'docker'`.
    ../../modules/nixos/docker.nix
    ../../modules/nixos/research-agent-container.nix

    # Feature VM overrides — no-op for prod toplevel, only activates
    # under `config.system.build.vm`. See module header for usage.
    ../../modules/nixos/feature-vm.nix
  ];

  # ---------------------------------------------------------------------
  # CI/CD workflow — agenix secret declarations.
  # ---------------------------------------------------------------------

  age.secrets.deploy-ssh-key.file        = ../../secrets/deploy-ssh-key.age;
  age.secrets.github-webhook-secret.file = ../../secrets/github-webhook-secret.age;
  age.secrets.gh-janitor-token.file      = ../../secrets/gh-janitor-token.age;

  # LLM provider + research-agent secrets consumed by claude-cl-sync.service
  # and the research-agent-mcp wrapper. Both read raw key values with
  # `$(< file)` and export the matching env var themselves — `.age` files
  # contain the raw key only (no `KEY=` prefix). owner=jonathan + mode=0400
  # because the consumers run as the user, not root.
  age.secrets.anthropic-api-key = {
    file = ../../secrets/anthropic-api-key.age;
    owner = "jonathan";
    group = "users";
    mode = "0400";
  };
  age.secrets.openai-api-key = {
    file = ../../secrets/openai-api-key.age;
    owner = "jonathan";
    group = "users";
    mode = "0400";
  };
  age.secrets.exa-api-key = {
    file = ../../secrets/exa-api-key.age;
    owner = "jonathan";
    group = "users";
    mode = "0400";
  };
  age.secrets.tavily-api-key = {
    file = ../../secrets/tavily-api-key.age;
    owner = "jonathan";
    group = "users";
    mode = "0400";
  };
  age.secrets.claude-token = {
    file = ../../secrets/claude-token.age;
    owner = "jonathan";
    group = "users";
    mode = "0400";
  };

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
