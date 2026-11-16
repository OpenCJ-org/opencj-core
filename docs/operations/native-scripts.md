# Deploy native and GSC changes together

GSC can call new native functions only after a matching engine is deployed.
If a running server reads directly from an edited checkout, an automatic map
rotation can load newer scripts against its old executable.

## Prepare a compatible release

1. Identify the running executable and the exact scripts it loads.
2. Before an API-dependent edit, pin the runtime to a separate known-good script
   release. Do not replace existing pins without checking what they contain.
3. Build a separate candidate executable. The legacy engine makefile does not
   track every header dependency, so rebuild affected objects or perform a clean
   candidate build when headers change.
4. Create a release copy containing only intended script changes. Validate that
   exact binary/script pair on an isolated server.
5. Include matching compiled client assets and database migrations when the
   changed interface requires them. Retain rollback material privately.

If validation is incomplete, leave the running release pinned to its known-good
version. Do not switch it to an unfinished working tree.

## Apply and verify

Capture the current map and connected players. Follow the operator's maintenance
policy before stopping the OpenCJ service. Apply the tested executable, script
release and associated assets together; preserve credentials and unrelated
configuration. Restart only the intended service, restore its captured map,
and inspect startup and a representative feature.

A full server-process restart is required when loaded client fastfile metadata
changes; see [client assets](client-assets.md). A map restart alone is not proof
that cached package information was refreshed.

Record deployed revisions, hashes, runtime links and rollback locations in
private operating records. Later deployments must inspect and preserve unrelated
release pins. Build and test work should never silently deploy unfinished code.
