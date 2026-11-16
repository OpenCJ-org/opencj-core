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

## Map preview artwork

The [manifest](../../client-mod/source/map_previews.json) records eight original
loading images and two game captures. OpenCJ retains them based on the
maintainer's understanding of the community's established map-sharing practice.
No formal asset license or separate permission text has been recorded; this
retention decision is not a verified unrestricted license grant.

The [attribution notice](../../client-mod/licenses/map-previews.txt) records
mapper credits and source links and is included in client packages.
The [map catalogue](maps/catalogue.md) contains the detailed source evidence.
Map artwork and underlying game assets are not relicensed by the project AGPL.

## libcod license check

The pinned libcod tree supports CoD2 1.0, 1.2c and 1.3. Its history shares the
initial commit with [kungfooman/libcod](https://github.com/kungfooman/libcod).
The separate CoD4x submodule supplies the CoD4 server.

A brief review found no license file or source license headers in the pinned
tree, and no license file in its available Git history. GitHub reports no
recognized license for the original repository or the OpenCJ copy. The upstream
repository also contains no visible license file. The license status remains
unknown; no MIT, GPL or AGPL grant is inferred from public availability or from
licenses added by other forks.

Keep the existing libcod pin and attribution. An explicit grant from the relevant
upstream rights holders would be needed to resolve this missing license record.
This review does not alter or relicense the submodule.

## Material requiring a publication decision

These records identify unresolved issues, not permission to redistribute.

- **Active branding and game-derived content:** the current jumping-soldier
  logo is a cleaned version of an earlier image whose original author and
  permission record are not identified here. Preserve provenance for copied
  game content too; later edits do not supply a missing original license.
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

The legacy Windows batch builder uses an externally installed
[7-Zip](https://www.7-zip.org/download.html); see the
[build instructions](../operations/client-assets.md#legacy-batch-builder).
The bundled 4.42 executable has been removed, including from the history
intended for publication. Private recovery copies remain available.
The Python builder has no 7-Zip dependency. Any future installer or container
that redistributes this tool must follow the license of the version it supplies.

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
checkout. Unresolved items still prevent publication clearance. Follow the active coding guidelines alongside these licensing requirements.
