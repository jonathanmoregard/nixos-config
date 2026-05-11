let
  # jonathan's personal SSH key from the Mint-era laptop. Kept as a
  # recipient until confirmed dead — separate concern from this PR.
  jonathanMint = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPf3ZLrzmf0pNSTJS603CaNb6in/ctXc0hZSJ9BflOVl jonathan@nixos-vm";

  # jonathan's personal SSH key on dellan (~/.ssh/id_ed25519.pub).
  # Lets the unprivileged user decrypt .age files locally without
  # sudo against the root-owned host key.
  jonathanDellan = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINT9HeHhu82OoNsAHe/QAh116pSEANuZUr1h5m8R8kpp jonathan@dellan";

  # VM SSH host key (used by agenix to decrypt secrets at activation time)
  vm = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJaYUR/n99axrFFFr/uv987jwaa6fYik7Ykf9iRSieZV root@nixos-vm";

  # Dellan laptop SSH host key (used by agenix to decrypt secrets at activation time)
  dellan = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJNvaYqBU7k/iTKPHcfVGYz5WJNVWnf0t26SX6Y7SZ0e root@dellan";

  allKeys = [ jonathanMint jonathanDellan vm dellan ];

  # Subset of recipients for CI/CD secrets — restrict to dellan host
  # key + jonathan's editing keys. CI itself runs on GitHub-hosted
  # runners and never decrypts these; only dellan's webhook + deploy
  # unit consumes them.
  ciKeys = [ jonathanMint jonathanDellan dellan ];
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
  # LLM provider API keys.
  #
  # Consumed by:
  #   - claude-cl-sync.service   (home/claude-services.nix EnvironmentFile)
  #   - research-agent-mcp       (home/research-agent.nix wrapper, planned)
  # File CONTENTS expected at decrypt time (env-format, one var per file):
  #   anthropic-api-key.age   — ANTHROPIC_API_KEY=sk-ant-...
  #   openai-api-key.age      — OPENAI_API_KEY=sk-...
  # ---------------------------------------------------------------------
  "anthropic-api-key.age".publicKeys = allKeys;
  "openai-api-key.age".publicKeys    = allKeys;
}
