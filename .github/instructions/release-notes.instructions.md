---
applyTo: "**"
---

# Release notes

Every published OpenCJ version has a release note in `docs/releases/`. The
website shows the newest note on its homepage and all of them on its releases
page. Follow the format in [docs/releases/README.md](../../docs/releases/README.md).

## When to write one

- A change that sets or bumps the version in `VERSION` must add
  `docs/releases/<version>.md` in the same change. Its `Version:` line must
  equal `VERSION` exactly. The `web-unit` tests fail when it is missing.
- Use the planned release date in `Released:` and update it if the release
  moves.
- Changes between releases need no note of their own. The next version's note
  summarizes the player-facing changes since the previous release; review the
  Git history since that release to collect them.

## What to write

- Write for players: what they can now do or see, in plain language. Group
  related items under `## ` headings, such as gameplay, maps, tools and community.
- Put important limitations under `## Not included yet`.
- Check every claim against the current code and documentation. Take counts,
  such as the number of checkpointed pool maps, from the live data when the note
  is written; never copy a number from an older note.
- Leave out file paths, function names, issue numbers, commit hashes, private
  installation details and names of the people running OpenCJ. Do not mention
  or link other CoDJumper websites, servers or clans.

## After publishing

A published note describes its release. Fix factual errors in it, but record
later changes in the next version's note instead of rewriting the old one.
