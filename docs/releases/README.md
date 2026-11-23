# Release notes

Each published OpenCJ version gets one Markdown file in this folder; agents
follow the [release notes rule](../../.github/instructions/release-notes.instructions.md). The
website shows the newest release on its homepage and all of them on its
releases page. Add the file in the same change that prepares the release.

## Format

Name the file after the version, for example `0.9.0-beta.md`. The first three
lines are required:

```markdown
# Challenges and the Top 10
Version: 0.9.0 beta
Released: 2026-11-20

One or two sentences about the release.

## Gameplay
- Challenge tiers with points
- Tutorial mode for new players
```

After the header, the site understands paragraphs, `## ` subheadings, `- `
list items and `inline code`. Other Markdown is shown as plain text. A file
with an invalid header is skipped and reported in the website generator's log.
