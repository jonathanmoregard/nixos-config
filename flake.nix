{
  description = "jonathanmoregard's NixOS config";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";

    # agenix-rekey: extends agenix with a master-identity model so each
    # host's per-pubkey ciphertext is derived automatically from one
    # canonical secret. Removes the per-secret `publicKeys` bookkeeping
    # in secrets/secrets.nix and lets new hosts (test-vm, future
    # laptops) decrypt without re-editing every .age file.
    agenix-rekey.url = "github:oddlama/agenix-rekey";
    agenix-rekey.inputs.nixpkgs.follows = "nixpkgs";

    # Personal CLI tools — own uv2nix flakes, exposed system-wide via
    # `modules/nixos/listen-tools.nix`. Pinned to a tag in production
    # eventually; track main for now.
    tts-tool.url = "github:jonathanmoregard/tts-tool";
    tts-tool.inputs.nixpkgs.follows = "nixpkgs";
    substack-url-tool.url = "github:jonathanmoregard/substack-url-tool";
    substack-url-tool.inputs.nixpkgs.follows = "nixpkgs";
    prose-decorate.url = "github:jonathanmoregard/prose-decorate";
    prose-decorate.inputs.nixpkgs.follows = "nixpkgs";

    # microvm.nix — qemu+KVM microvm host module. Tracking `main`
    # because the most recent tagged release (v0.5.0, 2024-04) calls
    # `pkgs.writeReferencesToFile` which has been removed in current
    # nixpkgs. flake.lock pins the exact SHA so the build remains
    # reproducible; bumping via `nix flake update microvm` is a
    # deliberate PR with a re-run dellan-vm test.
    microvm.url = "github:astro/microvm.nix";
    microvm.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, home-manager, agenix, agenix-rekey, microvm,
              tts-tool, substack-url-tool, prose-decorate, ... }:
  let
    linuxSystem = "x86_64-linux";

    # Pre-built pkgs — overlays + allowUnfree applied here rather than in
    # modules. Required so the per-feature VM checks (tests/*.nix) can
    # reuse the same pkgs: the nixosTest framework injects pkgs
    # externally and that makes `nixpkgs.config` / `nixpkgs.overlays`
    # read-only inside modules.
    #
    # The listen-tools overlay exposes the standalone CLI packages
    # (substack-url-tool, tts-tool) as plain `pkgs.<name>` attributes
    # so modules don't need flake-input specialArgs threading.
    pkgsLinux = import nixpkgs {
      system = linuxSystem;
      config.allowUnfree = true;
      # Required for pkgs.androidenv.composeAndroidPackages — the
      # Android SDK terms of service must be accepted at evaluation
      # time, otherwise the derivation fails with a redirect to
      # `https://developer.android.com/studio/terms`. Consumed by
      # modules/nixos/android-dev.nix. Note: the flag scopes to this
      # whole `pkgsLinux` instance, so any future module that pulls in
      # an androidenv derivation auto-accepts the license. Today only
      # `android-dev.nix` does — if a build-farm host or anything
      # contributor-facing imports androidenv, scope a separate pkgs
      # import without this flag.
      config.android_sdk.accept_license = true;
      overlays = [
        (import ./overlays/beeper.nix)
        (import ./overlays/auphonic-cli.nix)
        (final: prev: {
          tts-tool = tts-tool.packages.${linuxSystem}.default;
          substack-url-tool = substack-url-tool.packages.${linuxSystem}.default;
          prose-decorate = prose-decorate.packages.${linuxSystem}.default;
        })
      ];
    };
  in {
    # NixOS VM (headless, QEMU/KVM)
    nixosConfigurations.vm = nixpkgs.lib.nixosSystem {
      system = linuxSystem;
      pkgs = pkgsLinux;
      modules = [
        ./hosts/vm/default.nix
        ./modules/common.nix
        ./modules/nixos/vm-tweaks.nix
        agenix.nixosModules.default
        agenix-rekey.nixosModules.default
        { environment.systemPackages = [ agenix.packages.${linuxSystem}.default ]; }
        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.users.jonathan = import ./home/jonathan-linux.nix;
        }
      ];
    };

    # Dell Latitude 7440 laptop — daily driver
    nixosConfigurations.dellan = nixpkgs.lib.nixosSystem {
      system = linuxSystem;
      pkgs = pkgsLinux;
      specialArgs = { inherit microvm; };
      modules = [
        ./hosts/dellan/default.nix
        ./modules/common.nix
        agenix.nixosModules.default
        agenix-rekey.nixosModules.default
        { environment.systemPackages = [ agenix.packages.${linuxSystem}.default ]; }
        microvm.nixosModules.host
        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.users.jonathan = import ./home/jonathan-linux.nix;
        }
      ];
    };

    # VM-based e2e tests, one per feature area. Run any single lane:
    #   nix build .#checks.x86_64-linux.vm-base -L
    # Or all five via `nix flake check`.
    #
    # Adding a lane: drop a new ./tests/<feature>.nix that imports
    # ./lib/common.nix and wire it here. No aggregate — CI's matrix
    # fan-out (.github/workflows/ci.yml) enumerates the lanes.
    checks.${linuxSystem} =
      let
        mkLane = path: import path {
          pkgs = pkgsLinux;
          inputs = { inherit home-manager agenix agenix-rekey microvm; };
        };
      in {
        vm-base         = mkLane ./tests/base.nix;
        vm-auto-deploy  = mkLane ./tests/auto-deploy.nix;
        vm-camera-relay = mkLane ./tests/camera-relay.nix;
        vm-desktop      = mkLane ./tests/desktop.nix;
        vm-keyring      = mkLane ./tests/keyring.nix;
        vm-kitty        = mkLane ./tests/kitty.nix;
        vm-claude-pane  = mkLane ./tests/claude-pane.nix;
        vm-autodoro     = mkLane ./tests/autodoro.nix;
        vm-microvm      = mkLane ./tests/microvm.nix;
        vm-listen-tools = mkLane ./tests/listen-tools.nix;
        vm-android-dev  = mkLane ./tests/android-dev.nix;
        # Not a VM lane: runtime-invocation harness for the research-agent
        # guest's egress-init script (offline-resilience contract). Cheap
        # runCommand; seconds, not minutes.
        egress-init-retry = import ./tests/egress-init-retry.nix {
          pkgs = pkgsLinux;
          script = self.nixosConfigurations.dellan.config
            .microvm.vms.research-agent.config.config
            .systemd.services.research-agent-egress-init.script;
        };
        # Not a VM lane: runtime-invocation harness for the cachix
        # post-build-hook's push-budget filter (skip microvm erofs +
        # >256MiB paths; never fail the build). Cheap runCommand.
        cachix-push-filter = import ./tests/cachix-push-filter.nix {
          pkgs = pkgsLinux;
          prodHook = self.nixosConfigurations.dellan.config
            .nix.settings.post-build-hook;
        };
        # Not a VM lane: fail-closed contract harness for the merged-and-
        # stale worktree sweeper (home/worktree-sweep-script.nix). Builds
        # a fixture bare repo + worktrees with real git, stubs gh, and
        # asserts every keep/delete predicate — destructive automation
        # ships only behind this. Cheap runCommand; seconds.
        worktree-sweep = import ./tests/worktree-sweep.nix {
          pkgs = pkgsLinux;
          sweepScript = import ./home/worktree-sweep-script.nix { pkgs = pkgsLinux; };
          # Drift gate: the harness asserts the deployed user unit execs
          # exactly the derivation under test.
          deployedExecStart = self.nixosConfigurations.dellan.config
            .home-manager.users.jonathan
            .systemd.user.services.nixos-worktree-sweep.Service.ExecStart;
        };
      };

    # Feature-VM flake apps. Two interactive modes + a screencap helper.
    #
    #   nix run .#feature-vm           — headless (default). For Claude
    #                                    Code / agentic flows. SSH on
    #                                    host:2222 + QMP + serial sockets
    #                                    exposed under $TMPDIR. Use this
    #                                    unless a real GUI is needed.
    #   nix run .#feature-vm-headful   — same boot but QEMU opens a GTK
    #                                    window. Requires $DISPLAY (i.e.
    #                                    a logged-in graphical session
    #                                    on dellan). Use when a human
    #                                    wants to drive the VM directly.
    #   nix run .#feature-vm-screencap -- <qmp-sock> <out.png>
    #                                  — capture VM display via QMP
    #                                    screendump → PNG. Works on the
    #                                    headless VM since QEMU's VGA
    #                                    device is still present without
    #                                    `-display none` driving a host
    #                                    window.
    apps.${linuxSystem} =
      let
        vm = self.nixosConfigurations.dellan.config.system.build.vm;

        mkFeatureVm = { name, displayMode }:
          let
            runner = pkgsLinux.writeShellApplication {
              inherit name;
              text = ''
                hostKey="$HOME/.ssh/id_ed25519"
                if [ ! -r "$hostKey" ]; then
                  echo "[${name}] ERROR: host SSH private key not readable at $hostKey" >&2
                  echo "[${name}] agenix decryption inside the VM would silently produce empty secrets — refusing to boot." >&2
                  exit 1
                fi

                # Stage the privkey into a launcher-owned cache dir so
                # the 9p export sees only the one file it needs.
                stagingDir="$HOME/.cache/feature-vm/host-ssh"
                mkdir -p "$stagingDir"
                chmod 0700 "$stagingDir"
                install -m 0400 "$hostKey" "$stagingDir/id_ed25519"

                TMPDIR="$(mktemp -d -t ${name}.XXXXXX)"
                export TMPDIR
                trap 'rm -rf "$TMPDIR"' EXIT INT TERM

                # Control sockets in $TMPDIR so they're auto-cleaned.
                # QMP    → screendump, send-key, query-status, etc.
                # Serial → tty access before sshd is up (or after panic).
                controlOpts="-qmp unix:$TMPDIR/qmp.sock,server=on,wait=off"
                controlOpts="$controlOpts -serial unix:$TMPDIR/serial.sock,server=on,wait=off"

                export QEMU_OPTS="''${QEMU_OPTS:-${displayMode} -snapshot $controlOpts}"

                echo "[${name}] tmpdir=$TMPDIR" >&2
                echo "[${name}] ssh:        ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ~/.ssh/id_ed25519 jonathan@localhost" >&2
                echo "[${name}] qmp:        nix run .#feature-vm-screencap -- $TMPDIR/qmp.sock /tmp/snap.png" >&2
                echo "[${name}] serial:     socat - UNIX-CONNECT:$TMPDIR/serial.sock" >&2

                # Don't `exec` — we need bash to stay alive long enough
                # to run the trap that cleans $TMPDIR on QEMU exit.
                cd "$TMPDIR"
                ${vm}/bin/run-dellan-vm "$@"
              '';
            };
          in {
            type = "app";
            program = "${runner}/bin/${name}";
          };

        screencap = pkgsLinux.writeShellApplication {
          name = "feature-vm-screencap";
          runtimeInputs = with pkgsLinux; [ socat netpbm ];
          text = ''
            if [ $# -lt 2 ]; then
              echo "usage: feature-vm-screencap <qmp-sock> <output.png>" >&2
              exit 2
            fi
            sock="$1"
            out="$2"
            if [ ! -S "$sock" ]; then
              echo "[feature-vm-screencap] no QMP socket at $sock — is the VM running?" >&2
              exit 1
            fi
            # QEMU writes the screendump to a path it can access.
            # Drop it next to the socket so the path is already
            # under the launcher's $TMPDIR.
            ppm="$(dirname "$sock")/screenshot.ppm"
            rm -f "$ppm"
            {
              printf '{"execute":"qmp_capabilities"}\n'
              printf '{"execute":"screendump","arguments":{"filename":"%s"}}\n' "$ppm"
              # Give QEMU time to render + write before EOF closes the socket.
              sleep 2
            } | socat -t 10 - UNIX-CONNECT:"$sock" >/dev/null
            if [ ! -s "$ppm" ]; then
              echo "[feature-vm-screencap] screendump produced no PPM output" >&2
              exit 1
            fi
            pnmtopng "$ppm" > "$out"
            rm -f "$ppm"
            echo "$out"
          '';
        };
      in {
        feature-vm = mkFeatureVm {
          name = "feature-vm";
          displayMode = "-display none";
        };
        feature-vm-headful = mkFeatureVm {
          name = "feature-vm-headful";
          # No `-display none` → QEMU picks gtk/sdl based on $DISPLAY.
          displayMode = "";
        };
        feature-vm-screencap = {
          type = "app";
          program = "${screencap}/bin/feature-vm-screencap";
        };
      };

    # `nix run .#update-beeper` — rewrites overlays/beeper.nix to the latest
    # upstream Beeper release. Wired into .github/workflows/update-beeper.yml.
    packages.${linuxSystem}.update-beeper = pkgsLinux.beeper-update;

    # agenix-rekey CLI plumbing. Exposes:
    #   nix run .#agenix -- generate           — bootstrap missing rekeyed copies
    #   nix run .#agenix -- edit <file>.age    — decrypt-edit-re-encrypt with master
    #   nix run .#agenix -- rekey              — regenerate per-host rekeyed copies
    #   nix run .#agenix -- update-masterkeys  — bulk re-encrypt to a new master
    agenix-rekey = agenix-rekey.configure {
      userFlake = self;
      nixosConfigurations = self.nixosConfigurations;
    };
  };
}
