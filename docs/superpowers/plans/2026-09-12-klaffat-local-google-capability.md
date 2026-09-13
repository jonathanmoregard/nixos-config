# Local Klaffat Google Calendar capability implementation plan

> **For Codex:** Execute this plan in the current isolated nixos-config
> worktree. Keep plaintext OAuth credentials out of command output, files
> readable by Jonathan, tests, commits, and logs.

**Goal:** Provide a passwordless, narrowly authorized command that starts a
real-Google Klaffat development server while root performs agenix-compatible
decryption and the server alone receives the OAuth credentials.

**Architecture:** A NixOS module builds an unprivileged launcher, a root-only
preparation program, an isolated system service, and a unit-specific polkit
rule. The launcher selects a validated Klaffat worktree; root copies reviewed
runtime artifacts, extracts only the two Google variables from the existing
age-encrypted environment, and systemd executes the app under a dedicated UID
with persistent local PostgreSQL.

**Tech stack:** NixOS modules, systemd, polkit, age, PostgreSQL, Bash, NixOS VM
tests, Python test driver.

---

### Task 1: Specify the production and test interfaces

**Files:**
- Create: `modules/nixos/klaffat-local-google.nix`
- Modify: `tests/klaffat-infra.nix`

1. Add VM assertions before the production module exists. The fixture must
   invoke `klaffat-local-google start <fixture-worktree>` as Jonathan and
   expect failure because the command is absent.
2. Define fixture paths, a fake decryptor package, and a fake Klaffat binary.
   The binary implements `migrate`, exposes `/healthz` on port 3740, and writes
   boolean evidence that the required Google variables arrived while an
   unrelated fixture variable and OAuth mock overrides did not.
3. Run `nix build .#checks.x86_64-linux.vm-klaffat-infra -L` and preserve the
   expected red result showing the feature is missing.

### Task 2: Implement validation and secret preparation

**Files:**
- Create: `modules/nixos/klaffat-local-google.nix`

1. Add `services.klaffatLocalGoogle` options: `enable`, `operator`,
   `worktreeRoot`, `encryptedEnvironmentRelativePath`, and internal test seams
   for the decryptor and repository URL.
2. Build a root-only preparation application. Validate the selector file,
   canonical path boundary, ownership, executable, regular files, and absence
   of symlinks or special files. Never run Git or load repository config as
   root; check the expected origin in the unprivileged launcher only.
3. Copy the application, static files, and KEK to a fresh runtime directory
   without following symlinks.
4. Run decryption under `timeout`, parse exactly one assignment for each
   allowed Google variable, reject control characters and duplicates, and
   atomically install only those two assignments. Trap cleanup of the complete
   plaintext output.
5. Exercise the preparation program in the VM against valid, malformed,
   failed, and hanging decryptor fixtures. Confirm every failure leaves no
   environment file and logs no secret value.

### Task 3: Implement the service and local launcher

**Files:**
- Modify: `modules/nixos/klaffat-local-google.nix`

1. Declare the `klaffat-local-google` system account, state directory, runtime
   directory, and hardened service.
2. Start an isolated PostgreSQL instance on a Unix socket, create the database
   on first run, run Klaffat migrations, and execute the prepared application
   on loopback port 3740.
3. Build `klaffat-local-google start|status|stop`. Make `start` atomically
   record the worktree selection, restart only the fixed service, bound its
   health polling, and print the localhost URL only on success.
4. Add a polkit rule for user `jonathan`, unit
   `klaffat-local-google.service`, and only start/stop/restart/reset-failed
   verbs. Clearing the one unit's failed latch lets a corrected worktree
   recover after repeated fail-closed preparation attempts.
5. In the VM, prove the operator can manage the target service but cannot
   manage a control unit. Prove the server UID, endpoint, environment
   isolation, and persistent state across restart.

### Task 4: Enable the capability on dellan

**Files:**
- Modify: `hosts/dellan/default.nix`

1. Import `modules/nixos/klaffat-local-google.nix` beside `klaffat-infra.nix`.
2. Set `services.klaffatLocalGoogle.enable = true`.
3. Evaluate the dellan configuration and inspect the generated unit, polkit
   rule, launcher, and preparation scripts for unexpected secret or user-input
   expansion.

### Task 5: Verify and review

**Files:**
- Modify only defects found by checks or review.

1. Run `nix flake check --no-build --all-systems` and the repository's eval
   warning check.
2. Run `nix build .#checks.x86_64-linux.vm-klaffat-infra -L`.
3. Run the focused production toplevel evaluation/build required by the repo.
4. Inspect generated scripts and run adversarial tests for empty selectors,
   path escapes, symlinks, wrong origins, malformed output, decrypt failure,
   decrypt hang, and health timeout.
5. Run the security/advice review loop; fix every blocker and high-severity
   issue, then rerun affected checks.
6. Commit with the required risk and behavioral-evidence trailers.

### Task 6: Deliver and operate

1. Push `feat/klaffat-local-google-capability` and open a PR to `main`.
2. Wait for every required GitHub check to finish green and resolve branch
   drift with a merge from `origin/main` if needed.
3. Ask Jonathan for the GitHub merge-button click; do not merge by CLI.
4. After automatic deployment completes, run:

   ```text
   klaffat-local-google start /home/jonathan/worktrees/klaffat-weekly-busy-distinction
   ```

5. Verify `/healthz`, `/login` local bypass, and a real Google authorization
   redirect with a present client ID and the localhost callback. Report only
   booleans and endpoint hosts; never inspect or print credential values.
