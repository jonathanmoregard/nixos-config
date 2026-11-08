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
  # A replacement only has to stop blocking once the old process is gone
  # (measured at ~1.5s), but a cold start is a whole Cinnamon coming up.
  coldStartDeadlineSecs = 60;
  termGraceSecs = 5;
  killGraceSecs = 10;
  # How many times the watchdog will start a Cinnamon into a session whose
  # name is unowned after it ended one itself, before concluding the session
  # is gone. The timer being PartOf graphical-session.target is the primary
  # defence against retrying into a logged-out session; this bound is what
  # holds if the timer outlives the session anyway, which linger makes
  # possible.
  absentStartLimit = 3;
  # Every deadline below is a floor, not a ceiling: each probe is TWO gdbus
  # calls (GetNameOwner then the property read), so a wait can overshoot its
  # deadline by 2*(probeTimeout+5) = 20s before the next check of the clock.
  # Worst case, with every call hanging: pid lookup 10 + capture 20 + launch
  # 30 + takeover 15+20 + SIGTERM 5+20 + SIGKILL 10+20 + the recovered-check
  # probe 20 + stop 15 + the last-resort start (30 + 60+20 + 20 + 15) = 330s.
  # This is the backstop for all of it, including a capture that SIGALRM
  # cannot interrupt (see capture()).
  startTimeoutSecs = 420;

  reportDir = "${config.home.homeDirectory}/.local/state/cinnamon-rescue";

  # @unit@ is substituted per attempt: a recovered Cinnamon keeps running as
  # this unit, so a fixed name would collide on the second hang of a session.
  #
  # @cinnamon@ is substituted with /proc/<wedged pid>/exe, which is the only
  # path guaranteed to be the binary the session is actually running.
  # /run/current-system/sw/bin/cinnamon is the NEWEST Cinnamon, which after a
  # nixos-rebuild switch without a re-login is a different store path from the
  # running one -- and a Cinnamon version bump is exactly when that differs.
  # This path is the fallback for when /proc/<pid>/exe cannot be read.
  restartCmd = lib.concatStringsSep " " [
    "${pkgs.systemd}/bin/systemd-run"
    "--user"
    "--quiet"
    "--collect"
    "--unit=@unit@"
    "@cinnamon@"
    "--replace"
  ];

  fallbackCinnamon = "/run/current-system/sw/bin/cinnamon";

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
      FALLBACK_CINNAMON = os.environ.get("CINNAMON_RESCUE_FALLBACK_BIN", "${fallbackCinnamon}")
      REPORT_DIR = os.environ.get("CINNAMON_RESCUE_STATE_DIR", "${reportDir}")
      THRESHOLD = int(os.environ.get("CINNAMON_RESCUE_THRESHOLD", "${toString threshold}"))
      COOLDOWN = int(os.environ.get("CINNAMON_RESCUE_COOLDOWN_SECS", "${toString cooldownSecs}"))
      PROBE_TIMEOUT = int(os.environ.get("CINNAMON_RESCUE_PROBE_TIMEOUT_SECS", "${toString probeTimeoutSecs}"))
      CAPTURE_LIMIT = int(os.environ.get("CINNAMON_RESCUE_CAPTURE_LIMIT_SECS", "${toString captureLimitSecs}"))
      TAKEOVER_DEADLINE = int(os.environ.get("CINNAMON_RESCUE_TAKEOVER_DEADLINE_SECS", "${toString takeoverDeadlineSecs}"))
      COLD_START_DEADLINE = int(os.environ.get("CINNAMON_RESCUE_COLD_START_DEADLINE_SECS", "${toString coldStartDeadlineSecs}"))
      ABSENT_START_LIMIT = int(os.environ.get("CINNAMON_RESCUE_ABSENT_START_LIMIT", "${toString absentStartLimit}"))
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
          # Bounds the Python-level work and the file write. It cannot
          # interrupt a /proc read that is blocked in an uninterruptible
          # kernel wait (a task wedged on its mmap lock) -- the handler does
          # not run until the syscall returns, so TimeoutStartSec on the unit
          # is the real backstop for that case. The report is worth less than
          # the recovery either way.
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


      def session_cinnamon(pid):
          """The binary the session is running, by preference over the newest
          one on the system."""
          if pid is not None:
              try:
                  exe = os.readlink("/proc/%d/exe" % pid)
                  if exe and not exe.endswith(" (deleted)"):
                      return exe
              except OSError:
                  pass
          return FALLBACK_CINNAMON


      def restart(exe):
          """Launch the replacement. Returns (launched, transient unit or None)."""
          unit = "cinnamon-rescue-replace-%d" % time.time()
          cmd = RESTART_CMD.replace("@unit@", unit)
          cmd = cmd.replace("@cinnamon@", exe)
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
          for sig, grace in ((signal.SIGTERM, TERM_GRACE), (signal.SIGKILL, KILL_GRACE)):
              # SIGKILL is for a process that would not leave, not for one
              # that already has.
              if not _pid_alive(pid):
                  print("cinnamon-rescue: the wedged Cinnamon (pid %s) has exited" % pid)
                  break
              # Re-checked before every signal, not once up front: tens of
              # seconds of grace pass in between, and a pid that was reaped
              # and reissued in that window must not be signalled.
              if ident is None or _proc_starttime(pid) != ident:
                  print("cinnamon-rescue: pid %s is not the process diagnosed as hung; "
                        "not signalling" % pid, file=sys.stderr)
                  return False
              if not _argv0_names_cinnamon(pid):
                  print("cinnamon-rescue: pid %s is not Cinnamon; not signalling" % pid,
                        file=sys.stderr)
                  return False
              try:
                  os.kill(pid, sig)
              except OSError as exc:
                  print("cinnamon-rescue: %s to pid %s failed: %s" % (sig.name, pid, exc),
                        file=sys.stderr)
                  return False
              # Recorded as soon as a signal lands: from here on an unowned
              # bus name is our doing, not an absent Cinnamon.
              _write_int("ended-cinnamon", 1)
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


      def _drop_unless_recovered(unit):
          """Stop a replacement that is still not working. Returns False when
          it turned out to be working and was therefore left alone."""
          # A handover can land just after the last grace expired. Stopping
          # the unit then would kill the Cinnamon that had just rescued the
          # session -- the rescue destroying its own result.
          if probe() == ALIVE:
              print("cinnamon-rescue: the replacement took over after the deadlines; "
                    "keeping it")
              return False
          _drop_pending_replacement(unit)
          return True


      def _recover(fails):
          pid = cinnamon_pid()
          # Taken before the replacement is launched: this is the process the
          # probe found wedged, and the only one escalation may signal.
          ident = _proc_starttime(pid) if pid is not None else None
          # Read once, here, for every launch below: the stranded start runs
          # after escalation ended this pid, where /proc/<pid>/exe is gone --
          # or, once the kernel has reissued the number, belongs to an
          # unrelated process that must never be handed to --replace.
          exe = session_cinnamon(pid)
          report = capture(pid, fails)
          print("cinnamon-rescue: hung after %d failed probes; report %s" % (fails, report))
          launched, unit = restart(exe)
          # Written before the outcome is known: a recovery that stalls must
          # still open the cooldown, or the timer retries escalation forever.
          _write_int("last-restart", int(time.time()))
          _write_int("failures", 0)
          if not launched:
              return 1
          # No pid means nothing owned the name, so this is a cold start
          # rather than a replacement waiting on a wedged process, and a
          # whole Cinnamon coming up needs the longer deadline.
          deadline = TAKEOVER_DEADLINE if pid is not None else COLD_START_DEADLINE
          if _await_takeover(deadline):
              print("cinnamon-rescue: replacement took over; the session answers again")
              return 0
          print("cinnamon-rescue: replacement has not taken over in %ds; escalating"
                % deadline, file=sys.stderr)
          if _escalate(pid, ident):
              print("cinnamon-rescue: replacement took over once the old Cinnamon ended")
              return 0
          if not _drop_unless_recovered(unit):
              return 0
          # Ending the old Cinnamon and then dropping its replacement leaves
          # nobody owning the name, which is a session with no window manager
          # at all -- worse than the hang it replaced. One bounded start
          # attempt beats stranding it there.
          #
          # Not gated on name_owned(): the stop above is --no-block, so a name
          # the dropped replacement claimed can still read as owned for a
          # moment, which would skip this start exactly when nothing is going
          # to own it. The session is known not to answer, and --replace is
          # built for the case where someone else holds the selection.
          print("cinnamon-rescue: starting a window manager for the stranded session",
                file=sys.stderr)
          launched, retry_unit = restart(exe)
          # A cold start is a whole Cinnamon coming up, not a replacement
          # that only had to stop blocking, so it gets the longer deadline.
          if launched and _await_takeover(COLD_START_DEADLINE):
              print("cinnamon-rescue: a fresh Cinnamon took over")
              return 0
          if launched and not _drop_unless_recovered(retry_unit):
              return 0
          print("cinnamon-rescue: recovery FAILED; the session is still wedged",
                file=sys.stderr)
          return 1


      def _cooldown_open():
          last = _read_int("last-restart")
          return bool(last) and int(time.time()) - last < COOLDOWN


      def check():
          state = probe()
          if state == ALIVE:
              _write_int("failures", 0)
              _write_int("ended-cinnamon", 0)
              _write_int("absent-starts", 0)
              return 0
          if state == ABSENT:
              # Normally a greeter or a non-Cinnamon session, where starting a
              # window manager would be wrong. But when we ended Cinnamon
              # ourselves and nothing replaced it, reading "absent" as healthy
              # would leave the session without a window manager for good.
              if not _read_int("ended-cinnamon"):
                  _write_int("failures", 0)
                  return 0
              attempts = _read_int("absent-starts")
              if attempts >= ABSENT_START_LIMIT:
                  # The session is gone rather than broken -- a logout, most
                  # likely, which leaves this timer running under linger.
                  # Stop treating it as ours to repair.
                  print("cinnamon-rescue: no Cinnamon after %d starts; treating the "
                        "session as ended" % attempts)
                  _write_int("ended-cinnamon", 0)
                  _write_int("failures", 0)
                  return 0
              if _cooldown_open():
                  print("cinnamon-rescue: no Cinnamon since our own restart, but the "
                        "%ds cooldown is still open" % COOLDOWN)
                  return 0
              _write_int("absent-starts", attempts + 1)
              print("cinnamon-rescue: no Cinnamon since our own restart; starting one",
                    file=sys.stderr)
              return _recover(_read_int("failures"))
          fails = _read_int("failures") + 1
          _write_int("failures", fails)
          if fails < THRESHOLD:
              print("cinnamon-rescue: unresponsive (%d/%d)" % (fails, THRESHOLD))
              return 0
          if _cooldown_open():
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
    # Bound to the graphical session, not timers.target: this user has linger
    # enabled, so a timers.target timer keeps firing after logout with the
    # runtime dir still in place, and the watchdog would try to recover a
    # session that is not there. Verified active in a live Cinnamon session
    # (systemctl --user is-active graphical-session.target) and asserted below
    # by the lane, which would fail if the timer never started.
    Unit = {
      Description = "Poll Cinnamon's main loop for responsiveness";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };
    Timer = {
      OnActiveSec = "2min";
      OnUnitActiveSec = "${toString intervalSecs}s";
      AccuracySec = "5s";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
