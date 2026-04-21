---
status: proposed
category: drift
date: 2026-04-19
source: mint-drift-agent
---

## yt-dlp not in home.packages

yt-dlp is in apt-mark showmanual but absent from all nix files.

```
In home/jonathan.nix home.packages, add:
  yt-dlp
```
