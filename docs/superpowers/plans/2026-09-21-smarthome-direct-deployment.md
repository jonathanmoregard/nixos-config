# Smarthome Direct Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (default) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `home-server` pull signed smarthome package releases directly from GitHub/Cachix, activate them through a two-generation app profile, and never compile or retain build closures locally.

**Architecture:** NixOS owns a local service module plus a cache-only package deployer. The deployer resolves an exact Git commit, evaluates its expected package path, verifies the recursively signed Cachix closure, atomically switches `/nix/var/nix/profiles/smarthome`, checks service health, and rolls back on failure. The first rollout leaves the old smarthome flake input inert as a migration remnant; a separate cleanup PR removes it only after live direct-deploy proof. Operating-system and application releases are already independent because production no longer imports the app module or package through that input.

**Tech Stack:** NixOS modules/tests, Bash, systemd, Nix profiles/store signatures, Git/SSH, agenix-rekey, Cachix

---

## File map

- `modules/nixos/house-automation-service.nix`: host-owned TOML rendering, system user, stable-profile command, and service hardening.
- `modules/nixos/smarthome-hydrate-release-paths.sh`: cache-only copy, signature import, recursive signer verification.
- `modules/nixos/smarthome-activate-package.sh`: profile switch, health gate, rollback, atomic markers, two-generation pruning.
- `modules/nixos/smarthome-auto-deploy.nix`: Git polling, exact package evaluation, systemd timer/service, pinned GitHub host keys.
- `modules/nixos/home-server-services.nix`: host composition and enablement options.
- `profiles/home-server-base.nix`: explicit low-disk Nix retention settings.
- `hosts/home-server/{default,deployment-identity}.nix`: encrypted app deploy key declaration and wiring.
- `tests/smarthome-hydrator.nix`: real signed/unsigned/missing cache harness.
- `tests/smarthome-activator.nix`: success, rollback, markers, and generation-pruning harness.
- `tests/home-server.nix`: host integration plus one-node production-systemd smoke.
- `flake.nix`: expose new checks while retaining the inert smarthome input until post-deploy cleanup.
- `docs/home-server/README.md`: operations, disk use, rollback, and credential boundaries.

### Task 1: Replace imported application module with host-owned service boundary

**Files:**
- Create: `modules/nixos/house-automation-service.nix`
- Modify: `modules/nixos/home-server-services.nix`
- Modify: `tests/home-server.nix`

- [ ] **Step 1: Make the host contract fail on the desired stable executable**

Add these values to `/etc/home-server-contract.json` in `tests/home-server.nix`:

```nix
automationExecutable = config.services.houseAutomation.executable;
automationCondition = config.systemd.services.house-automationd.unitConfig.ConditionFileIsExecutable;
```

Add assertions:

```python
assert values["automationExecutable"] == "/nix/var/nix/profiles/smarthome/bin/house-automationd", values
assert values["automationCondition"] == "/nix/var/nix/profiles/smarthome/bin/house-automationd", values
```

Stage and run:

```bash
git add tests/home-server.nix
nix build --no-link .#checks.x86_64-linux.vm-home-server -L
```

Expected: FAIL because imported app module has no `executable` option.

- [ ] **Step 2: Create local service module**

Copy the option validation, credential filtering, TOML generation, system user,
state directory, restart policy, and hardening directives from the reviewed
smarthome `nix/module.nix`. Replace its package option with:

```nix
executable = mkOption {
  type = types.str;
  default = "/nix/var/nix/profiles/smarthome/bin/house-automationd";
  description = "Absolute house-automationd executable selected by the dedicated app profile.";
};
```

Remove `environment.systemPackages = [ cfg.package ];`. Add validation and the
stable command:

```nix
{
  assertion = lib.hasPrefix "/" cfg.executable && !lib.hasInfix "\n" cfg.executable;
  message = "services.houseAutomation.executable must be an absolute single-line path";
}

systemd.services.house-automationd = {
  unitConfig.ConditionFileIsExecutable = cfg.executable;
  serviceConfig.ExecStart = "${cfg.executable} --config ${configFile} --state /var/lib/house-automation/state.sqlite3";
};
```

Import `./house-automation-service.nix` from `home-server-services.nix`.

- [ ] **Step 3: Give the existing host VM an explicit integration fixture**

