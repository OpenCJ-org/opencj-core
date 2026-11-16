# Contributing

Keep changes focused on one purpose and use concise commit subjects. Include
relevant verification and any behavior changes in the review description.
Read [AGENTS.md](AGENTS.md) and the [test guide](dev-tools/docs/testing.md).

Work on a branch in core. Changes to scripts, migrations, assets, tooling and
native extensions can be reviewed together. Keep engine changes in the relevant
submodule and record its commit in core. Preserve existing license notices.

Keep configuration, data, captures and local evidence under ignored `local/`
directories. Use synthetic fixtures for shareable tests. Review `git diff
--cached` before committing; ignore rules do not protect already-tracked files.

Before publication, review the exact branch history and run the publication
checks. Do not push local recovery refs, stashes, operator notes or backups.
Repository consolidation does not authorize publishing private working files.
