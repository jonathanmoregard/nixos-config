# vm-pr-swipe: the uid split that makes pr-swipe a merge gate holds at runtime.
#
#   - the executor starts with its credential and answers on its socket
#     (a malformed decision comes back refused: validation runs);
#   - the user account (where agents run) can neither connect to that socket
#     nor read the key, and cannot stop the executor;
#   - the user can launch the GUI (polkit), which maps a window as prswipe;
#   - the inbox/outbox handoff works across the two uids with the modes the
#     collector and GUI actually write.
#
# Run: nix build .#checks.x86_64-linux.vm-pr-swipe -L
{ pkgs, inputs }:
let
  # Throwaway RSA key; the real one is agenix, host keys only.
  testKey = pkgs.runCommand "pr-swipe-test-key.pem" { } ''
    ${pkgs.openssl}/bin/openssl genrsa -out $out 2048 2>/dev/null
  '';
  send = pkgs.writeText "pr-swipe-send.py" ''
    import json, socket, sys
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(10)
    s.connect("/run/pr-swipe/executor.sock")
    s.sendall((sys.argv[1] + "\n").encode())
    print(s.makefile().readline().strip())
  '';
in
(import ./lib/common.nix { inherit pkgs inputs; }).mkMinimalTest {
  name = "vm-pr-swipe";
  extraModules = [
    ../modules/nixos/pr-swipe.nix
    {
      environment.etc."pr-swipe-test/key.pem" = { source = testKey; mode = "0400"; };
      services.prSwipe = {
        enable = true;
        appId = 1;
        keyFile = "/etc/pr-swipe-test/key.pem";
      };
      environment.systemPackages = [ pkgs.python3 pkgs.xdotool ];
      # Stand-in for the user's X display; no auth file, local clients only.
      systemd.services.xvfb = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.xvfb}/bin/Xvfb :0 -nolisten tcp -screen 0 1280x1024x24";
      };
    }
  ];
  testScript = ''
    import json

    dellan.wait_for_unit("multi-user.target")
    dellan.wait_for_unit("pr-swipe-executor.service")
    dellan.wait_for_file("/run/pr-swipe/executor.sock")

    with subtest("executor answers prswipe and validates decisions"):
        out = dellan.succeed("runuser -u prswipe -- python3 ${send} '{\"action\": \"merge-now\"}'")
        r = json.loads(out)
        assert r["ok"] is False and "error" in r, r
        dellan.succeed("test -s /run/credentials/pr-swipe-executor.service/merge-gate.pem")

    with subtest("the user account cannot reach the executor or its key"):
        dellan.fail("runuser -u jonathan -- python3 ${send} '{}'")
        dellan.fail("runuser -u jonathan -- cat /run/credentials/pr-swipe-executor.service/merge-gate.pem")
        dellan.fail("runuser -u jonathan -- cat /etc/pr-swipe-test/key.pem")
        dellan.fail("runuser -u jonathan -- ls /var/lib/pr-swipe/state")
        dellan.fail("runuser -u jonathan -- systemctl stop pr-swipe-executor.service")
        dellan.succeed("systemctl is-active pr-swipe-executor.service")

    with subtest("inbox and outbox hand off across the two uids"):
        # collector side (user): cards land 0640 and inherit the shared group
        dellan.succeed("runuser -u jonathan -- sh -c 'echo {} > /var/lib/pr-swipe/inbox/c.json && chmod 0640 /var/lib/pr-swipe/inbox/c.json'")
        dellan.succeed("runuser -u prswipe -- cat /var/lib/pr-swipe/inbox/c.json")
        # gui side (prswipe): requests land 0660, the collector consumes and deletes them
        dellan.succeed("runuser -u prswipe -- sh -c 'echo {} > /var/lib/pr-swipe/outbox/r.json && chmod 0660 /var/lib/pr-swipe/outbox/r.json'")
        dellan.succeed("runuser -u jonathan -- cat /var/lib/pr-swipe/outbox/r.json")
        dellan.succeed("runuser -u jonathan -- rm /var/lib/pr-swipe/outbox/r.json")
        dellan.fail("runuser -u jonathan -- sh -c 'echo x > /var/lib/pr-swipe/returns/forged.json'")

    with subtest("the user launches the GUI, which maps a window as prswipe"):
        dellan.wait_for_unit("xvfb.service")
        dellan.wait_until_succeeds("DISPLAY=:0 ${pkgs.xdpyinfo}/bin/xdpyinfo >/dev/null")
        dellan.succeed("runuser -u jonathan -- env DISPLAY=:0 pr-swipe")
        dellan.wait_until_succeeds("DISPLAY=:0 xdotool search --name '^pr-swipe$'", timeout=60)
        dellan.succeed("test \"$(systemctl show -p User --value pr-swipe-gui.service)\" = prswipe")
        dellan.succeed("systemctl is-active pr-swipe-gui.service")
        dellan.fail("journalctl -u pr-swipe-gui.service | grep -q Traceback")

    with subtest("the running GUI still reaches the executor after the executor restarts"):
        # auto-deploy restarts the executor while the deck may be open
        dellan.succeed("systemctl restart pr-swipe-executor.service")
        dellan.wait_for_file("/run/pr-swipe/executor.sock")
        out = dellan.succeed(
            "nsenter -t $(systemctl show -p MainPID --value pr-swipe-gui.service) -m -- "
            "runuser -u prswipe -- python3 ${send} '{\"action\": \"merge-now\"}'")
        assert json.loads(out)["ok"] is False, out
  '';
}
