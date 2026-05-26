{ pkgs, ... }:
# Host-level Android development tooling for dellan.
#
# Why declared here (not a per-project devShell): the intender-app
# project uses a vendored ./gradlew + a docker-android emulator and
# expects `adb` and a JDK on PATH from the system. JDK17 is what the
# Android Gradle Plugin 8.x compileOptions in
# infra/emulator/workspace/src/app/build.gradle.kts pin to.
#
# `programs.adb.enable` was the canonical entry point in older NixOS
# releases (sets up the `adbusers` group + udev rules). It was removed
# in systemd 258 (nixpkgs-unstable, 2025): systemd-udev now handles the
# uaccess rules automatically, so the package alone is sufficient. See
# the upstream removal note in services/hardware/udev.nix.
{
  environment.systemPackages = [
    pkgs.android-tools  # adb, fastboot, mke2fs.android
  ];

  # JDK17 pinned in lockstep with the AGP toolchain declared in
  # ~/Repos/intender-app/infra/emulator/workspace/src/app/build.gradle.kts
  # (sourceCompatibility / targetCompatibility / jvmTarget all "17").
  # When the intender-app gradle config moves to 21, bump here too.
  # `programs.java.enable = true` also exports JAVA_HOME via
  # environment.sessionVariables — gradle uses it preferentially over
  # `java` on PATH, so both lookups resolve to the same JDK.
  programs.java = {
    enable = true;
    package = pkgs.jdk17;
  };
}
