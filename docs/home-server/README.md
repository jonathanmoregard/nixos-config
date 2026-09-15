# `home-server` runbook

This host is prepared for a fanless Dell Wyse 5070 (Pentium Silver J5005,
8 GB RAM, 128 GB SSD, wired Ethernet). It uses native NixOS services and the
repository's existing flake, agenix-rekey, Tailscale, CI, and pull-deployment
patterns. Nothing in this change installs or switches a physical machine.

## Architecture

```text
                    +------------------+
                    |    Rust logic    |
                    +---------+--------+
                              |
                            MQTT
                              |
                         Mosquitto
                    +---------+----------+
                    |                    |
              Zigbee2MQTT        TellStick adapter
                    |             discovery boundary
              ZBDongle-E                |
                    |             ZNet Lite v2
                 Zigbee           |           |
                              433 MHz       Z-Wave
```

Rust owns automation semantics. Zigbee2MQTT and future TellStick adapters only
translate protocol events and commands. Zigbee and Z-Wave remain separate
meshes; MQTT is their application-level meeting point. Home Assistant, Telldus
cloud, containers, and local LLM inference are absent.

## Readiness gates

Production-dependent values default to `null`. Leave them null until evidence
exists:

- `ageHostPublicKey`: public half of this host's real SSH host key.
- `zigbeeSerialPort`: real `/dev/serial/by-id/...` coordinator path.
- Matrix server name and secret source: permanent name and encrypted YAML.
- optional MQTT network-client password file and TellStick address/token.
- deploy key and any off-host backup destination.

With these values absent, configuration still evaluates and builds. Hardware,
public identity, or credential-dependent services stay disabled. Do not replace
these gates with fake production values.

## Blank-disk bootstrap

1. In firmware setup, select UEFI boot and enable **power on after AC loss**.
   NixOS cannot set that firmware policy. No Wi-Fi is required.
2. Boot a current NixOS installer. Use installer networking and a temporary LAN
   SSH setup only for bootstrap. Verify target disk with `lsblk` before any
   partitioning command.
3. Create a small EFI partition labelled `EFI` and an ext4 root partition
   labelled `nixos`. The committed pre-hardware configuration intentionally
   uses labels, not unknown UUIDs. Mount root at `/mnt` and EFI at `/mnt/boot`.
4. Clone this repository into `/mnt/etc/nixos`, then inspect generated hardware
   facts without blindly committing them:

   ```console
   sudo nixos-generate-config --root /mnt
   diff -u /mnt/etc/nixos/hosts/home-server/hardware-configuration.nix \
     /mnt/etc/nixos/hardware-configuration.nix
   ```

   Keep useful CPU, initrd, filesystem, and firmware facts. Do not replace the
   stable label mounts with transient device names.
5. Install the prepared host without copying user passwords into the Nix store:

   ```console
   cd /mnt/etc/nixos
   sudo nixos-install --flake .#home-server --no-root-passwd
   ```

6. Before reboot, set a real password for `jonathan` inside the installed
   system. Sudo is password-gated, so skipping this step would prevent
   Tailscale enrollment after first boot. The declarative configuration never
   provides a public default password. SSH remains key-only and root SSH is
   denied.

   ```console
   sudo nixos-enter --root /mnt -c 'passwd jonathan'
   ```
7. Reboot, enroll Tailscale from the local console, and verify the node appears
   in the intended tailnet. Final firewall policy admits SSH only on
   `tailscale0`; confirm tailnet access before ending installer/LAN access.

   ```console
   sudo tailscale up
   tailscale status
   ssh jonathan@home-server
   ```

8. Record host identity without copying the private key:

   ```console
   sudo cat /etc/ssh/ssh_host_ed25519_key.pub
   ```

   Put that public value in `homeServer.ageHostPublicKey`. The host module then
   selects `secrets/rekeyed/home-server` automatically. Run the repository's
   established rekey command from a trusted workstation:

   ```console
   nix run .#agenix-rekey.x86_64-linux.rekey
   ```

   Commit only encrypted source and rekeyed `.age` files. Never commit the host
   private key or decrypted output from `/run/agenix`.
