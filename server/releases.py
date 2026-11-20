"""Which version of the Mac app is current, and where its installer is.

Installers are published as GitHub releases (scripts/release.sh). The newest one is looked up at most every half
hour; installed Macs ask this service, compare with what they run, and update themselves. A Mac does not take the
service's word for the file: it only installs a package notarised by Apple and signed by the same developer as the
helper already running on it.
"""
import json
import logging
import os
import re
import threading
import time
import urllib.request

CHECK_EVERY_SECONDS = 30 * 60
INSTALLER_NAME = "YoungWonksFocus.pkg"
_lock = threading.Lock()
_cache = {"at": 0.0, "value": {}}


def number(version: str) -> tuple:
    """'v0.10.2' -> (0, 10, 2), so versions compare as numbers, not text."""
    return tuple(int(part) for part in re.findall(r"\d+", version or "")[:4])


def newer(candidate: str, than: str) -> bool:
    return bool(number(candidate)) and number(candidate) > number(than)


def fetch(repo: str) -> dict:
    asked = urllib.request.Request(f"https://api.github.com/repos/{repo}/releases/latest",
                                   headers={"Accept": "application/vnd.github+json", "User-Agent": "focus-service"})
    with urllib.request.urlopen(asked, timeout=10) as reply:
        release = json.load(reply)
    for asset in release.get("assets", []):
        if asset.get("name") == INSTALLER_NAME:
            return {"version": ".".join(str(n) for n in number(release.get("tag_name", ""))), "url": asset["browser_download_url"]}
    return {}


def latest() -> dict:
    """{'version': '0.3.1', 'url': 'https://github.com/...pkg'}, or {} when nothing is published yet."""
    repo = os.environ.get("RELEASES_REPO", "vraina/focus")
    with _lock:
        if time.time() - _cache["at"] > CHECK_EVERY_SECONDS:
            _cache["at"] = time.time()
            try:
                _cache["value"] = fetch(repo)
            except Exception as error:  # GitHub down or no release yet: keep what was known
                logging.info("could not look up the latest release: %s", error)
        return dict(_cache["value"])
