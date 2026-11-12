#!/usr/bin/env python3
"""Start update.yml as soon as a new limusic release has its .deb asset.

GitHub fires cron schedules hours late -- and for some repositories never fires
them at all -- so this watch polls upstream for most of a job's 6-hour limit and
watch.yml then starts the next watch. The schedule only restarts the chain after
a failure.
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
WORKFLOW = "update.yml"
# About half an hour of failed checks in a row: fail the run so it gets noticed.
MAX_FAILURES = 30


def token():
    return os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""


def fetch(url):
    headers = {"User-Agent": "limusic-bin-aur", "Accept": "application/vnd.github+json"}
    if token() and url.startswith(f"{API}/"):
        headers["Authorization"] = f"Bearer {token()}"
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()


def version_key(text):
    """Numeric tuple for a tag or pkgver, or None when it is not plain X.Y.Z."""
    match = re.fullmatch(r"v?(\d+(?:\.\d+)*)", text.strip())
    return tuple(map(int, match.group(1).split("."))) if match else None


def latest_release():
    """/releases/latest skips drafts and prereleases, which is what we track."""
    return json.loads(fetch(f"{API}/repos/{UPSTREAM}/releases/latest"))


def packaged_pkgver(repo):
    content = json.loads(fetch(f"{API}/repos/{repo}/contents/PKGBUILD?ref=main"))
    text = base64.b64decode(content["content"]).decode()
    match = re.search(r"^pkgver=(\S+)", text, re.M)
    if not match:
        raise ValueError("PKGBUILD has no pkgver")
    return match.group(1).strip("\"'")


def deb_asset(release, version):
    """The asset update.yml needs; a release can exist before its asset is up."""
    name = f"limusic_{version}_amd64.deb"
    return next((a for a in release.get("assets", []) if a["name"] == name), None)


def dispatch(repo):
    request = urllib.request.Request(
        f"{API}/repos/{repo}/actions/workflows/{WORKFLOW}/dispatches",
        data=json.dumps({"ref": "main"}).encode(), method="POST",
        headers={
            "User-Agent": "limusic-bin-aur",
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token()}",
        })
    with urllib.request.urlopen(request, timeout=60):
        pass


class Watch:
    def __init__(self, repo):
        self.repo = repo
        self.packaged = None  # newest tag the package already tracks
        self.started = set()  # tags this watch already handed to update.yml

    def poll(self):
        release = latest_release()
        tag = release["tag_name"]
        if tag == self.packaged or tag in self.started:
            return

        incoming, known = version_key(tag), version_key(packaged_pkgver(self.repo))
        if incoming is not None and known is not None and incoming <= known:
            # Already packaged (or the package is ahead): nothing to start.
            self.packaged = tag
            return

        version = tag.lstrip("v")
        if deb_asset(release, version) is None:
            # update.yml would fail on a missing source; wait for the upload.
            print(f"{tag} is published, waiting for limusic_{version}_amd64.deb", flush=True)
            return

        # Once per tag: a failed build is retried by the next watch or by
        # update.yml's own schedule.
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
