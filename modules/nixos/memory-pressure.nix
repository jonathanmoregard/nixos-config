# Kill disposable build descendants before memory pressure reaches desktop.
{ ... }:
{
  systemd.oomd = {
    enable = true;
    enableRootSlice = false;
    enableSystemSlice = false;
    enableUserSlices = false;
    settings.OOM.SwapUsedLimit = "80%";
  };

  # use-cgroups=true puts each derivation below this daemon cgroup. OOMD
  # monitors ancestor but selects offending build descendant; daemon survives
  # to serve next build.
  systemd.services.nix-daemon.serviceConfig = {
    MemoryAccounting = true;
    MemoryHigh = "12G";
    ManagedOOMSwap = "kill";
    ManagedOOMMemoryPressure = "kill";
    ManagedOOMMemoryPressureLimit = "40%";
    ManagedOOMMemoryPressureDurationSec = "10s";
  };
}
