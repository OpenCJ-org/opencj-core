# Save ownership and recording integrity

## Behavior

- Position and checkpoint writes report another session only after confirming
  that the run's ownership generation changed. Results for a run/instance the
  player has already left are ignored. Storage errors have a separate message,
  which does not claim that an uncertain commit definitely failed.
- savePosition locks its run row, checks ownership explicitly and accepts an
  exact repeat of the latest stored save without inserting it again. Equal
  counters alone do not suppress a different saved position. Save numbering is
  serialized. No automatic write retries were added.
- An unsuccessful demo upload cannot become ready or replace a playable winner.
  Promotion also requires the expected number of contiguous, non-empty chunks.
  A failed demo upload leaves the leaderboard finish intact.

Asynchronous SQL ownership, worker lifecycle, cancellation and uncertain outcomes are described in the [SQL adapter reference](sql-adapter.md). Demo publication uses the receipt-based transaction described in the [publication reference](demo-publication.md).
