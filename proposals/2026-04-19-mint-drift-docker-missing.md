---
status: proposed
category: drift
date: 2026-04-19
source: mint-drift-agent
---

## Docker and docker-compose not in config

docker.io and docker-compose-v2 are in apt-mark showmanual. On NixOS Docker requires a system-level virtualisation option and group membership; neither is declared.

```
In a NixOS module:
  virtualisation.docker.enable = true;
  users.users.jonathan.extraGroups = [ "docker" ];
```
