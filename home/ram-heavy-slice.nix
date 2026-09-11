# Disposable scopes for interactive Nix evaluation/builds and feature VMs.
{ ... }:
{
  systemd.user.slices.ram-heavy = {
    Unit = {
      Description = "Memory-heavy disposable workloads";
      Documentation = [ "man:systemd-oomd.service(8)" ];
    };

    Slice = {
      MemoryAccounting = true;
      MemoryHigh = "12G";
      ManagedOOMSwap = "kill";
      ManagedOOMMemoryPressure = "kill";
      ManagedOOMMemoryPressureLimit = "40%";
      ManagedOOMMemoryPressureDurationSec = "10s";
    };

    Install.WantedBy = [ "default.target" ];
  };
}
