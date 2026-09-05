#!/usr/bin/env python3
"""Bundle product changelog entries from the checked-out commit's local history."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

REPOSITORY = Path(__file__).resolve().parents[2]

# Product commits from before the Changelog: feature trailer was introduced.
# Keep this historical set fixed; new product entries opt in with the trailer.
LEGACY_FEATURE_COMMITS = frozenset({
    "3e53f515cb8bdeb3b2c2997ae220d28ec28350a8",
    "550ed87d4503f19e23af628ae37d751856344594",
    "39eb0e8bd1955a928efd89c0f2540f868ca92e4b",
    "9c2e1e15cc40f77019fae4ced7c79fc5647dfa94",
    "5febb60ea30bfeb109e95c09383644ff3cb4e3f4",
    "0771ce482d7d71d3771d60b6ce5250869203ff62",
    "665a3e9107ada8742ff549fa6424c2d0eb8815ef",
    "b3129f7a0ffd99e1fb41391a791bfa6c4792a535",
    "da712befb3ac9cab07d269fd887a574f48d53670",
    "02edbb03c1280ce3b0ca330d6e99db29b984e50d",
    "596b43be3d2e7575c1ecee76becc0b1a79960b45",
    "90f37e4514c4cd23a14836e1e9c2d7ebf3b1387c",
    "30595983cbc80293e7449b867dad6b9d32e67470",
    "b194b3e3e24819e40f3459bef65af7ac98b21f1b",
    "cfe33971124ff5c750d7107711c87274f599d043",
    "23d534323268347c662537d2194a5d2631a76355",
    "3390ce09dcc09b25b73c6c2d3d7962c42642b2b7",
    "9ceb41f7c9ba1f72c55136ba9ef309a606711ea1",
    "c00665ad77a054d2270a603ec624b7cb670f659a",
    "b14fd6294b02a5eb83e4ff2160e9d05592768f93",
    "6e280ac0a9b01b0e544f6c850385aa64521a324d",
    "956f1c7ecca8de2199ed83f029c67b5ffb0a03c0",
    "627f4282e6746745c272543bac744d2f9b319b93",
    "7abb1e59a3afcaeea19c9e9a7d697008b613cb5f",
    "1b5f48c8f53c0db090956926db642d6a96caf96d",
})


def git(*arguments: str) -> str:
    result = subprocess.run(
        ["git", "--no-replace-objects", "-C", str(REPOSITORY), *arguments],
        # Also block transports on older Git versions without GIT_NO_LAZY_FETCH.
        env={**os.environ, "GIT_NO_LAZY_FETCH": "1", "GIT_ALLOW_PROTOCOL": ""},
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"Cannot read local Git history: {detail}")
    return result.stdout.decode("utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="Destination Changelog.json path")
    arguments = parser.parse_args()

    if git("rev-parse", "--is-shallow-repository").strip() != "false":
        raise RuntimeError(
            "Complete Git history is required. Run git fetch --unshallow before "
            "building, or use actions/checkout with fetch-depth: 0. "
            "The build does not fetch history."
        )

    history = git(
        "log",
        "--no-merges",
        "--topo-order",
        "--no-decorate",
        "--no-notes",
        "--no-show-signature",
        "--encoding=UTF-8",
        "--format=%H%x00%ct%x00%s%x00%(trailers:key=Changelog,valueonly)",
        "-z",
        "HEAD",
        "--",
    )
    fields = history.removesuffix("\0").split("\0") if history else []
    if len(fields) % 4:
        raise RuntimeError("Git returned malformed changelog records")
    entries = [
        {"commit": fields[index], "timestamp": int(fields[index + 1]), "title": fields[index + 2]}
        for index in range(0, len(fields), 4)
        if fields[index] in LEGACY_FEATURE_COMMITS
        or any(value.strip().casefold() == "feature" for value in fields[index + 3].splitlines())
    ]
    # Python's stable sort preserves Git's topological traversal order for ties.
    entries.sort(key=lambda entry: entry["timestamp"], reverse=True)
    content = json.dumps(entries, ensure_ascii=False, indent=2) + "\n"
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(content, encoding="utf-8")


if __name__ == "__main__":
    try:
        main()
    except (OSError, UnicodeError, ValueError, RuntimeError) as error:
        print(f"error: Cannot generate Changelog.json: {error}", file=sys.stderr)
        raise SystemExit(1)
