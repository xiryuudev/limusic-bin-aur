#!/usr/bin/env python3
"""Start update-prerelease.yml as soon as a newer upstream release exists.

The prerelease channel follows the newest upstream release, rc or final: once a
final release ships, this package follows it too, so users are never left on an
older version.

GitHub fires cron schedules hours late and on some repositories never, so this
watch polls upstream for most of a job's 6-hour limit; watch-prerelease.yml then
starts the next watch.
"""
import argparse
import base64
import json
import os
import re
import time
import urllib.request

API = "https://api.github.com"
UPSTREAM = "SimoHypers/limusic"
WORKFLOW = "update-prerelease.yml"
# About half an hour of failed checks in a row: fail the run so it gets noticed.
MAX_FAILURES = 30


def token():
    return os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""


def fetch(url):
    headers = {"User-Agent": "limusic-bin-prerelease-aur", "Accept": "application/vnd.github+json"}
    if token() and url.startswith(f"{API}/"):
        headers["Authorization"] = f"Bearer {token()}"
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()


def version_key(text):
    """Sortable key for X.Y.Z and X.Y.Z-rc.N; an rc sorts before its final."""
    match = re.fullmatch(r"v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-?rc\.?(\d+))?", text.strip(), re.I)
    if not match:
        return None
    major, minor, patch, rc = match.groups()
    return (
        int(major),
        int(minor or 0),
        int(patch or 0),
        # a final release outranks any rc of the same X.Y.Z
        0 if rc is not None else 1,
        int(rc) if rc else 0,
    )


def newest_release():
    releases = json.loads(fetch(f"{API}/repos/{UPSTREAM}/releases?per_page=100"))
    versioned = [r for r in releases
                 if not r.get("draft") and version_key(r["tag_name"]) is not None]
    if not versioned:
        raise ValueError("no versioned upstream releases found")
    return max(versioned, key=lambda r: version_key(r["tag_name"]))


def packaged_pkgver(repo):
    content = json.loads(fetch(f"{API}/repos/{repo}/contents/PKGBUILD?ref=prerelease"))
    text = base64.b64decode(content["content"]).decode()
    match = re.search(r"^pkgver=(\S+)", text, re.M)
    if not match:
        raise ValueError("PKGBUILD has no pkgver")
    return match.group(1).strip("\"'")


def asset_present(release, version):
    """Every release ships an AppImage, rc and final alike."""
    name = f"limusic_{version}_amd64.AppImage"
    return any(a["name"] == name for a in release.get("assets", []))


def dispatch(repo):
    request = urllib.request.Request(
        f"{API}/repos/{repo}/actions/workflows/{WORKFLOW}/dispatches",
        data=json.dumps({"ref": os.environ.get("DISPATCH_REF", "main")}).encode(), method="POST",
        headers={
            "User-Agent": "limusic-bin-prerelease-aur",
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token()}",
        })
    with urllib.request.urlopen(request, timeout=60):
        pass


class Watch:
    def __init__(self, repo):
        self.repo = repo
        self.packaged = None  # newest tag already known to be packaged
        self.started = set()  # tags this watch already handed to update

    def poll(self):
        release = newest_release()
        tag = release["tag_name"]
        if tag == self.packaged or tag in self.started:
            return

        incoming = version_key(tag)
        known = version_key(packaged_pkgver(self.repo))
        if incoming is not None and known is not None and incoming <= known:
            # Already packaged (or the package is ahead): nothing to start.
            self.packaged = tag
            return

        version = tag.lstrip("v")
        if not asset_present(release, version):
            # update would fail without the source; wait for the upload.
            print(f"{tag} is published, waiting for limusic_{version}_amd64.AppImage", flush=True)
            return

        # Once per tag: a failed build is retried by the next watch or by the
        # update workflow's own schedule.
        dispatch(self.repo)
        self.started.add(tag)
        print(f"Started {WORKFLOW} for {tag}", flush=True)


def watch_for(watch, minutes, interval):
    deadline = time.monotonic() + minutes * 60
    failures = 0
    while True:
        try:
            watch.poll()
            failures = 0
        except (OSError, ValueError, KeyError) as error:
            failures += 1
            print(f"::warning::Release check failed: {error}", flush=True)
            if failures >= MAX_FAILURES:
                raise SystemExit(f"{failures} release checks failed in a row")
        if time.monotonic() + interval >= deadline:
            return
        time.sleep(interval)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--minutes", type=float, default=340, help="How long to watch")
    parser.add_argument("--interval", type=float, default=60, help="Seconds between checks")
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY"),
                        help="Packaging repository, owner/name (default: $GITHUB_REPOSITORY)")
    parser.add_argument("--once", action="store_true", help="Poll once and exit (for testing)")
    args = parser.parse_args()
    if not args.repo:
        parser.error("--repo is required outside GitHub Actions")
    if args.once:
        Watch(args.repo).poll()
        return
    watch_for(Watch(args.repo), args.minutes, args.interval)


if __name__ == "__main__":
    main()
