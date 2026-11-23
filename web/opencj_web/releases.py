"""Read release notes from docs/releases; the format is described in that folder's README."""

import datetime
import re
from dataclasses import dataclass, field

FORMAT_DESCRIPTION_FILE = "README.md"
INLINE_CODE_PATTERN = re.compile(r"`([^`]+)`")


@dataclass(frozen=True)
class TextSegment:
    text: str
    is_code: bool


@dataclass(frozen=True)
class ReleaseBlock:
    kind: str  # "heading", "paragraph" or "list"
    segments: tuple = ()
    items: tuple = ()


@dataclass
class Release:
    title: str
    version: str
    released_on: datetime.date
    slug: str
    blocks: list = field(default_factory=list)


def split_inline_code(text):
    """Split text into plain and `code` segments, so templates can escape each one."""
    segments = []
    position = 0
    for match in INLINE_CODE_PATTERN.finditer(text):
        if match.start() > position:
            segments.append(TextSegment(text[position:match.start()], False))
        segments.append(TextSegment(match.group(1), True))
        position = match.end()
    if position < len(text):
        segments.append(TextSegment(text[position:], False))
    return tuple(segments)


def _read_header(lines, source_name):
    if len(lines) < 3:
        raise ValueError(source_name + ": needs a title, version and release date")
    if not lines[0].startswith("# "):
        raise ValueError(source_name + ": first line must be '# Title'")
    if not lines[1].startswith("Version: "):
        raise ValueError(source_name + ": second line must be 'Version: ...'")
    if not lines[2].startswith("Released: "):
        raise ValueError(source_name + ": third line must be 'Released: YYYY-MM-DD'")

    title = lines[0][2:].strip()
    version = lines[1][len("Version: "):].strip()
    date_text = lines[2][len("Released: "):].strip()
    try:
        released_on = datetime.date.fromisoformat(date_text)
    except ValueError:
        raise ValueError(source_name + ": release date must be YYYY-MM-DD") from None
    if title == "" or version == "":
        raise ValueError(source_name + ": title and version must not be empty")
    return title, version, released_on


def _read_blocks(lines):
    blocks = []
    paragraph_lines = []
    list_items = []

    def finish_paragraph():
        if paragraph_lines:
            text = " ".join(paragraph_lines)
            blocks.append(ReleaseBlock("paragraph", segments=split_inline_code(text)))
            paragraph_lines.clear()

    def finish_list():
        if list_items:
            items = tuple(split_inline_code(item) for item in list_items)
            blocks.append(ReleaseBlock("list", items=items))
            list_items.clear()

    for line in lines:
        stripped = line.strip()
        if stripped == "":
            finish_paragraph()
            finish_list()
        elif stripped.startswith("## "):
            finish_paragraph()
            finish_list()
            blocks.append(ReleaseBlock("heading", segments=split_inline_code(stripped[3:])))
        elif stripped.startswith("- "):
            finish_paragraph()
            list_items.append(stripped[2:])
        else:
            finish_list()
            paragraph_lines.append(stripped)
    finish_paragraph()
    finish_list()
    return blocks


def preview_blocks(blocks, line_budget):
    """Return (blocks, was_shortened) using at most line_budget lines.

    A paragraph, a heading and each list item count as one line. A list is cut
    between items; a heading is never left as the last block without content.
    """
    preview = []
    lines_used = 0
    for block in blocks:
        if block.kind == "list":
            remaining = line_budget - lines_used
            if remaining <= 0:
                return _drop_trailing_heading(preview), True
            if len(block.items) > remaining:
                preview.append(ReleaseBlock("list", items=block.items[:remaining]))
                return preview, True
            preview.append(block)
            lines_used += len(block.items)
        else:
            if lines_used + 1 > line_budget:
                return _drop_trailing_heading(preview), True
            preview.append(block)
            lines_used += 1
    return preview, False


def _drop_trailing_heading(blocks):
    if blocks and blocks[-1].kind == "heading":
        return blocks[:-1]
    return blocks


def parse_release(text, source_name):
    """Parse one release note; raise ValueError naming the file when the header is invalid."""
    lines = text.splitlines()
    title, version, released_on = _read_header(lines, source_name)
    slug = re.sub(r"[^a-z0-9]+", "-", version.lower()).strip("-")
    if slug == "":
        raise ValueError(source_name + ": version has no letters or digits")
    return Release(title, version, released_on, slug, _read_blocks(lines[3:]))


def read_releases(releases_dir):
    """Return valid releases newest first, plus a message for each file that could not be read."""
    releases = []
    problems = []
    if not releases_dir.is_dir():
        return releases, ["Release notes folder is missing: " + str(releases_dir)]
    for note_path in sorted(releases_dir.glob("*.md")):
        if note_path.name == FORMAT_DESCRIPTION_FILE:
            continue
        try:
            releases.append(parse_release(note_path.read_text(encoding="utf-8"), note_path.name))
        except (OSError, UnicodeDecodeError, ValueError) as error:
            problems.append(str(error))
    releases.sort(key=lambda release: (release.released_on, release.version), reverse=True)
    return releases, problems
