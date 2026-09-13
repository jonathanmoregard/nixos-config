# Home Server Design

## Goal and safety state

Add `nixosConfigurations.home-server` for a Dell Wyse 5070 while preserving current Dellan behavior and deployment. Configuration must build and boot in CI before hardware exists, but physical activation remains gated on facts available only during bootstrap:

- generated SSH host public key for agenix-rekey
- stable ZBDongle-E `/dev/serial/by-id/...` path
- permanent Matrix server name
- encrypted service credentials
- off-host backup destination

No fake production key, hardware identifier, domain, or backup target is committed. Required-value options default to null. Zigbee activates only when a stable serial path exists; Matrix activates only when permanent server name and secret file exist; auto-deploy activates only when host identity and deploy credential exist. Dedicated VM tests supply isolated fixtures. Bootstrap documentation records each value after evidence exists.

## Existing architecture reused

The host is explicitly registered in `flake.nix`, matching `vm` and `dellan`. It reuses the shared `pkgsLinux`, `modules/common.nix`, agenix, agenix-rekey, `modules/nixos/tailscale.nix`, and `modules/nixos/nixos-auto-deploy.nix`. It does not import desktop Home Manager or microVM modules.

`profiles/base.nix` is not reused because it hard-codes Dellan hostname, NetworkManager, Btrfs scrub, workstation groups, and a workstation state version. A focused `profiles/home-server-base.nix` reuses its security decisions without changing existing hosts.

## Host foundation

`home-server` uses x86-64, systemd-boot, wired DHCP through systemd-networkd, `Europe/Stockholm`, systemd-timesyncd, persistent journald capped by age and size, key-only OpenSSH, Tailscale, Nix daily GC/weekly optimization, scaled low-space thresholds, smartd autodetection, and NixOS firewall.

Tracked pre-hardware storage uses filesystem labels rather than unknown UUIDs: ext4 root label `nixos` and FAT EFI label `EFI`. Stateful services use separate `/var/lib/<service>` paths so Matrix/PostgreSQL/Zigbee/automation data can later move to another filesystem through normal mount configuration. README requires BIOS power-on-after-AC-loss.

SSH listens normally, but firewall admits port 22 only through `tailscale0` after bootstrap. Installer environment supplies temporary LAN SSH; operator enrolls Tailscale before switching to final system. Password and keyboard-interactive authentication are disabled; root login is disabled.

## Service topology

Mosquitto listens on `127.0.0.1:1883` with persistence. Local-only clients may use anonymous access because packets cannot enter from any network interface. Optional Tailscale MQTT listener is separately gated and requires agenix-backed password files plus ACLs. Application topics use `house/v1/...`; Zigbee2MQTT native topics stay `zigbee2mqtt/...`. Documentation marks events and commands non-retained and availability/LWT state as retainable.

Zigbee2MQTT uses pinned nixpkgs module, dedicated user/state directory, Mosquitto ordering, `serial.adapter = "ember"`, configured stable by-id port, `permit_join = false`, and Zigbee-only firmware. Frontend binds all addresses only when firewall restricts port 8080 to `tailscale0`; otherwise it stays loopback. Current upstream supports EmberZNet firmware families 7.4.x through 9.1.x and recommends 7.4.4 or newer for ZBDongle-E; bootstrap verifies live upstream support before flashing. No multiprotocol firmware is accepted.

House automation uses `smarthome.nixosModules.default` and pinned package. Nix generates topology/config; agenix paths supply optional credentials. Service health stays loopback-only. Systemd owns `/var/lib/house-automation`.

TellStick remains an optional local-LAN adapter. Configuration captures address and token file only after the operator inspects the device's own `/api` index and completes local authorization. No Telldus cloud dependency exists. Zigbee and TellStick 433 MHz/Z-Wave remain distinct radio meshes joined only at MQTT/domain boundary.

Matrix uses Synapse, PostgreSQL 17 selected by repository state version, local Unix-socket peer auth, closed registration, persistent media, and loopback HTTP by default. Private Tailscale access can bind port 8008 with firewall scope `tailscale0`. Public federation stays off because no domain/reverse-proxy convention exists. Permanent `server_name` and agenix YAML secret file are bootstrap requirements; changing server name later is explicitly prohibited.

No reverse proxy, Home Assistant, container runtime, local LLM, Prometheus, Grafana, or InfluxDB is added.

## Secrets and bootstrap

Host always imports shared agenix-rekey module, but sets its per-host public key and declares secrets only after real SSH host key is recorded. Source secrets remain encrypted to user master identity; per-host ciphertext lives under `secrets/rekeyed/home-server`. Root-owned service secrets use mode `0400`; only daemon-specific users receive narrower files when required.

Provisioned names cover deploy SSH key, optional webhook HMAC, MQTT network clients, Matrix secret YAML, TellStick bearer token, future cloud AI environment, and optional backup environment. Existing `add-secret --host home-server` flow is reused once host key and insertion marker exist. No values are generated or displayed during this preparation.

Initial Tailscale enrollment follows current manual `tailscale up` convention. Auth-key support remains available through standard NixOS option but is not required or invented.

## Deployment and CI

Existing Dellan auto-deploy stays unchanged. Home server reuses pull/reset/rebuild, rollback guard, poison latch, and polling module after host identity plus deploy credential are configured. Webhook remains disabled initially; hourly polling avoids another public ingress. Flake attribute follows hostname `home-server`.

CI retains `build dellan toplevel` and adds `build home-server toplevel`; no job is renamed. New `vm-home-server` lane imports only server modules, supplies fake secrets/serial package where needed, and behaviorally checks Mosquitto, PostgreSQL/Synapse, automation health, hardening-relevant unit fields, firewall exposure, persistence directories, and 04:00 reset behavior through daemon test tooling. Branch-protection bootstrap includes new stable check name.

The pinned `smarthome` input makes application test/build outputs available to NixOS CI without another deployment framework. Smarthome's own repository runs Rust fmt, Clippy, tests, and build. NixOS CI builds full host closure.

## Backup and recovery

Git covers declarative config and encrypted sources only. README inventories mutable state:

- `/var/lib/postgresql`
- `/var/lib/matrix-synapse` and media store
- `/var/lib/house-automation`
- `/var/lib/zigbee2mqtt`
- Mosquitto persistence directory
- optional TellStick bridge state

Documentation gives consistent snapshots/exports: `pg_dump` for Synapse database, filesystem copy for media while service is quiesced or snapshot-consistent, SQLite backup API command for automation, Zigbee2MQTT data/coordinator backup, and adapter state copy. Until encrypted off-host destination and restore drill exist, docs say mutable data is not backed up. No disabled backup provider module is added because repository has no convention or destination.

Recovery covers blank-disk partition labels, NixOS install, generated hardware configuration review, host key recording, agenix rekey, Tailscale enrollment, stable dongle discovery, first build/switch, deploy-target clone, health checks, rollback, and full Git rebuild after disk loss.
