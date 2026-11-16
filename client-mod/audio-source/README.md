# Route finish audio

The two MP3s come from Pixabay:

- [Level Complete by freesound_gamestudio](https://pixabay.com/sound-effects/film-special-effects-level-complete-394515/): `freesound_gamestudio-level-complete-394515.mp3`, ordinary route completion.
- [Victory Fanfare by Universfield](https://pixabay.com/sound-effects/musical-victory-fanfare-152480/): `universfield-victory-fanfare-152480.mp3`, new top-three time or low-RPG finish.

Both pages identify the Pixabay Content License. They are third-party audio,
not AGPL or CC0 assets. The [license terms](https://pixabay.com/service/terms/)
restrict standalone redistribution. Keeping source MP3s and lightly converted
WAVs in a public repository therefore remains unresolved, separately from
incorporating sound into the game. See [licenses and asset sources](../../docs/reference/licensing.md).
The conversion below changes encoding, sample rate and volume; it does not
establish a new license or remove the source restrictions.

Run `python3 dev-tools/scripts/build-finish-sounds.py` from the workspace on the
server to regenerate the WAV assets (requires libsndfile with MP3 support).
The converter never amplifies the source, caps peaks at -6 dBFS and RMS at
-20 dBFS, and outputs 44.1 kHz 16-bit PCM. `opencj_finish.csv` applies a further
50% volume using the interface volume group. These are loaded 2D sounds embedded
in `mod.ff`, played locally only to the finisher.

Ranking follows the existing mode-inclusion rules and uses one best run per
player on each board. Time is ordered by time then RPGs; low-RPG by RPGs then
time. Exact ties retain the older run, so repeating an existing result does not
create another record fanfare. Any of a route's finish checkpoints can qualify.