Create `fakeAutomation` in `tests/home-server.nix` with
`pkgs.writeShellApplication`. It must parse and ignore `--config`/`--state`,
start `python3 -m http.server 9876 --bind 127.0.0.1`, and keep running. Set:

```nix
services.houseAutomation.executable = lib.mkForce "${fakeAutomation}/bin/house-automationd";
```

Replace application-semantic MQTT assertions with integration assertions for
active service, loopback health HTTP 200, state directory, and hardening. The
smarthome repository's simulated-house lane remains sole owner of automation
semantics.

- [ ] **Step 4: Parse and prove green host integration**

```bash
git add modules/nixos/house-automation-service.nix modules/nixos/home-server-services.nix tests/home-server.nix
nix-instantiate --parse modules/nixos/house-automation-service.nix >/dev/null
nix-instantiate --parse modules/nixos/home-server-services.nix >/dev/null
nix build --no-link .#checks.x86_64-linux.vm-home-server -L
git diff --check
```

Expected: PASS.

- [ ] **Step 5: Commit service boundary**

```bash
git commit -m "refactor(home-server): own automation service boundary"
```

### Task 2: Add cache-only signed closure hydration

**Files:**
- Create: `modules/nixos/smarthome-hydrate-release-paths.sh`
- Create: `tests/smarthome-hydrator.nix`
- Modify: `flake.nix`

- [ ] **Step 1: Write red signed-cache harness**

`tests/smarthome-hydrator.nix` must generate a disposable Nix signing key at
test runtime, create one signed file binary cache and one unsigned cache, and
invoke the deployed helper against three cases:

```bash
expect_success signed --from "file://$SIGNED_CACHE" --trusted-key "$PUBLIC_KEY" "$SIGNED_PATH"
expect_failure unsigned --from "file://$UNSIGNED_CACHE" --trusted-key "$PUBLIC_KEY" "$UNSIGNED_PATH"
expect_failure missing --from "file://$SIGNED_CACHE" --trusted-key "$PUBLIC_KEY" "$MISSING_PATH"
```

Each invocation must export an isolated `NIX_STORE_DIR`/`NIX_STATE_DIR`, use a
two-second timeout and one attempt, and assert logs contain either `signature
verification failed` or `not available` for negative cases. Add:

```nix
smarthome-hydrator = import ./tests/smarthome-hydrator.nix {
  inherit pkgs;
  script = ./modules/nixos/smarthome-hydrate-release-paths.sh;
};
```

Run after staging. Expected: FAIL because helper is absent.

- [ ] **Step 2: Implement hydrator from proven Klaffat boundary**

Start from `/home/jonathan/Repos/klaffat/deploy/scripts/hydrate-release-paths.sh`.
Keep its strict argument validation, monotonic deadline, process-group timeout,
`nix copy --option max-jobs 0 --option always-allow-substitutes true`, signature
copy, recursive `nix store verify --sigs-needed 1`, and signer-name check.
Change only source URL validation from S3-only to:

```bash
case "$source_url" in
  https://*|file://*) ;;
  *) usage ;;
esac
```

Add both `--option fallback false` and `--option builders ""` to `nix copy`.
No command may realize a derivation.

- [ ] **Step 3: Run focused harness and parser**

```bash
git add modules/nixos/smarthome-hydrate-release-paths.sh tests/smarthome-hydrator.nix flake.nix
bash -n modules/nixos/smarthome-hydrate-release-paths.sh
nix-instantiate --parse tests/smarthome-hydrator.nix >/dev/null
nix build --no-link .#checks.x86_64-linux.smarthome-hydrator -L
git diff --check
```

Expected: PASS; signed succeeds, unsigned and missing fail.

- [ ] **Step 4: Commit hydrator**

```bash
git commit -m "feat(home-server): verify cached smarthome closures"
```

### Task 3: Add atomic app-profile activation and rollback

**Files:**
- Create: `modules/nixos/smarthome-activate-package.sh`
- Create: `tests/smarthome-activator.nix`
- Modify: `flake.nix`

- [ ] **Step 1: Write red activator harness**

Build three fixture packages named `house-automationd`: healthy v1, unhealthy
v2, healthy v3. Stub `systemctl` and `curl` through `PATH`, use an isolated Nix
profile, and assert this exact sequence:

