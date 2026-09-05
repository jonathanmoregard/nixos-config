# Throwaway agenix material for the klaffat-infra test lane and for the
# feature VM's klaffat overrides.
#
# The real `secrets/klaffat-*.age` files are encrypted to dellan's HOST
# key, which no test VM has and no test may ever hold. So a lane that
# wants to assert "the secret decrypted, is 0400 root, and the wrapper
# read it" has to bring its own recipient. This derivation mints one at
# build time — a fresh ed25519 identity plus one ciphertext per secret
# encrypted to it — so nothing decryptable by a test ever lands in git.
#
# The identity ends up world-readable in /nix/store. That is fine and
# deliberate: it decrypts nothing but these fixtures, whose plaintexts
# are literal strings visible three lines below.
{ pkgs }:

pkgs.runCommand "klaffat-infra-test-secrets"
{
  nativeBuildInputs = [ pkgs.age pkgs.openssh pkgs.nix ];
} ''
  mkdir -p "$out"

  # The identity in-VM agenix decrypts with.
  ssh-keygen -q -t ed25519 -N "" -C "klaffat-infra test identity" \
    -f "$out/id_ed25519"
  pub="$(cat "$out/id_ed25519.pub")"

  # klaffat-demo-host-key must be a REAL private key: klaffat-infra-install
  # derives the public half from it with `ssh-keygen -y`, so a dummy string
  # would pass the "is it 0400 root" assertion while failing the only thing
  # the secret is for.
  ssh-keygen -q -t ed25519 -N "" -C "klaffat-demo test host key" \
    -f "$out/demo_host_key"
  age -r "$pub" -o "$out/klaffat-demo-host-key.age" < "$out/demo_host_key"
  rm -f "$out/demo_host_key"

  for n in hcloud-token cloudflare-api-token state-passphrase \
           aws-access-key-id aws-secret-access-key; do
    printf 'TEST-%s' "$n" | age -r "$pub" -o "$out/klaffat-$n.age"
  done

  # A syntactically real Nix signing key, so `nix key convert-secret-to-public`
  # and `nix store sign --key-file` have something valid to chew on.
  nix --extra-experimental-features nix-command \
    key generate-secret --key-name klaffat-demo-test-1 > "$out/signing-key"
  age -r "$pub" -o "$out/klaffat-nix-signing-key.age" < "$out/signing-key"
  rm -f "$out/signing-key"
''
