---
status: proposed
category: drift
date: 2026-04-19
source: mint-drift-agent
---

## Cursor IDE not in home.packages

cursor (Cursor IDE, cursor.sh) appears in apt-mark showmanual as a user-installed package and is not declared in any nix file. It is available in nixpkgs as pkgs.cursor (unfree).

```
In home/desktop-apps.nix home.packages, add:
  cursor
And ensure allowUnfree = true is set in the flake nixpkgs config.
```
