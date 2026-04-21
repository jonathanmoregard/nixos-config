---
status: proposed
category: drift
date: 2026-04-19
source: mint-drift-agent
---

## llm-guard-daemon and router services not in home-manager config

Four systemd user services are enabled on the live system (llm-guard-daemon, router-ingestor, router-worker, router-ingestor-scan) plus a timer (router-ingestor-scan.timer). None are declared in home-manager. On fresh install these daemons will not start.

```
Read each live unit file and model them in home/jonathan-linux.nix:
  systemd.user.services.llm-guard-daemon = {
    Unit.Description = "LLM Guard Daemon";
    Service.ExecStart = "/path/to/binary";  # read from live unit
    Install.WantedBy = [ "default.target" ];
  };
Repeat for router-ingestor, router-worker. For the scan timer, also add a matching systemd.user.timers.router-ingestor-scan entry mirroring the live .timer unit.
```
