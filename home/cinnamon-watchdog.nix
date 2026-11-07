{ pkgs, lib, config, ... }:
# cinnamon-watchdog — restart Cinnamon when its main loop stops dispatching.
#
# A wedged main loop leaves Xorg running, so the cursor still tracks the
# mouse while nothing is clickable and no notification can render. Recovery
# therefore cannot ask the user anything; it has to act on its own.
#
# The replacement cannot be launched and trusted. `cinnamon --replace` blocks
# in XWindowEvent until the outgoing window manager's selection window is
# destroyed (muffin 6.6.3, take_manager_selection, whose own comment reads
# "We sort of block infinitely here which is probably lame"). A wedged main
# loop never processes the SelectionClear that would make it exit, so the
# replacement waits forever on precisely the fault it was launched to repair.
# Recovery is therefore verified, and escalates when takeover stalls.
#
# Asserted by tests/desktop.nix (vm-desktop).
let
  threshold = 3;
  cooldownSecs = 300;
  probeTimeoutSecs = 5;
  intervalSecs = 20;
  captureLimitSecs = 20;
  takeoverDeadlineSecs = 15;
  termGraceSecs = 5;
  killGraceSecs = 10;
  # Must exceed capture + launch + takeover wait + both escalation graces,
  # each of which can overshoot by one probe timeout.
  startTimeoutSecs = 150;

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
      TAKEOVER_DEADLINE = int(os.environ.get("CINNAMON_RESCUE_TAKEOVER_DEADLINE_SECS", "${toString takeoverDeadlineSecs}"))
      TERM_GRACE = int(os.environ.get("CINNAMON_RESCUE_TERM_GRACE_SECS", "${toString termGraceSecs}"))
      KILL_GRACE = int(os.environ.get("CINNAMON_RESCUE_KILL_GRACE_SECS", "${toString killGraceSecs}"))
      SYSTEMCTL = os.environ.get("CINNAMON_RESCUE_SYSTEMCTL", "${pkgs.systemd}/bin/systemctl")


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
          """Launch the replacement. Returns (launched, transient unit or None)."""
          unit = "cinnamon-rescue-replace-%d" % time.time()
          cmd = RESTART_CMD.replace("@unit@", unit)
          # systemd-run does not forward this process's environment to the
          # transient unit, so DISPLAY has to be handed over explicitly.
          display = os.environ.get("DISPLAY") or ":0"
          argv = shlex.split(cmd)
          transient = bool(argv) and argv[0].endswith("systemd-run")
          if transient:
              argv.insert(1, "--setenv=DISPLAY=" + display)
          # systemd-run returns as soon as the job is queued, so rc only says
          # the replacement was launched -- never that it took over.
          rc, out = _run(argv, 30)
          if rc != 0:
              print("cinnamon-rescue: restart failed rc=%d: %s" % (rc, out.strip()),
                    file=sys.stderr)
              return False, None
          return True, (unit if transient else None)


      def _await_takeover(deadline):
          """Poll the main loop until it answers again, or deadline elapses."""
          end = time.monotonic() + deadline
          while True:
              if probe() == ALIVE:
                  return True
              if time.monotonic() >= end:
                  return False
              time.sleep(1)


      def _argv0_names_cinnamon(pid):
          # The guard that keeps escalation from ever signalling a bystander:
          # the pid comes from the broker, and a stale or recycled pid must
          # not be killable. Cinnamon's comm is ".cinnamon-wrapp", so match
          # argv[0] rather than the thread name.
          raw = _slurp("/proc/%d/cmdline" % pid, 4096)
          if not raw or raw.startswith("<unreadable"):
              return False
          argv0 = raw.split("\0")[0]
          return "cinnamon" in os.path.basename(argv0).lower()


      def _proc_starttime(pid):
          """Field 22 of /proc/<pid>/stat, which tells two pids of the same
          number apart across recycling."""
          raw = _slurp("/proc/%d/stat" % pid, 2048)
          if not raw or raw.startswith("<unreadable") or ")" not in raw:
              return None
          # comm can hold spaces and parens, so the fields after the LAST
          # paren start at stat's field 3; field 22 is index 19 of those.
          fields = raw.rsplit(")", 1)[-1].split()
          return fields[19] if len(fields) > 19 else None


      def _pid_alive(pid):
          try:
              os.kill(pid, 0)
              return True
          except ProcessLookupError:
              return False
          except OSError:
              # Exists but is not ours to signal; treat as alive and let the
              # kill below report the real error.
              return True


      def _escalate(pid, ident):
          """End the wedged Cinnamon so the waiting replacement can proceed."""
          if pid is None:
              print("cinnamon-rescue: no pid to escalate against", file=sys.stderr)
              return False
          # Identity, not bus ownership. A stalled --replace has often taken
          # the name already while the old process goes on blocking it, so
          # re-reading the owner refuses exactly when escalation is needed;
          # the start time pins the same process across pid recycling.
          if ident is None or _proc_starttime(pid) != ident:
              print("cinnamon-rescue: pid %s is not the process diagnosed as hung; "
                    "not signalling" % pid, file=sys.stderr)
              return False
          if not _argv0_names_cinnamon(pid):
              print("cinnamon-rescue: pid %s is not Cinnamon; not signalling" % pid,
                    file=sys.stderr)
              return False
          for sig, grace in ((signal.SIGTERM, TERM_GRACE), (signal.SIGKILL, KILL_GRACE)):
              # SIGKILL is for a process that would not leave, not for one
              # that already has.
              if not _pid_alive(pid):
                  print("cinnamon-rescue: the wedged Cinnamon (pid %s) has exited" % pid)
                  break
              try:
                  os.kill(pid, sig)
              except OSError as exc:
                  print("cinnamon-rescue: %s to pid %s failed: %s" % (sig.name, pid, exc),
                        file=sys.stderr)
                  return False
              print("cinnamon-rescue: sent %s to the wedged Cinnamon (pid %s)" % (sig.name, pid))
              if _await_takeover(grace):
                  return True
          return False


      def _drop_pending_replacement(unit):
          # A replacement blocked in XWindowEvent has already taken the window
          # manager selection without managing anything, so leaving it behind
          # would aim the next --replace at a process that can never answer.
          if not unit:
              return
          # --no-block: stopping waits for the process to die, and a process
          # blocked in XWindowEvent does not answer SIGTERM, so a blocking
          # stop burns the unit's whole start timeout. systemd escalates to
          # SIGKILL on its own schedule.
          rc, out = _run([SYSTEMCTL, "--user", "stop", "--no-block", unit], 15)
          if rc != 0:
              print("cinnamon-rescue: could not stop %s: %s" % (unit, out.strip()),
                    file=sys.stderr)


      def _recover(fails):
          pid = cinnamon_pid()
          # Taken before the replacement is launched: this is the process the
          # probe found wedged, and the only one escalation may signal.
          ident = _proc_starttime(pid) if pid is not None else None
          report = capture(pid, fails)
          print("cinnamon-rescue: hung after %d failed probes; report %s" % (fails, report))
          launched, unit = restart()
          # Written before the outcome is known: a recovery that stalls must
          # still open the cooldown, or the timer retries escalation forever.
          _write_int("last-restart", int(time.time()))
          _write_int("failures", 0)
          if not launched:
              return 1
          if _await_takeover(TAKEOVER_DEADLINE):
              print("cinnamon-rescue: replacement took over; the session answers again")
              return 0
          print("cinnamon-rescue: replacement has not taken over in %ds; escalating"
                % TAKEOVER_DEADLINE, file=sys.stderr)
          if _escalate(pid, ident):
              print("cinnamon-rescue: replacement took over once the old Cinnamon ended")
              return 0
          _drop_pending_replacement(unit)
          print("cinnamon-rescue: recovery FAILED; the session is still wedged",
                file=sys.stderr)
          return 1


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
