# A throwaway GitHub App private key for test and feature VMs, plus the
# matching public key (for a fake GitHub API to verify JWTs against) and the
# key encrypted to a throwaway age identity (for agenix to open in the VM).
# Everything here is world-readable in /nix/store and authenticates nowhere.
#
#   $out/app.pem             the RSA private key (plaintext)
#   $out/app.pub.pem         its public key
#   $out/id_ed25519          age identity that opens github-app-key.age
#   $out/github-app-key.age  app.pem encrypted to that identity
{ pkgs }:
pkgs.runCommand "github-app-key-fixture"
  { nativeBuildInputs = [ pkgs.age pkgs.openssh pkgs.openssl ]; } ''
    mkdir -p "$out"
    openssl genrsa -out "$out/app.pem" 2048
    openssl rsa -in "$out/app.pem" -pubout -out "$out/app.pub.pem"
    ssh-keygen -q -t ed25519 -N "" -C "github-app-key fixture identity" -f "$out/id_ed25519"
    age -r "$(cat "$out/id_ed25519.pub")" -o "$out/github-app-key.age" < "$out/app.pem"
  ''
