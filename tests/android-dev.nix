# vm-android-dev: asserts the dellan host exposes the Android dev
# toolchain the intender-app project needs at the system level.
#
# Asserts on the prod-toplevel image that JAVA_HOME resolves to a
# runnable JDK and that ANDROID_HOME points at the composed SDK's real
# layout (the libexec/android-sdk prefix is an implicit nixpkgs contract).
#
# (No adbusers/group assertion — systemd 258 retired programs.adb in
# favour of systemd-udev's automatic uaccess rules, so the group is
# no longer provisioned. The android-tools package alone is enough.)
#
# Run: nix build .#checks.x86_64-linux.vm-android-dev -L
{ pkgs, inputs }:
(import ./lib/common.nix { inherit pkgs inputs; }).mkTest {
  name = "vm-android-dev";
  testScript = ''
    dellan.wait_for_unit("multi-user.target")

    # JAVA_HOME exported by programs.java.enable — gradle reads this
    # in preference to `java` on PATH, so a missing JAVA_HOME would
    # let `java -version` pass while gradle still failed to launch.
    # Login shells inherit environment.sessionVariables, so check via
    # a login shell rather than the default test-driver exec env.
    java_home = dellan.succeed("bash -lc 'echo -n \"$JAVA_HOME\"'")
    assert java_home, (
        f"JAVA_HOME unset under a login shell — programs.java.enable did not export it:\n[{java_home!r}]"
    )
    dellan.succeed(f"test -x {java_home}/bin/java")

    # ANDROID_HOME exported by environment.sessionVariables.
    android_home = dellan.succeed("bash -lc 'echo -n \"$ANDROID_HOME\"'")
    assert android_home, (
        f"ANDROID_HOME unset under a login shell:\n[{android_home!r}]"
    )

    # platform-tools + platforms;android-34 + build-tools;34.0.0 land
    # under the SDK root. Assert the three binaries / dirs AGP 8.x
    # touches at build time exist and look sane.
    dellan.succeed(f"test -x {android_home}/platform-tools/adb")
    dellan.succeed(f"test -f {android_home}/platforms/android-34/android.jar")
    dellan.succeed(f"test -x {android_home}/build-tools/34.0.0/aapt2")
  '';
}