```text
activate v1 -> last-success=v1 and profile=v1
activate v2 -> exit 1, last-failure=v2, profile restored to v1
activate v3 -> last-success=v3 and profile=v3
activate v1 again -> profile=v1 and exactly two generations remain
```

Also send `TERM` after profile mutation and assert either the old profile is
restored or exit status 2 plus `rollback incomplete` is recorded. Wire the
check as `checks.x86_64-linux.smarthome-activator`; first run must fail because
script is absent.

- [ ] **Step 2: Implement activation transaction**

Implement this public interface:

```text
smarthome-activate-package PACKAGE_PATH REVISION STATE_DIR PROFILE SERVICE HEALTH_URL
```

Validate package store-path shape, 40-character lowercase revision, absolute
state/profile paths, executable `bin/house-automationd`, and `SERVICE=-` iff
`HEALTH_URL=-`. Record old resolved profile when present. Switch with:

```bash
nix-env --profile "$profile" --set "$package_path"
```

When service is enabled, run `systemctl restart "$service"`, then retry
`curl --fail --silent --show-error "$health_url"` for 30 seconds. Any restart,
health, marker-write, or signal failure must restore the old path with
`nix-env --profile "$profile" --set "$old_path"`, restart it, verify old
health, and atomically write `last-failure`. Success atomically writes:

```text
rev=<revision>
path=<package path>
previous_path=<old path or none>
```

After success, parse generation numbers from `nix-env --list-generations` and
delete every generation except the highest two by passing explicit generation
numbers to `nix-env --delete-generations`. Never delete generations after an
incomplete rollback.

- [ ] **Step 3: Run focused harness**

```bash
git add modules/nixos/smarthome-activate-package.sh tests/smarthome-activator.nix flake.nix
bash -n modules/nixos/smarthome-activate-package.sh
nix-instantiate --parse tests/smarthome-activator.nix >/dev/null
nix build --no-link .#checks.x86_64-linux.smarthome-activator -L
git diff --check
```

Expected: PASS, including rollback and exact two-generation assertion.

- [ ] **Step 4: Commit activator**

```bash
git commit -m "feat(home-server): switch smarthome profile atomically"
```

### Task 4: Add pull deploy module and script contract

**Files:**
- Create: `modules/nixos/smarthome-auto-deploy.nix`
- Create: `tests/smarthome-auto-deploy.nix`
- Modify: `flake.nix`

- [ ] **Step 1: Write red module/script contract**

The check must evaluate an enabled module and inspect its generated unit/script.
Assert:

```nix
assert config.systemd.services.smarthome-deploy.serviceConfig.StateDirectory == "smarthome-deploy";
assert config.systemd.services.smarthome-deploy.serviceConfig.TimeoutStartSec == "infinity";
assert config.systemd.timers.smarthome-deploy.timerConfig.OnUnitActiveSec == "15min";
assert config.services.smarthome-auto-deploy.profile == "/nix/var/nix/profiles/smarthome";
assert lib.hasInfix "--option max-jobs 0" deployScript;
assert lib.hasInfix "--option fallback false" deployScript;
assert lib.hasInfix "--option builders ''" deployScript;
assert lib.hasInfix "fetch --depth=1" deployScript;
```

The runtime harness must use local Git and stubbed hydrator/activator packages to
prove missing/wrong-mode keys fail, first release activates, replay is a no-op,
branch advance activates, and matching last-success plus a different active
profile reports `rollback in effect; refusing to clobber`.

- [ ] **Step 2: Implement deployment module**

Define `services.smarthome-auto-deploy` options with these defaults:

```nix
repoUrl = "git@github.com:jonathanmoregard/smarthome.git";
branch = "main";
interval = "15min";
sourceDir = "/var/lib/smarthome-deploy/source";
profile = "/nix/var/nix/profiles/smarthome";
packageAttr = "packages.x86_64-linux.default";
cache.url = "https://jonathanmoregard.cachix.org";
cache.publicKey = "jonathanmoregard.cachix.org-1:Qzksr/c2ciAaV4j/U2mGFd1HTgOAicks8gJNs1Ztxo8=";
serviceName = null;
healthUrl = null;
```

Require absolute root-owned mode-0400 deploy key. Pin GitHub ed25519, RSA, and
ECDSA host keys copied from reviewed Klaffat pull-deploy module. Use a
machine-owned shallow checkout and this command shape:

