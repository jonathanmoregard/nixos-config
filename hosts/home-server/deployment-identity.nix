{ config, ... }:

{
  homeServer = {
    ageHostPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEnGlRJufT9hIgzqFqHujW28DsSX1YDYg/0vGG7BsO1+ root@home-server";
    deployKeyFile = config.age.secrets.deploy-ssh-key.path;
  };

  age.secrets.deploy-ssh-key.rekeyFile = ../../secrets/deploy-ssh-key.age;
}
