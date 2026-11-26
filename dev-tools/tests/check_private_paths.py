"""Reject tracked text that names a personal user directory or a private identifier.

Checks every file Git tracks or has staged, so it also guards a commit when run
from the pre-commit hook in `.githooks/`. Two kinds of text are refused:

- user profile paths with a real account name: Windows `<drive>:\\Users\\<name>`,
  macOS `/Users/<name>/` and Linux `/home/<name>/`. Placeholders such as `<user>`
  or `%USERNAME%` are allowed;
- literal identifiers listed, one per line, in the untracked file at
  `git rev-parse --git-path info/private-identifiers` (for example an account
  name). That file stays local; lines starting with `#` are comments.
"""

import re
import subprocess
import sys
from pathlib import Path

# Generic names used in documentation and by CI runners, not personal accounts.
ALLOWED_ACCOUNT_NAMES = {"user", "username", "users", "public", "default", "example", "runner", "you"}
WINDOWS_PROFILE = re.compile(r"\b[A-Za-z]:[\\/]+(?:Users|Documents and Settings)[\\/]+([^\\/\s\"'`<>%$]+)",
                             re.IGNORECASE)
POSIX_PROFILE = re.compile(r"(?<![\w.])/(?:home|Users)/([A-Za-z0-9_.-]+)/")
# Files larger than this are not text sources worth scanning line by line.
MAX_TEXT_BYTES = 4 * 1024 * 1024
BINARY_SNIFF_BYTES = 8192


def git(*arguments):
    return subprocess.run(["git", *arguments], check=True, capture_output=True).stdout


def private_identifiers():
    path = Path(git("rev-parse", "--git-path", "info/private-identifiers").decode().strip())
    if not path.is_file():
        return []
    names = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            names.append(line.lower())
    return names


def text_lines(path):
    """The file's lines, or nothing for binary, large or missing files."""
    try:
        if path.stat().st_size > MAX_TEXT_BYTES:
            return []
        data = path.read_bytes()
    except OSError:
        return []
    if b"\0" in data[:BINARY_SNIFF_BYTES]:
        return []
    return data.decode("utf-8", errors="replace").splitlines()


def findings(relative_path, lines, identifiers):
    for number, line in enumerate(lines, start=1):
        for pattern in (WINDOWS_PROFILE, POSIX_PROFILE):
            for match in pattern.finditer(line):
                if match.group(1).lower() not in ALLOWED_ACCOUNT_NAMES:
                    yield f"{relative_path}:{number}: personal user directory"
        lowered = line.lower()
        for identifier in identifiers:
            if identifier in lowered:
                yield f"{relative_path}:{number}: private identifier"


def main():
    root = Path(git("rev-parse", "--show-toplevel").decode().strip())
    identifiers = private_identifiers()
    tracked = git("-C", str(root), "ls-files", "-z", "--cached").decode().split("\0")
    problems = []
    for relative_path in filter(None, tracked):
        problems.extend(findings(relative_path, text_lines(root / relative_path), identifiers))
    if problems:
        # The matched text itself is not printed, so the report cannot leak it again.
        print("Private text in tracked files; replace it with a placeholder such as <user>:")
        print("\n".join(problems))
        return 1
    print(f"No personal paths or private identifiers in {len(tracked) - 1} tracked files.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
