{ pkgs, lib, ... }:
# lid-guard — closing the lid keeps dellan running only while a Claude Code
# or Codex pane still has work in flight; otherwise the lid suspends as usual.
#
# Cinnamon's csd-power holds logind's handle-lid-switch inhibitor for the
# whole session, so the dconf keys below (not services.logind) decide what a
# lid close does. lid-guard flips them between `idleAction` and "nothing".
#
# "Work in flight" (the user's definition: a close proxy to "no work ongoing,
# delegated work waiting to be picked up included"):
#   - an open turn: UserPromptSubmit/PostToolUse mark it, Stop/StopFailure/
#     PermissionRequest/SessionEnd clear it. A permission prompt is idle:
#     nothing progresses behind a closed lid until someone answers it. An
#     approved Bash command is still covered while it runs, by the process
#     scan below (foreground commands also write tasks/*.output).
#   - a background subagent: SubagentStart .. SubagentStop, one marker each;
#     its own PermissionRequest clears it, its next PostToolUse restores it
#   - every marker also lapses after idleTtlMinutes with no hook event for it,
#     which bounds what no hook reports (an ESC interrupt skips Stop)
#   - a background Bash command: a process holding the harness's
#     /tmp/claude-<uid>/<project>/<session>/tasks/<id>.output open, counted
#     only while younger than bashCapMinutes so a dev server left running
#     ages out instead of pinning the machine awake
#
# Markers live under $XDG_RUNTIME_DIR/agent-activity/<session>/ and record
# the agent's pid; a dead pid (crashed pane) is ignored and reaped. The hook
# wiring lives in ~/.claude/settings.json (synced to Codex by
# ai-client-config) and calls `agent-activity mark` with the hook JSON on
# stdin. A 30 s timer reconciles for ageing and dead pids; hooks reconcile
# immediately on every state change. Every failure falls back to
# `idleAction` — the machine suspends rather than cooks in a bag.
#
# Asserted by tests/desktop.nix (vm-desktop).
let
  idleAction = "suspend";
  bashCapMinutes = 45;
  idleTtlMinutes = 20;

  agentActivity = pkgs.writers.writePython3Bin "agent-activity"
    { flakeIgnore = [ "E501" ]; }
    ''
      import contextlib
      import fcntl
      import json
      import os
      import re
      import shutil
      import subprocess
      import sys
      import time

      IDLE_ACTION = "${idleAction}"
      BUSY_ACTION = "nothing"
      KEYS = (
          "/org/cinnamon/settings-daemon/plugins/power/lid-close-ac-action",
          "/org/cinnamon/settings-daemon/plugins/power/lid-close-battery-action",
      )
      DCONF = "${pkgs.dconf}/bin/dconf"
      AGENT_COMMS = ("claude", "codex")
      BASH_CAP_SECS = int(os.environ.get("AGENT_ACTIVITY_BASH_CAP_SECS", ${toString (bashCapMinutes * 60)}))
      IDLE_TTL_SECS = int(os.environ.get("AGENT_ACTIVITY_IDLE_TTL_SECS", ${toString (idleTtlMinutes * 60)}))
      SAFE = re.compile(r"[^A-Za-z0-9_.-]")
      BUSY_EVENTS = {"UserPromptSubmit", "PostToolUse"}
      IDLE_EVENTS = {"Stop", "StopFailure", "PermissionRequest"}


      def state_dir():
          base = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
          return os.path.join(base, "agent-activity")


      def safe(name):
          return SAFE.sub("_", str(name))[:128]


      def comm(pid):
          try:
              with open(f"/proc/{pid}/comm") as f:
                  return f.read().strip()
          except OSError:
              return ""


      def parent(pid):
          try:
              with open(f"/proc/{pid}/stat") as f:
                  return int(f.read().rsplit(")", 1)[1].split()[1])
          except (OSError, IndexError, ValueError):
              return 0


      def agent_pid():
          """Nearest ancestor that is the claude/codex process running this hook."""
          pid = os.getppid()
          for _ in range(16):
              if pid <= 1:
                  return None
              if comm(pid) in AGENT_COMMS:
                  return pid
              pid = parent(pid)
          return None


      def write_marker(path):
          os.makedirs(os.path.dirname(path), exist_ok=True)
          tmp = f"{path}.tmp{os.getpid()}"
          with open(tmp, "w") as f:
              json.dump({"pid": agent_pid()}, f)
          os.replace(tmp, path)


      def touch_marker(path):
          """Refresh the marker's activity time; True when it was newly created."""
          try:
              os.utime(path)
              return False
          except FileNotFoundError:
              write_marker(path)
              return True


      def remove(path):
          try:
              os.remove(path)
              return True
          except FileNotFoundError:
              return False


      def mark(event):
          data = json.load(sys.stdin)
          # The hook wiring names its event; the payload's field is the fallback.
          event = event or data.get("hook_event_name", "")
          session = data.get("session_id")
          if not session:
              return False
          sdir = os.path.join(state_dir(), safe(session))
          # Hooks fired inside a subagent carry its agent_id; they belong to
          # that subagent's marker, never to the main turn.
          agent_id = data.get("agent_id")
          if event == "SessionEnd":
              changed = os.path.isdir(sdir)
              shutil.rmtree(sdir, ignore_errors=True)
              return changed
          if agent_id:
              sub = os.path.join(sdir, f"sub-{safe(agent_id)}")
              if event == "SubagentStop" or event in IDLE_EVENTS:
                  return remove(sub)
              if event == "SubagentStart" or event in BUSY_EVENTS:
                  return touch_marker(sub)
              return False
          turn = os.path.join(sdir, "turn")
          if event in BUSY_EVENTS:
              return touch_marker(turn)
          if event in IDLE_EVENTS:
              return remove(turn)
          return False


      def live_markers():
          """Yield (session, marker) for markers whose agent is still alive."""
          root = state_dir()
          now = time.time()
          try:
              sessions = os.listdir(root)
          except FileNotFoundError:
              return
          for session in sessions:
              sdir = os.path.join(root, session)
              try:
                  names = os.listdir(sdir)
              except OSError:
                  continue
              for name in names:
                  path = os.path.join(sdir, name)
                  try:
                      with open(path) as f:
                          pid = json.load(f).get("pid")
                      fresh = now - os.stat(path).st_mtime < IDLE_TTL_SECS
                  except (OSError, ValueError, AttributeError):
                      continue
                  # A pid that isn't an agent any more is a crashed pane.
                  if fresh and (pid is None or comm(pid) in AGENT_COMMS):
                      yield session, name
                  else:
                      remove(path)
              # Still holds live markers → stays; empty → removed.
              with contextlib.suppress(OSError):
                  os.rmdir(sdir)


      def boot_time():
          with open("/proc/stat") as f:
              for line in f:
                  if line.startswith("btime "):
                      return int(line.split()[1])
          return 0


      def background_bash():
          """Yield (pid, age_secs, output_file) for young background Bash commands."""
          prefix = f"/tmp/claude-{os.getuid()}/"
          tick = os.sysconf("SC_CLK_TCK")
          btime = boot_time()
          now = time.time()
          for entry in os.listdir("/proc"):
              if not entry.isdigit() or comm(entry) in AGENT_COMMS:
                  continue
              try:
                  fds = os.listdir(f"/proc/{entry}/fd")
              except OSError:
                  continue
              for fd in fds:
                  try:
                      target = os.readlink(f"/proc/{entry}/fd/{fd}")
                  except OSError:
                      continue
                  if not (target.startswith(prefix) and "/tasks/" in target and target.endswith(".output")):
                      continue
                  try:
                      with open(f"/proc/{entry}/stat") as f:
                          start = int(f.read().rsplit(")", 1)[1].split()[19]) / tick
                  except (OSError, IndexError, ValueError):
                      break
                  age = now - (btime + start)
                  if age < BASH_CAP_SECS:
                      yield int(entry), age, target
                  break


      def reasons():
          for session, name in live_markers():
              yield f"{session}: {name}"
          for pid, age, target in background_bash():
              yield f"background bash pid {pid} ({int(age // 60)} min): {target}"


      def dconf_env():
          # HM activation may run without the session bus address exported;
          # the user bus socket is still at its standard path.
          env = dict(os.environ)
          bus = f"/run/user/{os.getuid()}/bus"
          if "DBUS_SESSION_BUS_ADDRESS" not in env and os.path.exists(bus):
              env["DBUS_SESSION_BUS_ADDRESS"] = f"unix:path={bus}"
          return env


      def set_action(action):
          value = f"'{action}'"
          env = dconf_env()
          for key in KEYS:
              current = subprocess.run([DCONF, "read", key], capture_output=True, text=True, timeout=10, env=env).stdout.strip()
              if current != value:
                  subprocess.run([DCONF, "write", key, value], check=True, timeout=10, env=env)


      def reconcile():
          # Serialized: a timer run that sampled markers just before a Stop
          # hook removed its turn must not write "nothing" after the hook's
          # "suspend". Whoever holds the lock last also sampled last.
          os.makedirs(state_dir(), exist_ok=True)
          with open(os.path.join(state_dir(), ".lock"), "w") as lock:
              fcntl.flock(lock, fcntl.LOCK_EX)
              reconcile_locked()


      def reconcile_locked():
          try:
              active = next(reasons(), None) is not None
              set_action(BUSY_ACTION if active else IDLE_ACTION)
          except Exception:
              set_action(IDLE_ACTION)
              raise


      def main():
          cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
          if cmd == "mark":
              # A hook must never fail the agent or print into its context.
              # stderr on exit 0 stays out of the model's context.
              try:
                  if mark(sys.argv[2] if len(sys.argv) > 2 else ""):
                      reconcile()
              except Exception as exc:
                  print(f"agent-activity mark: {exc!r}", file=sys.stderr)
              return 0
          if cmd == "reconcile":
              reconcile()
              return 0
          if cmd == "status":
              found = list(reasons())
              print("active" if found else "idle")
              for r in found:
                  print(f"  {r}")
              return 0
          print("usage: agent-activity [mark [EVENT]|reconcile|status]", file=sys.stderr)
          return 2


      sys.exit(main())
    '';
in
{
  home.packages = [ agentActivity ];

  dconf.settings."org/cinnamon/settings-daemon/plugins/power" = {
    lid-close-ac-action = idleAction;
    lid-close-battery-action = idleAction;
  };

  # dconfSettings just wrote idleAction; restore the live answer at once
  # instead of leaving a deploy mid-turn exposed until the next timer tick.
  home.activation.lidGuardReconcile = lib.hm.dag.entryAfter [ "dconfSettings" ] ''
    run ${agentActivity}/bin/agent-activity reconcile || true
  '';

  systemd.user.services.lid-guard = {
    Unit.Description = "Keep the lid-close action in step with agent activity";
    Service = {
      Type = "oneshot";
      ExecStart = "${agentActivity}/bin/agent-activity reconcile";
    };
  };

  systemd.user.timers.lid-guard = {
    Unit.Description = "Re-check agent activity for the lid-close action";
    Timer = {
      OnActiveSec = "30s";
      OnUnitActiveSec = "30s";
      AccuracySec = "5s";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
