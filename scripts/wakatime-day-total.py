#!/usr/bin/env python3
"""Print WakaTime coding time for one calendar day, in seconds.

Usage: wakatime-day-total.py YYYY-MM-DD

Past days are read from the summaries endpoint, not `wakatime-cli --today`:
the CLI returns an empty line with exit 0 on some installs (issue #1414) and
can only answer for the current day, so a Day Close after midnight got the
wrong day (issue #1398).

WakaTime now rejects plugin API keys (`waka_...`) on the summaries endpoint
with HTTP 403 ("API Keys are only for plugins, use your personal oauth token").
The statusbar endpoint still accepts them and, unlike the CLI output seen in
issue #859, includes the AI Coding category in its grand total. So the current
day is read from the statusbar endpoint; a past day needs an OAuth token in
WAKATIME_OAUTH_TOKEN (sent as Bearer) and otherwise reports the real reason.

Exit 0: stdout is the total seconds (integer, > 0).
Exit 3: no value; stdout is a short reason in parentheses for the caller to
show as is. Never fabricates a number.
"""

import base64
import configparser
import json
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import date

ENV_FILES = ("~/.config/aist/env", "~/.iwe/.exocortex.env", "~/.wakatime.env")
KEY_LINE = re.compile(
    r"^(?:export\s+)?WAKATIME_API_KEY\s*=\s*([\"']?)([^\"'\n]+)\1\s*$"
)


def no_value(reason):
    print(f"({reason})")
    sys.exit(3)


def key_from_env_file(path):
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                m = KEY_LINE.match(line)
                if m:
                    return m.group(2).strip()
    except (OSError, UnicodeError) as exc:
        print(f"wakatime-day-total: cannot read {path}: {exc}", file=sys.stderr)
    return None


def find_api_key():
    key = os.environ.get("WAKATIME_API_KEY", "").strip()
    if key:
        return key
    for raw in ENV_FILES:
        path = os.path.expanduser(raw)
        if os.path.isfile(path):
            key = key_from_env_file(path)
            if key:
                return key
    cfg_path = os.path.expanduser("~/.wakatime.cfg")
    if os.path.isfile(cfg_path):
        cfg = configparser.ConfigParser()
        try:
            cfg.read(cfg_path, encoding="utf-8")
            return cfg.get("settings", "api_key", fallback=None)
        except (OSError, configparser.Error) as exc:
            print(f"wakatime-day-total: cannot read {cfg_path}: {exc}", file=sys.stderr)
    return None


def day_seconds(body, target):
    days = body.get("data") if isinstance(body, dict) else None
    if not isinstance(days, list):
        return None
    entry = next(
        (
            d
            for d in days
            if isinstance(d, dict) and d.get("range", {}).get("date") == target
        ),
        None,
    )
    total = entry.get("grand_total") if isinstance(entry, dict) else None
    seconds = total.get("total_seconds") if isinstance(total, dict) else None
    if isinstance(seconds, bool) or not isinstance(seconds, (int, float)):
        return None
    return seconds


def main():
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        sys.exit(2)
    target = sys.argv[1]
    try:
        date.fromisoformat(target)
    except ValueError:
        print(f"wakatime-day-total: not a YYYY-MM-DD date: {target!r}", file=sys.stderr)
        sys.exit(2)

    is_today = target == date.today().isoformat()
    oauth_token = os.environ.get("WAKATIME_OAUTH_TOKEN", "").strip()
    if oauth_token and not is_today:
        headers = {"Authorization": f"Bearer {oauth_token}"}
    else:
        api_key = find_api_key()
        if not api_key:
            no_value(
                "WAKATIME_API_KEY not found — use Neon fallback: domain_event coding_time"
            )
        auth = base64.b64encode(f"{api_key}:".encode()).decode()
        headers = {"Authorization": f"Basic {auth}"}
    headers["Accept"] = "application/json"

    if is_today and not oauth_token:
        url = "https://wakatime.com/api/v1/users/current/status_bar/today"
    else:
        url = f"https://wakatime.com/api/v1/users/current/summaries?start={target}&end={target}"
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        if exc.code == 403 and not is_today:
            no_value(
                "WakaTime refuses plugin API keys for past days (HTTP 403); "
                "set WAKATIME_OAUTH_TOKEN or use Neon fallback: domain_event coding_time"
            )
        no_value(
            f"WakaTime API error: {exc} — use Neon fallback: domain_event coding_time"
        )
    # OSError covers URLError and socket timeouts on every Python 3 version;
    # ValueError covers JSONDecodeError and UnicodeDecodeError.
    except (OSError, ValueError) as exc:
        no_value(
            f"WakaTime API error: {exc} — use Neon fallback: domain_event coding_time"
        )

    if is_today and not oauth_token:
        # statusbar shape: {"data": {"grand_total": {"total_seconds": N}}}
        total = body.get("data", {}).get("grand_total") if isinstance(body, dict) else None
        seconds = total.get("total_seconds") if isinstance(total, dict) else None
        if isinstance(seconds, bool) or not isinstance(seconds, (int, float)):
            seconds = None
    else:
        seconds = day_seconds(body, target)
    if seconds is None:
        no_value(f"no WakaTime entry for {target}")
    if seconds <= 0:
        no_value(f"no positive WakaTime time for {target}")
    print(int(seconds))


if __name__ == "__main__":
    main()
