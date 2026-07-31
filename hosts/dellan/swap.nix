# Swap + zram for dellan.
#
# Rationale: 2026-07-31 incident — 6 chrome OOM-kills in ~10 minutes with 0 B
# swap. 30 GiB RAM was 19 GiB used / 5.6 GiB shared under normal load (4
# concurrent Claude Code sessions + research-agent + scraper microvms + Chrome
# with many tabs); a burst pushed it past available and the kernel OOM-killed
# instead of paging. Without any swap, the OOM path is the only relief valve,
# and it manifests as a visible freeze plus lost work.
#
# Layer 1: zram (compressed in-RAM swap). Cheap, no disk write, ~2-3× effective
# capacity for the hot working set of Chrome renderers / claude subprocesses.
# NixOS default `algorithm = zstd`, `memoryPercent = 50` (up to 15 GiB of RAM
# used as compressed swap; typical residency far smaller).
#
# Layer 2: disk swapfile (16 GiB). Backstop when zram fills — pages cold to
# disk instead of triggering OOM. Cryptroot means writes are encrypted at the
# block layer; swap contents get the same protection as everything else on /.
{ ... }:
{
  zramSwap.enable = true;

  # Prod size. Test VMs (nixosTest) override this to a smaller size in
  # tests/lib/common.nix `node` because their 8 GiB virtio disk can't fit
  # a 16 GiB swapfile.
  swapDevices = [{
    device = "/var/lib/swapfile";
    size = 16384;  # MiB
  }];
}
