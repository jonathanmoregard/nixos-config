# What the feature-vm launcher builds: a host's VM (attr = "vm") or the
# system inside it that `feature-vm apply` activates (attr = "toplevel"),
# or the VM's pinned sshd host key (attr = "hostkey"), optionally with an
# extra module layered on.
#
#   nix build --impure --file scripts/feature-vm-target.nix \
#     --argstr flake DIR --argstr host tuxedo --argstr attr vm
{ flake, host, module ? "", attr ? "vm" }:
let
  base = (builtins.getFlake flake).nixosConfigurations.${host};
  sys = if module == "" then base else base.extendModules { modules = [ (import module) ]; };
in
if attr == "vm" then sys.config.system.build.vm
else if attr == "toplevel" then sys.config.virtualisation.vmVariant.system.build.toplevel
else if attr == "hostkey" then sys.config.virtualisation.vmVariant.system.build.featureVmHostKey
else throw "feature-vm-target: attr must be vm, toplevel or hostkey, got ${attr}"