9. Add required secrets through the existing
   `add-secret <name> --host home-server` flow. Wire each service to its
   decrypted runtime path. Build in CI, review, merge, then perform the first
   deliberate switch from the target console or Tailscale SSH session.
   Auto-deploy stays off until its key path is supplied.

   Set owner to the service that opens a secret directly:

   ```console
   add-secret matrix-synapse-secrets --host home-server \
     --owner matrix-synapse --group matrix-synapse --mode 0400
   add-secret house-automation-mqtt --host home-server \
     --owner house-automation --group house-automation --mode 0400
   ```

   Root/systemd loads deploy, network-MQTT, and TellStick credentials, so use
   `--owner root --group root --mode 0400` for those. Never rely on
   `add-secret`'s user-owned defaults for a system service.

## Secrets

Expected encrypted provisions are:

- automation/MQTT client environment, when authenticated networking is used;
- Matrix Synapse YAML secret values;
- optional Tailscale bootstrap material (interactive enrollment is preferred);
- deploy SSH key;
- optional TellStick local bearer token;
- future cloud-AI API environment;
- future public TLS/DNS and backup credentials.

Source files stay encrypted in Git. agenix-rekey creates host-recipient copies
under `secrets/rekeyed/home-server`; runtime files appear under `/run/agenix`
with narrow ownership and modes. Services read those paths at runtime. Secret
values must never appear in Nix strings, generated store-backed configuration,
logs, MQTT payload diagnostics, or unit command lines.

## MQTT conventions

Mosquitto is an internal bus. Local services use `127.0.0.1:1883`; no global
firewall port is opened. Its anonymous loopback ACL grants only
`zigbee2mqtt/#` and `house/v1/#`; an empty NixOS Mosquitto ACL denies all
traffic. Optional network clients require an authenticated listener restricted
to `tailscale0`.

- Zigbee2MQTT keeps its native `zigbee2mqtt/...` topics.
- Application APIs use versioned `house/v1/...` topics.
- Button/input events and commands are not retained.
- Bridge status, device availability, and service LWT may be retained.
- Commands include no automation logic beyond desired device state.

Useful observation commands:

```console
mosquitto_sub -h 127.0.0.1 -t 'zigbee2mqtt/#' -v
mosquitto_sub -h 127.0.0.1 -t 'house/v1/#' -v
```

## ZBDongle-E and Zigbee2MQTT

Mount the Sonoff ZBDongle-E on a USB extension cable, away from chassis and
USB 3 radio noise. It runs Zigbee coordinator firmware only—never concurrent
Zigbee/Thread multiprotocol firmware.

Discover stable identity after attachment:

```console
ls -l /dev/serial/by-id/
udevadm info --query=property --name /dev/serial/by-id/<exact-id>
```

Set the exact by-id path as `zigbeeSerialPort`. Never use `/dev/ttyUSB0` or
`/dev/ttyACM0`. Configuration selects Zigbee2MQTT's current `ember` adapter.
Before first start, compare installed Zigbee2MQTT version's EmberZNet support
table with live coordinator firmware. Prepared design expects supported
EmberZNet 7.4.x–9.1.x firmware and at least 7.4.4, but upstream support remains
the authority at bootstrap time.

Firmware upgrade procedure:

1. Stop Zigbee2MQTT and back up `/var/lib/zigbee2mqtt`, including coordinator
   backup, configuration, and database.
2. Record current firmware and exact by-id device.
3. Obtain ZBDongle-E **coordinator** firmware from Sonoff or the firmware source
   linked by current Zigbee2MQTT documentation. Reject multiprotocol images.
4. Use the current Silicon Labs/Sonoff-supported flasher while Zigbee2MQTT is
   stopped. Do not guess a chip, serial device, or image.
