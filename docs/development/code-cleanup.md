# Keeping code cleanup reviewable

The [coding guidelines](../../dev-tools/agent-guidelines/coding-guidelines.md)
apply to first-party code across OpenCJ languages and repositories.

Use focused new commits for cleanup. Keep published feature commits intact.
Group related changes by a responsibility or feature, even when that requires
several core components. Preserve the separate engine commit and core gitlink
when engine changes are needed.

Separate these purposes where practical:

- Mechanical layout and comment wrapping with verified unchanged meaning.
- Naming, interfaces, structure and explanatory comments.
- Behavior fixes, with their trigger, result and relevant validation.

Use line history to identify the 2026 work. Repository import/move commits are
not evidence that every imported line was written by AI. Nearby human-written
code can be cleaned when it makes the same function or feature coherent; leave
unrelated upstream and generated sections alone.

Record only verified mechanical commits in `.git-blame-ignore-revs`. Use:

```sh
git blame --ignore-revs-file .git-blame-ignore-revs -- path/to/file
git log --follow -- path/to/file
```

To use the ignore list for ordinary blame commands in this checkout:

```sh
git config blame.ignoreRevsFile .git-blame-ignore-revs
```

Do not add substantive refactors, renames with changed contracts, or behavior
fixes to the ignore list. Record detailed verification in the review or private
working record; keep commit subjects concise. A syntax/token/AST comparison
supports a mechanical-change claim but does not replace relevant runtime tests.

Applied SQL migrations are checksummed history. Preserve their recorded bytes;
make any required schema/behavior change in a new migration. Improve maintained
source/templates and nearby explanations without silently invalidating an
existing migration ledger.
