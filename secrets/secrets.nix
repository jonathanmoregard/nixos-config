let
  # jonathan's personal SSH key (used from Mint laptop to manage secrets)
  jonathan = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPf3ZLrzmf0pNSTJS603CaNb6in/ctXc0hZSJ9BflOVl jonathan@nixos-vm";

  # VM SSH host key (used by agenix to decrypt secrets at activation time)
  vm = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJaYUR/n99axrFFFr/uv987jwaa6fYik7Ykf9iRSieZV root@nixos-vm";

  # Dellan laptop SSH host key (used by agenix to decrypt secrets at activation time)
  dellan = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJNvaYqBU7k/iTKPHcfVGYz5WJNVWnf0t26SX6Y7SZ0e root@dellan";

  allKeys = [ jonathan vm dellan ];

  # Subset of recipients for CI/CD secrets — restrict to dellan host
  # key + jonathan's editing key. CI itself runs on GitHub-hosted
  # runners and never decrypts these; only dellan's webhook + deploy
  # unit consumes them.
  ciKeys = [ jonathan dellan ];
in {
  # ---------------------------------------------------------------------
  # CI/CD workflow secrets.
  #
  # File CONTENTS expected at decrypt time:
  #   deploy-ssh-key.age         — raw OpenSSH private key (ed25519).
  #                                Used by nixos-deploy.service to fetch
  #                                origin/main from github.com.
  #   github-webhook-secret.age  — KEY=VALUE: WEBHOOK_SECRET=<hex>
  #                                (env-format because consumed via
  #                                 systemd EnvironmentFile)
  #   gh-janitor-token.age       — KEY=VALUE: GH_TOKEN=<pat>
  #                                (env-format; janitor cron for stale
  #                                 PR / branch / label cleanup)
  # ---------------------------------------------------------------------
  "deploy-ssh-key.age".publicKeys        = ciKeys;
  "github-webhook-secret.age".publicKeys = ciKeys;
  "gh-janitor-token.age".publicKeys      = ciKeys;

  # ---------------------------------------------------------------------
  # LLM provider + research-agent API keys / tokens.
  #
  # Consumed by:
  #   - claude-cl-sync.service   (home/claude-services.nix wrapper)
  #   - research-agent-mcp       (home/research-agent-mcp.nix wrapper)
  # File CONTENTS expected at decrypt time (RAW value, no `KEY=` prefix —
  # both wrappers read with `$(< file)` and export the appropriate env
  # var themselves):
  #   anthropic-api-key.age   — sk-ant-...
  #   openai-api-key.age      — sk-... | sk-proj-...
  #   exa-api-key.age         — Exa neural-search API key
  #   tavily-api-key.age      — Tavily web-search API key
  #   claude-token.age        — Claude Code OAuth token (research-agent
  #                              calls headless `claude` inside the
  #                              isolated dev container)
  # ---------------------------------------------------------------------
  "anthropic-api-key.age".publicKeys = allKeys;
  "openai-api-key.age".publicKeys    = allKeys;
  "exa-api-key.age".publicKeys       = allKeys;
  "tavily-api-key.age".publicKeys    = allKeys;
  "claude-token.age".publicKeys      = allKeys;
}
