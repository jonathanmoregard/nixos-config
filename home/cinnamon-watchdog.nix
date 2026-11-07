{ pkgs, lib, config, ... }:
# cinnamon-watchdog — restart Cinnamon when its main loop stops dispatching.
#
# A wedged main loop leaves Xorg running, so the cursor still tracks the
# mouse while nothing is clickable and no notification can render. Recovery
# therefore cannot ask the user anything; it has to act on its own.
#
# Asserted by tests/desktop.nix (vm-desktop).
let
  threshold = 3;
  cooldownSecs = 300;
  probeTimeoutSecs = 5;
  intervalSecs = 20;
  captureLimitSecs = 20;
  startTimeoutSecs = 60;

  reportDir = "${config.home.homeDirectory}/.local/state/cinnamon-rescue";

  # @unit@ is substituted per attempt: a recovered Cinnamon keeps running as
  # this unit, so a fixed name would collide on the second hang of a session.
  # /run/current-system/sw/bin, not a store path, because --replace has to
  # match the Cinnamon the live session is running.
  restartCmd = lib.concatStringsSep " " [
    "${pkgs.systemd}/bin/systemd-run"
    "--user"
    "--quiet"
    "--collect"
    "--unit=@unit@"
    "/run/current-system/sw/bin/cinnamon"
    "--replace"
  ];

  cinnamonRescue = pkgs.writers.writePython3Bin "cinnamon-rescue"
    { flakeIgnore = [ "E501" ]; }
    ''
      """cinnamon-rescue — detect and recover a hung Cinnamon session."""
      import os
      import re
      import shlex
      import signal
      import subprocess
      import sys
      import time

      BUS_NAME = "org.Cinnamon"
      BUS_PATH = "/org/Cinnamon"
      DBUS = "org.freedesktop.DBus"
      PROBE_PROP = "CinnamonVersion"

      ALIVE, HUNG, ABSENT = 0, 1, 2

      GDBUS = os.environ.get("CINNAMON_RESCUE_GDBUS", "${pkgs.glib}/bin/gdbus")
      JOURNALCTL = os.environ.get("CINNAMON_RESCUE_JOURNALCTL", "${pkgs.systemd}/bin/journalctl")
      RESTART_CMD = os.environ.get("CINNAMON_RESCUE_RESTART_CMD", "${restartCmd}")
      REPORT_DIR = os.environ.get("CINNAMON_RESCUE_STATE_DIR", "${reportDir}")
      THRESHOLD = int(os.environ.get("CINNAMON_RESCUE_THRESHOLD", "${toString threshold}"))
      COOLDOWN = int(os.environ.get("CINNAMON_RESCUE_COOLDOWN_SECS", "${toString cooldownSecs}"))
      PROBE_TIMEOUT = int(os.environ.get("CINNAMON_RESCUE_PROBE_TIMEOUT_SECS", "${toString probeTimeoutSecs}"))
      CAPTURE_LIMIT = int(os.environ.get("CINNAMON_RESCUE_CAPTURE_LIMIT_SECS", "${toString captureLimitSecs}"))


      def counter_dir():
          # Counters belong to the current boot: a count left behind by a hang
          # the user power-cycled through must not let the next session's first
          # failure skip the threshold. Reports go to disk instead, because
          # they are read after a reboot.
          explicit = os.environ.get("CINNAMON_RESCUE_COUNTER_DIR")
          if explicit:
              return explicit
          base = os.environ.get("XDG_RUNTIME_DIR") or "/run/user/%d" % os.getuid()
          return os.path.join(base, "cinnamon-rescue")


      def _run(argv, timeout):
          try:
              p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
              return p.returncode, (p.stdout or "") + (p.stderr or "")
          except subprocess.TimeoutExpired:
              return 124, "timed out after %ds" % timeout
          except OSError as exc:
              return 127, str(exc)


      def _gdbus(dest, path, method, *args):
          argv = [
              GDBUS, "call", "--session", "--timeout", str(PROBE_TIMEOUT),
              "--dest", dest, "--object-path", path, "--method", method,
          ] + list(args)
          # Wall-clock bound of its own, in case gdbus ignores --timeout: a
          # watchdog that can hang is not a watchdog.
          return _run(argv, PROBE_TIMEOUT + 5)


      def name_owned():
          rc, _ = _gdbus(DBUS, "/org/freedesktop/DBus", DBUS + ".GetNameOwner", BUS_NAME)
          return rc == 0


      def main_loop_responds():
          # NOT Peer.Ping, and not Introspect: GDBus answers both from its own
          # worker thread, so a Cinnamon whose main loop has stopped
          # dispatching still replies to them instantly. Reading a property off
          # Cinnamon's own interface is dispatched through the main context,
          # which is the thing that stops when the session wedges.
          rc, _ = _gdbus(
              BUS_NAME, BUS_PATH, DBUS + ".Properties.Get", BUS_NAME, PROBE_PROP,
          )
          return rc == 0


      def probe():
          # An unowned name means Cinnamon is not running at all (greeter,
          # non-Cinnamon session), where replacing it would be wrong.
          if not name_owned():
              return ABSENT
          return ALIVE if main_loop_responds() else HUNG


      def cinnamon_pid():
          rc, out = _gdbus(
              DBUS, "/org/freedesktop/DBus",
              DBUS + ".GetConnectionUnixProcessID", BUS_NAME,
          )
          if rc != 0:
              return None
          # Anchor on the type tag so the digits in "uint32" are not scraped
          # into the pid.
          m = re.search(r"uint32\s+(\d+)", out)
          return int(m.group(1)) if m else None


      def _read_int(name, default=0):
          try:
              with open(os.path.join(counter_dir(), name)) as fh:
                  return int(fh.read().strip() or default)
          except (OSError, ValueError):
              return default


      def _write_int(name, value):
          # Never let a state-write failure stop a recovery.
          try:
              os.makedirs(counter_dir(), exist_ok=True)
              tmp = os.path.join(counter_dir(), name + ".tmp")
              with open(tmp, "w") as fh:
                  fh.write(str(value))
              os.replace(tmp, os.path.join(counter_dir(), name))
          except OSError as exc:
              print("cinnamon-rescue: cannot write %s: %s" % (name, exc), file=sys.stderr)


      def _slurp(path, limit=4096):
          try:
              with open(path, "rb") as fh:
                  return fh.read(limit).decode("utf-8", "replace").strip()
          except OSError as exc:
              return "<unreadable: %s>" % exc


      class _CaptureTimeout(Exception):
          pass


      def _on_alarm(signum, frame):
          raise _CaptureTimeout("exceeded %ds" % CAPTURE_LIMIT)


      def _report_body(pid, fails):
          out = [
              "cinnamon-rescue hang report",
              "when=%s" % time.strftime("%Y-%m-%d %H:%M:%S %z"),
              "pid=%s" % ("<unresolved>" if pid is None else pid),
              "reason=%d consecutive failed %s.Properties.Get(%s) to %s"
              % (fails, DBUS, PROBE_PROP, BUS_NAME),
              "",
          ]
          if pid is None:
              out.append("No pid from the broker, so no /proc state to read.")
              return out
          proc = "/proc/%d" % pid
          out += [
              "cmdline=%s" % _slurp(proc + "/cmdline").replace("\0", " "),
              "wchan=%s" % _slurp(proc + "/wchan", 256),
              "",
              "status:",
          ]
          keep = ("State:", "Threads:", "VmRSS:", "voluntary_ctxt_switches:",
                  "nonvoluntary_ctxt_switches:")
          for line in _slurp(proc + "/status", 8192).splitlines():
              if line.startswith(keep):
                  out.append("  " + line)
          out += ["", "threads:"]
          try:
              for tid in sorted(os.listdir(proc + "/task"), key=int):
                  raw = _slurp("%s/task/%s/stat" % (proc, tid), 1024)
                  # "pid (comm) state ..." — comm can hold spaces and parens,
                  # so split on the LAST paren.
                  state = raw.rsplit(")", 1)[-1].split()[0] if ")" in raw else "?"
                  comm = raw.split("(", 1)[-1].rsplit(")", 1)[0] if "(" in raw else "?"
                  out.append("  tid=%s state=%s comm=%s wchan=%s" % (
                      tid, state, comm, _slurp("%s/task/%s/wchan" % (proc, tid), 128),
                  ))
          except OSError as exc:
              out.append("  <unreadable: %s>" % exc)
          out += [
              "",
              "ptrace: kernel.yama.ptrace_scope=%s"
              % _slurp("/proc/sys/kernel/yama/ptrace_scope", 16),
              "No native backtrace: a user service cannot attach a debugger to",
              "a non-descendant. From a TTY as root:",
              "  gdb -p %s -batch -ex 'thread apply all bt'" % pid,
              "",
              "journal (user, last 80 lines):",
          ]
          rc, log = _run([JOURNALCTL, "--user", "-n", "80", "--no-pager"], 20)
          out.append(log if rc == 0 else "<journalctl failed: %s>" % log)
          return out


      def capture(pid, fails):
          """Write a hang report, returning its path or a reason it is absent."""
          # /proc reads on a task wedged in-kernel can block on its mmap lock,
          # which would eat the unit's start timeout and cost this tick's
          # recovery. The report is worth less than the recovery.
          previous = signal.signal(signal.SIGALRM, _on_alarm)
          signal.alarm(CAPTURE_LIMIT)
          try:
              body = _report_body(pid, fails)
              os.makedirs(REPORT_DIR, exist_ok=True)
              path = os.path.join(
                  REPORT_DIR, "hang-%s.txt" % time.strftime("%Y%m%dT%H%M%S"),
              )
              with open(path, "w") as fh:
                  fh.write("\n".join(body) + "\n")
              return path
          except (_CaptureTimeout, OSError) as exc:
              return "<capture failed: %s>" % exc
          finally:
              signal.alarm(0)
              signal.signal(signal.SIGALRM, previous)


      def restart():
          cmd = RESTART_CMD.replace("@unit@", "cinnamon-rescue-replace-%d" % time.time())
          env = dict(os.environ)
          # systemd-run does not forward this process's environment to the
          # transient unit, so DISPLAY has to be handed over explicitly.
          display = env.get("DISPLAY") or ":0"
          argv = shlex.split(cmd)
          if argv and argv[0].endswith("systemd-run"):
              argv.insert(1, "--setenv=DISPLAY=" + display)
          rc, out = _run(argv, 30)
          if rc != 0:
              print("cinnamon-rescue: restart failed rc=%d: %s" % (rc, out.strip()),
                    file=sys.stderr)
              return False
          return True


      def _recover(fails):
          report = capture(cinnamon_pid(), fails)
          print("cinnamon-rescue: hung after %d failed probes; report %s" % (fails, report))
          ok = restart()
          _write_int("last-restart", int(time.time()))
          _write_int("failures", 0)
          return 0 if ok else 1


      def check():
          state = probe()
          if state != HUNG:
              _write_int("failures", 0)
              return 0
          fails = _read_int("failures") + 1
          _write_int("failures", fails)
          if fails < THRESHOLD:
              print("cinnamon-rescue: unresponsive (%d/%d)" % (fails, THRESHOLD))
              return 0
          last = _read_int("last-restart")
          if last and int(time.time()) - last < COOLDOWN:
              print("cinnamon-rescue: hung, but %ds cooldown is still open; not restarting"
                    % COOLDOWN)
              return 0
          return _recover(fails)


      def main(argv):
          cmd = argv[1] if len(argv) > 1 else "check"
          if cmd == "probe":
              return probe()
          if cmd == "check":
              return check()
          if cmd == "now":
              return _recover(_read_int("failures"))
          if cmd == "status":
              print("failures=%d/%d" % (_read_int("failures"), THRESHOLD))
              print("last-restart=%d cooldown=%ds" % (_read_int("last-restart"), COOLDOWN))
              print("probe=%d (0 alive, 1 hung, 2 not running)" % probe())
              return 0
          print("usage: cinnamon-rescue [probe|check|now|status]", file=sys.stderr)
          return 64


      if __name__ == "__main__":
          sys.exit(main(sys.argv))
    '';
in
{
  home.packages = [ cinnamonRescue ];

  systemd.user.services.cinnamon-watchdog = {
    Unit.Description = "Recover Cinnamon if its main loop stops dispatching";
    Service = {
      Type = "oneshot";
      ExecStart = "${cinnamonRescue}/bin/cinnamon-rescue check";
      TimeoutStartSec = "${toString startTimeoutSecs}s";
      KillMode = "process";
    };
  };

  systemd.user.timers.cinnamon-watchdog = {
    Unit.Description = "Poll Cinnamon's main loop for responsiveness";
    Timer = {
      OnBootSec = "2min";
      OnUnitActiveSec = "${toString intervalSecs}s";
      AccuracySec = "5s";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
