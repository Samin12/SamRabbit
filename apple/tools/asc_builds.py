#!/usr/bin/env python3
"""The latest SamRabbit builds on App Store Connect and whether TestFlight offers them yet.

    /usr/bin/python3 -I apple/tools/asc_builds.py [--wait BUILD] [--limit 5]

Uses the App Store Connect API key testflight.sh uses (~/.config/samrabbit/asc/key.json, or SAMRABBIT_ASC_KEY), signs
its short-lived ES256 token with /usr/bin/openssl (stdlib only otherwise) and prints, newest first, each build's
number, processing state and internal TestFlight state. ``--wait BUILD`` polls until that build is processed and
ready for internal testing (exit 0), failed or invalid (exit 1), or 30 minutes passed (exit 2). Never prints the key.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = "com.samrabbit.mobile"


def _b64(raw: bytes) -> bytes:
    return base64.urlsafe_b64encode(raw).rstrip(b"=")


def _raw_signature(der: bytes) -> bytes:
    """An ECDSA DER signature as JWT's r||s (32 bytes each)."""
    at = 3 if der[1] & 0x80 else 2
    parts = []
    for _ in range(2):
        if der[at] != 2:
            raise ValueError("not a DER ECDSA signature")
        size = der[at + 1]
        parts.append(der[at + 2:at + 2 + size].lstrip(b"\0").rjust(32, b"\0"))
        at += 2 + size
    return b"".join(parts)


def token(key_json: str) -> str:
    with open(key_json, encoding="utf-8") as handle:
        key = json.load(handle)
    now = int(time.time())
    head = _b64(json.dumps({"alg": "ES256", "kid": key["keyId"], "typ": "JWT"}).encode())
    body = _b64(json.dumps({"iss": key["issuerId"], "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}).encode())
    message = head + b"." + body
    der = subprocess.run(["/usr/bin/openssl", "dgst", "-sha256", "-sign",
                          os.path.join(os.path.dirname(key_json), key["keyFile"])],
                         input=message, capture_output=True, check=True).stdout
    return (message + b"." + _b64(_raw_signature(der))).decode()


def get(path: str, bearer: str) -> dict:
    request = urllib.request.Request(API + path, headers={"Authorization": "Bearer " + bearer})
    with urllib.request.urlopen(request, timeout=30) as answer:
        return json.load(answer)


def builds(key_json: str, limit: int) -> list:
    bearer = token(key_json)
    app = get("/apps?" + urllib.parse.urlencode({"filter[bundleId]": BUNDLE_ID, "fields[apps]": "bundleId"}), bearer)
    app_id = app["data"][0]["id"]
    found = get("/builds?" + urllib.parse.urlencode({
        "filter[app]": app_id, "sort": "-uploadedDate", "limit": str(limit), "include": "buildBetaDetail",
        "fields[builds]": "version,processingState,uploadedDate,expired,buildBetaDetail",
        "fields[buildBetaDetails]": "internalBuildState"}), bearer)
    beta = {item["id"]: item["attributes"] for item in found.get("included", []) if item["type"] == "buildBetaDetails"}
    rows = []
    for item in found.get("data", []):
        detail = (item.get("relationships", {}).get("buildBetaDetail", {}).get("data") or {}).get("id")
        rows.append({"build": item["attributes"]["version"], "processing": item["attributes"]["processingState"],
                     "testflight": beta.get(detail, {}).get("internalBuildState"),
                     "uploaded": item["attributes"].get("uploadedDate")})
    return rows


def main(argv: list) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--wait", metavar="BUILD")
    parser.add_argument("--limit", type=int, default=5)
    options = parser.parse_args(argv)
    key_json = os.path.expanduser(os.environ.get("SAMRABBIT_ASC_KEY") or "~/.config/samrabbit/asc/key.json")
    deadline = time.monotonic() + 30 * 60
    while True:
        try:
            rows = builds(key_json, options.limit)
        except (urllib.error.URLError, OSError, ValueError, KeyError, IndexError) as error:
            print(f"asc_builds: {type(error).__name__}: {error}", file=sys.stderr)
            rows = []
        if not options.wait:
            for row in rows:
                print(f"{row['build']}  {row['processing']:<11} {row['testflight'] or '-':<26} {row['uploaded']}")
            return 0
        match = next((row for row in rows if row["build"] == options.wait), None)
        if match:
            if match["processing"] in ("FAILED", "INVALID"):
                print(f"{options.wait}: {match['processing']}")
                return 1
            if match["processing"] == "VALID" and match["testflight"] == "IN_BETA_TESTING":
                print(f"{options.wait}: ready in TestFlight")
                return 0
        if time.monotonic() > deadline:
            print(f"{options.wait}: {match['processing'] + '/' + str(match['testflight']) if match else 'not seen'}"
                  " after 30 minutes")
            return 2
        time.sleep(30)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
