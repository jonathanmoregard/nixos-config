# The daily-driver workstation as a QEMU test guest: the same modules
# flake.nix's mkWorkstation builds the real host from, minus what a VM
# cannot model. Every full-host node imports it (tests/lib/common.nix
# `node`, tests/microvm.nix), and lanes call that node `workstation`.
#
# Which host it models is flake.nix's `primaryHost`, passed in as
# `workstation.host` with `workstation.modules` (= workstationModules).
# A machine upgrade is a change to `primaryHost`, not to the tests.
{ workstation }:
{ lib, pkgs, ... }:
let
  hostDir = ../../hosts + "/${workstation.host}";
  githubAppKeyFixture = import ./github-app-key-fixture.nix { inherit pkgs; };
in
{
  imports = workstation.modules ++ [ (hostDir + "/default.nix") ];

  # The GitHub App key the broker signs with
  # (modules/nixos/github-app-broker), as a fixture this VM can open: the
  # real ciphertext is encrypted to the laptop's host key, and may not exist
  # yet.
  age.identityPaths = [ "${githubAppKeyFixture}/id_ed25519" ];
  services.githubAppBroker.keyCiphertext =
    lib.mkForce "${githubAppKeyFixture}/github-app-key.age";
  # The App id tests/base.nix writes into jonathan's client config.
  services.githubAppBroker.appId = lib.mkForce 123;

  # The laptop's real hardware/disk config. The virtualisation module
  # provides a virtio rootfs and the test framework boots without a
  # bootloader.
  disabledModules = [ (hostDir + "/hardware-configuration.nix") ];
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;

  # Hardware-only options a QEMU guest cannot model, forced off whatever
  # host is primary (a no-op where a host leaves one off). A new host that
  # enables another platform driver adds it here.
  #
  # tuxedo-drivers: boot.kernelModules loads tuxedo_keyboard, which probes
  # the laptop's embedded controller, and a udev rule writes the charging
  # profile into that driver's sysfs. The driver's build against the
  # profile's kernel stays gated by tests/tuxedo-profile.nix, which vm-base
  # builds.
  hardware.tuxedo-drivers.enable = lib.mkForce false;

  # Do not autostart the dictation app in a guest. autoLogin reaches
  # graphical-session.target, which pulls in voquill.service, and no guest has
  # a usable audio sink — so voquill's output-stream error path spins with no
  # backoff and no cap.
  #
  # Measured 2026-11-06, in the first vm-base run that ever EXECUTED it: the
  # old ExecStart was a wrapper around a binary under ~/Repos that does not
  # exist in a guest, so every earlier run died instantly and logged nothing.
  # Pointed at `pkgs.voquill` it starts, and then emits 67,770
  # `alsa::poll() returned POLLERR` lines in 113s — a sustained 598/s, and 93%
  # of that lane's entire output. journald never throttled it: it scales
  # RateLimitBurst by free disk space, and these guests have 12 GiB (17.6k-18.6k
  # messages per 30s window against a nominal 10000 burst, zero "Suppressed"
  # lines). voquill and aggregator-ingest-failure-notify are both uid-1003 user
  # units sharing one user journal, so the flood made that notifier's marker
  # unreadable and failed a tests/base.nix assertion that has nothing to do
  # with voquill. The notifier HAD fired; only the read-back was drowned.
  #
  # This lives here rather than in tests/lib/common.nix's `node` because
  # tests/microvm.nix imports THIS file directly and would otherwise keep the
  # autostart. Every lane on this file is covered: vm-base, vm-android-dev,
  # vm-autodoro, vm-listen-tools (all mkTest) and vm-microvm.
  #
  # It removes no coverage a guest could give — voquill needs an audio device,
  # a GPU and a real X session. The unit itself is still built and installed
  # here; only its autostart is dropped. The real host keeps
  # WantedBy=graphical-session.target. The unbounded error loop is an upstream
  # voquill bug, reported separately; the guest only made it visible.
  home-manager.users.jonathan.systemd.user.services.voquill.Install.WantedBy =
    lib.mkForce [ ];

  # The NixOS test framework turns the manual off for every node
  # (nixos/lib/testing/nixos-test-base.nix, "no-manual"), so
  # system.build.manual does not exist, and modules/nixos/offline-ai.nix
  # interpolates its optionsJSON and manualHTML into the offline-ai
  # wrapper. An empty stand-in lets the node evaluate without building the
  # manual. No VM lane runs offline-ai; the wrapper the host really
  # deploys, manual paths included, is exercised by the `offline-ai` check.
  system.build.manual =
    let
      stub = pkgs.runCommand "nixos-manual-test-stub" { } ''
        mkdir -p "$out/share/doc/nixos"
        printf '{}\n' > "$out/share/doc/nixos/options.json"
      '';
    in
    {
      optionsJSON = stub;
      manualHTML = stub;
    };
}
