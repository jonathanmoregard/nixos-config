# vm-secret-fingerprints: modules/nixos/secret-fingerprints.nix on real
# agenix secrets.
#
# Run: nix build .#checks.x86_64-linux.vm-secret-fingerprints -L
#
# The lane mints its own agenix identity and ciphertexts at build time
# from the throwaway literals below (pattern: tests/lib/klaffat-fixtures.nix);
# nothing here is a real credential.
#
# Invariants, measured on the generated file:
#   1. root:secret-fingerprints 0440 in a root 0755 dir; jonathan reads it
#      but cannot chmod, write or truncate it; another user cannot read it.
#   2. Schema v1; sha256(salt || value) is present for every value that
#      must be masked (single-line file, KEY=value values, JSON strings,
#      runs inside values).
#   3. Absent for values that must not be: < 12 chars, private-key
#      material, ordinary words, and weak root-only values (a phrase, a
#      word+year value, words+digits built to look random, an env value).
#      A root-OWNED but jonathan-readable secret counts as readable.
#   4. Logs never contain a fixture value.
#   5. A restart draws a fresh salt and yields the same values.
#   6. A secret changed by a switch is re-fingerprinted with no manual step.
#   7. An unreadable secret is reported through /var/lib/unit-failures
#      without failing the unit (a failed unit would fail the switch);
#      the next clean run removes the record.
{ pkgs, inputs }:
let
  lib = pkgs.lib;

  # access: "user" = jonathan 0400, "root" = root 0400,
  # "group" = root:users 0440 (root-owned, jonathan-readable).
  fixtures = {
    fp-whole = { access = "user"; value = "Xq7vR2mK9pL4wT8nB3cJ6hF1"; };
    fp-env = {
      access = "user";
      value = ''
        # throwaway env fixture
        API_KEY="k3Y-ENV-quoted-Value-1234"
        export OTHER='single-Quoted-Value-5678'
        SHORT=abc123
        PASSWORD=correcthorsebatterystaple
        URL=https://example.invalid/path?token=Ab12Cd34Ef56Gh78Ij90 # note gitleaks:allow (throwaway fixture)
      '';
    };
    fp-json = {
      access = "user";
      value = builtins.toJSON {
        type = "service_account";
        private_key_id = "0123456789abcdef0123456789abcdef01234567";
        private_key = "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7\n-----END PRIVATE KEY-----\n"; # gitleaks:allow (throwaway fixture)
        nested.list = [ "Nested-JSON-Value-42abc" ];
      };
    };
    fp-short = { access = "user"; value = "short123"; };
    fp-passphrase = { access = "user"; value = "correct horse battery staple"; };
    fp-group = { access = "group"; value = "weak group pass 1234"; };
    fp-root-b62 = { access = "root"; value = "hZ3kQ9vB7mW2xR5tL8nC4pJ6yF1gD0sA"; };
    fp-root-hex = { access = "root"; value = "fedcba9876543210fedcba9876543210fedcba98"; };
    fp-root-passphrase = { access = "root"; value = "correct-horse-battery-staple"; };
    fp-root-camel = { access = "root"; value = "MyDogRex2019IsTheBestDog"; };
    fp-root-built = { access = "root"; value = "KlaffatDemo1Hetzner2Prod3Token"; };
    fp-root-env = { access = "root"; value = "ROOT_PASSWORD=correcthorsebatterystaple\n"; };
  };
  changedWhole = "Zz9yX8wV7uT6sR5qP4oN3mL2";
  values = lib.mapAttrs (_: f: f.value) fixtures;

  secretsDrv = pkgs.runCommand "secret-fingerprints-test-secrets"
    {
      nativeBuildInputs = [ pkgs.age pkgs.openssh ];
      valuesJson = builtins.toJSON (values // { fp-whole-changed = changedWhole; });
      passAsFile = [ "valuesJson" ];
    } ''
    mkdir -p "$out"
    ssh-keygen -q -t ed25519 -N "" -C "test identity" -f "$out/id_ed25519"
    pub="$(cat "$out/id_ed25519.pub")"

    # A real OpenSSH private key, exactly as agenix would hold one.
    ssh-keygen -q -t ed25519 -N "" -C "pem fixture" -f "$out/pem"
    age -r "$pub" -o "$out/fp-pem.age" < "$out/pem"
    rm -f "$out/pem" "$out/pem.pub"

    ${pkgs.python3}/bin/python3 -I - "$valuesJsonPath" "$out" <<'EOF'
    import json, sys
    for name, value in json.load(open(sys.argv[1])).items():
        open(f"{sys.argv[2]}/{name}.plain", "w").write(value)
    EOF
    for f in "$out"/*.plain; do
      age -r "$pub" -o "''${f%.plain}.age" < "$f"
      rm -f "$f"
    done
  '';

  perms = {
    user = { owner = "jonathan"; mode = "0400"; };
    root = { };
    group = { owner = "root"; group = "users"; mode = "0440"; };
  };
in
(import ./lib/common.nix { inherit pkgs inputs; }).mkMinimalTest {
  name = "vm-secret-fingerprints";
  extraModules = [
    ../modules/nixos/secret-fingerprints.nix
    {
      services.secretFingerprints.enable = true;
      age.identityPaths = [ "${secretsDrv}/id_ed25519" ];
      age.secrets = lib.mapAttrs (name: f:
        { file = "${secretsDrv}/${name}.age"; } // perms.${f.access}) fixtures
        // { fp-pem = { file = "${secretsDrv}/fp-pem.age"; owner = "jonathan"; }; };
      users.users.eve.isNormalUser = true;
      users.users.jonathan.extraGroups = [ "users" ];

      specialisation.changed.configuration = {
        age.secrets.fp-whole.file = lib.mkForce "${secretsDrv}/fp-whole-changed.age";
      };
    }
  ];

  testScript = ''
    import hashlib, json, re

    FIX = json.loads(${builtins.toJSON (builtins.toJSON values)})
    CHANGED = ${builtins.toJSON changedWhole}
    OUT = "/run/secret-fingerprints/jonathan.json"
    RECORD = "/var/lib/unit-failures/secret-fingerprints.json"

    MASKED = [
        FIX["fp-whole"],                                  # single-line file
        "k3Y-ENV-quoted-Value-1234",                      # KEY="value"
        "single-Quoted-Value-5678",                       # export KEY='value'
        "correcthorsebatterystaple",                      # KEY=value, no digits
        "https://example.invalid/path?token=Ab12Cd34Ef56Gh78Ij90",  # comment cut  gitleaks:allow (fixture)
        "Ab12Cd34Ef56Gh78Ij90",                           # run inside a value
        "0123456789abcdef0123456789abcdef01234567",       # JSON string
        "Nested-JSON-Value-42abc",                        # nested JSON string
        FIX["fp-passphrase"],                             # readable: no entropy gate
        FIX["fp-group"],                                  # root-owned, group-readable
        FIX["fp-root-b62"],                               # root-only, random-shaped
        FIX["fp-root-hex"],
    ]
    NOT_MASKED = [
        FIX["fp-short"], "abc123",                        # < 12 chars
        "service_account",                                # ordinary word
        "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7",  # PEM body in JSON
        FIX["fp-root-passphrase"],                        # root-only, weak shapes
        FIX["fp-root-camel"],
        FIX["fp-root-built"],
        FIX["fp-root-env"].strip(),
    ]

    def load():
        return json.loads(dellan.succeed(f"cat {OUT}"))

    def has(doc, v):
        h = hashlib.sha256(bytes.fromhex(doc["salt"]) + v.encode()).hexdigest()
        return h in doc["fingerprints"]

    def assert_masking(doc):
        for v in MASKED:
            assert has(doc, v), f"not masked: {len(v)}-char fixture"
        for v in NOT_MASKED:
            assert not has(doc, v), f"masked but must not be: {len(v)}-char fixture"

    def as_jonathan(cmd):
        return f"su jonathan -s /bin/sh -c {cmd!r}"

    dellan.wait_for_unit("multi-user.target")
    dellan.wait_for_unit("secret-fingerprints.service")

    with subtest("1. ownership: readable, not tamperable"):
        assert dellan.succeed(f"stat -c '%U %G %a' {OUT}").strip() == "root secret-fingerprints 440"
        assert dellan.succeed("stat -c '%U %a' /run/secret-fingerprints").strip() == "root 755"
        dellan.succeed(as_jonathan(f"cat {OUT} >/dev/null"))
        dellan.fail(as_jonathan(f"chmod u+w {OUT}"))
        dellan.fail(as_jonathan(f"truncate -s 0 {OUT}"))
        dellan.fail(as_jonathan(f"echo x >> {OUT}"))
        dellan.fail(as_jonathan(f"rm -f {OUT}"))
        dellan.fail(f"su eve -s /bin/sh -c 'cat {OUT}'")

    doc = load()
    with subtest("2+3. schema and masked values"):
        assert set(doc) == {"version", "salt", "min_len", "fingerprints", "generated"}, doc.keys()
        assert doc["version"] == 1 and doc["min_len"] == 12
        assert re.fullmatch(r"[0-9a-f]{64}", doc["salt"])
        assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", doc["generated"]), doc["generated"]
        assert doc["fingerprints"] == sorted(set(doc["fingerprints"]))
        assert_masking(doc)
        pem = dellan.succeed("cat /run/agenix/fp-pem")
        pem_parts = [pem.strip(), *pem.splitlines(), *re.findall(r"[A-Za-z0-9_-]{12,}", pem)]
        assert len(pem_parts) > 3, "PEM fixture too small for a meaningful check"
        assert not any(has(doc, v) for v in pem_parts), "PEM material fingerprinted"

    with subtest("4. logs carry no values"):
        log = dellan.succeed("journalctl -u secret-fingerprints.service --no-pager -o cat")
        assert "fingerprints" in log, log
        for name, value in FIX.items():
            for piece in [value.strip(), *re.findall(r"[A-Za-z0-9_-]{8,}", value)]:
                if piece not in ("service_account", "throwaway", "gitleaks"):
                    assert piece not in log, f"value of {name} in journal"

    with subtest("5. restart: fresh salt, same values"):
        dellan.succeed("systemctl restart secret-fingerprints.service")
        again = load()
        assert again["salt"] != doc["salt"], "salt reused across runs"
        assert len(again["fingerprints"]) == len(doc["fingerprints"])
        assert_masking(again)

    with subtest("6. a secret changed by a switch is re-fingerprinted"):
        dellan.succeed("/run/current-system/specialisation/changed/bin/switch-to-configuration test")
        changed = load()
        assert has(changed, CHANGED), "new value not fingerprinted after switch"
        assert not has(changed, FIX["fp-whole"]), "old value still fingerprinted"
        dellan.succeed("/run/booted-system/bin/switch-to-configuration test")
        assert has(load(), FIX["fp-whole"]), "switch back did not regenerate"

    with subtest("7. an unreadable secret is reported, never fails the unit"):
        dellan.fail(f"test -e {RECORD}")
        dellan.succeed("rm -f $(readlink -f /run/agenix/fp-short)")
        dellan.succeed("systemctl restart secret-fingerprints.service")
        dellan.succeed("systemctl is-active secret-fingerprints.service")
        rec = json.loads(dellan.succeed(f"cat {RECORD}"))
        assert rec["unit"] == "secret-fingerprints.service", rec
        assert "1 of " in rec["summary"], rec
        assert {"unit", "result", "exit_status", "failed_at", "summary", "inspect"} <= set(rec), rec
        assert dellan.succeed(f"stat -c '%a' {RECORD}").strip() == "644"
        assert "DEGRADED" in dellan.succeed("journalctl -u secret-fingerprints.service -o cat")
        assert has(load(), FIX["fp-root-b62"]), "degraded run dropped the other secrets"
        dellan.succeed("/run/current-system/activate")
        dellan.succeed("systemctl restart secret-fingerprints.service")
        dellan.fail(f"test -e {RECORD}")
        assert_masking(load())
  '';
}
