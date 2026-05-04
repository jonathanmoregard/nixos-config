# modules/nixos/github-webhook.nix
#
# GitHub webhook handler for production deploy. Used ONLY for push:main
# events; PR-triggered jobs use the GHA self-hosted runner's long-poll
# directly (no webhook needed for those).
#
# Architecture:
#   tailscale funnel  ──► localhost:9091 ──► systemd socket-activated
#                                            python3 handler
#                                            ──► systemctl start
#                                                nixos-deploy.service
#
# Security:
#   - HMAC-SHA256 verification using secret in agenix
#   - X-GitHub-Delivery UUID replay protection (24h TTL)
#   - Slowloris hardening: socket.settimeout(5), MaxConnections=4,
#     TimeoutStartSec=10s
#   - Rate limit: 10 connections per 10s on the socket
{ config, lib, pkgs, ... }:

let
  cfg = config.services.githubWebhook;

  handlerScript = pkgs.writers.writePython3Bin "github-webhook-handler" {
    libraries = [ ];
  } ''
    """GitHub webhook handler. Stdin = HTTP request; stdout = response.

    Environment:
      WEBHOOK_SECRET       HMAC secret (from EnvironmentFile via agenix)
      DEPLOY_UNIT          systemd unit to start on valid push:main
                           (default: nixos-deploy.service)
      SEEN_DIR             dir for X-GitHub-Delivery dedup state
                           (default: /var/lib/github-webhook)
    """
    import hashlib
    import hmac
    import json
    import os
    import socket
    import subprocess
    import sys
    import time

    SEEN_TTL = 24 * 3600  # 24h
    READ_TIMEOUT_S = 5

    def respond(code, body=""):
        sys.stdout.write(f"HTTP/1.1 {code}\r\n")
        sys.stdout.write(f"Content-Length: {len(body)}\r\n")
        sys.stdout.write("Content-Type: text/plain\r\n\r\n")
        sys.stdout.write(body)
        sys.stdout.flush()

    def main():
        # Slowloris hardening: hard-cap stdin read time.
        try:
            sock = socket.fromfd(0, socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(READ_TIMEOUT_S)
        except OSError:
            pass  # not a socket (e.g. local test); skip.

        try:
            raw = sys.stdin.buffer.read()
        except socket.timeout:
            respond("408 Request Timeout")
            return 0

        # Parse minimal HTTP — split headers/body on the first blank line.
        try:
            head_blob, body = raw.split(b"\r\n\r\n", 1)
        except ValueError:
            respond("400 Bad Request")
            return 0

        headers = {}
        for line in head_blob.split(b"\r\n")[1:]:
            if b":" in line:
                k, _, v = line.partition(b":")
                headers[k.strip().lower().decode()] = v.strip().decode()

        secret = os.environ.get("WEBHOOK_SECRET", "").encode()
        if not secret:
            respond("500 Internal Server Error", "no secret configured")
            return 1

        sig_header = headers.get("x-hub-signature-256", "")
        if not sig_header.startswith("sha256="):
            respond("401 Unauthorized", "missing signature")
            return 0
        expected = sig_header[len("sha256="):]
        digest = hmac.new(secret, body, hashlib.sha256).hexdigest()
        if not hmac.compare_digest(digest, expected):
            respond("401 Unauthorized", "bad signature")
            return 0

        delivery = headers.get("x-github-delivery", "")
        if not delivery:
            respond("400 Bad Request", "missing X-GitHub-Delivery")
            return 0

        seen_dir = os.environ.get("SEEN_DIR", "/var/lib/github-webhook")
        os.makedirs(seen_dir, exist_ok=True)
        seen_file = os.path.join(seen_dir, "seen")
        now = int(time.time())

        # Read existing entries; prune those older than SEEN_TTL.
        entries = []
        if os.path.exists(seen_file):
            with open(seen_file) as fh:
                for ln in fh:
                    parts = ln.rstrip("\n").split(" ", 1)
                    if len(parts) == 2:
                        try:
                            ts = int(parts[0])
                        except ValueError:
                            continue
                        if now - ts < SEEN_TTL:
                            entries.append((ts, parts[1]))

        if any(uuid == delivery for _, uuid in entries):
            respond("200 OK", "duplicate delivery; ignored")
            return 0

        entries.append((now, delivery))
        tmp = seen_file + ".tmp"
        with open(tmp, "w") as fh:
            for ts, uuid in entries:
                fh.write(f"{ts} {uuid}\n")
        os.rename(tmp, seen_file)

        event = headers.get("x-github-event", "")
        if event != "push":
            respond("200 OK", f"event {event} ignored")
            return 0

        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            respond("400 Bad Request", "bad json")
            return 0

        if payload.get("ref") != "refs/heads/main":
            respond("200 OK", "non-main push ignored")
            return 0

        unit = os.environ.get("DEPLOY_UNIT", "nixos-deploy.service")
        # sudo invocation matches the sudoers rule exactly: command path
        # + start --no-block <unit>, which is the only allowed form.
        subprocess.run(
            ["sudo", "/run/current-system/sw/bin/systemctl", "start", "--no-block", unit],
            check=False,
        )
        respond("200 OK", f"queued: systemctl start {unit}")
        return 0

    if __name__ == "__main__":
        sys.exit(main())
  '';
in
{
  options.services.githubWebhook = {
    enable = lib.mkEnableOption "GitHub webhook handler for push:main";

    port = lib.mkOption {
      type = lib.types.port;
      default = 9091;
      description = "Local port the handler listens on (Tailscale Funnel terminates TLS upstream).";
    };

    secretFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to file containing WEBHOOK_SECRET=<value>. Typically agenix-decrypted.";
    };

    deployUnit = lib.mkOption {
      type = lib.types.str;
      default = "nixos-deploy.service";
      description = "systemd unit to start on valid push:main.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d /var/lib/github-webhook 0700 github-webhook github-webhook - -"
    ];

    users.users.github-webhook = {
      isSystemUser = true;
      group = "github-webhook";
    };
    users.groups.github-webhook = { };

    systemd.sockets.github-webhook = {
      description = "Listen for GitHub webhooks";
      # Bind localhost only — Tailscale Funnel terminates TLS upstream
      # and forwards to localhost. Don't expose to other interfaces.
      listenStreams = [ "127.0.0.1:${toString cfg.port}" ];
      socketConfig = {
        Accept = true;
        MaxConnections = 4;
        # Rate limit: 10 new connections per 10s, then queue.
        # GH retries failed webhooks 3x with exp backoff over ~30s — burst=10
        # absorbs retry waves without dropping legitimate deliveries.
        TriggerLimitIntervalSec = 10;
        TriggerLimitBurst = 10;
      };
      wantedBy = [ "sockets.target" ];
    };

    systemd.services."github-webhook@" = {
      description = "Handle one GitHub webhook delivery";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${handlerScript}/bin/github-webhook-handler";
        EnvironmentFile = cfg.secretFile;
        Environment = [
          "DEPLOY_UNIT=${cfg.deployUnit}"
          "SEEN_DIR=/var/lib/github-webhook"
        ];
        StandardInput = "socket";
        StandardOutput = "socket";
        TimeoutStartSec = "10s";
        User = "github-webhook";
        Group = "github-webhook";
      };
    };

    # Allow github-webhook user to start the deploy unit without a password.
    # Earlier draft used a polkit rule, but socket-activated handlers run
    # without a D-Bus session — polkit's manage-units lookup falls back to
    # PID 1 socket and returns EACCES. A scoped sudoers rule works in the
    # no-D-Bus context.
    security.sudo.extraRules = [{
      users = [ "github-webhook" ];
      commands = [{
        command = "/run/current-system/sw/bin/systemctl start --no-block ${cfg.deployUnit}";
        options = [ "NOPASSWD" ];
      }];
    }];
  };
}
