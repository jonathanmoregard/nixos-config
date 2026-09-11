{ pkgs, config }:

# Fast evaluated-config contract for storage maintenance. This intentionally
# checks Dellan's final merged module values rather than a duplicate fixture.
assert config.nix.gc.automatic;
assert config.nix.gc.dates == [ "Sun 04:15" ];
assert config.nix.gc.options == "--delete-older-than 14d";
assert config.nix.optimise.automatic;
assert config.nix.optimise.dates == [ "Wed 04:15" ];
assert config.systemd.timers.nix-gc.timerConfig.OnCalendar == [ "Sun 04:15" ];
assert config.systemd.timers.nix-gc.timerConfig.Persistent;
assert config.systemd.timers.nix-optimise.timerConfig.OnCalendar == [ "Wed 04:15" ];
assert config.systemd.timers.nix-optimise.timerConfig.Persistent;

pkgs.runCommand "nix-maintenance-contract" { } ''
  echo "ok: weekly 14-day GC and weekly store optimisation enabled" > "$out"
''
