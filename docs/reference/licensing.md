# Licenses and asset sources

The project license covers OpenCJ-authored work that OpenCJ can license.
It does not replace third-party notices or grant rights to game content,
map artwork, downloaded audio or external build tools.

## Component licenses

| Component | Recorded license |
| --- | --- |
| Core code and documentation | [AGPL version 3](../../LICENSE), subject to existing third-party notices |
| Development tools | [AGPL version 3](../../dev-tools/LICENSE), selected for this component |
| Client project code, server scripts, native extensions and database tools | Their existing component AGPL version 3 files |
| Discord bridge | Its existing [GPL version 3](../../discord-integration/LICENSE) |
| CoD4x engine submodule | Its own [license](../../cod4x-server/License.md), copyright notices, file-specific licenses and upstream terms |
| libcod submodule | No explicit repository license or source license grant was located in the pinned tree; unresolved |

Do not apply the core license to an independently licensed component or to
unverified third-party material. A submodule does not supply a missing license.

## Identified third-party inputs

| Material | Source and terms | Local record |
| --- | --- | --- |
| Flag SVGs and derived atlases | [flag-icons v7.5.0](https://github.com/lipis/flag-icons/tree/v7.5.0), MIT | [MIT notice](../../client-mod/licenses/flag-icons.txt), source SVGs and atlas manifest |
| Ele, Any% and TAS geometry, optional rabbit badge | [Lucide 0.468.0](https://github.com/lucide-icons/lucide/tree/0.468.0), ISC with upstream attribution | [Version-matched notice](../../client-mod/cod4/licenses/lucide.txt); adapted geometry, color, stroke and composition |
| Country lookup data | [DB-IP Lite](https://db-ip.com/db/lite.php), CC BY 4.0 | [Data notice](../../server-db/tools/geoip/LICENSE-DATA.txt); download separately and retain attribution for converted/indexed data |

The two [route-finish sounds](../../client-mod/audio-source/README.md) are
included as assets of that feature under the Pixabay Content License.
Their [notice](../../client-mod/licenses/pixabay-audio.txt) and
[source catalogue](../../client-mod/audio-source/sources.json) identify both
creators, original pages, file hashes and conversion changes. The project AGPL
license does not relicense this audio. Redistribution must comply with the
Pixabay terms, including the restriction on standalone redistribution.

Client notices are staged under `client-mod/cod4/licenses/` and packaged as
`licenses/` in the IWD. Keep the relevant notices with separately distributed
asset exports too. A notice for one asset does not license unrelated assets.

## Material requiring a publication decision

These records identify unresolved issues, not permission to redistribute.

- **Map preview artwork:** the [manifest](../../client-mod/source/map_previews.json)
  records eight original loading images and two game captures. Hashes, mapper
  credit and public downloads establish provenance, not permission to
  redistribute images separately. Obtain relevant terms/permission or supply
  these images as external inputs. The [map catalogue](maps/catalogue.md)
  records source attribution.
- **Bundled 7-Zip:** `client-mod/cod4/7za.exe` identifies itself as version 4.42.
  Version-matched notices and corresponding-source arrangements are not
  recorded here. The old batch builder invokes it; the Python builder uses
  Python archive support. Prefer an externally installed tool, or complete
  the exact-version distribution requirements before publishing the binary.
  See [7-Zip licensing](https://www.7-zip.org/license.txt); current-version
  notices are not evidence for the exact old binary.
- **Older artwork and game-derived content:** retain original author and
  permission records for branding/rank inputs and copied game/map files.
  Editing, converting or using ImageGen on an existing image does not
  establish rights to the original.
- **Engine contents:** CoD4x retains upstream notices and additional
  statements in its README. Its bundled game-derived binaries require
  separate review. libcod's missing explicit grant remains unresolved.
  The core license does not settle these questions.

Where material must be excluded, deleting it from the current tree is not
enough: review the Git history that would be published too. Keep required local
inputs and recovery copies private.

## Retired assets

The unused exit and gear icon files and their CSV/GDT registrations have been
removed. Their historical asset files and registrations are excluded from the
history intended for publication; original copies and revision mappings are
kept privately. The current menus do not use these icons.

## External tools and data

Obtain base games, Windows Mod Tools and map packages separately under their
respective terms. Do not copy installations or license keys into the repository.
A generator's source license does not license its inputs.

Artwork/audio tooling installs [Pillow](https://pillow.readthedocs.io/en/stable/about.html),
[CairoSVG](https://cairosvg.org/documentation/) and
[libsndfile](https://libsndfile.github.io/libsndfile/) separately. Their licenses
and dependency notices apply when redistributing the tools; they are external
prerequisites here.

The icon recipes use DejaVu Sans and Nimbus Sans from URW Base35. Install the
fonts separately; core includes no font binaries. Retain the relevant font
notices if a future package embeds fonts, and inspect the exact font package's
license and exceptions.

Keep new asset records with the asset: creator, source URL, version/hash where
available, applicable license/permission, changes made and notices needed in
exports. Private download receipts and correspondence stay outside the public
checkout. Unresolved items still prevent publication clearance. The coding
guidelines remain inactive.
