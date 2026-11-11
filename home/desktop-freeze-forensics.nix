{ pkgs, lib, config, ... }:
# desktop-freeze-forensics — record what the desktop was doing, so the next
# freeze is diagnosable instead of a guess.
#
# This exists because of the 2026-11-09 21:00 freeze, where the machine was
# demonstrably alive and every existing signal said "healthy":
# cinnamon-watchdog probed Cinnamon's main loop every 20s and got ALIVE every
# time, including 38s before the reboot; Cinnamon processed a monitor hotplug
# seconds before it; no OOM kill, no amdgpu reset, no hung_task, no Xorg
# crash; the screensaver could not have locked (idle-delay 900s, user idle
# ~9min) and the display could not have slept (1800s). The screen was still
# unusable and the session was lost to a reboot.
#
# Nothing on the box recorded the facts that would have separated the
# candidates: was input still reaching X, was the panel lit, were the DRM
# connectors still on, what held focus, was anything spinning. This samples
# exactly those, once per tick, to a rolling on-disk log.
#
# Deliberately NOT here:
#
#   * Any X grab. The most direct way to ask "does something hold the
#     keyboard" is to try to take it (XGrabKeyboard -> AlreadyGrabbed), and
#     that is rejected outright: a sampler that grabs the keyboard every 20s
#     is a plausible cause of the freeze it is meant to explain. Everything
#     below is a read of /proc, /sys, or an X/DBus query that takes nothing.
#
#   * Any D-Bus call that can activate what it asks about. The same
#     principle as the grab, and less obvious: several Cinnamon names are
#     activatable, so a method call on one while it is unowned makes the bus
#     START that service. Asking "is the screensaver active" the naive way
#     therefore spawns a screensaver -- and a locker takes the input grab.
#     The screensaver probe says `--auto-start=no` to the bus, which is that
#     refusal stated once. Measured rather than assumed: against an
#     activatable name on a scratch session bus, a plain `gdbus call` logged
#     "Activating service name=..." and the service really started, while
#     this call returned "does not exist" and started nothing. Caught in
#     review before it ever shipped; the log would otherwise have been
#     recording a locker it had started itself.
#
#   * Any recovery action. The fault is not identified yet, so there is
#     nothing to recover from and no safe trigger to hang it on. Recovery of
#     a wedged Cinnamon main loop already exists (home/cinnamon-watchdog.nix)
#     and is untouched here: it worked correctly during the event and was
#     simply out of scope for it.
#
# Asserted by tests/desktop.nix (vm-desktop).
let
  intervalSecs = 20;
  # Every X and DBus call is bounded, because a wedged X server is the
  # scenario: a sampler that blocks on the fault it is sampling records
  # nothing. A timeout is itself a datum and is logged as one.
  callTimeoutSecs = 4;
  # Backstop for the whole tick: the bounded /proc walk, at most 5 bounded
  # subprocess calls (xprintidle, 2 gdbus, 2 xprop) plus file IO. Generous
  # enough that a slow-but-working desktop is never cut off, short enough
  # that ticks cannot pile up at a 20s interval.
  tickTimeoutSecs = 60;
  # Budget for the single /proc walk, which is the one step whose duration
  # this code does not control (see scan_procs_bounded). Comfortably under
  # tickTimeoutSecs so that giving up on it still leaves time to write.
  procBudgetSecs = 15;

  stateDir = "${config.home.homeDirectory}/.local/state/desktop-freeze";
  # ~250 bytes/line at 20s is ~1MB/day, so this is ~4 days per file and
  # ~8 days across the rotation. Long enough to cover "it froze again last
  # week"; bounded enough to never be the reason a disk fills.
  maxBytes = 4 * 1024 * 1024;

  freezeSampler = pkgs.writers.writePython3Bin "desktop-freeze-sample"
    { flakeIgnore = [ "E501" ]; }
    ''
      """desktop-freeze-sample — append one line of desktop state per tick."""
      import glob
      import os
      import re
      import subprocess
      import sys
      import threading
      import time

      BUSCTL = os.environ.get("FREEZE_BUSCTL", "${pkgs.systemd}/bin/busctl")
      XPRINTIDLE = os.environ.get("FREEZE_XPRINTIDLE", "${pkgs.xprintidle}/bin/xprintidle")
      XPROP = os.environ.get("FREEZE_XPROP", "${pkgs.xprop}/bin/xprop")
      STATE_DIR = os.environ.get("FREEZE_STATE_DIR", "${stateDir}")
      CALL_TIMEOUT = int(os.environ.get("FREEZE_CALL_TIMEOUT_SECS", "${toString callTimeoutSecs}"))
      MAX_BYTES = int(os.environ.get("FREEZE_MAX_BYTES", "${toString maxBytes}"))
      PROC_BUDGET = int(os.environ.get("FREEZE_PROC_BUDGET_SECS", "${toString procBudgetSecs}"))
      # busctl's own --timeout must expire BEFORE the subprocess timeout that
      # wraps it, or the two race: whichever fires first decides whether the
      # tick learns "the peer accepted the call and never answered" (busctl
      # wins and says so) or merely "the process was killed" (subprocess
      # wins, stderr empty, the distinction lost). Strictly smaller, floor 1.
      CALL_TIMEOUT_INNER = max(1, CALL_TIMEOUT - 1)
      # Overridable so the test can point every /sys read at a fixture tree
      # instead of the builder's real hardware, which has no backlight and
      # whose DRM connectors say nothing about this code being right.
      SYS_ROOT = os.environ.get("FREEZE_SYS_ROOT", "")


      def _sys(path):
          return SYS_ROOT + path


      def _run(argv, timeout=None):
          """(ok, text, stderr). Never raises: a failed probe is a field value.

          stderr is returned, not discarded, because for D-Bus it carries the
          only thing that distinguishes "nobody owns this name" from "the bus
          did not answer at all" -- both of which are a plain exit 1. Dropping
          it made a dead session bus indistinguishable from an absent
          screensaver, which is a wrong answer in the exact circumstance this
          log exists for.
          """
          try:
              p = subprocess.run(
                  argv, capture_output=True, text=True,
                  # errors="replace" because xprop returns a WM_CLASS
                  # verbatim and an X STRING property is Latin-1, not
                  # UTF-8. Strict decoding would raise UnicodeDecodeError
                  # -- which is neither OSError nor TimeoutExpired, so it
                  # would escape this function and lose the whole tick,
                  # for as long as that one window held focus.
                  errors="replace",
                  timeout=timeout or CALL_TIMEOUT,
              )
          except subprocess.TimeoutExpired:
              return False, "timeout", ""
          except OSError as exc:
              return False, "error:%s" % type(exc).__name__, ""
          err = (p.stderr or "").strip()
          if p.returncode != 0:
              return False, "rc%d" % p.returncode, err
          return True, (p.stdout or "").strip(), err


      def _read(path, limit=256):
          try:
              with open(path, "rb") as fh:
                  return fh.read(limit).decode("utf-8", "replace").strip()
          except OSError:
              return None


      def _clean(value):
          """Keep the log one-line and parseable as key=value pairs."""
          if value is None:
              return "?"
          value = re.sub(r"\s+", "_", str(value).strip())
          value = value.replace("=", "-")
          return value or "?"


      def _bus_failure(out, stderr):
          """Label a failed busctl call. Never invents a substantive answer.

          These must stay apart, because during a freeze they point at
          different culprits: nobody is running the screensaver; the
          screensaver is running but has stopped answering; the session bus
          itself is gone; the bus answered and refused.

          Every string below was observed from busctl, not guessed. Three
          details that are easy to get wrong and were only found by looking:

          1. THE TWO BUS IMPLEMENTATIONS WORD "UNOWNED" DIFFERENTLY, and
             this host runs the one whose wording is less obvious:

               dbus-broker  Call failed: Destination does not exist
               dbus-daemon  Call failed: Name "org.x" does not exist

             dbus-broker is what runs here (systemd user session, see the
             `dbusd` matcher). dbus-daemon is what `dbus-run-session` gives
             a scratch experiment -- so a string captured that way is NOT
             the string production emits, and matching only it silently
             reclassifies every real unowned screensaver. Both are listed.

          2. QUOTING IS NOT UNIFORM, and some near-misses also contain the
             words "does not exist":

               wrong path  Call failed: Object does not exist at path "/x"
               no method   Call failed: No such method "Foo"

             Those two come from a LIVE, OWNED peer and carry CURLY quotes
             (systemd composes them; the unowned texts above come from the
             bus and are ASCII). So an unanchored `does not exist` test
             files a working screensaver as "no screensaver running". Each
             accepted phrase is therefore written out in full, and anything
             unrecognised falls through to `callerr` rather than being
             guessed at.

          3. ORDER MATTERS. "Failed to connect ...: Connection timed out" is
             a dead bus, not a slow screensaver, so the connect test runs
             before the timeout test.

          There is no structured alternative to this prose: `--json=short`
          was tried and leaves stderr exactly as above, so busctl's `call`
          verb never exposes the D-Bus error name.

          `out` carries the probe-level outcome instead ("timeout" when our
          own subprocess kill beat busctl, "error:<Type>" when it could not
          be launched at all).
          """
          stderr = stderr or ""
          if out == "timeout" or out.startswith("error:"):
              return out
          if re.search(r"Failed to connect", stderr):
              return "busfail"
          if re.search(r'Destination does not exist'        # dbus-broker
                       r'|Name "[^"]*" does not exist',     # dbus-daemon
                       stderr):
              return "unowned"
          # Measured, not assumed: SIGSTOPping the bus daemon and leaving a
          # live peer unresponsive BOTH yield "Connection timed out", so
          # this one label genuinely cannot say which stalled. The two-call
          # design it replaced could, and that is a real loss. The `dbusd`
          # field narrows it from the same line without another bus call,
          # but only as evidence, not as proof -- see PROC_MATCHERS.
          if re.search(r"[Tt]imed out|[Tt]imeout", stderr):
              return "notimely"
          # The bus answered and refused: wrong object path, unknown method,
          # wrong signature, AccessDenied. That is a fault in this probe or
          # a changed screensaver API -- emphatically NOT "the session bus
          # is gone", which is what this used to be filed as.
          if stderr:
              return "callerr"
          return "unparsed"


      def idle_ms():
          # The single most useful field, and the one nothing else records:
          # the X idle counter resets on any input event, so a value near
          # zero means input WAS arriving. That separates "the desktop stopped
          # accepting input" from "the user had walked away", which is
          # precisely the ambiguity that made the 2026-11-09 freeze
          # undiagnosable after the fact.
          ok, out, _ = _run([XPRINTIDLE])
          if not ok:
              return out
          return out if out.isdigit() else "?"


      def screensaver_active():
          """Is the screen locked? Asked in a way that cannot start a locker.

          The host ships org.cinnamon.ScreenSaver.service in
          /run/current-system/sw/share/dbus-1/services/, so the name is
          D-Bus-activatable: a plain method call on it while it is unowned
          makes the bus START cinnamon-screensaver. A sampler doing that
          every 20s would spawn a locker -- and a locker takes the input
          grab -- into the session it is supposed to be a passive witness to.
          Same class of self-inflicted fault as taking an X grab, which this
          module refuses for the same reason.

          `--auto-start=no` is that refusal, stated once to the bus. It was
          measured, not assumed: against an activatable name on a scratch
          session bus, a plain `gdbus call` logged "Activating service
          name=..." and the service really started, while this call returned
          "does not exist" and started nothing.

          This replaced a hand-rolled two-step -- GetNameOwner, then address
          the unique name it returned -- which was correct but larger, and
          which needed a third state ("vanished") purely to describe the
          owner disappearing between its two calls. One call has no gap
          between calls, so that state stopped existing rather than being
          handled.
          """
          ok, out, err = _run([
              BUSCTL, "--user", "call", "--auto-start=no",
              "--timeout=%d" % CALL_TIMEOUT_INNER,
              "org.cinnamon.ScreenSaver", "/org/cinnamon/ScreenSaver",
              "org.cinnamon.ScreenSaver", "GetActive",
          ])
          if not ok:
              return _bus_failure(out, err)
          # Match the reply shape rather than looking for "true" anywhere in
          # it. A substring test turned every unexpected reply -- empty
          # output, a changed signature, a future formatting change -- into
          # "0", which does not mean "could not tell", it means "the
          # screensaver was running and the screen was NOT locked". That is a
          # claim about the desktop manufactured out of a parse failure, and
          # the most misleading thing this log could say about a freeze.
          if re.fullmatch(r"b\s+true", out):
              return "1"
          if re.fullmatch(r"b\s+false", out):
              return "0"
          return "active_unparsed"


      def _sys_class(subdir):
          """(entries, present) for a /sys class directory.

          `present` separates "the kernel exposes this class and it is empty"
          from "this path is not readable at all". Both used to collapse into
          "none", which reads as a substantive observation -- no backlight, no
          enabled connector -- when it may only mean the sampler was looking
          somewhere that does not exist. On a machine whose symptom is a dark
          screen, "no enabled connector" is close to a diagnosis, so it must
          never be something a bad path can fabricate.
          """
          root = _sys("/sys/class/" + subdir)
          return sorted(glob.glob(os.path.join(root, "*"))), os.path.isdir(root)


      def backlight():
          """<name>:<brightness>/<max>:power<bl_power> for each backlight."""
          out = []
          devices, present = _sys_class("backlight")
          for d in devices:
              # bl_power is the field that answers "was the panel actually
              # lit": 0 is on, 4 is off. Brightness alone does not, because a
              # dimmed-but-on panel and a powered-off one can report the same
              # non-zero brightness.
              out.append("%s:%s/%s:power%s" % (
                  os.path.basename(d),
                  _read(os.path.join(d, "brightness")) or "?",
                  _read(os.path.join(d, "max_brightness")) or "?",
                  _read(os.path.join(d, "bl_power")) or "?",
              ))
          if out:
              return ",".join(out)
          return "none" if present else "unreadable"


      def connectors():
          """<name>:<status>:<dpms> for every enabled DRM connector."""
          out = []
          devices, present = _sys_class("drm")
          for d in devices:
              if not re.match(r"card\d+-", os.path.basename(d)):
                  continue
              if (_read(os.path.join(d, "enabled")) or "") != "enabled":
                  continue
              name = os.path.basename(d).split("-", 1)[-1]
              out.append("%s:%s:%s" % (
                  name,
                  _read(os.path.join(d, "status")) or "?",
                  _read(os.path.join(d, "dpms")) or "?",
              ))
          if out:
              return ",".join(out)
          return "none" if present else "unreadable"


      def active_window():
          """WM_CLASS of the focused window, or why it could not be read."""
          ok, out, _ = _run([XPROP, "-root", "_NET_ACTIVE_WINDOW"])
          if not ok:
              return out
          m = re.search(r"(0x[0-9a-fA-F]+)", out)
          if not m:
              return "none"
          wid = m.group(1)
          if int(wid, 16) == 0:
              return "none"
          ok, out, _ = _run([XPROP, "-id", wid, "WM_CLASS"])
          if not ok:
              return out
          names = re.findall(r'"([^"]*)"', out)
          return names[-1] if names else "unnamed"


      # Matched on argv[0]'s basename. A candidate prefixed with "=" must
      # equal the basename exactly.
      #
      # That distinction is load-bearing and was found by running this on
      # the real host: a substring match for "cinnamon" reports
      # `cinnamon-session-binary`, not the Cinnamon shell, because the
      # session binary has the lower pid; and the X server's argv[0] is
      # plain `X`, so a substring match for "xorg" reports it absent while
      # it is plainly running.
      #
      # argv[0] specifically, not comm and not /proc/<pid>/exe: the shell
      # runs as `/run/current-system/sw/bin/cinnamon --replace` whose exe
      # is the wrapper target `.cinnamon-wrapped` and whose comm is the
      # 15-char truncation `.cinnamon-wrapp`. argv[0] is the only one of
      # the three that says `cinnamon`, and it survives the `--replace`
      # that cinnamon-watchdog performs.
      PROC_MATCHERS = (
          ("xorg", ("=x", "xorg")),
          ("cinnamon", ("=cinnamon",)),
          # The screensaver's fallback locker holds the input grab while
          # the screen is locked. If it is ever alive while ss_active=0, it
          # is holding a grab nothing is showing a prompt for -- the shape
          # of upstream linuxmint/cinnamon#13820.
          ("locker", ("=cs-backup-locker",)),
          # A pam helper still alive across several ticks is an unlock
          # conversation that never finished.
          ("pamhelper", ("cinnamon-screensaver-pam-helper",)),
          # The session bus daemon, carried to help disambiguate
          # ss_active=notimely: busctl reports a stalled BUS and a stalled
          # PEER with the same "Connection timed out", so the label alone
          # cannot say which. This costs no extra bus call, since the /proc
          # walk already runs.
          #
          # READ IT AS A HINT, NOT AS PROOF. Several brokers usually exist
          # (system bus, user bus, any nested session) and _fmt_hits reports
          # the highest pid, which is not necessarily the one this probe
          # talks to -- that heuristic is tuned for spotting a stalled
          # `cinnamon --replace`, not for picking a bus. The `+N` suffix is
          # the tell that others were seen. So D or T here alongside
          # notimely is good evidence the bus stalled; S here does not by
          # itself clear the bus.
          #
          # dbus-broker, not dbus-daemon: that is what this host runs, and
          # the difference matters elsewhere too (see _bus_failure).
          ("dbusd", ("=dbus-broker",)),
      )


      def _fmt_hits(hits):
          if not hits:
              return "absent"
          # Highest pid, so a replacement started by cinnamon-watchdog is
          # reported rather than the wedged process it replaced. The `+N`
          # is the tell for two Cinnamons coexisting, which is exactly what
          # a stalled `cinnamon --replace` looks like.
          hits.sort()
          pid, state, cpu = hits[-1]
          extra = "+%d" % (len(hits) - 1) if len(hits) > 1 else ""
          return "%d:%s:%d%s" % (pid, state, cpu, extra)


      def scan_procs():
          """{name: "pid:state:cpu_ticks"} for every PROC_MATCHERS entry.

          One pass for all matchers rather than one pass each: every
          /proc/<pid>/cmdline read is a chance to block (see
          scan_procs_bounded), so the number of them is worth minimising.
          """
          hits = dict((name, []) for name, _ in PROC_MATCHERS)
          for d in glob.glob("/proc/[0-9]*"):
              cmdline = _read(os.path.join(d, "cmdline"), 4096)
              if not cmdline:
                  continue
              base = os.path.basename(cmdline.split("\0")[0]).lower()
              if not base:
                  continue
              wanted = [
                  name for name, candidates in PROC_MATCHERS
                  if any(
                      base == c[1:] if c.startswith("=") else c in base
                      for c in candidates
                  )
              ]
              if not wanted:
                  continue
              stat = _read(os.path.join(d, "stat"), 2048)
              if not stat or ")" not in stat:
                  continue
              # comm can hold spaces and parens, so split on the LAST paren;
              # the fields after it begin at stat's field 3, so utime
              # (field 14) and stime (field 15) are indices 11 and 12.
              fields = stat.rsplit(")", 1)[-1].split()
              if len(fields) <= 12:
                  continue
              entry = (int(os.path.basename(d)), fields[0],
                       int(fields[11]) + int(fields[12]))
              for name in wanted:
                  hits[name].append(entry)
          return dict((name, _fmt_hits(h)) for name, h in hits.items())


      def scan_procs_bounded():
          """scan_procs() in a daemon thread, so a tick is never hostage to it.

          Reading /proc/<pid>/cmdline takes the target's mmap_lock, and
          that wait is not reliably interruptible -- a signal or an alarm
          may not land until it returns. Every other probe here is a
          subprocess with a timeout, so this walk is the one step whose
          duration is not ours to bound from the inside.

          That matters more than it would in ordinary code: a freeze is
          precisely when some process is wedged, so the single step that
          can block forever is the one that would block during the event
          this sampler exists to record. Blocking past TimeoutStartSec
          means systemd kills the tick before it writes, and the sample is
          lost at the only moment it was worth taking.

          So the walk runs in a daemon thread and the tick waits only
          PROC_BUDGET for it. If it never finishes, these four fields read
          "timeout" and every other field is still written. Daemon, so a
          thread stuck in the kernel cannot keep the process from exiting;
          systemd reaps it with the unit's cgroup.
          """
          box = {}

          def target():
              try:
                  box["r"] = scan_procs()
              except Exception as exc:  # noqa: BLE001 - a field, not a crash
                  box["r"] = dict(
                      (name, "error:%s" % type(exc).__name__)
                      for name, _ in PROC_MATCHERS
                  )

          th = threading.Thread(target=target, daemon=True)
          try:
              th.start()
          except Exception as exc:  # noqa: BLE001 - fields, not a crash
              # Thread exhaustion (RLIMIT_NPROC, a runaway spawner) is
              # itself a freeze symptom, so this is the one moment the rest
              # of the line matters most. Before this, the failure escaped
              # to main() and cost ALL of it: the whole sample collapsed to
              # "sampler=failed:RuntimeError" -- no idle_ms, no ss_active,
              # no PSI -- for the event the log exists to explain.
              return dict(
                  (name, "error:%s" % type(exc).__name__)
                  for name, _ in PROC_MATCHERS
              )
          th.join(PROC_BUDGET)
          return box.get("r") or dict((name, "timeout") for name, _ in PROC_MATCHERS)


      def pressure(resource):
          raw = _read("/proc/pressure/" + resource, 512)
          if not raw:
              return "?"
          m = re.search(r"some avg10=([0-9.]+)", raw)
          return m.group(1) if m else "?"


      def sample():
          # Bounded, so its cost is PROC_BUDGET at worst and the rest of
          # the tick always runs. Worst case for a whole tick is then
          # PROC_BUDGET + 5 bounded subprocess calls, comfortably inside
          # the unit's TimeoutStartSec.
          procs = scan_procs_bounded()
          return [
              ("t", time.strftime("%Y-%m-%dT%H:%M:%S%z")),
              # Monotonic too: a wall clock that jumps (suspend, NTP step)
              # makes a gap in the log ambiguous, and the length of the gap
              # is the thing being measured.
              ("mono", "%.0f" % time.monotonic()),
              ("idle_ms", idle_ms()),
              ("ss_active", screensaver_active()),
              ("focus", active_window()),
              ("backlight", backlight()),
              ("conn", connectors()),
              ("xorg", procs["xorg"]),
              ("cinnamon", procs["cinnamon"]),
              ("locker", procs["locker"]),
              ("pamhelper", procs["pamhelper"]),
              ("dbusd", procs["dbusd"]),
              ("load", (_read("/proc/loadavg", 128) or "?").split(" ")[0]),
              ("psi_cpu", pressure("cpu")),
              ("psi_io", pressure("io")),
              ("psi_mem", pressure("memory")),
          ]


      def rotate(path):
          try:
              if os.path.getsize(path) < MAX_BYTES:
                  return
          except OSError:
              return
          try:
              os.replace(path, path + ".1")
          except OSError as exc:
              print("desktop-freeze-sample: rotate failed: %s" % exc, file=sys.stderr)


      def write(line):
          os.makedirs(STATE_DIR, exist_ok=True)
          path = os.path.join(STATE_DIR, "samples.log")
          rotate(path)
          # Flushed and fsynced per line, which is the whole point of writing
          # to disk at all: a freeze that ends in a held power button loses
          # anything still in the page cache, and the minutes just before the
          # freeze are the only ones worth having.
          with open(path, "a") as fh:
              fh.write(line + "\n")
              fh.flush()
              os.fsync(fh.fileno())
          return path


      def main(argv):
          cmd = argv[1] if len(argv) > 1 else "tick"
          if cmd not in ("tick", "show"):
              print("usage: desktop-freeze-sample [tick|show]", file=sys.stderr)
              return 64
          # Collecting a sample must not be able to fail the tick.
          #
          # Every probe below is individually defensive, but the collection
          # around them was not, and "individually defensive" is exactly the
          # reasoning that misses the step that has no probe in it. Observed:
          # under a process-count limit, threading.Thread.start() raises
          # RuntimeError("can't start new thread"), which escaped sample(),
          # skipped write() entirely and exited 1 -- a failed unit and no
          # line, at the moment a line is worth most. Resource exhaustion is
          # not a hypothetical here: it is a plausible shape for the freeze
          # this log exists to explain.
          #
          # So the sample is best-effort and the line is written regardless.
          # A line saying only when the tick ran and that it broke is worth
          # more than a unit failure and silence.
          try:
              fields = sample()
          except Exception as exc:  # noqa: BLE001 - a datum, not a crash
              fields = [
                  ("t", time.strftime("%Y-%m-%dT%H:%M:%S%z")),
                  ("mono", "%.0f" % time.monotonic()),
                  ("sampler", "failed:%s" % type(exc).__name__),
              ]
          line = " ".join("%s=%s" % (k, _clean(v)) for k, v in fields)
          if cmd == "show":
              print(line)
              return 0
          try:
              write(line)
          except Exception as exc:  # noqa: BLE001 - never fail the unit
              # A sampler that fails the unit on a full disk turns a
              # diagnostic into an outage of its own. Same for any other
              # write-path surprise: the tick is the thing being observed
              # least, so it is the thing allowed to fail most quietly.
              print("desktop-freeze-sample: write failed: %s: %s"
                    % (type(exc).__name__, exc), file=sys.stderr)
              return 0
          return 0


      if __name__ == "__main__":
          sys.exit(main(sys.argv))
    '';
in
{
  home.packages = [ freezeSampler ];

  systemd.user.services.desktop-freeze-forensics = {
    Unit.Description = "Sample desktop input and display state for freeze diagnosis";
    Service = {
      Type = "oneshot";
      ExecStart = "${freezeSampler}/bin/desktop-freeze-sample tick";
      TimeoutStartSec = "${toString tickTimeoutSecs}s";
      # The sampler reads X and the session bus. HM user services do not
      # reliably carry the graphical session's environment, so both are
      # named here rather than inherited (same reason home/autodoro.nix
      # does it).
      Environment = [
        "DISPLAY=:0"
        "DBUS_SESSION_BUS_ADDRESS=unix:path=%t/bus"
      ];
    };
  };

  systemd.user.timers.desktop-freeze-forensics = {
    # PartOf/WantedBy the graphical session, not timers.target: this user has
    # linger enabled, so a timers.target timer keeps firing after logout and
    # would fill the log with X-call timeouts from a session that is simply
    # not there.
    Unit = {
      Description = "Poll desktop input and display state";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };
    Timer = {
      OnActiveSec = "1min";
      OnUnitActiveSec = "${toString intervalSecs}s";
      AccuracySec = "5s";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
