# Test sources and discovery

Start with the [test guide](../../docs/development/testing.md).

From the core root:

```sh
python3 -B dev-tools/scripts/test.py portable
python3 -B dev-tools/scripts/test.py list
python3 -B dev-tools/scripts/test.py list focused-gsc
```

[The catalogue](catalogue.json) is the maintained inventory of current suites,
their fixtures, commands, requirements and effects. Existing runner paths remain
stable because scripts, native includes and fixture copies refer to them.
Component-local tests remain beside their component and appear in the same
catalogue.

Only reviewed portable entry points run automatically. GSC/native sources need
their owning harness; database and engine checks require an explicitly prepared
test installation. Keep generated output in ignored `../local/`.

### Checkpoint publication

Run `python3 -B dev-tools/tests/run-checkpoint-publication.py` to exercise real GSC
publication against a temporary schema-only copy of the selected database. All
route and player rows are synthetic. The test checks repeated publication,
alternative connections, checkpoint ID and historical-statistics preservation,
rejected requirement edits, retirement, and rollback after a partial write.
The engine account is restricted to that fixture schema. The runner deletes its
schema, account and temporary credential file on exit; logs and draft snapshots
remain under ignored `dev-tools/local/`. This does not exercise a live player's
editor UI or concurrent publishers.
