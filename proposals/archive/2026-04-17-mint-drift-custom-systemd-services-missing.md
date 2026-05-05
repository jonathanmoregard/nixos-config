---
status: reviewed
category: drift
date: 2026-04-17
source: mint-drift-agent
---

## 5 custom systemd user services enabled but not in home-manager

The following services are active in ~/.config/systemd/user/ and enabled on the live system but are not declared anywhere in home-manager: llm-guard-daemon, router-ingestor, router-worker, whisper-writer, filter-chain. They would not be installed or started after a rebuild.

**Resolution (2026-04-21):**
- `llm-guard-daemon` — **uninstalled** (stopped, disabled, file removed)
- `whisper-writer` — **uninstalled** (already `.disabled`, file removed)
- `router-ingestor`, `router-worker`, `router-ingestor-scan` + timer — **ported** to `home/router-services.nix`
- `filter-chain` — not a custom service; provided by pipewire system package (NixOS recreates via `services.pipewire`)

```
# Read each unit file, then declare in a new home/custom-services.nix:
# cat ~/.config/systemd/user/whisper-writer.service  (etc.)
systemd.user.services.whisper-writer = {
  Unit.Description = "<from file>";
  Service.ExecStart = "<from file>";
  Install.WantedBy = [ "graphical-session.target" ];
};
# Repeat for llm-guard-daemon, router-ingestor, router-worker, filter-chain
# Import the new file in home/jonathan-linux.nix
```