```bash
git -C "$source" fetch --depth=1 --prune origin "+refs/heads/$branch:refs/remotes/origin/$branch"
git -C "$source" reset --hard "refs/remotes/origin/$branch"
git -C "$source" reflog expire --expire=now --all
git -C "$source" gc --prune=now
package_path="$(nix eval --raw \
  --option max-jobs 0 --option fallback false --option builders "" \
  "$source#$package_attr.outPath")"
```

Validate one exact store path, hydrate it with Task 2 helper, then activate it
with Task 3 helper. Use `last-success` as deployed truth. No-op only when commit
and active profile path both match; refuse automatic redeploy when commit
matches but profile differs. Hold one `flock` across fetch, hydration,
activation, and marker observation.

Create `smarthome-deploy.service`, failure notifier, and persistent randomized
timer. Unit has no ambient credential environment and obtains SSH identity only
through `GIT_SSH_COMMAND` with `IdentitiesOnly`, `BatchMode`, and strict host-key
checking.

- [ ] **Step 3: Run focused contract**

```bash
git add modules/nixos/smarthome-auto-deploy.nix tests/smarthome-auto-deploy.nix flake.nix
nix-instantiate --parse modules/nixos/smarthome-auto-deploy.nix >/dev/null
nix-instantiate --parse tests/smarthome-auto-deploy.nix >/dev/null
nix build --no-link .#checks.x86_64-linux.smarthome-auto-deploy -L
git diff --check
```

Expected: PASS.

- [ ] **Step 4: Commit pull deploy module**

```bash
git commit -m "feat(home-server): pull cached smarthome releases"
```

### Task 5: Wire low-disk production settings and preserve migration fallback

**Files:**
- Modify: `flake.nix`
- Modify: `modules/nixos/home-server-services.nix`
- Modify: `profiles/home-server-base.nix`
- Modify: `tests/home-server.nix`
- Modify: `tests/home-server-cd.nix`

- [x] **Step 1: Add red production assertions**

Extend home-server contract with:

```nix
smarthomeDeployEnabled = config.services.smarthome-auto-deploy.enable;
smarthomeProfile = config.services.smarthome-auto-deploy.profile;
keepDerivations = config.nix.settings.keep-derivations;
keepOutputs = config.nix.settings.keep-outputs;
```

Assert deploy enabled in test fixture, profile path exact, both retention flags
false, and `jonathan@dellan` key still present.

- [x] **Step 2: Compose deployment independently of topology**

Import `smarthome-auto-deploy.nix` from `home-server-services.nix`. Add
`homeServer.smarthomeDeployKeyFile` as a nullable runtime path. Enable deploy
when that path is non-null, independent of `houseSettings`; pass:

```nix
services.smarthome-auto-deploy = {
  enable = true;
  deployKeyFile = cfg.smarthomeDeployKeyFile;
  serviceName = if houseAutomationEnabled then "house-automationd.service" else null;
  healthUrl = if houseAutomationEnabled then "http://127.0.0.1:9876/healthz" else null;
};
```

- [x] **Step 3: Make disk retention explicit**

Add to `profiles/home-server-base.nix`:

```nix
nix.settings = {
  min-free = lib.mkForce (1024 * 1024 * 1024);
  max-free = lib.mkForce (5 * 1024 * 1024 * 1024);
  keep-derivations = false;
  keep-outputs = false;
};
```

- [x] **Step 4: Keep the old smarthome input inert until live proof**

Keep `inputs.smarthome` and its lock entry unchanged in this rollout PR. Confirm
production and tests no longer import `smarthome.nixosModules.default` or read a
package from the input:

```bash
rg -n 'smarthome\.nixosModules|inputs\.smarthome' tests modules hosts flake.nix
```

Expected: no module imports or production package reads. Flake argument plumbing
may remain as an inert migration remnant. Remove the input and lock entry in a
separate cleanup PR only after live direct-deploy verification.

- [x] **Step 5: Update test fixtures and gates**

Set a fixture deploy-key path plus stub deploy helper in `tests/home-server.nix`.
Confirm Task 1 already removed smarthome input imports from
`tests/home-server-cd.nix`; preserve the existing operating-system pull-deploy
test unchanged otherwise.

