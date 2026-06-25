# Shared agenix-rekey config: master identity + storage scheme.
# Imported by every host that owns rekey-managed secrets. Per-host
# specifics (hostPubkey, localStorageDir) stay in each host's
# default.nix because they're literally per-host values.
#
# Master identity model:
#   - publicKey: jonathan's user ed25519 SSH key — what `agenix rekey`
#     encrypts the source .age files to.
#   - identity:  runtime path "/home/jonathan/.ssh/id_ed25519". NOT a
#     nix path — would copy the private key into the store, defeating
#     the purpose. agenix-rekey reads this when editing or rekeying.
#
# Storage scheme:
#   - storageMode = "local" — rekeyed per-host ciphertext lives in
#     secrets/rekeyed/<host>/ tracked in git. The host's private SSH
#     key is the only thing that decrypts that subtree, so committing
#     is safe.
{ ... }:
{
  age.rekey = {
    masterIdentities = [
      {
        identity = "/home/jonathan/.ssh/id_ed25519";
        pubkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINT9HeHhu82OoNsAHe/QAh116pSEANuZUr1h5m8R8kpp jonathan@dellan";
      }
    ];
    storageMode = "local";
    # Per-host localStorageDir is set in each host's default.nix because
    # the `local` storage mode needs a relative path expression that
    # evaluates against the flake root; hosts know their hostname so
    # they can compose the path correctly.
  };
}
