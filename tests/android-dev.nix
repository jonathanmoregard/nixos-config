# vm-android-dev: asserts the dellan host exposes the Android dev
# toolchain the intender-app project needs at the system level.
#
# Two assertions on the prod-toplevel image:
#   - `adb` is on PATH and reports a sensible version line
#   - `java` is on PATH at JDK 17 (AGP 8.x compileOptions pin)
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

    # adb on PATH + reports a version line. `adb version` exits 0 even
    # without a server running and prints "Android Debug Bridge version".
    adb_out = dellan.succeed("adb version")
    assert "Android Debug Bridge" in adb_out, (
        f"adb on PATH but did not look like android-tools adb:\n{adb_out}"
    )

    # java on PATH + JDK17. `java -version` writes to stderr; capture
    # both. AGP 8.x needs major version 17.
    java_out = dellan.succeed("java -version 2>&1")
    assert 'version "17' in java_out, (
        f"expected JDK 17 on PATH, got:\n{java_out}"
    )

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
  '';
}
