# Small tools for an internet or infrastructure outage, next to offline-ai
# (the local model + Kiwix library). Each covers something the model and
# the ZIMs cannot do well: navigate, compute exactly, look a word up, read
# scanned paper, and listen to radio once an SDR dongle exists. None runs
# a daemon except dictd (a few MB, TCP 2628, closed by the firewall).
#
# Chosen from research-agent report ff2e5f74 (2026-10-01). Marginal cost on
# top of the tuxedo system, measured with `nix path-info -r` against
# cache.nixos.org: ~560 MiB total, of which Organic Maps is ~460 MiB.
# Left out: gqrx (+1.7 GiB, add with an SDR); the Reticulum mesh stack
# (nomadnet/sideband need rns, which nixpkgs marks unfree, and the
# reticulum-group-chat package alone is only a hub); translateLocally (no
# Swedish model); js8call and fldigi (need a transceiver); localsend
# (Flutter; `python3 -m http.server` covers LAN file transfer).
#
# Needs doing while still online (the tools cannot fetch it later):
#   - Organic Maps: download the Sweden region in the app.
#   - Zeal: download the docsets you want (Tools > Docsets).
#   - tldr: filled by the tldr-update timer below; `tldr --update` by hand
#     after first deploy.
{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    organicmaps # offline OSM maps, search and routing (`OMaps`)
    kiwix # desktop reader for the survival-corpus ZIMs without the model
    zeal # offline API docs (docsets downloaded in-app)
    qalculate-gtk # exact unit-aware arithmetic
    libqalculate # `qalc` on the CLI
    tesseract # OCR, all languages incl. swe
    man-pages
    man-pages-posix
    rtl-sdr # rtl_fm: tune FM (Sveriges Radio P4) with a ~30 EUR dongle
    multimon-ng # decode POCSAG/APRS/EAS/Morse from rtl_fm audio
    direwolf # APRS software TNC
  ];

  # Lets jonathan use an RTL-SDR dongle without root (plugdev + udev rules,
  # DVB driver blacklisted so it does not grab the stick).
  hardware.rtl-sdr.enable = true;
  users.users.jonathan.extraGroups = [ "plugdev" ];

  # `dict <word>`: English definitions (WordNet, Wiktionary). No Swedish
  # dictd database exists in nixpkgs; the model covers sv<->en.
  services.dictd = {
    enable = true;
    DBs = with pkgs.dictdDBs; [ wordnet wiktionary ];
  };

  # tldr pages, refreshed by home-manager's tldr-update timer while online
  # so the cache is there when the network is not.
  home-manager.users.jonathan.programs.tealdeer.enable = true;
}
