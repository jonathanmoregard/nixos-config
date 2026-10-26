# Stand-in for the two api.github.com endpoints the GitHub App key broker
# (modules/nixos/github-app-broker) calls with an App JWT:
#
#   GET  /app/installations/<id>                which account installed the App
#   POST /app/installations/<id>/access_tokens  mint an installation token
#
# Both answer only a JWT that verifies against the fixture App key's public
# half and that GitHub would accept (RS256, exp at most 10 minutes ahead), so
# an answer proves the broker signed with the key it was given. The minted
# token names the installation and repository ids it was minted for. Every
# authenticated request is appended to <log> as `<METHOD> <path>`, and each
# token request's JSON body (keys sorted) to <log>.bodies.
#
# Usage: fake-github-api.py <public-key.pem> <port> <openssl> <log>
#            <installation_id>=<account login>...
import base64
import json
import subprocess
import sys
import tempfile
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

PUBLIC_KEY, PORT, OPENSSL, LOG = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
ACCOUNTS = dict(arg.split("=", 1) for arg in sys.argv[5:])


def unb64(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def verified_claims(authorization):
    if not authorization.startswith("Bearer "):
        return None
    parts = authorization[len("Bearer "):].split(".")
    if len(parts) != 3:
        return None
    header, payload, signature = parts
    with tempfile.NamedTemporaryFile() as sig:
        sig.write(unb64(signature))
        sig.flush()
        check = subprocess.run(
            [OPENSSL, "dgst", "-sha256", "-verify", PUBLIC_KEY, "-signature", sig.name],
            input=(header + "." + payload).encode(),
            capture_output=True,
        )
    if check.returncode != 0:
        return None
    if json.loads(unb64(header)).get("alg") != "RS256":
        return None
    claims = json.loads(unb64(payload))
    now = time.time()
    if claims["exp"] - now > 600 or claims["iat"] > now + 60:
        return None
    return claims


class Handler(BaseHTTPRequestHandler):
    def authorized_path(self):
        claims = verified_claims(self.headers.get("Authorization", ""))
        if claims is None:
            self.reply(401, {"message": "fake GitHub: bad JWT"})
            return None
        with open(LOG, "a") as log:
            log.write(f"{self.command} {self.path}\n")
        path = self.path.strip("/").split("/")
        if len(path) < 3 or path[:2] != ["app", "installations"] or path[2] not in ACCOUNTS:
            self.reply(404, {"message": "Not Found"})
            return None
        return path

    def do_GET(self):
        path = self.authorized_path()
        if path is None:
            return
        if len(path) != 3:
            self.reply(404, {"message": "Not Found"})
            return
        self.reply(200, {"id": int(path[2]), "account": {"login": ACCOUNTS[path[2]]}})

    def do_POST(self):
        path = self.authorized_path()
        if path is None:
            return
        if len(path) != 4 or path[3] != "access_tokens":
            self.reply(404, {"message": "Not Found"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length) or b"{}")
        with open(LOG + ".bodies", "a") as bodies:
            bodies.write(json.dumps(body, sort_keys=True) + "\n")
        repos = body.get("repository_ids", [])
        token = "ghs_vm_" + path[2] + "".join("_" + str(r) for r in repos)
        self.reply(201, {
            "token": token,
            "expires_at": "2099-01-01T00:00:00Z",
            "permissions": {"contents": "write"},
            "repository_selection": "selected" if repos else "all",
        })

    def reply(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
