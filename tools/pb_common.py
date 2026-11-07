"""Tiny PocketBase admin client (stdlib only). Credentials come from the environment:

    export PB_URL=https://novalleyduck.novafox.at
    export PB_EMAIL=...        # superuser
    export PB_PASSWORD=...

Never commit credentials. The iOS app never uses these: it only reads public collections.
"""
import json
import os
import sys
import urllib.error
import urllib.request

PB_URL = os.environ.get("PB_URL", "https://novalleyduck.novafox.at").rstrip("/")


class PBError(RuntimeError):
    def __init__(self, status, body):
        super().__init__(f"HTTP {status}: {body}")
        self.status, self.body = status, body


class PocketBase:
    def __init__(self, url=PB_URL):
        self.url, self.token = url, None

    def request(self, method, path, body=None, timeout=60):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.url + path, data=data, method=method)
        req.add_header("Content-Type", "application/json")
        req.add_header("User-Agent", "haltmal-tools/1.0")   # Cloudflare blocks Python-urllib
        if self.token:
            req.add_header("Authorization", self.token)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                raw = r.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as e:
            raise PBError(e.code, e.read().decode(errors="replace")) from None

    def login(self):
        email, pw = os.environ.get("PB_EMAIL"), os.environ.get("PB_PASSWORD")
        if not email or not pw:
            sys.exit("Set PB_EMAIL and PB_PASSWORD (superuser) in the environment.")
        r = self.request("POST", "/api/collections/_superusers/auth-with-password",
                         {"identity": email, "password": pw})
        self.token = r["token"]
        return self

    def collection(self, name):
        try:
            return self.request("GET", f"/api/collections/{name}")
        except PBError as e:
            if e.status == 404:
                return None
            raise

    def batch_upsert(self, collection, records, chunk=100):
        """Upsert records (each with an explicit 15-char id) through the batch API."""
        for i in range(0, len(records), chunk):
            part = records[i:i + chunk]
            self.request("POST", "/api/batch", {"requests": [
                {"method": "PUT", "url": f"/api/collections/{collection}/records", "body": r}
                for r in part]}, timeout=120)
            print(f"  {collection}: {min(i + chunk, len(records))}/{len(records)}", end="\r")
        if records:
            print()
