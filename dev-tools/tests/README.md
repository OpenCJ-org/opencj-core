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
