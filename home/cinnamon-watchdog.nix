{ pkgs, lib, config, ... }:
# cinnamon-watchdog — recover a hung Cinnamon without a hard reboot.
#
# Cinnamon's main loop is what dispatches button presses. When it blocks,
# Xorg keeps running and the cursor still tracks the mouse, but nothing is
# clickable and no notification can render — so the session looks like a
# dead machine while the kernel, GPU and disk are all perfectly healthy.
# Twice (2026-10-29 12:56, 2026-11-07 14:53) that cost a hard power-off and
# an unclean btrfs; both times every background service kept logging
# normally straight through the "freeze", and cinnamon's own last log line
# was ~40 min before the power cut.
#
# Liveness is a D-Bus Peer.Ping to org.Cinnamon. The ping is answered *from
# the main loop*, so a blocked loop fails it — while the bus name stays
# owned, because name ownership is tracked by the broker, not by Cinnamon.
# That distinction is the whole design:
#
#   name unowned  → Cinnamon is not running (greeter, non-Cinnamon session).
#                   Do nothing. Starting it here would be wrong.
#   name owned,
#   ping fails    → main loop is wedged. This is the state worth acting on.
#
# Three consecutive failures (~1 min unresponsive) are required before
# acting, so a transient stall never costs you your window manager, and a
# cooldown stops a repeatedly-wedging Cinnamon from becoming a restart loop.
#
# The hang left no trace either time, which is why it went unexplained, so
# the watchdog captures diagnostics *before* recovering. kernel.yama
# ptrace_scope=1 forbids a user service from attaching a debugger to a
# non-descendant, so the report is /proc-based (wchan + per-thread states)
# and records the gdb command to run by hand from a TTY for more depth.
#
# `cinnamon-rescue now` is the manual escape hatch over SSH or Ctrl+Alt+F2.
#
# Asserted by tests/desktop.nix (vm-desktop).
let
  threshold = 3;
  cooldownSecs = 300;
  pingTimeoutSecs = 5;
  intervalSecs = 20;

  stateDir = "${config.home.homeDirectory}/.local/state/cinnamon-rescue";

  # `cinnamon --replace` must outlive the watchdog service, so it is handed
  # to a transient unit of its own instead of being spawned inside the
  # service's cgroup (which systemd tears down when the oneshot exits).
  # /run/current-system/sw/bin is deliberate over a store path: --replace
  # has to match the Cinnamon the live session is actually running.
  restartCmd = lib.concatStringsSep " " [
    "${pkgs.systemd}/bin/systemd-run"
    "--user"
    "--quiet"
    "--collect"
    "--no-block"
    "--unit=cinnamon-rescue-replace"
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
      import subprocess
      import sys
      import time

      BUS_NAME = "org.Cinnamon"
      BUS_PATH = "/org/Cinnamon"
      DBUS_NAME = "org.freedesktop.DBus"
      DBUS_PATH = "/org/freedesktop/DBus"

      # probe() exit codes; also cinnamon-rescue's own exit status.
      ALIVE, HUNG, ABSENT = 0, 1, 2

      GDBUS = os.environ.get("CINNAMON_RESCUE_GDBUS", "${pkgs.glib}/bin/gdbus")
      JOURNALCTL = os.environ.get("CINNAMON_RESCUE_JOURNALCTL", "${pkgs.systemd}/bin/journalctl")
      RESTART_CMD = os.environ.get("CINNAMON_RESCUE_RESTART_CMD", "${restartCmd}")
      STATE_DIR = os.environ.get("CINNAMON_RESCUE_STATE_DIR", "${stateDir}")
      THRESHOLD = int(os.environ.get("CINNAMON_RESCUE_THRESHOLD", "${toString threshold}"))
      COOLDOWN = int(os.environ.get("CINNAMON_RESCUE_COOLDOWN_SECS", "${toString cooldownSecs}"))
      PING_TIMEOUT = int(os.environ.get("CINNAMON_RESCUE_PING_TIMEOUT_SECS", "${toString pingTimeoutSecs}"))


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
              GDBUS, "call", "--session", "--timeout", str(PING_TIMEOUT),
              "--dest", dest, "--object-path", path, "--method", method,
          ] + list(args)
          # Wall-clock bound of its own, in case gdbus ignores --timeout:
          # a watchdog that can itself hang is not a watchdog.
          return _run(argv, PING_TIMEOUT + 5)


      def name_owned():
          rc, _ = _gdbus(DBUS_NAME, DBUS_PATH, DBUS_NAME + ".GetNameOwner", BUS_NAME)
          return rc == 0


      def responds():
          rc, _ = _gdbus(BUS_NAME, BUS_PATH, DBUS_NAME + ".Peer.Ping")
          return rc == 0


      def probe():
          if not name_owned():
              return ABSENT
          return ALIVE if responds() else HUNG


      def cinnamon_pid():
          rc, out = _gdbus(
              DBUS_NAME, DBUS_PATH,
              DBUS_NAME + ".GetConnectionUnixProcessID", BUS_NAME,
          )
          if rc != 0:
              return None
          # "(uint32 1234,)" — anchor on the type tag so the digits in
          # "uint32" itself can't be scraped into the pid.
          m = re.search(r"uint32\s+(\d+)", out)
          return int(m.group(1)) if m else None


      def _state(name):
          return os.path.join(STATE_DIR, name)


      def _read_int(name, default=0):
          try:
              with open(_state(name)) as fh:
                  return int(fh.read().strip() or default)
          except (OSError, ValueError):
              return default


      def _write_int(name, value):
          os.makedirs(STATE_DIR, exist_ok=True)
          tmp = _state(name + ".tmp")
          with open(tmp, "w") as fh:
              fh.write(str(value))
          os.replace(tmp, _state(name))


      def _slurp(path, limit=4096):
          try:
              with open(path, "rb") as fh:
                  return fh.read(limit).decode("utf-8", "replace").strip()
          except OSError as exc:
              return "<unreadable: %s>" % exc


      def capture(pid, fails):
          """Write a hang report and return its path."""
          os.makedirs(STATE_DIR, exist_ok=True)
          path = os.path.join(STATE_DIR, "hang-%s.txt" % time.strftime("%Y%m%dT%H%M%S"))
          out = [
              "cinnamon-rescue hang report",
              "when=%s" % time.strftime("%Y-%m-%d %H:%M:%S %z"),
              "pid=%s" % ("<unresolved>" if pid is None else pid),
              "reason=%d consecutive failed %s.Peer.Ping to %s" % (fails, DBUS_NAME, BUS_NAME),
              "",
          ]
          if pid is None:
              out.append("No pid from the broker, so no /proc state to read.")
          else:
              proc = "/proc/%d" % pid
              out += [
                  "cmdline=%s" % _slurp(proc + "/cmdline").replace("\0", " "),
                  # The kernel function the main thread is parked in — the
                  # single most useful datum for "what was it blocked on".
                  "wchan=%s" % _slurp(proc + "/wchan", 256),
                  "",
                  "status:",
              ]
              status = _slurp(proc + "/status", 8192)
              keep = ("State:", "Threads:", "VmRSS:", "voluntary_ctxt_switches:",
                      "nonvoluntary_ctxt_switches:")
              for line in status.splitlines():
                  if line.startswith(keep):
                      out.append("  " + line)
              out += ["", "threads:"]
              try:
                  for tid in sorted(os.listdir(proc + "/task"), key=lambda t: int(t)):
                      # stat: pid (comm) state ...; comm can contain spaces
                      # and parens, so read the state after the LAST paren.
                      raw = _slurp("%s/task/%s/stat" % (proc, tid), 1024)
                      state = raw.rsplit(")", 1)[-1].split()[0] if ")" in raw else "?"
                      comm = raw.split("(", 1)[-1].rsplit(")", 1)[0] if "(" in raw else "?"
                      out.append("  tid=%s state=%s comm=%s wchan=%s" % (
                          tid, state, comm,
                          _slurp("%s/task/%s/wchan" % (proc, tid), 128),
                      ))
              except OSError as exc:
                  out.append("  <unreadable: %s>" % exc)
          out += [
              "",
              "ptrace: kernel.yama.ptrace_scope=%s" % _slurp("/proc/sys/kernel/yama/ptrace_scope", 16),
              "A user service cannot attach a debugger to a non-descendant, so",
              "there is no native backtrace here. For one, from a TTY as root:",
              "  gdb -p %s -batch -ex 'thread apply all bt'" % (pid if pid else "<pid>"),
              "",
              "journal (user, last 80 lines):",
          ]
          rc, log = _run([JOURNALCTL, "--user", "-n", "80", "--no-pager"], 20)
          out.append(log if rc == 0 else "<journalctl failed: %s>" % log)
          with open(path, "w") as fh:
              fh.write("\n".join(out) + "\n")
          return path


      def restart():
          env = dict(os.environ)
          # A systemd user service does not necessarily inherit DISPLAY, and
          # `cinnamon --replace` needs one. Single seat, so :0.
          env.setdefault("DISPLAY", ":0")
          try:
              subprocess.Popen(
                  shlex.split(RESTART_CMD), env=env,
                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                  start_new_session=True,
              )
              return True
          except OSError as exc:
              print("cinnamon-rescue: restart failed: %s" % exc, file=sys.stderr)
              return False


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
          now = int(time.time())
          last = _read_int("last-restart")
          if last and now - last < COOLDOWN:
              print("cinnamon-rescue: hung, but %ds cooldown is still open; not restarting"
                    % COOLDOWN)
              return 0
          report = capture(cinnamon_pid(), fails)
          print("cinnamon-rescue: hung after %d failed pings; report %s" % (fails, report))
          ok = restart()
          _write_int("last-restart", now)
          _write_int("failures", 0)
          return 0 if ok else 1


      def now():
          report = capture(cinnamon_pid(), _read_int("failures"))
          print("cinnamon-rescue: report %s" % report)
          ok = restart()
          _write_int("last-restart", int(time.time()))
          _write_int("failures", 0)
          return 0 if ok else 1


      def main(argv):
          cmd = argv[1] if len(argv) > 1 else "check"
          if cmd == "probe":
              return probe()
          if cmd == "check":
              return check()
          if cmd == "now":
              return now()
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
    Unit.Description = "Recover Cinnamon if its main loop stops responding";
    Service = {
      Type = "oneshot";
      ExecStart = "${cinnamonRescue}/bin/cinnamon-rescue check";
      # The replacement Cinnamon is launched into its own transient unit,
      # but keep the service from reaping anything it leaves behind.
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
