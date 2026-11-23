# Route finish audio

The two MP3s come from Pixabay:

- [Level Complete by freesound_gamestudio](https://pixabay.com/sound-effects/film-special-effects-level-complete-394515/): `freesound_gamestudio-level-complete-394515.mp3`, ordinary route completion.
- [Victory Fanfare by Universfield](https://pixabay.com/sound-effects/musical-victory-fanfare-152480/): `universfield-victory-fanfare-152480.mp3`, new top-three time or low-RPG finish.

Both source and converted files are retained as inputs and assets of OpenCJ's
route-finish feature. They keep the Pixabay Content License and are not
relicensed under AGPL or CC0. See the [creator and license notice](../licenses/pixabay-audio.txt)
and [source catalogue](sources.json) for URLs, hashes and conversion details.
The notice is also included under `licenses/pixabay-audio.txt` in client IWDs.
Any redistribution must comply with the linked terms, including the restriction
on standalone redistribution; credit does not override that restriction.

Run `python3 dev-tools/scripts/build-finish-sounds.py` from the workspace on the
server to regenerate the WAV assets (requires libsndfile with MP3 support).
Use `--output-dir <directory>` to inspect a separate build without replacing the
checked-in WAVs. The converter validates decoded metadata before allocating its
sample buffer and closes the decoder on failures. Silent audio produces silent
PCM, with `null` peak/RMS dBFS values in the report.

The converter never amplifies the source, caps peaks at -6 dBFS and RMS at
-20 dBFS, and outputs 44.1 kHz 16-bit PCM. `opencj_finish.csv` applies a further
50% volume using the interface volume group. These are loaded 2D sounds embedded
in `mod.ff`, played locally only to the finisher.

Ranking follows the existing mode-inclusion rules and uses one best run per
player on each board. Time is ordered by time then RPGs; low-RPG by RPGs then
time. Exact ties retain the older run, so repeating an existing result does not
create another record fanfare. Any of a route's finish checkpoints can qualify.
