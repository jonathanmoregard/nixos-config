let
  # jonathan's personal SSH key (used from Mint laptop to manage secrets)
  jonathan = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPf3ZLrzmf0pNSTJS603CaNb6in/ctXc0hZSJ9BflOVl jonathan@nixos-vm";

  # VM SSH host key (used by agenix to decrypt secrets at activation time)
  vm = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJaYUR/n99axrFFFr/uv987jwaa6fYik7Ykf9iRSieZV root@nixos-vm";

  # Dellan laptop SSH host key (used by agenix to decrypt secrets at activation time)
  dellan = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJNvaYqBU7k/iTKPHcfVGYz5WJNVWnf0t26SX6Y7SZ0e root@dellan";

  allKeys = [ jonathan vm dellan ];

  # Subset of recipients for CI/CD secrets — restrict to dellan host
  # key + jonathan's editing key. Excludes vm because the CI runner
  # only runs on dellan; a leaked key on vm shouldn't auto-decrypt.
  ciKeys = [ jonathan dellan ];
in {
  # ---------------------------------------------------------------------
  # CI/CD workflow secrets (round 7).
  #
  # File CONTENTS expected at decrypt time:
  #   github-runner-token.age    — raw GitHub registration token
  #                                (just the token string, no key=value)
  #   actions-runner-ssh-key.age — raw OpenSSH private key (ed25519)
  #   github-webhook-secret.age  — KEY=VALUE: WEBHOOK_SECRET=<hex>
  #                                (env-format because consumed via
  #                                 systemd EnvironmentFile)
  #   gh-janitor-token.age       — KEY=VALUE: GH_TOKEN=<pat>
  #                                (env-format; future janitor cron)
  # ---------------------------------------------------------------------
  "github-runner-token.age".publicKeys    = ciKeys;
  "actions-runner-ssh-key.age".publicKeys = ciKeys;
  "github-webhook-secret.age".publicKeys  = ciKeys;
  "gh-janitor-token.age".publicKeys       = ciKeys;

  # Attic RS256 token signing secret. Format expected:
  #   ATTIC_SERVER_TOKEN_RS256_SECRET="<base64 of `openssl genrsa -traditional 4096`>"
  "atticd-rs256-secret.age".publicKeys    = ciKeys;
}
