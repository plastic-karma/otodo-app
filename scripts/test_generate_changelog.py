import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class ChangelogTests(unittest.TestCase):
    def test_feature_entries_use_commit_times_and_exclude_maintenance(self) -> None:
        generator = Path(__file__).with_name("generate_changelog.py").resolve()
        with tempfile.TemporaryDirectory(prefix="otodo-changelog-") as directory:
            repository = Path(directory)
            environment = {
                **os.environ,
                "GIT_AUTHOR_NAME": "Changelog test",
                "GIT_AUTHOR_EMAIL": "changelog@example.invalid",
                "GIT_COMMITTER_NAME": "Changelog test",
                "GIT_COMMITTER_EMAIL": "changelog@example.invalid",
            }
            subprocess.run(
                ["git", "init", "--quiet", "--initial-branch=main", str(repository)],
                check=True,
                env=environment,
            )
            features = []
            changes = [
                ("First capture feature", "2026-09-01T10:00:00+00:00", True),
                ("Upgrade CI artifact uploads", "2026-09-05T11:00:00+00:00", False),
                ('Second feature Ω "quoted"', "2026-09-03T09:00:00+00:00", True),
                ("Backported capture fix", "2026-08-31T12:00:00+00:00", True),
            ]
            for title, date, is_feature in changes:
                subprocess.run(
                    [
                        "git", "-C", str(repository),
                        "-c", "core.hooksPath=" + os.devnull,
                        "-c", "commit.gpgsign=false",
                        "commit", "--quiet", "--allow-empty", "-m", title,
                        "-m", "Changelog: feature" if is_feature else "",
                    ],
                    check=True,
                    env={**environment, "GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date},
                )
                if is_feature:
                    commit = subprocess.check_output(
                        ["git", "-C", str(repository), "rev-parse", "HEAD"],
                        text=True,
                        env=environment,
                    ).strip()
                    features.append({
                        "commit": commit,
                        "timestamp": int(datetime.datetime.fromisoformat(date).timestamp()),
                        "title": title,
                    })

            output = repository / "Changelog.json"
            subprocess.run(
                [sys.executable, str(generator), str(output)],
                check=True,
                env={**environment, "GIT_DIR": str(repository / ".git")},
            )
            self.assertEqual(
                json.loads(output.read_text(encoding="utf-8")),
                [features[1], features[0], features[2]],
            )


if __name__ == "__main__":
    unittest.main()