```bash
git add flake.nix modules/nixos/home-server-services.nix profiles/home-server-base.nix tests/home-server.nix tests/home-server-cd.nix
nix eval .#checks.x86_64-linux --apply builtins.attrNames
nix build --no-link .#checks.x86_64-linux.vm-home-server -L
nix build --no-link --rebuild .#checks.x86_64-linux.vm-home-server-cd -L
nix build --no-link .#nixosConfigurations.home-server.config.system.build.toplevel -L
git diff --check
```

Expected: all pass and check list includes three focused script checks.

- [x] **Step 6: Commit decoupling**

```bash
git commit -m "refactor(home-server): decouple smarthome releases"
```

### Task 6: Prove production systemd wiring in a lean VM

**Files:**
- Modify: `tests/home-server.nix`

- [x] **Step 1: Add one-node systemd smoke**

Extend the existing production-shaped `vm-home-server` lane. Boot with healthy
v1 already in the stable profile, then use the production auto-deploy service,
sandbox, and activator to move to healthy v2 from a local Git origin. Replace
only the already-focused boundaries (Nix evaluation and cache hydration) with
deterministic test packages. Test sequence:

```python
home_server.wait_for_unit("multi-user.target")
home_server.succeed("systemctl start smarthome-deploy.service")
home_server.wait_until_succeeds("curl -fsS http://127.0.0.1:9876/healthz | jq -e '.fixture == \"direct-deploy-v2\"'")
home_server.succeed("test -s /var/lib/smarthome-deploy/last-success")
home_server.succeed("test $(nix-env --profile /nix/var/nix/profiles/smarthome --list-generations | wc -l) -eq 2")
home_server.succeed("systemctl start smarthome-deploy.service")
home_server.succeed("journalctl -u smarthome-deploy.service | grep -F 'already deployed'")
home_server.succeed("test -z \"$(systemctl --failed --no-legend)\"")
```

Also assert the deploy key is mode 0400 and the fixture evaluator receives
`max-jobs=0`, `fallback=false`, and empty builders. Keep test boundary explicit:
the focused hydrator harness already proves real signed/unsigned/missing cache
behavior in an isolated store; the focused activator harness already proves
health rollback and two-generation pruning. Repeating those cases behind a
bespoke TLS cache would add runtime, not new coverage.

- [x] **Step 2: Prove red then green**

Add the runtime assertions while the old deploy stub remains and record their
failure. Then replace the stub with deterministic evaluator/hydrator fixtures.
Stage before every flake run.

```bash
git add tests/home-server.nix
nix build --no-link --rebuild .#checks.x86_64-linux.vm-home-server -L
```

Fix any fixture/module gap at its root, then rerun until PASS.

- [x] **Step 3: Commit VM proof**

```bash
git commit -m "test(home-server): prove direct smarthome deployment"
```

### Task 7: Provision read-only repository identity

**Files:**
- Create after authorization: `secrets/smarthome-deploy-ssh-key.age`
- Create after authorization: `secrets/rekeyed/home-server/*-smarthome-deploy-ssh-key.age`
- Modify: `hosts/home-server/default.nix`
- Modify: `hosts/home-server/deployment-identity.nix`

- [x] **Step 1: Obtain explicit credential authorization**

Pause before generating or uploading a new SSH credential. Ask one question:
permission to create a repository-specific read-only smarthome deploy key,
encrypt its private half through agenix-rekey, and upload only its public half
to GitHub.

- [x] **Step 2: Generate without writing plaintext into repository**

```bash
key_dir="$(mktemp -d)"
chmod 0700 "$key_dir"
ssh-keygen -q -t ed25519 -N '' -C 'smarthome@home-server' -f "$key_dir/key"
ADD_SECRET_SKIP_GIT=1 add-secret smarthome-deploy-ssh-key \
  --host home-server --owner root --group root --mode 0400 --from-stdin \
  < "$key_dir/key"
gh api --method POST repos/jonathanmoregard/smarthome/keys \
  -f title='home-server read-only deploy' \
  -f key="$(cat "$key_dir/key.pub")" \
  -F read_only=true
shred -u "$key_dir/key" "$key_dir/key.pub"
rmdir "$key_dir"
```

Expected: GitHub returns `read_only: true`; repository contains only encrypted
source/rekeyed files.

- [x] **Step 3: Wire runtime key**

