"""The `upstream` node of vm-egress-switchover: "the internet", hermetically.

One HTTPS listener on :443 (a test-CA leaf with every name below as a SAN)
serves stub APIs and pages by Host header:

  api.exa.ai, api.tavily.com   search JSON whose result URLs are shop.test pages
  api.ebay.com                 OAuth token + Browse API item summaries
  api.tradera.com              a minimal search answer
  www.ebay.com                 listing pages
  www.ikea.com                 a search page (the shop template) + product pages
  shop.test                    articles with outlinks, a GET-form store for
                               browse sessions, an XHR SPA for intercept_page
  canary.test                  anything; every hit is appended to /var/log/canary
  api.anthropic.com            200 for the jail's TLS probe

Every request is logged as one JSON line to /var/log/upstream/requests.jsonl
(client address, host, method, path) so the lane can prove which keyed host
was reached from where. No real external service is ever contacted.
"""
from __future__ import annotations

import json
import ssl
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

LOG = "/var/log/upstream/requests.jsonl"
CANARY = "/var/log/canary"
_lock = threading.Lock()


def _append(path: str, obj: dict) -> None:
    with _lock, open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(obj, sort_keys=True) + "\n")


def _page(title: str, body: str) -> bytes:
    return (f"<!doctype html><html><head><meta charset='utf-8'><title>{title}</title>"
            f"</head><body><h1>{title}</h1>{body}</body></html>").encode()


def exa_results(n: int) -> dict:
    return {"results": [{
        "title": f"Kettle review {i}",
        "url": f"https://shop.test/article/{i}",
        "publishedDate": "2026-10-01",
        "author": "lane",
        "highlights": [f"Kettle {i} boils water fast."],
        "text": f"Kettle {i} boils water fast. Full review text.",
    } for i in range(1, max(1, min(n, 5)) + 1)]}


STORE = """
<form action="/store/results" method="get">
  <input id="q" name="q" aria-label="Search" autocomplete="off">
  <button id="go" type="submit">Search</button>
</form>
<p>Lane test store.</p>
"""

SPA = """
<input id="q" aria-label="Search">
<button id="go" onclick="search()">Search</button>
<pre id="out"></pre>
<script>
function search() {
  fetch('/api/search?q=' + encodeURIComponent(document.getElementById('q').value))
    .then(r => r.json())
    .then(j => { document.getElementById('out').textContent = JSON.stringify(j); });
}
</script>
"""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # one JSON line per request instead
        pass

    def _send(self, status: int, body: bytes, ctype: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
        self.close_connection = True

    def _json(self, obj: dict, status: int = 200) -> None:
        self._send(status, json.dumps(obj).encode(), "application/json")

    def _html(self, title: str, body: str, status: int = 200) -> None:
        self._send(status, _page(title, body), "text/html; charset=utf-8")

    def _route(self) -> None:
        host = (self.headers.get("Host") or "").split(":")[0].lower()
        parts = urlsplit(self.path)
        path, query = parts.path, parse_qs(parts.query)
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        rec = {"ts": time.time(), "client": self.client_address[0], "host": host,
               "method": self.command, "path": path}
        _append(LOG, rec)
        if host == "canary.test":
            _append(CANARY, rec)
            return self._html("canary", "<p>canary</p>")
        if host == "api.exa.ai" and path == "/search":
            try:
                n = int(json.loads(raw or b"{}").get("numResults") or 3)
            except (ValueError, AttributeError):
                n = 3
            return self._json(exa_results(n))
        if host == "api.tavily.com" and path == "/search":
            return self._json({"answer": "Kettles boil water.", "results": [
                {"title": "Kettle guide", "url": "https://shop.test/article/1",
                 "content": "Kettle guide.", "raw_content": ""}]})
        if host == "api.ebay.com" and path == "/identity/v1/oauth2/token":
            return self._json({"access_token": "lane-ebay-oauth", "expires_in": 7200,
                               "token_type": "Application Access Token"})
        if host == "api.ebay.com" and path == "/buy/browse/v1/item_summary/search":
            return self._json({"total": 1, "itemSummaries": [{
                "title": "Lane kettle", "legacyItemId": "123456789012",
                "itemWebUrl": "https://www.ebay.com/itm/123456789012?hash=lane",
                "price": {"value": "19.00", "currency": "EUR"},
                "condition": "Used", "buyingOptions": ["FIXED_PRICE"],
            }]})
        if host == "api.tradera.com":
            return self._json({"items": [], "totalNumberOfItems": 0})
        if host == "www.ebay.com" and path.startswith("/itm/"):
            return self._html("eBay listing", "<p>Lane kettle, used, 19 EUR.</p>")
        if host == "www.ikea.com" and path == "/se/sv/search/":
            q = (query.get("q") or [""])[0]
            return self._html(f"IKEA search {q}",
                              "<a href='https://www.ikea.com/se/sv/p/lane-kettle-10000001/'>"
                              "LANE kettle</a>")
        if host == "www.ikea.com" and path.startswith("/se/sv/p/"):
            return self._html("LANE kettle", "<p>Stainless kettle, 1.7 l.</p>")
        if host == "shop.test":
            if path.startswith("/article/"):
                n = path.rsplit("/", 1)[-1]
                return self._html(f"Article {n}",
                                  f"<p>Review body.</p><a href='https://shop.test/more/{n}'>"
                                  f"Read more about kettle {n}</a>")
            if path.startswith("/more/"):
                return self._html("More", "<p>Deeper review.</p>")
            if path == "/store":
                return self._html("Lane store", STORE)
            if path == "/store/results":
                q = (query.get("q") or [""])[0]
                return self._html(f"Results for {q}", f"<p>3 kettles match {q}.</p>")
            if path == "/spa":
                return self._html("Lane SPA", SPA)
            if path == "/api/search":
                q = (query.get("q") or [""])[0]
                return self._json({"query": q, "hits": ["kettle-a", "kettle-b"]})
        if host == "api.anthropic.com":
            return self._json({"lane": "tls-probe-ok"})
        return self._html("not found", "<p>no such page</p>", 404)

    do_GET = do_POST = do_HEAD = _route


def main() -> None:
    cert, key = sys.argv[1], sys.argv[2]
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    srv = ThreadingHTTPServer(("0.0.0.0", 443), Handler)
    srv.daemon_threads = True
    # Handshake in the handler thread, not in accept(): one slow client must
    # not stall every other connection.
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True, do_handshake_on_connect=False)
    srv.serve_forever()


if __name__ == "__main__":
    main()
