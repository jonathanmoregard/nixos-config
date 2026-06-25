# v4l2loopback write-buffer headroom for the camera relay.
#
# v4l2loopback allocates only 2 write buffers per device by default
# (`max_buffers` [DEFAULT: 2]). For the IPU6 webcam relay pipeline
# (v4l2-relayd: appsrc ! videoconvert ! ... ! v4l2sink) that is fatal:
# while no consumer is attached the loopback recycles the producer's
# buffers instantly, but the moment a consumer (Chrome / Meet) attaches
# and starts holding buffers for reading, GStreamer v4l2sink's 2-slot
# buffer pool has zero headroom — videoconvert's next buffer request
# fails ("failed to allocate buffer" → "could not get buffer from
# pool" → "Internal data stream error"), v4l2-relayd quits its main
# loop and exits 0, SILENTLY ("Deactivated successfully" is the only
# journal trace). systemd restarts it, the consumer re-attaches, it
# dies again ~2 frames in. User-visible: camera shows 1-2 s of video
# then "camera not found", forever (observed at relay restart counter
# 480 on dellan). The crash needs the videoconvert element in the
# pipeline — it is the element that allocates from v4l2sink's proposed
# pool — which is why the ipu6ep NV12→YUY2 instance dies while a
# trivial YUY2→YUY2 relay survives.
#
# 8 buffers gives the pool real headroom. Verified empirically in the
# feature VM (stock v4l2loopback 0.15.3, kernel 6.18.31):
#   - 2 buffers → producer dies <2 s after consumer attach, every time
#   - 8 buffers → 1800/1800 frames over 60 s at steady 30 fps, across
#     consumer attach / detach / re-attach cycles
# Cost: ~11 MB extra kernel memory per device at 1280x720 YUY2.
# Upstream v4l2loopback's DQBUF spec-violation (PR #656, unmerged) is
# real but NOT the user-facing killer: the full PR-656 series was
# tested and the relay still died with 2 buffers, while stock 0.15.3
# survives with 8.
#
# NB: a module parameter applies at module LOAD. After deploying this,
# the running system keeps the old value until reboot (v4l2loopback
# loads at boot and the ipu6 relay keeps its device alive across
# service restarts). Manual alternative: stop v4l2-relayd-ipu6, delete
# the device, rmmod + modprobe v4l2loopback, start the relay.
#
# Regression-guarded by tests/camera-relay.nix (vm-camera-relay lane),
# which imports this module; without it the lane reproduces the death.
{ ... }:
{
  # Merges with the v4l2-relayd module's own
  # "options v4l2loopback devices=0" line — modprobe.d(5) combines
  # multiple `options` lines for the same module.
  boot.extraModprobeConfig = ''
    options v4l2loopback max_buffers=8
  '';
}
