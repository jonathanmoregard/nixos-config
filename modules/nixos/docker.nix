{ ... }:
{
  virtualisation.docker.enable = true;
  users.users.jonathan.extraGroups = [ "wheel" "networkmanager" "docker" ];
}