Add to `hosts/home-server/deployment-identity.nix`:

```nix
homeServer.smarthomeDeployKeyFile = config.age.secrets.smarthome-deploy-ssh-key.path;
```

Verify the `add-secret` declaration has root/root/0400 and run:

```bash
nix eval --raw .#nixosConfigurations.home-server.config.age.secrets.smarthome-deploy-ssh-key.path
nix build --no-link .#nixosConfigurations.home-server.config.system.build.toplevel -L
```

Expected path: `/run/agenix/smarthome-deploy-ssh-key`; build passes.

- [x] **Step 4: Commit encrypted credential wiring**

```bash
git add hosts/home-server secrets/smarthome-deploy-ssh-key.age secrets/rekeyed/home-server
git commit -m "secret(home-server): add smarthome deploy identity"
```

### Task 8: Document operations and run mandatory gates

**Files:**
- Modify: `docs/home-server/README.md`

- [x] **Step 1: Document operating commands**

Add exact commands for status, on-demand deployment, active commit/path,
generations, failure diagnostics, manual rollback, retry, Cachix availability,
and store use:

```bash
systemctl status smarthome-deploy.timer smarthome-deploy.service
sudo systemctl start smarthome-deploy.service
sudo cat /var/lib/smarthome-deploy/last-success
sudo cat /var/lib/smarthome-deploy/last-failure
sudo nix-env --profile /nix/var/nix/profiles/smarthome --list-generations
sudo nix-env --profile /nix/var/nix/profiles/smarthome --rollback
sudo systemctl restart house-automationd.service
nix path-info -Sh /nix/var/nix/profiles/smarthome
sudo nix-store --gc --print-dead
```

State that only two app generations remain rooted, GC removes older runtime and
evaluation paths, server never builds, Cachix write token stays GitHub-only,
deploy key is read-only, and dellan SSH remains independent.

- [x] **Step 2: Run automated gates**

```bash
git add -A
nix eval .#checks.x86_64-linux --apply builtins.attrNames
nix build --no-link .#checks.x86_64-linux.smarthome-hydrator -L
nix build --no-link .#checks.x86_64-linux.smarthome-activator -L
nix build --no-link .#checks.x86_64-linux.smarthome-auto-deploy -L
nix build --no-link .#checks.x86_64-linux.vm-home-server -L
nix build --no-link --rebuild .#checks.x86_64-linux.vm-home-server-cd -L
nix build --no-link .#nixosConfigurations.home-server.config.system.build.toplevel -L
git diff --check
```

Expected: all pass.

- [x] **Step 3: Run mandatory interactive smoke**

Run:

```bash
nix build .#checks.x86_64-linux.vm-home-server.driverInteractive \
  -o result-smarthome-interactive
./result-smarthome-interactive/bin/nixos-test-driver
```

At the driver prompt execute:

```python
# Run the test script first: it creates the disposable Git origin and stable
# v1 profile before exercising the production deploy unit.
run_tests()
print(home_server.succeed("cat /var/lib/smarthome-deploy/last-success"))
print(home_server.succeed("readlink -f /nix/var/nix/profiles/smarthome"))
print(home_server.succeed("curl -fsS http://127.0.0.1:9876/healthz"))
print(home_server.succeed("nix-env --profile /nix/var/nix/profiles/smarthome --list-generations"))
print(home_server.succeed("cat /var/lib/smarthome-deploy/nix-invocations"))
assert home_server.succeed("systemctl --failed --no-legend").strip() == ""
```

Expected: actual package health succeeds, release marker/profile exist, second
deployment logs a no-op, and no unit is failed. Exit driver to stop VMs.

- [ ] **Step 4: Commit documentation, review, push, and open PR**

```bash
git add docs/home-server/README.md
git commit -m "docs(home-server): operate direct app deployment"
git push -u origin feat/smarthome-direct-deploy
gh pr create --base main --head feat/smarthome-direct-deploy \
  --title "feat(home-server): deploy smarthome directly from cache" \
  --body 'Adds signed cache-only package deployment with two-generation rollback, preserves dellan SSH, leaves the old source pin inert until live proof, and proves missing/unsigned/unhealthy releases fail closed in VM tests.'
gh pr checks --watch
```

Expected: PR opens against `main`; all discovered checks pass. Do not merge;
human merge remains required.
