# vm-cache-publisher: wiring of modules/nixos/cache-publisher.nix + the
# global pre-push enqueue body. The gates themselves are covered by the
# cache-publisher-unit check; this lane proves the privilege split and the
# fail-closed behaviour with GitHub unreachable (the VM has no network):
#
#   jonathan cannot read the Cachix token, and cannot list the spool
#   jonathan's pre-push hook drops `owner/repo sha` for GitHub remotes only
#   the publisher runs as cache-publisher and consumes the spool
#   GitHub unreachable → entry kept for retry, nothing pushed
#   malformed spool entry → dropped
#
# Run: nix build .#checks.x86_64-linux.vm-cache-publisher -L
{ pkgs, inputs }:
(import ./lib/common.nix { inherit pkgs inputs; }).mkFeatureTest {
  name = "vm-cache-publisher";
  hm = ../home/_test-cache-publisher.nix;
  extraModules = [
    ../modules/nixos/cache-publisher.nix
    {
      services.cache-publisher.tokenFile = "/etc/cache-publisher-test-token";
      environment.etc."cache-publisher-test-token" = {
        text = "FAKE-TOKEN-NOT-REAL";
        user = "cache-publisher";
        group = "cache-publisher";
        mode = "0400";
      };
    }
  ];
  testScript = ''
    import shlex
    sha = "1" * 40
    dellan.wait_for_unit("multi-user.target")
    dellan.wait_for_unit("home-manager-jonathan.service")

    def as_jonathan(cmd):
        return f"su - jonathan -c {cmd!r}"

    # ── privilege split ────────────────────────────────────────────────
    dellan.fail(as_jonathan("cat /etc/cache-publisher-test-token"))
    dellan.fail(as_jonathan("ls /var/lib/cache-publisher/queue"))
    dellan.fail(as_jonathan("ls /var/lib/cache-publisher/state"))
    assert dellan.succeed("systemctl show -p User --value cache-publisher.service").strip() == "cache-publisher"
    dellan.succeed("systemctl is-active cache-publisher.path")
    dellan.succeed("systemctl is-enabled cache-publisher.timer cache-publisher-scan.timer")

    # Hold the publisher so the hook's spool entries can be inspected.
    dellan.succeed("systemctl stop cache-publisher.path")

    # ── enqueue hook: GitHub remotes only, silent ──────────────────────
    hook = "~/.config/git/hooks/pre-push"
    out = dellan.succeed(as_jonathan(
        f"cd /tmp && printf 'refs/heads/main {sha} refs/heads/main {"0" * 40}\\n' | {hook} origin https://github.com/me/tool.git"
    ))
    assert out.strip() == "", out
    dellan.succeed(as_jonathan(
        f"cd /tmp && printf 'refs/heads/x {"2" * 40} refs/heads/x {"0" * 40}\\n' | {hook} origin https://gitlab.com/me/other.git"
    ))
    dellan.succeed(as_jonathan(
        f"cd /tmp && printf '(delete) {"0" * 40} refs/heads/y {sha}\\n' | {hook} origin git@github.com:me/tool.git"
    ))
    entries = dellan.succeed("cat /var/lib/cache-publisher/queue/*").strip().splitlines()
    assert entries == [f"me/tool {sha}"], entries

    # Hostile entries: garbage, a symlink to the token, a FIFO, a directory.
    # The publisher must drop them, never echo the token, never hang, and
    # the directory it cannot remove must not re-trigger it in a loop.
    q = "/var/lib/cache-publisher/queue"
    dellan.succeed(as_jonathan(f"echo 'me/tool; touch /tmp/pwned' > {q}/bad"))
    dellan.succeed(as_jonathan(f"ln -s /etc/cache-publisher-test-token {q}/link"))
    dellan.succeed(as_jonathan(f"mkfifo {q}/fifo"))
    dellan.succeed(as_jonathan(f"mkdir {q}/junkdir && touch {q}/junkdir/f"))

    # ── publisher: GitHub unreachable → keep for retry, push nothing ───
    dellan.succeed("timeout 60 systemctl start cache-publisher.service")
    log = dellan.succeed("journalctl -u cache-publisher.service --no-pager")
    assert f"retry me/tool@{sha[:12]}: github unreachable" in log, log
    assert "drop malformed spool entry 'bad'" in log, log
    assert "drop malformed spool entry 'link'" in log, log
    assert "drop malformed spool entry 'fifo'" in log, log
    assert "FAKE-TOKEN" not in log, log
    assert "pushed" not in log, log
    dellan.succeed(f"test -f /var/lib/cache-publisher/state/pending/me__tool__{sha}")
    dellan.fail("test -e /tmp/pwned")
    left = dellan.succeed(f"ls -A {q}").split()
    assert left == ["junkdir"], left

    # The path unit drains new entries on its own.
    dellan.succeed("systemctl start cache-publisher.path")
    dellan.succeed(as_jonathan(f"echo 'me/other {"3" * 40}' > /var/lib/cache-publisher/queue/n1"))
    dellan.wait_until_succeeds(
        "journalctl -u cache-publisher.service --no-pager | grep -q 'retry me/other@333333333333'", timeout=60
    )
    # Gate (e) realises fixed-output derivations into the anonymous eval
    # store from inside the hardened service. Prove a FOD build works under
    # the unit's exact sandboxing, as cache-publisher (file:// stands in for
    # the internet the VM lacks: a loopback HTTP server).
    dellan.succeed("mkdir -p /srv/blob && echo public-bytes > /srv/blob/blob")
    dellan.succeed("systemd-run --unit blob-http ${pkgs.python3}/bin/python3 -m http.server 8000 --bind 127.0.0.1 --directory /srv/blob")
    dellan.wait_for_open_port(8000)
    h = dellan.succeed("nix-hash --type sha256 --flat --base32 /srv/blob/blob").strip()
    props = dellan.succeed(
        "systemctl show cache-publisher.service -p NoNewPrivileges -p ProtectSystem -p PrivateTmp "
        "-p PrivateDevices -p ProtectKernelTunables -p ProtectKernelModules -p ProtectControlGroups "
        "-p RestrictSUIDSGID -p LockPersonality -p ProtectHome -p RestrictAddressFamilies"
    ).splitlines()
    expr = (
        'derivation { name = "blob"; system = builtins.currentSystem; builder = "builtin:fetchurl"; '
        'url = "http://127.0.0.1:8000/blob"; outputHashMode = "flat"; outputHashAlgo = "sha256"; '
        f'outputHash = "{h}"; }}'
    )
    dellan.succeed(
        "systemd-run --wait --pipe -p User=cache-publisher -p Group=cache-publisher "
        + " ".join(f"-p {shlex.quote(p)}" for p in props if p and not p.endswith("="))
        + " -p ReadWritePaths=/var/lib/cache-publisher"
        + " -E HOME=/var/lib/cache-publisher"
        + " ${pkgs.nix}/bin/nix --extra-experimental-features nix-command build --impure --no-link"
        + f" --store /var/lib/cache-publisher/evalstore --expr '{expr}'"
    )

    # ...and with the unit's IP filter on top, the same fetch from loopback
    # is refused: "anonymous" also means "from outside", so nothing on
    # loopback/LAN/tailnet can stand in for a public download.
    deny = dellan.succeed("systemctl show cache-publisher.service -p IPAddressDeny --value").strip()
    assert "127.0.0.0/8" in deny and "100.64.0.0/10" in deny and "192.168.0.0/16" in deny, deny
    expr2 = expr.replace('"blob"', '"blob2"', 1)
    dellan.succeed("echo other-bytes > /srv/blob/blob2")
    h2 = dellan.succeed("nix-hash --type sha256 --flat --base32 /srv/blob/blob2").strip()
    expr2 = expr2.replace("8000/blob", "8000/blob2").replace(h, h2)
    dellan.fail(
        "systemd-run --wait --pipe -p User=cache-publisher -p Group=cache-publisher "
        + " ".join(f"-p {shlex.quote(p)}" for p in props if p and not p.endswith("="))
        + f" -p {shlex.quote('IPAddressDeny=' + deny)}"
        + " -p ReadWritePaths=/var/lib/cache-publisher"
        + " -E HOME=/var/lib/cache-publisher"
        + " ${pkgs.nix}/bin/nix --extra-experimental-features nix-command build --impure --no-link"
        + f" --store /var/lib/cache-publisher/evalstore --expr '{expr2}'"
    )
    resolv = dellan.succeed("systemctl show cache-publisher.service -p BindReadOnlyPaths --value")
    assert "cache-publisher-resolv.conf:/etc/resolv.conf" in resolv, resolv

    # The leftover directory does not keep re-triggering the publisher.
    dellan.sleep(10)
    runs = int(dellan.succeed(
        "journalctl -u cache-publisher.service --no-pager | grep -c 'Starting Push public' || true"
    ).strip())
    assert runs <= 3, f"publisher re-triggered {runs} times"
    dellan.succeed("systemctl is-active cache-publisher.path")
  '';
}
