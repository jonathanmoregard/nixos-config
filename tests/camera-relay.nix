# vm-camera-relay: v4l2loopback ↔ gst v4l2sink producer survival.
#
# Reproduces (and guards against) the IPU6 webcam relay death: with
# v4l2loopback's default of 2 write buffers per device, GStreamer
# v4l2sink's buffer pool has zero headroom. While no consumer is
# attached the loopback recycles producer buffers instantly, but the
# moment a consumer attaches and holds buffers for reading,
# videoconvert's next allocation from the pool fails → "Internal data
# stream error" → v4l2-relayd exits 0 silently → systemd restart-loops
# it, dying ~2 frames after every re-attach. On dellan: camera shows
# 1-2 s of video then "camera not found" in every Google Meet call
# (relay observed at restart counter 480). Fix + full post-mortem:
# modules/nixos/v4l2loopback-buffers.nix (imported below — the exact
# module prod imports via laptop.nix).
#
# The bug needs NO camera hardware: any v4l2-relayd producer with a
# videoconvert stage hits it. This lane runs the real prod machinery —
# the v4l2-relayd binary, the nixpkgs service module, v4l2loopback-ctl
# device creation — with videotestsrc standing in for icamerasrc, then
# attaches a consumer the way Chrome does and asserts the producer
# SURVIVES. Red without v4l2loopback-buffers.nix; green with it.
#
# Run: nix build .#checks.x86_64-linux.vm-camera-relay -L
{ pkgs, inputs }:
(import ./lib/common.nix { inherit pkgs inputs; }).mkMinimalTest {
  name = "vm-camera-relay";
  extraModules = [
    ../modules/nixos/v4l2loopback-buffers.nix
    ({ config, pkgs, ... }: {
      services.v4l2-relayd.instances.test = {
        enable = true;
        cardLabel = "Test Relay Camera";
        input.pipeline = "videotestsrc";
        # NV12 mirrors the prod ipu6ep instance (nixpkgs ipu6.nix sets
        # input.format = "NV12"). The format mismatch vs the YUY2 output
        # makes the service module insert `videoconvert ! queue` before
        # v4l2sink — REQUIRED to trigger the bug: videoconvert is the
        # element that allocates from v4l2sink's proposed buffer pool
        # and dies when the pool has no headroom. With YUY2-in (no
        # conversion) v4l2sink copies in its own render path, which
        # BLOCKS on DQBUF instead of failing, and the lane
        # false-passes (verified empirically via GST_DEBUG).
        input.format = "NV12";
      };
      environment.systemPackages = [ pkgs.v4l-utils ];
    })
  ];
  testScript = ''
    dellan.wait_for_unit("multi-user.target")
    dellan.wait_for_unit("v4l2-relayd-test.service")

    dev = dellan.succeed("cat /run/v4l2-relayd-test/device").strip()
    print(f"[diag] loopback device: {dev}")

    # The loopback is created with exclusive caps (-x 1): the capture
    # side only advertises formats once the producer's v4l2sink has
    # completed STREAMON (splash preroll). Without this gate v4l2-ctl
    # exits 0 with "unsupported stream type" WITHOUT streaming and the
    # frame assertions below would be hollow.
    dellan.wait_until_succeeds(
        f"v4l2-ctl -d {dev} --list-formats 2>&1 | grep -q YUYV", timeout=60
    )

    pid_before = dellan.succeed(
        "systemctl show -p MainPID --value v4l2-relayd-test.service"
    ).strip()
    # Baseline, not assumed 0: a benign restart during early startup
    # (before the format gate passed) must not false-red the lane. The
    # assertions below check the DELTA across the consumer sessions.
    restarts_before = dellan.succeed(
        "systemctl show -p NRestarts --value v4l2-relayd-test.service"
    ).strip()

    # Attach a consumer exactly like a browser does: open the capture
    # side and stream frames. This is what flips the producer from
    # instant buffer recycling to consumer-paced recycling — and, with
    # only 2 write buffers, kills it ~2 frames in. 90 frames @30fps =
    # 3s of sustained streaming, well past the failure point.
    # timeout(1) bounds the hang when the producer dies mid-stream and
    # the consumer's DQBUF blocks forever.
    consumer = dellan.execute(
        f"timeout 30 v4l2-ctl -d {dev} --stream-mmap --stream-count=90 "
        "--stream-to=/dev/null 2>&1"
    )
    print(f"[diag] consumer rc={consumer[0]} out={consumer[1]!r}")

    # Diagnostics BEFORE assertions — once one fails the VM is gone.
    print("[diag] relay journal:\n" + dellan.succeed(
        "journalctl -u v4l2-relayd-test.service --no-pager | tail -40"
    ))
    restarts = dellan.succeed(
        "systemctl show -p NRestarts --value v4l2-relayd-test.service"
    ).strip()
    pid_after = dellan.succeed(
        "systemctl show -p MainPID --value v4l2-relayd-test.service"
    ).strip()
    print(f"[diag] NRestarts={restarts} pid_before={pid_before} pid_after={pid_after}")

    # 1. The consumer must actually receive its 90 frames. v4l2-ctl
    #    prints one '<' marker per dequeued frame; rc alone is not
    #    enough (v4l2-ctl exits 0 on "unsupported stream type").
    frames = consumer[1].count("<")
    assert consumer[0] == 0, (
        f"consumer failed to stream 90 frames (rc={consumer[0]}): {consumer[1]!r}"
    )
    assert frames >= 90, (
        f"consumer dequeued only {frames}/90 frames — producer starved or died "
        f"mid-stream: {consumer[1]!r}"
    )
    # 2. The producer must survive the consumer attach — same PID, no
    #    restarts. Without buffer headroom the relay hits "Internal
    #    data stream error", exits 0 silently ~2 frames after attach,
    #    and systemd restart-loops it.
    assert restarts == restarts_before, (
        f"v4l2-relayd-test restarted ({restarts_before} -> {restarts}) during "
        "a consumer attach — v4l2sink buffer-pool starvation (v4l2loopback "
        "write-buffer headroom)"
    )
    assert pid_before == pid_after, (
        f"relay main PID changed {pid_before} -> {pid_after} during consumer attach"
    )

    # 3. Detach/re-attach: a second consumer session must work too
    #    (Meet rejoin path). Guards against wedges that only appear on
    #    the second open — prod also died 0.3s after consumer DETACH.
    consumer2 = dellan.execute(
        f"timeout 30 v4l2-ctl -d {dev} --stream-mmap --stream-count=30 "
        "--stream-to=/dev/null 2>&1"
    )
    frames2 = consumer2[1].count("<")
    assert consumer2[0] == 0 and frames2 >= 30, (
        f"second consumer session broken (rc={consumer2[0]}, "
        f"frames={frames2}/30): {consumer2[1]!r}"
    )
    restarts2 = dellan.succeed(
        "systemctl show -p NRestarts --value v4l2-relayd-test.service"
    ).strip()
    assert restarts2 == restarts_before, (
        f"relay restarted ({restarts_before} -> {restarts2}) on second "
        "consumer session"
    )
  '';
}
