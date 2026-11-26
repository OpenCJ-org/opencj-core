---
applyTo: "**"
---

# File placement and publication privacy

Apply this rule before adding, moving or expanding any file or entry, including
documentation, scripts, fixtures, examples, configuration and commit messages.
First decide its purpose, its correct folder, whether its contents can be public,
and whether Git should track it. Review new entries in an existing public file
just as carefully as new files.

## Use the established folders

- Put shared active agent instructions in `.github/copilot-instructions.md`
  and scoped instructions in `.github/instructions/*.instructions.md`, with
  the appropriate `applyTo` scope. Keep `AGENTS.md` entry points small and
  link to those instructions.
- Put installation guides in `docs/setup/`, build and testing methods in
  `docs/development/`, current behavior in `docs/reference/`, and reusable
  operating procedures in `docs/operations/`.
- Put accepted technical decisions in `docs/decisions/`, proposed designs in
  `docs/proposals/`, and reusable research findings in `docs/research/`.
  State whether a design is accepted, proposed or superseded. Keep personal
  investigation diaries and session records private.
- Put reusable development scripts in `dev-tools/scripts/`, tests and
  reviewed synthetic fixtures in `dev-tools/tests/`, and component code or
  assets in the relevant component. Follow an existing narrower folder when
  one fits. Do not collect unrelated files in the root or create a catch-all
  documentation folder.
- Keep the active shared coding policy in `dev-tools/agent-guidelines/`.
  Put unapproved future proposals in its `drafts/` directory; proposals do not
  override the active policy until approved.

The documentation folders above are at the core repository root. Do not
recreate their old locations under `dev-tools/docs/`. Update the relevant
index and links when adding or moving public documentation.

## Decide what may be public

Public files should contain reusable project information and reviewed examples.
Keep personal installation paths, private accounts and contact details,
credentials, player data, local setup scripts, raw recordings and captures,
test output, deployment receipts, session notes and recovery records private.
Preserve required public contributor attribution and third-party notices.

For mixed material, separate the reusable procedure or technical finding from
the private record. Use configurable paths and synthetic examples in the public
part. Replacing a person's name with a generic name does not make their
operational record suitable for publication. Preserve private originals in the
established private archive outside the checkout.

Use ignored `dev-tools/local/` for disposable local output and local working
material when appropriate. Keep durable private archives outside the checkout.
Consult private operator instructions for actual locations; do not copy those
locations into public documentation. If a file's publication status is unclear,
keep it private while resolving the uncertainty.

## Licensing and attribution

When adding, reusing, modifying or packaging third-party code, artwork, audio,
fonts, datasets or tools, identify the original source and applicable license.
Keep required copyright notices, license text or links, creator attribution and
modification notices with the material. Update its source/version/hash record
when the input changes.

Follow the existing notice folders and asset catalogues. Include the required
notices in distributed archives, binaries and asset exports as well as in the
source checkout; verify their presence in the resulting package. Keep notices
accurate when material is changed or removed, without dropping notices still
required by retained content.

Do not assume that a public download, a user-supplied file or the root project
license grants additional rights to third-party material. Attribution alone
does not replace license conditions. If terms or provenance are unclear, record
the uncertainty and resolve it before declaring the material cleared for
publication; do not invent a license or silently relicense it.

Licensing requirements apply alongside the active coding guidelines.

## Make tracking match the decision

Track reusable source, documentation, sanitized example configuration and
necessary reviewed fixtures. Ignore private configuration and generated output.
Use narrow, purpose-specific patterns in the appropriate `.gitignore`; use
`.git/info/exclude` for exceptional exclusions that apply only to this checkout.
Do not hide entire file types or source folders to avoid reviewing their contents.

Before staging, inspect the complete diff, including new files and metadata.
The `private-paths` portable check, also run by the `.githooks/pre-commit` hook
(`git config core.hooksPath .githooks`), rejects personal user directories and the
identifiers listed in the untracked `info/private-identifiers` file of the Git
directory.
Check that private files are ignored with `git check-ignore -v`, and check
whether they are already tracked with `git ls-files -- <path>`. Do not force-add
private material. An ignore rule neither untracks an existing file nor removes
it from Git history. If private information was already tracked, preserve a
private recovery copy, remove it from the intended public tree, and review all
history that would be published before considering the issue resolved.

Use an approved public commit identity, such as a verified GitHub no-reply
address or the contributor's approved anonymous address. Do not put private
details in commit messages, branch names or tag descriptions.

Never publish private recovery refs, old unsanitized branches or stashes.
Inspect the exact branches, tags and submodule commits intended for publication;
a clean working tree alone is insufficient. Do not use mirror-push.
