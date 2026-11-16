{ pkgs, ... }:
# notification-log — a local history of desktop notifications.
#
# Cinnamon shows a notification and forgets it. This unit watches the
# session bus for org.freedesktop.Notifications.Notify calls and appends
# each one to $XDG_STATE_HOME/notification-log/notifications.jsonl;
# `notifications` prints the history.
#
# It is a bus MONITOR (`busctl monitor`, i.e. BecomeMonitor), never an
# owner of org.freedesktop.Notifications: Cinnamon keeps delivering every
# notification exactly as before, and a crash here cannot cost one.
#
# The log is bounded: entries older than retentionDays are dropped and at
# most maxEntries are kept. Bodies may be private, so the directory is 0700,
# the file 0600, and the journal line names only the app and summary.
#
# Asserted by tests/desktop.nix (vm-desktop).
let
  maxEntries = 5000;
  retentionDays = 30;
  # A body is stored up to this many characters; the rest is cut.
  maxBodyChars = 4096;
  maxSummaryChars = 1024;
  maxAppChars = 256;
  # Trim on start, then after this many appends or once a day, whichever
  # comes first, so the file never grows far past maxEntries.
  trimEveryAppends = 500;
  trimEverySecs = 86400;

  matchRule = "type='method_call',interface='org.freedesktop.Notifications',member='Notify'";

  common = ''
    import os
    from datetime import datetime, timedelta, timezone

    RETENTION = timedelta(days=${toString retentionDays})


    def log_path():
        base = os.environ.get("XDG_STATE_HOME") or os.path.expanduser(
            "~/.local/state"
        )
        return os.path.join(base, "notification-log", "notifications.jsonl")


    def parse_ts(value):
        try:
            ts = datetime.fromisoformat(value)
        except (TypeError, ValueError):
            return None
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=timezone.utc)
        return ts
  '';

  capture = pkgs.writers.writePython3Bin "notification-log-capture"
    { flakeIgnore = [ "E501" ]; }
    ''
      """Append every Notify call on the session bus to the notification log.

      Default: read `busctl --user monitor --json=short` output.
      --stdin: read that same line format from stdin instead (tests, replay).
      """
      import json
      import subprocess
      import sys
      import time

      ${common}

      MAX_ENTRIES = ${toString maxEntries}
      MAX_BODY = ${toString maxBodyChars}
      MAX_SUMMARY = ${toString maxSummaryChars}
      MAX_APP = ${toString maxAppChars}
      TRIM_EVERY_APPENDS = ${toString trimEveryAppends}
      TRIM_EVERY_SECS = ${toString trimEverySecs}
      BUSCTL = [
          "${pkgs.systemd}/bin/busctl", "--user", "monitor", "--json=short",
          "--match", "${matchRule}",
      ]


      def ensure_dir(path):
          d = os.path.dirname(path)
          os.makedirs(d, mode=0o700, exist_ok=True)
          os.chmod(d, 0o700)


      def clean(s, n):
          """s cut to n characters, with lone surrogates (which no UTF-8
          writer accepts) replaced so neither the log nor the journal line
          can fail on them."""
          return s[:n].encode("utf-8", "replace").decode("utf-8")


      def record_from(line, now):
          """The log record for one monitor line, or None if it is not a
          well-formed Notify call."""
          try:
              msg = json.loads(line)
          except ValueError:
              return None
          if not isinstance(msg, dict):
              return None
          if msg.get("member") != "Notify" or \
                  msg.get("interface") != "org.freedesktop.Notifications":
              return None
          payload = msg.get("payload")
          data = payload.get("data") if isinstance(payload, dict) else None
          if not isinstance(data, list) or len(data) < 5:
              return None
          app, summary, body = data[0], data[3], data[4]
          if not all(isinstance(v, str) for v in (app, summary, body)):
              return None
          hints = data[6] if len(data) > 6 and isinstance(data[6], dict) else {}
          urgency = None
          u = hints.get("urgency")
          if isinstance(u, dict) and u.get("type") == "y":
              v = u.get("data")
              if isinstance(v, int) and not isinstance(v, bool) and 0 <= v <= 2:
                  urgency = v
          sender = msg.get("sender")
          return {
              "ts": now.isoformat(timespec="seconds"),
              "app": clean(app, MAX_APP),
              "summary": clean(summary, MAX_SUMMARY),
              "body": clean(body, MAX_BODY),
              "urgency": urgency,
              "sender": clean(sender, MAX_APP) if isinstance(sender, str) else None,
          }


      def append(path, rec):
          fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
          try:
              os.fchmod(fd, 0o600)
              # ASCII-only, so a U+2028 or U+0085 in a body stays an escape
              # instead of a raw character that splitlines() reads as a line
              # break, which would split the record into unparsable halves.
              os.write(fd, (json.dumps(rec) + "\n").encode())
          finally:
              os.close(fd)


      def trim(path):
          """Drop entries past retention, keep the newest MAX_ENTRIES.

          Rewrites through a temp file and rename, so a reader never sees a
          half-written log. This process is the only writer.
          """
          try:
              with open(path, encoding="utf-8", errors="replace") as f:
                  lines = f.read().splitlines()
          except FileNotFoundError:
              return
          cutoff = datetime.now(timezone.utc) - RETENTION
          keep = []
          for line in lines:
              try:
                  rec = json.loads(line)
              except ValueError:
                  continue
              ts = parse_ts(rec.get("ts")) if isinstance(rec, dict) else None
              if ts is not None and ts >= cutoff:
                  keep.append(line)
          keep = keep[-MAX_ENTRIES:]
          if len(keep) == len(lines):
              return
          tmp = path + ".tmp"
          fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
          with os.fdopen(fd, "w", encoding="utf-8") as f:
              f.write("".join(line + "\n" for line in keep))
          os.replace(tmp, path)


      def oneline(s, n=200):
          return " ".join(s.split())[:n]


      def run(stream, path):
          appended = 0
          last_trim = time.monotonic()
          for line in stream:
              rec = record_from(line, datetime.now(timezone.utc))
              if rec is None:
                  continue
              append(path, rec)
              print(f"{oneline(rec['app'], 60)}: {oneline(rec['summary'])}", flush=True)
              appended += 1
              if appended >= TRIM_EVERY_APPENDS or \
                      time.monotonic() - last_trim >= TRIM_EVERY_SECS:
                  trim(path)
                  appended = 0
                  last_trim = time.monotonic()


      def main(argv):
          os.umask(0o077)
          path = log_path()
          ensure_dir(path)
          trim(path)
          if argv[1:] == ["--stdin"]:
              stdin = open(sys.stdin.fileno(), encoding="utf-8",
                           errors="replace", closefd=False)
              run(stdin, path)
              return 0
          if argv[1:]:
              print("usage: notification-log-capture [--stdin]", file=sys.stderr)
              return 2
          proc = subprocess.Popen(BUSCTL, stdout=subprocess.PIPE,
                                  encoding="utf-8", errors="replace")
          run(proc.stdout, path)
          rc = proc.wait()
          # The monitor ending means capture has stopped; let systemd restart.
          print(f"busctl monitor exited rc={rc}", file=sys.stderr, flush=True)
          return rc or 1


      if __name__ == "__main__":
          sys.exit(main(sys.argv))
    '';

  cli = pkgs.writers.writePython3Bin "notifications"
    { flakeIgnore = [ "E501" ]; }
    ''
      """Show the desktop notification history kept by notification-log."""
      import argparse
      import json
      import subprocess
      import sys
      import unicodedata

      ${common}

      URGENCY = {0: "low", 1: "normal", 2: "critical"}


      def safe(s):
          """s with control characters and lone surrogates shown as U+FFFD.
          Any app can send a notification, so its text must not be able to
          drive the terminal (escape sequences, title changes, clears)."""
          return "".join(
              "�" if c != "\t" and unicodedata.category(c) in ("Cc", "Cs") else c
              for c in str(s)
          )


      def service_state():
          r = subprocess.run(
              ["${pkgs.systemd}/bin/systemctl", "--user", "is-active",
               "notification-log.service"],
              capture_output=True, text=True,
          )
          return r.stdout.strip() or "unknown"


      def since_ts(text):
          r = subprocess.run(
              ["${pkgs.coreutils}/bin/date", "-d", text, "+%s"],
              capture_output=True, text=True,
          )
          if r.returncode != 0:
              sys.exit(f"notifications: cannot parse --since {text!r}")
          return datetime.fromtimestamp(int(r.stdout), timezone.utc)


      def read_log(path):
          try:
              with open(path, encoding="utf-8", errors="replace") as f:
                  lines = f.read().splitlines()
          except FileNotFoundError:
              return []
          cutoff = datetime.now(timezone.utc) - RETENTION
          out = []
          for line in lines:
              try:
                  rec = json.loads(line)
              except ValueError:
                  continue
              ts = parse_ts(rec.get("ts")) if isinstance(rec, dict) else None
              # The capture trims only on start and on appends, so apply the
              # retention window here too.
              if ts is not None and ts >= cutoff:
                  out.append(rec)
          return out


      def show(rec):
          ts = parse_ts(rec["ts"]).astimezone().strftime("%Y-%m-%d %H:%M:%S")
          urg = URGENCY.get(rec.get("urgency"))
          tag = f"  [{urg}]" if urg and urg != "normal" else ""
          app = safe(rec.get("app") or "")
          summary = safe(rec.get("summary") or "")
          print(f"{ts}  {app}{tag}  {summary}")
          for line in str(rec.get("body") or "").splitlines():
              print(f"    {safe(line)}")


      def main():
          p = argparse.ArgumentParser(prog="notifications", description=__doc__)
          p.add_argument("-n", type=int, default=20, metavar="N",
                         help="show the newest N (default 20, 0 = all)")
          p.add_argument("--since", metavar="WHEN",
                         help='only entries since WHEN (any `date -d` text, e.g. "1 hour ago")')
          p.add_argument("--json", action="store_true",
                         help="print raw JSON lines")
          a = p.parse_args()

          path = log_path()
          recs = read_log(path)
          if a.since:
              cutoff = since_ts(a.since)
              recs = [r for r in recs if parse_ts(r["ts"]) >= cutoff]
          if a.n > 0:
              recs = recs[-a.n:]

          state = service_state()
          if state == "active":
              down = None
          elif state == "unknown":
              # systemctl could not reach the user manager (no user bus in
              # this environment), which says nothing about the service.
              down = "notification-log: capture state unknown (systemctl --user unavailable here)"
          else:
              down = f"notification-log: NOT running ({state}); new notifications are not being logged"
          if a.json:
              for r in recs:
                  print(json.dumps(r))
              if down:
                  print(down, file=sys.stderr)
              return 0
          if not recs:
              print(f"No notifications logged in {path}.")
              print(down or "notification-log: active (capturing)")
              return 0
          for r in recs:
              show(r)
          if down:
              print(down, file=sys.stderr)
          return 0


      if __name__ == "__main__":
          sys.exit(main())
    '';
in
{
  home.packages = [ capture cli ];

  systemd.user.services.notification-log = {
    # Bound to the graphical session like cinnamon-watchdog: with linger the
    # user manager outlives logout, and there is nothing to log without one.
    Unit = {
      Description = "Log desktop notifications from the session bus";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "${capture}/bin/notification-log-capture";
      Restart = "always";
      RestartSec = "5s";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
