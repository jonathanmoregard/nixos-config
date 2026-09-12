{ pkgs, config }:

# Fast evaluated-config contract for storage maintenance. This intentionally
# checks Dellan's final merged module values rather than a duplicate fixture.
assert config.nix.gc.automatic;
assert config.nix.gc.dates == [ "daily" ];
assert config.nix.gc.options == "--delete-older-than 14d";
assert config.nix.settings.min-free == 200 * 1024 * 1024 * 1024;
assert config.nix.settings.max-free == 300 * 1024 * 1024 * 1024;
assert config.nix.optimise.automatic;
assert config.nix.optimise.dates == [ "Wed 04:15" ];
assert config.systemd.timers.nix-gc.timerConfig.OnCalendar == [ "daily" ];
assert config.systemd.timers.nix-gc.timerConfig.Persistent;
assert config.systemd.timers.nix-optimise.timerConfig.OnCalendar == [ "Wed 04:15" ];
assert config.systemd.timers.nix-optimise.timerConfig.Persistent;

pkgs.runCommand "nix-maintenance-contract" { } ''
  echo "ok: daily 14-day GC, 200/300 GiB pressure guard, and weekly store optimisation enabled" > "$out"
''