5. Power-cycle dongle, confirm by-id path, start Zigbee2MQTT, and inspect bridge
   logs/state before pairing or restoring.

Frontend is private/Tailscale-only. Keep `permit_join = false` normally. Open a
short pairing window deliberately, pair one device, give it a stable
`friendly_name`, verify exposed capabilities, then close joining.

IKEA LED2111G6 and Hue bulbs can join directly without Hue Bridge. Declare only
reported capabilities. LED2111G6 may need sparse separate brightness and CCT
updates; do not assume one long simultaneous hardware transition. Use Zigbee
groups for synchronized room commands with per-device fallback. Mains-powered
bulbs/plugs can route and form mesh backbone; battery remotes/sensors do not.

For E1810/E1524, verify `toggle`/center and directional action events reach
`house-automationd`. Main mappings stay declarative: up/down change brightness
offset, left/right change temperature offset, center single toggles, and center
double toggles follow/frozen mode. Double clicks wait for classification, so no
single-click flash occurs. Freeze and unfreeze each emit a brief, distinct
brightness acknowledgement overlay; return to curve remains smooth. At 04:00
Europe/Stockholm every physical control owner returns to FOLLOW, independent of
which scope was selected.

## Add topology

Static floors, rooms, scopes, device aliases/capabilities, groups, controls,
curves, and automation settings belong in generated daemon configuration. Use
exact Zigbee2MQTT friendly names and validate with the smarthome flake checks.
`homeServer.houseSettings` defaults to null and the daemon remains disabled
until this real topology is supplied; no example device can receive commands
on a production boot.
Runtime offsets, selected runtime scopes, frozen baseline/mode, and reset marker
live in SQLite. Transient overlays and connection state do not.

Circadian output composes live/frozen baseline, user offsets, contextual
modifiers, and temporary overlays. Whole-hour notification is a 500 ms layer;
expiration recomputes current desired state instead of restoring a stale saved
brightness.

## TellStick migration

TellStick ZNet Lite v2 remains local legacy infrastructure for 433.92 MHz and
Z-Wave. First inspect firmware and authenticated local API exposed by the real
unit. Probe documented `/api` discovery/auth surfaces, record sanitized request
and event fixtures, then select a maintained NixOS-suitable adapter or build the
small translation bridge. Do not invent endpoint or payload semantics before
that evidence exists. `homeServer.tellstickAdapterPackage` defines the disabled
integration boundary: its package must expose `bin/tellstick-mqtt-bridge`; the
unit supplies `TELLSTICK_BASE_URL`, a private `TELLSTICK_TOKEN_FILE`,
`MQTT_URL`, and `MQTT_NAMESPACE=house/v1/tellstick`. Address, encrypted token
path, and adapter package must all be configured together. Bridge output enters
MQTT under that versioned namespace; Rust still owns automation. Telldus cloud
is never a dependency.

## Matrix

Matrix stays disabled until a permanent `server_name` and encrypted Synapse
secret file are configured. Changing `server_name` later changes user IDs and
is not a migration shortcut. Initial listener is private/Tailscale-only;
registration is closed, PostgreSQL is used instead of SQLite, and no federation
or public DNS name is invented.

After enabling, create initial users administratively over the private route,
verify registration remains closed, and inspect upload/media limits. Add public
federation later only with an explicit domain, DNS/TLS plan, and this repository's
chosen reverse-proxy convention.

## Mutable state and backups

Git backs up declarative configuration and encrypted secrets only. Until a
tested off-host destination exists, mutable data is **not truly backed up**.

