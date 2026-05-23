# vm-kitty-momentum: end-to-end proof that kitty's X11 momentum
# scroll fires for a libinput touchpad device.
#
# Pipeline:
#   1. Boot dellan-in-a-VM, auto-login into Cinnamon/X.
#   2. Install a udev rule that tags any uinput device named
#      "synthetic-touchpad" as ID_INPUT_TOUCHPAD=1.
#   3. modprobe uinput.
#   4. Start touchpad-fling.py FIRST (background, --trigger-file mode).
#      Wait for DEVICE_READY — Xorg hot-adds the device, libinput
#      dispatches it as a touchpad.
#   5. THEN launch kitty with --debug-input. Kitty's startup XI device
#      enumeration sees the synth device with its complete ScrollClass
#      info, sets is_finger_based + is_highres on it.
#   6. Capture diagnostics while device alive — xinput list <id> shows
#      the ScrollClass increments that gate is_highres.
#   7. Touch the trigger file → fling fires.
#   8. Assert kitty's debug log contains MOMENTUM_PHASE_BEGAN.
#
# Run: nix build .#checks.x86_64-linux.vm-kitty-momentum -L
{ pkgs, inputs }:
let
  pyEvdev = pkgs.python3.withPackages (ps: [ ps.evdev ]);
  flingScript = ./touchpad-fling.py;
  xiMonitor = pkgs.runCommandCC "xi-scroll-monitor" {
    buildInputs = [ pkgs.libx11 pkgs.libxi ];
  } ''
    mkdir -p $out/bin
    cc ${./xi-scroll-monitor.c} -lX11 -lXi -o $out/bin/xi-scroll-monitor
  '';
