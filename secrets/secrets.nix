# agenix rules for the klaffat provisioning secrets.
#
# Only the `klaffat-*.age` files live here. Every OTHER `.age` file in
# this directory is managed by agenix-rekey (see
# modules/nixos/agenix-rekey-common.nix): its source is encrypted to
# jonathan's USER key and `agenix rekey` produces the per-host copies in
# secrets/rekeyed/<host>/. Those must not be listed here — a rules entry
# would invite `agenix -e` to re-encrypt them under the wrong scheme.
#
# The klaffat secrets are deliberately outside that scheme. They are
# encrypted directly to dellan's HOST key, so jonathan — the principal an
# AI agent runs as — cannot decrypt them. See the header of
# modules/nixos/klaffat-infra.nix for the full rationale.
#
# ── Editing a secret ──────────────────────────────────────────────────
#
# agenix resolves the paths below relative to the rules file, so run it
# from THIS directory, as root, with the host key as the identity:
#
#   cd <checkout>/secrets
#   sudo agenix -e -i /etc/ssh/ssh_host_ed25519_key klaffat-hcloud-token.age
#
# (`sudo` because /etc/ssh/ssh_host_ed25519_key is root-only — which is
# the entire point.)
#
# ── Recovery recipient ────────────────────────────────────────────────
#
# Right now dellan's host key is the ONLY thing that can decrypt these
# files. If the laptop dies, the ciphertext in this repo is unrecoverable
# and every credential has to be reissued at the provider. Generate an
# offline age identity (`age-keygen`, stored off the laptop — paper or a
# hardware token), uncomment `recovery` below with its PUBLIC half, and
# re-encrypt each file once with the command above.
let
  # dellan's SSH host key — /etc/ssh/ssh_host_ed25519_key.pub.
  # Same value as `age.rekey.hostPubkey` in hosts/dellan/default.nix.
  dellan-host = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJNvaYqBU7k/iTKPHcfVGYz5WJNVWnf0t26SX6Y7SZ0e root@dellan";

  # Offline recovery identity — founder to fill in, then re-encrypt.
  # recovery = "age1...";

  klaffat = [
    dellan-host
    # recovery
  ];
in
{
  "klaffat-hcloud-token.age".publicKeys = klaffat;
  "klaffat-cloudflare-api-token.age".publicKeys = klaffat;
  "klaffat-state-passphrase.age".publicKeys = klaffat;
  "klaffat-demo-host-key.age".publicKeys = klaffat;

  # AWS (eu-north-1) IAM user `klaffat-laptop`: OpenTofu state bucket RW,
  # nix cache bucket RW, and admin over the Terraform-managed IAM/OIDC/
  # SecretsManager resources. The demo host's read-only user lives on the
  # host, never here.
  "klaffat-aws-access-key-id.age".publicKeys = klaffat;
  "klaffat-aws-secret-access-key.age".publicKeys = klaffat;

  # Binary-cache signing key (`sudo klaffat-publish`). A REAL key already —
  # generated root-side inside the encrypting pipeline, never written in the
  # clear, never displayed. Its public half lives in the klaffat host's
  # `nix.settings.trusted-public-keys`; the secret half is additionally
  # mirrored into AWS Secrets Manager by
  # `sudo klaffat-publish --upload-signing-key` so Actions can sign with the
  # same key. Rotating it means generating a new one, re-uploading, AND
  # updating the host — in that order.
  "klaffat-nix-signing-key.age".publicKeys = klaffat;
}
