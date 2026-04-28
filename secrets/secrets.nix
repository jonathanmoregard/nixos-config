let
  # jonathan's personal SSH key (used from Mint laptop to manage secrets)
  jonathan = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPf3ZLrzmf0pNSTJS603CaNb6in/ctXc0hZSJ9BflOVl jonathan@nixos-vm";

  # VM SSH host key (used by agenix to decrypt secrets at activation time)
  vm = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJaYUR/n99axrFFFr/uv987jwaa6fYik7Ykf9iRSieZV root@nixos-vm";

  # Dellan laptop SSH host key (used by agenix to decrypt secrets at activation time)
  dellan = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJNvaYqBU7k/iTKPHcfVGYz5WJNVWnf0t26SX6Y7SZ0e root@dellan";

  allKeys = [ jonathan vm dellan ];
in {
  # Add secrets here as needed, e.g.:
  # "my-api-key.age".publicKeys = allKeys;
}