in
(import ./lib/common.nix { inherit pkgs inputs; }).mkTest {
  name = "vm-kitty-momentum";
  testScript = ''
    dellan.wait_for_unit("multi-user.target")
    dellan.wait_for_unit("home-manager-jonathan.service")
    dellan.wait_for_unit("default.target", "jonathan")
    dellan.wait_for_x()

    # /etc is read-only on NixOS; /run/udev/rules.d is tmpfs and gets
    # merged with system rules.
    dellan.succeed(
        "mkdir -p /run/udev/rules.d && "
        "cat > /run/udev/rules.d/99-synthetic-touchpad.rules <<'EOF'\n"
        'ACTION=="add|change", SUBSYSTEM=="input", '
        'ATTRS{name}=="synthetic-touchpad", '
        'ENV{ID_INPUT}="1", ENV{ID_INPUT_TOUCHPAD}="1"\n'
        "EOF"
    )
    dellan.succeed("udevadm control --reload")

    dellan.succeed("modprobe uinput")
    dellan.succeed("test -c /dev/uinput")

    # Create synth device FIRST so kitty's startup XI enumeration sees
    # it. --trigger-file lets the harness fire the fling at the right
    # moment (after kitty is ready and pointer is positioned).
    # systemd-run --no-block detaches cleanly from the test-driver's
    # exec channel — `&` alone caused the channel to never EOF.
    dellan.succeed(
        "rm -f /tmp/fling.trigger /tmp/fling.log && "
        "systemd-run --collect --no-block --unit=fling-synth "
        "--property=StandardOutput=file:/tmp/fling.log "
        "--property=StandardError=file:/tmp/fling.log "
        "${pyEvdev}/bin/python3 ${flingScript} "
        "--trigger-file /tmp/fling.trigger --persist 5.0 "
        "--steps 30 --dy -35"
    )
    dellan.wait_until_succeeds(
        "grep -q DEVICE_READY /tmp/fling.log", timeout=15
    )
    # Let udev process + Xorg hot-add the device.
    dellan.sleep(2)

    # Diagnostic: xinput list shows ScrollClass info (valuator
    # increments that gate kitty's is_highres flag).
    print("[diag] xinput list (before kitty):\n" + dellan.succeed(
        "su jonathan -c 'DISPLAY=:0 ${pkgs.xinput}/bin/xinput list'"
    ))
    print("[diag] xinput list synthetic-touchpad (classes):\n"
          + dellan.succeed(
        "su jonathan -c 'DISPLAY=:0 ${pkgs.xinput}/bin/xinput list "
        "\"synthetic-touchpad\"'"
    ))
    print("[diag] xinput list-props synthetic-touchpad:\n" + dellan.succeed(
        "su jonathan -c 'DISPLAY=:0 ${pkgs.xinput}/bin/xinput list-props "
        "\"synthetic-touchpad\"'"
    ))
    print("[diag] udevadm info synth event:\n" + dellan.succeed(
        "ev=$(awk '/DEVICE_READY/ {print $2; exit}' /tmp/fling.log); "
        "udevadm info \"$ev\" 2>&1 || true"
    ))

    # Launch kitty AFTER synth device is attached. Kitty enumerates
    # XI devices at startup; we want our synth device to be present
    # in that enumeration, fully classed.
    # Confirm we're running the patched kitty (overlay applied).
    kitty_path = dellan.succeed(
        "su jonathan -c 'readlink -f $(command -v kitty)'"
    ).strip()
    print(f"[diag] kitty binary path: {kitty_path}")
    print("[diag] strings | grep scrolldbg in glfw-x11.so:\n" + dellan.succeed(
        "${pkgs.binutils-unwrapped}/bin/strings "
        "${pkgs.kitty}/lib/kitty/kitty/glfw-x11.so | "
        "grep -E 'scrolldbg|KITTY_SCROLL_DEBUG' | head -5"
    ))

    dellan.succeed(
        "su jonathan -c 'KITTY_SCROLL_DEBUG=1 DISPLAY=:0 setsid kitty -1 "
        "--debug-input </dev/null >/tmp/kitty.out 2>/tmp/kitty.log &'"
    )
    dellan.wait_until_succeeds(
        "find /tmp -maxdepth 1 -name 'kitty.sock-*' -type s | "
        "head -1 | grep -q .",
        timeout=60,
    )
    dellan.sleep(2)

    # Pointer over kitty window — smooth-scroll XI_Motion events
    # are delivered to the X window under the pointer.
    dellan.succeed(
        "su jonathan -c 'DISPLAY=:0 ${pkgs.xdotool}/bin/xdotool "
        "mousemove 200 200'"
    )

    # Start XI scroll-event monitor BEFORE the fling. Captures the actual
    # (deviceid, sourceid) tuple of XI_Motion events kitty receives, so
    # we can diff against kitty's scroll_devices[] entries to know which
    # slave device the events are routed through.
    dellan.succeed(
        "rm -f /tmp/xi-monitor.log && "
        "systemd-run --collect --no-block --unit=xi-monitor "
        "--property=User=jonathan "
        "--setenv=DISPLAY=:0 "
        "--property=StandardOutput=file:/tmp/xi-monitor.log "
        "--property=StandardError=file:/tmp/xi-monitor.log "
        "${xiMonitor}/bin/xi-scroll-monitor 60"
    )
    dellan.wait_until_succeeds(
        "grep -q READY /tmp/xi-monitor.log", timeout=10
    )

    # Fire the fling.
    dellan.succeed("touch /tmp/fling.trigger")
    dellan.wait_until_succeeds(
        "grep -q FLING_COMPLETE /tmp/fling.log", timeout=15
    )
    dellan.wait_until_succeeds(
        "grep -q PERSIST_DONE /tmp/fling.log", timeout=15
    )
    dellan.succeed("systemctl stop fling-synth 2>/dev/null || true")

    print("[diag] fling.log:\n" + dellan.succeed("cat /tmp/fling.log"))
    print("[diag] xi-monitor.log (which deviceid did kitty see?):\n"
          + dellan.succeed(
        "head -40 /tmp/xi-monitor.log 2>&1 || true"
    ))
    print("[diag] kitty-scrolldbg.log (was patched code path taken?):\n"
          + dellan.succeed(
        "head -60 /tmp/kitty-scrolldbg.log 2>&1 || echo 'NO LOG FILE'"
    ))
    dellan.succeed("systemctl stop xi-monitor 2>/dev/null || true")
    print("[diag] kitty.log tail:\n" + dellan.succeed(
        "tail -400 /tmp/kitty.log"
    ))

    # Primary assertion: kitty's momentum scroller fired.
    dellan.succeed("grep -q MOMENTUM_PHASE_BEGAN /tmp/kitty.log")
    dellan.succeed("grep -q MOMENTUM_PHASE_ACTIVE /tmp/kitty.log")
  '';
}
