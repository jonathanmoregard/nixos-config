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
# The keymap also reports typing counts ('Q' 'S', then keystrokes, backspaces
# and misses as little-endian uint16 since the previous report; never which
# keys). The listener appends them to $XDG_STATE_HOME/corne-stats/stats.tsv and
# `corne-accuracy` summarises accuracy (1 - backspaces/keystrokes) per day.
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
      import threading
      import time

      HID_ID = b"HID_ID=0003:00004653:00000001"  # USB, foostan Corne (crkbd rev1)
      RAW_USAGE_PAGE = bytes([0x06, 0x60, 0xFF])  # QMK raw HID usage page 0xFF60
      MISS = b"QM\x01"
      STATS = b"QS"
      MIN_GAP = 0.08  # seconds; a burst of misses gives one beep per gap
      RESCAN = 3

      # Test seams: a fixed device path (e.g. a FIFO), a player command and
      # the stats file.
      DEVICE = os.environ.get("CORNE_MISS_BEEP_DEVICE")
      STATS_FILE = os.environ.get("CORNE_STATS_FILE") or os.path.join(
          os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
          "corne-stats", "stats.tsv")
      STATS_FILE = os.path.abspath(STATS_FILE)
      PLAYER = shlex.split(os.environ.get(
          "CORNE_MISS_BEEP_PLAYER",
          "${pkgs.pipewire}/bin/pw-play --volume 0.5 ${beepSound}",
      ))


      def log(msg):
          print(f"corne-miss-beep: {msg}", file=sys.stderr, flush=True)


      # A persistent failure (no ACL, pipewire down, disk full) is logged once
      # per distinct message; success on that channel re-arms it.
      _last_failure = {}


      def failed(channel, msg):
          if _last_failure.get(channel) != msg:
              log(msg)
              _last_failure[channel] = msg


      def succeeded(channel):
          _last_failure.pop(channel, None)


      def find_device():
          if DEVICE:
              return DEVICE if os.path.exists(DEVICE) else None
          for node in sorted(glob.glob("/sys/class/hidraw/hidraw*")):
              try:
                  with open(f"{node}/device/uevent", "rb") as f:
                      if HID_ID not in f.read().upper().splitlines():
                          continue
                  with open(f"{node}/device/report_descriptor", "rb") as f:
                      if not f.read().startswith(RAW_USAGE_PAGE):
                          continue
              except OSError:
                  continue
              return "/dev/" + os.path.basename(node)
          return None


      def play():
          try:
              r = subprocess.run(PLAYER, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=10)
          except (OSError, subprocess.TimeoutExpired) as e:
              failed("player", f"player failed: {e}")
              return
          if r.returncode != 0:
              err = r.stderr.decode(errors="replace").strip()[:200]
              failed("player", f"player exited {r.returncode}: {err}")
          else:
              succeeded("player")


      def record_stats(data):
          keys, bsp, miss = (int.from_bytes(data[i:i + 2], "little") for i in (2, 4, 6))
          row = f"{time.strftime('%Y-%m-%dT%H:%M:%S')}\t{keys}\t{bsp}\t{miss}\n"
          try:
              os.makedirs(os.path.dirname(STATS_FILE), exist_ok=True)
              with open(STATS_FILE, "a") as f:
                  f.write(row)
              succeeded("stats")
          except OSError as e:
              failed("stats", f"stats write failed: {e}")


      def listen(path):
          last = 0.0
          fd = os.open(path, os.O_RDONLY)
          succeeded("device")
          log(f"listening on {path}")
          try:
              while True:
                  data = os.read(fd, 64)
                  if not data:  # FIFO writer closed
                      return
                  # The raw HID interface has no report IDs, so a report
                  # arrives as-is and the marker sits at offset 0.
                  if data.startswith(STATS) and len(data) >= 8:
                      record_stats(data)
                      continue
                  if not data.startswith(MISS):
                      continue
                  now = time.monotonic()
                  if now - last < MIN_GAP:
                      continue
                  last = now
                  threading.Thread(target=play, daemon=True).start()
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
                  # Unplug (EIO) or no ACL (EACCES); a successful open re-arms it.
                  failed("device", f"{path}: {e}")
                  time.sleep(RESCAN)


      main()
    '';

  corneAccuracy = pkgs.writers.writePython3Bin "corne-accuracy"
    { flakeIgnore = [ "E501" ]; }
    ''
      """Typing accuracy from the Corne's counts: today, the last 7 days, all time."""
      import collections
      import datetime
      import os
      import sys

      path = os.environ.get("CORNE_STATS_FILE") or os.path.join(
          os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
          "corne-stats", "stats.tsv")
      days = collections.defaultdict(lambda: [0, 0, 0])
      try:
          with open(path) as f:
              for line in f:
                  parts = line.rstrip("\n").split("\t")
                  if len(parts) != 4:
                      continue
                  try:
                      counts = [int(x) for x in parts[1:]]
                  except ValueError:
                      continue
                  day = days[parts[0][:10]]
                  for i in range(3):
                      day[i] += counts[i]
      except FileNotFoundError:
          sys.exit(f"no stats yet ({path}); type on the Corne with corne-miss-beep running")


      def line(label, keys, bsp, miss):
          if keys == 0:
              return f"{label:<12} no typing"
          acc = 100 * max(0, keys - bsp) / keys
          return f"{label:<12} {acc:5.1f}% accuracy  {keys:>7} keys  {bsp:>6} backspaces  {100 * miss / keys:4.1f} missed shortcuts/100 keys"


      def total(dates):
          t = [0, 0, 0]
          for d in dates:
              for i in range(3):
                  t[i] += days[d][i]
          return t


      today = datetime.date.today()
      week = [(today - datetime.timedelta(n)).isoformat() for n in range(7)]
      print(line("today", *days[today.isoformat()]))
      print(line("last 7 days", *total(d for d in week if d in days)))
      print(line("all time", *total(list(days))))
      print()
      for d in sorted((d for d in week if d in days), reverse=True):
          print(line(d, *days[d]))
      print("\naccuracy = 1 - backspaces/keystrokes (Ctrl+Backspace counts once)")
    '';
in
{
  home.packages = [ corneMissBeep corneAccuracy ];

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
