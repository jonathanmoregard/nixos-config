{ config, ... }:

# Physical coordinator and its network identity. Kept apart from default.nix,
# like deployment-identity.nix, so test hosts with a different host key can
# drop the hardware path and the host-encrypted key together.
{
  # Sonoff ZBDongle-E (EFR32MG21, CP2102N bridge) observed on this host.
  # Channel 25 sits above the 2.4 GHz Wi-Fi channels 1/6/11 seen nearby.
  # PAN IDs are broadcast in beacons and need no secrecy; only the key does.
  homeServer = {
    zigbeeSerialPort = "/dev/serial/by-id/usb-Itead_Sonoff_Zigbee_3.0_USB_Dongle_Plus_V2_94b12b3f9478f011aba8a3e70ba521c7-if00-port0";
    zigbeeChannel = 25;
    zigbeePanId = 50324;
    zigbeeExtendedPanId = [ 52 207 50 36 195 122 154 61 ];
    zigbeeNetworkKeyFile = config.age.secrets.zigbee2mqtt-network-key.path;
  };

  age.secrets.zigbee2mqtt-network-key.rekeyFile = ../../secrets/zigbee2mqtt-network-key.age;
}