| Service | Mutable state | Consistent export |
|---|---|---|
| automation | `/var/lib/house-automation/state.sqlite3` | `house-automationd backup --database ... --destination ...` |
| Mosquitto | `/var/lib/mosquitto` | stop briefly or copy from a filesystem snapshot |
| Zigbee2MQTT | `/var/lib/zigbee2mqtt` | stop briefly; copy configuration, database, and coordinator backup |
| PostgreSQL/Synapse | PostgreSQL data directory | `sudo -u postgres pg_dump --format=custom matrix-synapse > matrix-synapse.dump` |
| Matrix media | `/var/lib/matrix-synapse/media_store` | copy/snapshot after coordinating with database export |
| TellStick bridge | adapter-specific state, if any | define after local adapter selection |

Example automation export:

```console
sudo install -d -m 0700 /srv/backup-staging
sudo house-automationd backup \
  --database /var/lib/house-automation/state.sqlite3 \
  --destination /srv/backup-staging/house-automation.sqlite3
```

Copy exports off-host, encrypt where needed, record retention, and test restore.
Matrix database and media belong to one recovery point. Do not add databases,
media, MQTT persistence, or live Zigbee state to Git.

## Recovery and rollback

Normal rollback remains standard NixOS:

```console
sudo nixos-rebuild switch --rollback
nix-env --list-generations -p /nix/var/nix/profiles/system
```

Existing auto-deploy detects an active older generation and stops rather than
overwriting deliberate rollback. Resume only after diagnosing and switching a
known-good forward generation.

After disk loss: replace disk, repeat labelled ext4 bootstrap, restore Git and
the same SSH host identity if securely backed up (otherwise add/rekey a new host
recipient), enroll Tailscale, rebuild `#home-server`, then restore each mutable
service from a tested off-host recovery point. A Git-only rebuild restores
service definitions, not rooms' offsets, Zigbee network, Matrix history/media,
or broker persistence.

## CD simulation

Run the target-sized deployment lane from the NixOS configuration worktree:

```console
nix build --no-link --rebuild .#checks.x86_64-linux.vm-home-server-cd -L
```

The disposable x86-64 VM has four vCPUs, 8 GiB RAM, and a sparse 128 GiB ext4
disk. A local bare Git origin and preloaded v1/v2 runtime closures replace
GitHub/Tailscale and binary-cache transport. Everything after those boundaries
is real: `nixos-deploy.service` fetches and resets the checkout, passes memory
admission, runs `nixos-rebuild switch`, advances the system profile, records the
exact successful commit, preserves Mosquitto and automation health, no-ops on
replay, and refuses to overwrite a real rollback.

This proves deployment mechanics and target resource shape, not physical
hardware. The NixOS test harness shares the host Nix store with the guest, so
it does not benchmark SSD throughput or model full-store capacity pressure.
QEMU cannot validate J5005 microarchitecture details, SSD SMART,
ZBDongle-E USB/Ember firmware or RF behavior, BIOS power-after-AC-loss,
Tailscale identity/enrollment, or real GitHub authentication and routing.
Complete those checks during bootstrap.

## Health and debugging

```console
systemctl status tailscaled mosquitto zigbee2mqtt house-automationd postgresql matrix-synapse
journalctl -u house-automationd -b --no-pager
journalctl -u zigbee2mqtt -b --no-pager
journalctl -u matrix-synapse -b --no-pager
curl --fail-with-body http://127.0.0.1:9876/healthz
tailscale status
ss -lntup
sudo nft list ruleset
df -h / /var/lib
smartctl --scan
sudo smartctl -a /dev/<ssd-device>
```

Daemon health becomes ready only after database migration, MQTT connection, and
Zigbee2MQTT bridge readiness. MQTT/Zigbee reconnects, device availability, and
desired/observed reconciliation appear in structured journald fields. To explain
an unexpected lamp target, inspect device, room, source, action, scope,
old/new target, curve mode, availability, reconnect, and overlay fields.

Simulation covers protocol and state behavior with real daemon/Mosquitto and a
fake Zigbee2MQTT peer. VM tests cannot validate RF quality, USB enumeration,
coordinator flashing, actual pairing, SSD SMART support, BIOS AC recovery, or
Tailscale control-plane enrollment; complete those physical smoke checks during
bootstrap.
