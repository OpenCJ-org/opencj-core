# OpenCJ documentation

| Folder | Contents |
| --- | --- |
| [Setup](setup/development.md) | Prerequisites, configuration and first run |
| [Development](development/testing.md) | Tests, build methods and repository layout |
| Reference | Current [gameplay](reference/gameplay/camera.md), [UI](reference/ui/commands.md), [checkpoints](reference/checkpoints/editor.md), [demos](reference/demos/viewing.md), [database](reference/database/data-model.md), [native](reference/native/helpers.md) and [map catalogue](reference/maps/catalogue.md) behavior |
| [Operations](operations/database.md) | Reusable database, native/script and client-asset procedures |
| [Decisions](decisions/spectator-fps.md) | Accepted choices and their reasons |
| [Proposals](proposals/map-download-authorization.md) | Unimplemented designs |
| [Research](research/anti-overlay.md) | Exploratory findings, not implementation instructions |

Source paths written inline are relative to the repository root unless a command
states another working directory. Machine locations come from local arguments
or configuration.

Agent instructions live in [.github](../.github/copilot-instructions.md), with a
small root [AGENTS.md](../AGENTS.md) entry point. The coding-guideline draft is
separate and remains inactive. Investigation diaries, private policy data,
recordings, deployment receipts and personal setup notes do not belong in these
public folders.

## Reference index

- [Licenses and asset sources](reference/licensing.md): component licenses, third-party notices and unresolved redistribution questions.

- Checkpoints: [editor](reference/checkpoints/editor.md), [ground contact](reference/checkpoints/ground-contact.md).
- Gameplay: [camera](reference/gameplay/camera.md), [saved history](reference/gameplay/save-history.md), [player names](reference/gameplay/player-names.md).
- Demos: [lifecycle](reference/demos/lifecycle.md), [selection](reference/demos/selection.md), [viewing](reference/demos/viewing.md).
- UI: [commands](reference/ui/commands.md), [map routes](reference/ui/map-routes.md), [notifications](reference/ui/notifications.md), [progress bar](reference/ui/progress-bar.md), [country flags](reference/ui/country-flags.md), [FPS history](reference/ui/fps-history.md), [bounce boundaries](reference/ui/fps-bounce-boundaries.md), [scoreboard input](reference/ui/scoreboard-input.md).
- Database: [data model](reference/database/data-model.md), [route identity](reference/database/route-identity.md), [save integrity](reference/database/save-integrity.md), [SQL adapter](reference/database/sql-adapter.md), [demo publication](reference/database/demo-publication.md), [query performance](reference/database/query-performance.md).
- Native: [helpers](reference/native/helpers.md), [memory ownership](reference/native/memory.md), [download cvars](reference/native/download-cvars.md), [specular scale](reference/native/specular-scale.md).
- Maps: [catalogue and attribution](reference/maps/catalogue.md).
- Development: [repository layout](development/repository-layout.md), [testing](development/testing.md), [performance workloads](development/performance.md), [sticky walls](development/sticky-walls.md), [preview assets](development/map-previews.md).
- Operations: [database](operations/database.md), [client assets](operations/client-assets.md), [native/scripts](operations/native-scripts.md).
