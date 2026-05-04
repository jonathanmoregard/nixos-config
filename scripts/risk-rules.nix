{
  # ======================================================================
  # Source 1: package names — EXACT match against the package-name token
  # left of the colon in `nix store diff-closures` output.
  # `linux: 6.1 → 6.2` matches the literal string "linux", NOT "linux-firmware".
  # Add both names if you want both.
  # DO NOT add flake.lock to trivial — closure delta is the only signal for
  # lock bumps.
  # ======================================================================
  packages = {
    critical = [
      "linux"
      "linux-firmware"
      "systemd-boot"
      "grub"
      "bootspec"
    ];
    high = [
      "openssh"
      "systemd"
      "agenix"
      "pam"
    ];
    # any package add/remove not matched above → MEDIUM (default)
  };

  # Source 1b: agenix secret rotation appears as `*.age: ε → ∅` lines.
  # Match: filename SUFFIX `.age` on the package-name token.
  secrets = {
    high = [ ".age" ];
  };

  # ======================================================================
  # Source 2: paths inside the etc/ derivation. Match: PREFIX from
  # /etc-relative path. `systemd/system/` matches `systemd/system/foo.service`
  # but NOT `dbus-1/systemd/system/`.
  #
  # NOTE: bootloader/kernel risk is NOT detected here — boot.json lives at
  # /run/current-system/boot.json (not /etc), and kernel-modules at
  # /run/{current,booted}-system/kernel-modules/. Those changes surface in
  # Source 1 via the `linux`, `systemd-boot`, `grub`, `bootspec` package
  # entries. Don't add boot.json/kernel-modules to etcPaths — they would
  # be dead rules.
  # ======================================================================
  etcPaths = {
    critical = [ ];
    high = [
      "systemd/system/"
      "pam.d/"
      "sudoers"
      "ssh/"
      "shadow"
      "passwd"
    ];
    # other etc paths → MEDIUM
  };

  # ======================================================================
  # Source 3: source-tree paths from `git diff --name-only`. Match: PREFIX.
  # ======================================================================
  sourceTree = {
    trivial = [
      "docs/"
      "README"
      "tests/baselines/"
    ];
    # other source paths fall through to derivation-based scoring
  };
}
