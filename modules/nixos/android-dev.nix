{ pkgs, ... }:
# Host-level Android development tooling for dellan.
#
# Why declared here (not a per-project devShell): the intender-app
# project uses a vendored ./gradlew + a docker-android emulator and
# expects `adb`, a JDK, and an Android SDK on PATH / under ANDROID_HOME
# from the system. JDK17 + platforms;android-34 + build-tools;34.0.0
# are what the Android Gradle Plugin 8.x compileOptions in
# infra/emulator/workspace/src/app/build.gradle.kts pin to
# (compileSdk = 34, sourceCompatibility = 17, targetSdk = 34).
#
# `programs.adb.enable` was the canonical entry point in older NixOS
# releases (sets up the `adbusers` group + udev rules). It was removed
# in systemd 258 (nixpkgs-unstable, 2025): systemd-udev now handles the
# uaccess rules automatically, so the package alone is sufficient. See
# the upstream removal note in services/hardware/udev.nix.
#
# The SDK derivation requires `config.android_sdk.accept_license =
# true` in the nixpkgs import — set at the flake level next to
# allowUnfree. Without it the build fails with a redirect to the SDK
# terms-of-service page at evaluation time.
let
  # Composed SDK — platform + build-tools matched to the intender-app
  # AGP toolchain. `cmdLineToolsVersion = "11.0"` pins the cmdline-tools
  # bundle; composeAndroidPackages defaults to "latest" so cmdline-tools
  # are already present, this only fixes the version (revision 11.0 is
  # confirmed valid in nixpkgs's androidenv repo.json).
  androidComposition = pkgs.androidenv.composeAndroidPackages {
    platformVersions = [ "34" ];
    buildToolsVersions = [ "34.0.0" ];
    cmdLineToolsVersion = "11.0";
    includeEmulator = false;       # we use docker-android, not the host SDK emulator
    includeSystemImages = false;   # likewise
    includeNDK = false;            # not used by intender-app
  };
  # SDK root path. `libexec/android-sdk` is an implicit contract across
  # nixpkgs's androidenv (compose-android-packages.nix's symlink farm
  # and build-app.nix both hardcode this prefix). If a future nixpkgs
  # bump relocates the layout, the assertions in tests/android-dev.nix
  # catch it (ANDROID_HOME/platforms/android-34/android.jar etc.).
  androidSdkRoot = "${androidComposition.androidsdk}/libexec/android-sdk";
in
{
  environment.systemPackages = [
    pkgs.android-tools             # adb, fastboot
    androidComposition.androidsdk  # platform-tools + platforms;34 + build-tools;34.0.0
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

  # ANDROID_HOME + ANDROID_SDK_ROOT — AGP 8.x reads either, but some
  # plugins (KSP, Hilt's KAPT fallback) only respect one. Setting both
  # avoids surprises. environment.sessionVariables exports them via
  # /etc/profile + the home-manager session-variables file, so they
  # land in interactive shells, login shells, and graphical sessions.
  environment.sessionVariables = {
    ANDROID_HOME = androidSdkRoot;
    ANDROID_SDK_ROOT = androidSdkRoot;
  };
}
