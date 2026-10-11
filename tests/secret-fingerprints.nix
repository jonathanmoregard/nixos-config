# vm-secret-fingerprints: known-value masking, producer half
# (modules/nixos/secret-fingerprints.nix) on real agenix secrets.
#
# Run: nix build .#checks.x86_64-linux.vm-secret-fingerprints -L
#
# The lane brings its own agenix recipient and ciphertexts, minted at build
# time from the literal throwaway values below (pattern:
# tests/lib/klaffat-fixtures.nix). Nothing here is a real credential, and
# the identity that decrypts them is world-readable in the store on
# purpose.
#
# Invariants, each measured on the generated file — not on the unit
# definition:
#
#   1. after boot the file exists, owned by jonathan, 0400, in a root
#      0755 directory; jonathan reads it, another user cannot;
#   2. schema v1; every fingerprint equals sha256(salt || value) for the
#      whole-file, KEY=value, JSON-string and [A-Za-z0-9_-]{12,} run
#      cases, computed HERE from the literal fixtures;
#   3. excluded: values < 12 chars, PEM private-key material, derived
#      words without digit+letter ("service_account");
#   4. root-only secrets: machine-looking tokens are fingerprinted, a
#      passphrase and a camel-case phrase are not; a root-OWNED but
#      jonathan-readable (group 0440) secret counts as readable, because
#      readability is probed as jonathan, not inferred from owner;
#   5. logs never contain a fixture value;
#   6. a restart is idempotent (same set, same salt);
#   7. a secret CHANGE on switch regenerates the file with no manual step
#      (restartTriggers), salt unchanged;
#   8. a missing secret leaves the /var/lib/unit-failures record Claude
#      sessions read and still writes the rest — WITHOUT failing the unit,
#      since a failed unit fails `nixos-rebuild switch` and would poison
#      the auto-deploy; the next good run clears the record;
#   9. the salt survives a reboot.
{ pkgs, inputs }:
let
  lib = pkgs.lib;

  # name -> { value, root }. `root = true`: default agenix owner root:root
  # 0400 (not readable by jonathan).
  fixtures = {
    fp-whole = { value = "Xq7vR2mK9pL4wT8nB3cJ6hF1"; };
    fp-env = {
      value = ''
        # throwaway env fixture
        API_KEY="k3Y-ENV-quoted-Value-1234"
        export OTHER='single-Quoted-Value-5678'
        SHORT=abc123
        URL=https://example.invalid/path?token=Ab12Cd34Ef56Gh78Ij90 # note gitleaks:allow (throwaway fixture)
      '';
    };
    fp-json = {
      value = builtins.toJSON {
        type = "service_account";
        private_key_id = "0123456789abcdef0123456789abcdef01234567";
        private_key = "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7\n-----END PRIVATE KEY-----\n"; # gitleaks:allow (throwaway fixture)
        nested.list = [ "Nested-JSON-Value-42abc" ];
      };
    };
    fp-short = { value = "short123"; };
    fp-passphrase = { value = "correct horse battery staple"; };
    fp-root-b62 = { value = "hZ3kQ9vB7mW2xR5tL8nC4pJ6yF1gD0sA"; root = true; };
    fp-root-hex = { value = "fedcba9876543210fedcba9876543210fedcba98"; root = true; };
    fp-root-passphrase = { value = "correct-horse-battery-staple"; root = true; };
    fp-root-camel = { value = "MyDogRex2019IsTheBestDog"; root = true; };
    fp-group = { value = "weak group pass 1234"; group = true; };
  };
  changedWhole = "Zz9yX8wV7uT6sR5qP4oN3mL2";

  secretsDrv = pkgs.runCommand "secret-fingerprints-test-secrets"
    {
      nativeBuildInputs = [ pkgs.age pkgs.openssh ];
      fixturesJson = builtins.toJSON (lib.mapAttrs (_: f: f.value) fixtures);
      inherit changedWhole;
      passAsFile = [ "fixturesJson" ];
    } ''
    mkdir -p "$out"
    ssh-keygen -q -t ed25519 -N "" -C "secret-fingerprints test identity" \
      -f "$out/id_ed25519"
    pub="$(cat "$out/id_ed25519.pub")"

    # The PEM case: a real OpenSSH private key, so its armour and body
    # are exactly what agenix would hold.
    ssh-keygen -q -t ed25519 -N "" -C "pem fixture" -f "$out/pem"
    age -r "$pub" -o "$out/fp-pem.age" < "$out/pem"
    rm -f "$out/pem.pub"

    ${pkgs.python3}/bin/python3 -I - "$fixturesJsonPath" "$out" <<'EOF'
    import json, sys
    for name, value in json.load(open(sys.argv[1])).items():
        open(f"{sys.argv[2]}/{name}.plain", "w").write(value)
    EOF
    for f in "$out"/*.plain; do
      n=$(basename "$f" .plain)
      age -r "$pub" -o "$out/$n.age" < "$f"
      rm -f "$f"
    done
    printf '%s' "$changedWhole" | age -r "$pub" -o "$out/fp-whole-changed.age"
  '';

  secretDecl = name: f: {
    file = "${secretsDrv}/${name}.age";
  } // lib.optionalAttrs (!(f.root or false) && !(f.group or false)) {
    owner = "jonathan";
    mode = "0400";
  } // lib.optionalAttrs (f.group or false) {
    owner = "root";
    group = "users";
    mode = "0440";
  };
in
(import ./lib/common.nix { inherit pkgs inputs; }).mkMinimalTest {
  name = "vm-secret-fingerprints";
  extraModules = [
    ../modules/nixos/secret-fingerprints.nix
    {
      services.secretFingerprints.enable = true;
      age.identityPaths = [ "${secretsDrv}/id_ed25519" ];
      age.secrets = (lib.mapAttrs secretDecl fixtures) // {
        fp-pem = { file = "${secretsDrv}/fp-pem.age"; owner = "jonathan"; };
      };
      users.users.eve = { isNormalUser = true; };
      users.users.jonathan.extraGroups = [ "users" ];

      specialisation.changed.configuration = {
        age.secrets.fp-whole.file = lib.mkForce "${secretsDrv}/fp-whole-changed.age";
      };
    }
  ];

  testScript = ''
    import hashlib, json, re

    FIX = json.loads(${builtins.toJSON (builtins.toJSON (lib.mapAttrs (_: f: f.value) fixtures))})
    CHANGED = ${builtins.toJSON changedWhole}
    OUT = "/run/secret-fingerprints/jonathan.json"
    RECORD = "/var/lib/unit-failures/secret-fingerprints.json"

    def load():
        return json.loads(dellan.succeed(f"cat {OUT}"))

    def fp(doc, v):
        return hashlib.sha256(bytes.fromhex(doc["salt"]) + v.encode()).hexdigest()

    def has(doc, v):
        return fp(doc, v) in set(doc["fingerprints"])

    dellan.wait_for_unit("multi-user.target")
    dellan.wait_for_unit("secret-fingerprints.service")

    with subtest("1. file, owner, mode, readers"):
        assert dellan.succeed(f"stat -c '%U %G %a' {OUT}").strip() == "jonathan root 400"
        assert dellan.succeed("stat -c '%U %a' /run/secret-fingerprints").strip() == "root 755"
        dellan.succeed(f"su jonathan -s /bin/sh -c 'cat {OUT}' >/dev/null")
        dellan.fail(f"su eve -s /bin/sh -c 'cat {OUT}'")
        assert dellan.succeed("stat -c '%U %a' /var/lib/secret-fingerprints/salt").strip() == "root 600"

    doc = load()
    with subtest("2. schema and included values"):
        assert doc["version"] == 1 and doc["min_len"] == 12, doc.keys()
        assert re.fullmatch(r"[0-9a-f]{64}", doc["salt"]), "salt shape"
        assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", doc["generated"]), doc["generated"]
        assert doc["fingerprints"] == sorted(set(doc["fingerprints"]))
        assert all(re.fullmatch(r"[0-9a-f]{64}", h) for h in doc["fingerprints"])
        assert set(doc) == {"version", "salt", "min_len", "fingerprints", "generated"}
        for v in [
            FIX["fp-whole"],                              # whole file
            "k3Y-ENV-quoted-Value-1234",                  # KEY="value"
            "single-Quoted-Value-5678",                   # export KEY='value'
            "https://example.invalid/path?token=Ab12Cd34Ef56Gh78Ij90",  # comment cut  gitleaks:allow (fixture)
            "Ab12Cd34Ef56Gh78Ij90",                       # run inside a value
            "0123456789abcdef0123456789abcdef01234567",   # JSON string
            "Nested-JSON-Value-42abc",                    # nested JSON string
            FIX["fp-passphrase"],                         # user-readable: no entropy rule
            FIX["fp-root-b62"],                           # root-only, machine-looking
            FIX["fp-root-hex"],
            FIX["fp-group"],                              # root-owned, group-readable
        ]:
            assert has(doc, v), f"missing fingerprint for fixture value #{len(v)} chars"

    with subtest("3+4. excluded values"):
        pem = dellan.succeed("cat /run/agenix/fp-pem")
        pem_runs = [r for r in re.findall(r"[A-Za-z0-9_-]+", pem) if len(r) >= 12]
        assert pem_runs, "PEM fixture has no long runs; the exclusion check would be vacuous"
        for v in [pem.strip(), *pem.splitlines(), *pem_runs]:
            assert not has(doc, v), "PEM material fingerprinted"
        for v in [
            FIX["fp-short"], "abc123",                    # < 12
            "service_account",                            # derived word, no digit
            FIX["fp-json"],                               # whole file holding a PEM
            "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7",  # JSON PEM body
            FIX["fp-root-passphrase"],                    # root-only, human-looking
            FIX["fp-root-camel"],
        ]:
            assert not has(doc, v), f"unexpected fingerprint ({len(v)} chars)"

    with subtest("5. logs carry no values"):
        log = dellan.succeed("journalctl -u secret-fingerprints.service --no-pager -o cat")
        assert "fingerprints written" in log, log
        for name, value in FIX.items():
            for piece in [value.strip(), *re.findall(r"[A-Za-z0-9_-]{8,}", value)]:
                if piece in ("service_account", "throwaway"):
                    continue
                assert piece not in log, f"value of {name} in journal"

    with subtest("6. restart is idempotent"):
        dellan.succeed("systemctl restart secret-fingerprints.service")
        again = load()
        assert again["salt"] == doc["salt"]
        assert again["fingerprints"] == doc["fingerprints"]

    with subtest("7. a secret change on switch regenerates without a manual step"):
        dellan.succeed(
            "/run/current-system/specialisation/changed/bin/switch-to-configuration test"
        )
        dellan.wait_until_succeeds(f"grep -q . {OUT}")
        changed = load()
        assert changed["salt"] == doc["salt"], "salt changed on regeneration"
        assert has(changed, CHANGED), "new value not fingerprinted after switch"
        assert not has(changed, FIX["fp-whole"]), "old value still fingerprinted"
        assert has(changed, FIX["fp-root-b62"])
        dellan.succeed("/run/booted-system/bin/switch-to-configuration test")
        back = load()
        assert back["fingerprints"] == doc["fingerprints"], "switch back did not regenerate"

    with subtest("8. a missing secret is recorded for Claude, keeps the rest, never fails the unit"):
        dellan.fail(f"test -e {RECORD}")
        dellan.succeed("rm -f $(readlink -f /run/agenix/fp-short)")
        dellan.succeed("systemctl restart secret-fingerprints.service")
        dellan.succeed("systemctl is-active secret-fingerprints.service")
        rec = json.loads(dellan.succeed(f"cat {RECORD}"))
        assert rec["unit"] == "secret-fingerprints.service", rec
        assert "1 of " in rec["summary"] and "NOT be masked" in rec["summary"], rec
        assert {"unit", "result", "exit_status", "failed_at", "summary", "inspect"} <= set(rec), rec
        assert dellan.succeed(f"stat -c '%a' {RECORD}").strip() == "644"
        log = dellan.succeed("journalctl -u secret-fingerprints.service --no-pager -o cat")
        assert "DEGRADED" in log and "1 missing" in log, log
        partial = load()
        assert has(partial, FIX["fp-whole"]), "partial run dropped readable secrets"
        assert has(partial, FIX["fp-root-b62"]), "partial run dropped root-only secrets"
        dellan.succeed("/run/current-system/activate")
        dellan.succeed("systemctl restart secret-fingerprints.service")
        dellan.fail(f"test -e {RECORD}")
        assert load()["fingerprints"] == doc["fingerprints"]

    with subtest("9. salt survives reboot"):
        dellan.shutdown()
        dellan.start()
        dellan.wait_for_unit("secret-fingerprints.service")
        rebooted = load()
        assert rebooted["salt"] == doc["salt"]
        assert rebooted["fingerprints"] == doc["fingerprints"]
  '';
}
