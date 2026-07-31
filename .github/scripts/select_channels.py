#!/usr/bin/env python3
"""Turn .github/channels.json into a GitHub Actions build matrix.

Shared by docker-publish.yml and stack-update-watch.yml so both workflows build
the same channels from the same table. Keeping this out of the workflow YAML
also makes it testable from launcher/tests/test-channels.sh.

Environment:
  REQUESTED             channel name, or "all"/empty for every channel
  STACK_IMAGE_OVERRIDE  replace the channel's stack image; requires REQUESTED

Prints {"include": [{channel, stack_image, tags}, ...]} where `tags` is a
space-separated string. Matrix include values are kept scalar on purpose:
arrays in include entries are awkward to consume from workflow expressions.
"""

from __future__ import annotations

import json
import os
import pathlib
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
CHANNELS_FILE = REPO_ROOT / ".github" / "channels.json"


def load_channels() -> list[dict]:
    channels = json.loads(CHANNELS_FILE.read_text())
    if not isinstance(channels, list) or not channels:
        raise SystemExit(f"::error::{CHANNELS_FILE} must be a non-empty list")

    seen_tags: dict[str, str] = {}
    for entry in channels:
        for key in ("channel", "stack_image", "launcher_tags"):
            if not entry.get(key):
                raise SystemExit(f"::error::channel entry {entry!r} is missing {key}")
        for tag in entry["launcher_tags"]:
            if tag in seen_tags:
                raise SystemExit(
                    f"::error::tag {tag!r} is claimed by both "
                    f"{seen_tags[tag]!r} and {entry['channel']!r}"
                )
            seen_tags[tag] = entry["channel"]
    return channels


def main() -> int:
    channels = load_channels()
    requested = (os.environ.get("REQUESTED") or "").strip()
    override = (os.environ.get("STACK_IMAGE_OVERRIDE") or "").strip()

    if requested and requested != "all":
        channels = [c for c in channels if c["channel"] == requested]
        if not channels:
            known = ", ".join(sorted(c["channel"] for c in load_channels()))
            raise SystemExit(f"::error::unknown channel {requested!r}; known channels: {known}")
        if override:
            channels[0] = {**channels[0], "stack_image": override}
    elif override:
        raise SystemExit("::error::stack_image requires an explicit channel")

    include = [
        {
            "channel": c["channel"],
            "stack_image": c["stack_image"],
            "tags": " ".join(c["launcher_tags"]),
        }
        for c in channels
    ]
    print(json.dumps({"include": include}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
