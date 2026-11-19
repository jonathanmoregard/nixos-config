{ pkgs, ... }:
# corne-miss-beep: a soft beep when the Corne reports a typing "miss".
#
# The hands-down-se QMK keymap (jonathanmoregard/qmk_firmware,
# keyboards/crkbd/keymaps/hands-down-se) sends a 32-byte raw HID report
# starting 'Q' 'M' 0x01 whenever a pair is typed the long way instead of with
# its adaptive roll, H combo or the Repeat key. This user service reads the
# Corne's raw HID interface (usage page 0xFF60) and plays a short, quiet tone
# per report, so the hint is heard without looking at the keyboard.
#
# Access: hardware.keyboard.qmk.enable (hosts/tuxedo) installs the QMK udev
# rules, which tag the Corne's hidraw nodes `uaccess`. With no Corne plugged
# in the service just rescans every few seconds.
#
# Asserted by tests/base.nix (vm-base).
let
  # A small crystal-bell "ting" (picked by ear from seven candidates): E7
  # fundamental plus a 0.6 % detuned twin for shimmer and two inharmonic
  # overtones, each decaying exponentially; 2 ms attack, 0.5 s long.
  beepSound = pkgs.runCommand "corne-miss-ting.wav" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    python3 - "$out" <<'PY'
    import math, struct, sys, wave
    rate, dur, f0, vol = 48000, 0.5, 2637, 0.25
    partials = [(1, 1.0, 0.18), (1.006, 0.6, 0.18), (2.32, 0.3, 0.08), (4.25, 0.12, 0.04)]
    attack = int(0.002 * rate)
    out = []
    for i in range(int(dur * rate)):
        t = i / rate
        s = sum(a * math.exp(-t / tau) * math.sin(2 * math.pi * f0 * r * t) for r, a, tau in partials)
        out.append(s * min(1, i / attack))
    peak = max(abs(x) for x in out)
    with wave.open(sys.argv[1], "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(b"".join(struct.pack("<h", int(x / peak * vol * 32767)) for x in out))
    PY
  '';

  corneMissBeep = pkgs.writers.writePython3Bin "corne-miss-beep"
    { flakeIgnore = [ "E501" ]; }
    ''
      import glob
      import os
      import shlex
      import subprocess
      import sys
      import time

      VID_PID = "00004653:00000001"  # foostan Corne (crkbd rev1)
      RAW_USAGE_PAGE = bytes([0x06, 0x60, 0xFF])  # QMK raw HID usage page 0xFF60
      MISS = b"QM\x01"
      MIN_GAP = 0.08  # seconds; a burst of misses gives one beep per gap
      RESCAN = 3

      # Test seams: a fixed device path (e.g. a FIFO) and a player command.
      DEVICE = os.environ.get("CORNE_MISS_BEEP_DEVICE")
      PLAYER = shlex.split(os.environ.get(
          "CORNE_MISS_BEEP_PLAYER",
          "${pkgs.pipewire}/bin/pw-play --volume 0.5 ${beepSound}",
      ))


      def log(msg):
          print(f"corne-miss-beep: {msg}", file=sys.stderr, flush=True)


      def find_device():
          if DEVICE:
              return DEVICE if os.path.exists(DEVICE) else None
          for node in sorted(glob.glob("/sys/class/hidraw/hidraw*")):
              try:
                  with open(f"{node}/device/uevent") as f:
                      if VID_PID not in f.read().upper():
                          continue
                  with open(f"{node}/device/report_descriptor", "rb") as f:
                      if not f.read().startswith(RAW_USAGE_PAGE):
                          continue
              except OSError:
                  continue
              return "/dev/" + os.path.basename(node)
          return None


      def listen(path):
          last = 0.0
          fd = os.open(path, os.O_RDONLY)
          log(f"listening on {path}")
          try:
              while True:
                  data = os.read(fd, 64)
                  if not data:  # FIFO writer closed
                      return
                  if MISS not in data[:4]:
                      continue
                  now = time.monotonic()
                  if now - last < MIN_GAP:
                      continue
                  last = now
                  try:
                      subprocess.Popen(PLAYER, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                  except OSError as e:
                      log(f"player failed: {e}")
          finally:
              os.close(fd)


      def main():
          waiting = False
          while True:
              path = find_device()
              if path is None:
                  if not waiting:
                      log("no Corne raw HID interface; waiting")
                      waiting = True
                  time.sleep(RESCAN)
                  continue
              waiting = False
              try:
                  listen(path)
              except OSError as e:
                  log(f"{path}: {e}")
                  time.sleep(1)


      main()
    '';
in
{
  home.packages = [ corneMissBeep ];

  systemd.user.services.corne-miss-beep = {
    Unit = {
      Description = "Soft beep on Corne typing misses (raw HID)";
      After = [ "pipewire.service" ];
    };
    Service = {
      ExecStart = "${corneMissBeep}/bin/corne-miss-beep";
      Restart = "always";
      RestartSec = 5;
    };
    Install.WantedBy = [ "default.target" ];
  };
}
