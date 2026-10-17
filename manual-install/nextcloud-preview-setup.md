# Nextcloud AIO: Preview Generation Setup, Cleanup and Regeneration

Assumes the manual-install AIO compose project. Container names below match your setup; adjust if they differ.

```bash
# Helper (skip if you already have the nc-occ alias)
alias nc-occ='docker exec -u www-data manual-install-nextcloud-aio-nextcloud-1 php occ'
```

Commands marked **(verify)** have changed between Nextcloud versions. Check with `--help` before running them on version 34.

---

## 0. Prerequisites

HEIC decoding needs imagick with the HEIC delegate. Check:

```bash
docker exec manual-install-nextcloud-aio-nextcloud-1 php -r 'print_r(Imagick::queryFormats("HEIC"));'
```

You should see `HEIC` in the array. Your `.env` / compose should contain:

```
NEXTCLOUD_ADDITIONAL_APKS="imagemagick imagemagick-heic libheif bash ffmpeg libva libva-vdpau-driver libva-intel-driver intel-media-driver mesa-va-gallium"
NEXTCLOUD_ADDITIONAL_PHP_EXTENSIONS="imagick"
```

After changing these, recreate the container: `docker compose up -d`.

## 1. Set preview providers

AIO rewrites `enabledPreviewProviders` at every container start, so re-check this after each restart.

```bash
nc-occ config:system:delete enabledPreviewProviders
i=0
for p in JPEG PNG GIF BMP MarkDown MP3 TXT OpenDocument Movie Krita HEIC TIFF XBitmap PDF; do
  nc-occ config:system:set enabledPreviewProviders $i --value="OC\\Preview\\$p"
  i=$((i+1))
done
nc-occ config:system:get enabledPreviewProviders
```

The resulting list is exactly:

```
OC\Preview\JPEG
OC\Preview\PNG
OC\Preview\GIF
OC\Preview\BMP
OC\Preview\MarkDown
OC\Preview\MP3
OC\Preview\TXT
OC\Preview\OpenDocument
OC\Preview\Movie
OC\Preview\Krita
OC\Preview\HEIC
OC\Preview\TIFF
OC\Preview\XBitmap
OC\Preview\PDF
```

Video previews (MP4, MOV, MKV, AVI) are handled by the `Movie` provider, which uses ffmpeg. PDF previews depend on imagick being able to read PDFs (usually needs Ghostscript in the container), so if PDF thumbnails fail, check the log.

## 2. Set preview size and limits (optional)

AIO defaults: 2048 x 2048, JPEG quality 60.

```bash
nc-occ config:system:set preview_max_x --value=2048 --type=integer
nc-occ config:system:set preview_max_y --value=2048 --type=integer
nc-occ config:system:set jpeg_quality --value=60 --type=integer
nc-occ config:system:set enable_previews --value=true --type=boolean

# Only if large files are skipped:
nc-occ config:system:set preview_max_filesize_image --value=100 --type=integer   # MB, default 50, -1 = unlimited
nc-occ config:system:set preview_max_memory --value=1024 --type=integer          # MB, default 256
```

Check any value with `nc-occ config:system:get <key>` (empty = default).

## 3. Install Preview Generator

```bash
nc-occ app:install previewgenerator
nc-occ app:enable previewgenerator
```

Optional: choose which sizes get pre-built (anything else is generated on first view):

```bash
nc-occ config:app:set previewgenerator squareSizes --value="32 256"
nc-occ config:app:set previewgenerator widthSizes --value="256 384"
nc-occ config:app:set previewgenerator heightSizes --value="256"
```

## 4. Clean up stale previews

Check what is available and what each command does first (verify):

```bash
nc-occ list preview
nc-occ preview:cleanup --help
nc-occ preview:reset-rendered-files --help
```

- `preview:cleanup` removes orphaned previews (source file gone). It is not a wipe-all command.
- `preview:reset-rendered-files` (Preview Generator) deletes generated previews so they can be rebuilt.
- Do not delete preview folders by hand. Newer versions track previews in the database and manual deletion can leave orphaned rows.

Optional sanity check on DB rows (table and user names are assumptions; use `\dt *preview*` inside psql if it errors):

```bash
docker exec -it manual-install-nextcloud-aio-database-1 psql -U oc_nextcloud -d nextcloud_database -c "SELECT count(*) FROM oc_previews;"
```

## 5. Refresh file and preview references in the database

```bash
nc-occ files:scan --all
nc-occ files:scan-app-data
nc-occ maintenance:repair
```

## 6. Clear caches

`maintenance:repair` clears the main caches. If stale thumbnails still show:

```bash
docker restart manual-install-nextcloud-aio-redis-1
```

This logs everyone out (sessions live in Redis).

## 7. Regenerate previews

Run inside `tmux` or `screen`. On a large library this takes hours.

```bash
nc-occ preview:generate-all -vvv
```

To keep it up to date afterwards, Preview Generator needs a cron job calling `preview:pre-generate` (AIO's built-in cron handles the standard background jobs, but verify this one is scheduled).

## 8. Rebuild the Memories index

Memories keeps its own index and does not rely on the preview table for its timeline.

```bash
nc-occ memories:index --help      # confirm available flags
nc-occ memories:index --force     # (verify flag)
```

## 9. Troubleshooting

Raise the log level temporarily, reproduce the problem, then restore it:

```bash
nc-occ config:system:set loglevel --value=0 --type=integer
tail -n 50 /mnt/16tb/ncdata/nextcloud.log
nc-occ config:system:set loglevel --value=2 --type=integer
```

**HEIC "image type not supported" on specific files** (`ReadHEICImage` error): if most HEICs work, the failing files are usually mislabeled, corrupt, or use a codec/profile libheif cannot decode. Compare a failing and a working file:

```bash
docker exec manual-install-nextcloud-aio-nextcloud-1 sh -c '
  f="/path/to/failing.heic"
  ls -l "$f"; head -c 32 "$f" | od -c | head -3
  magick identify -verbose "$f" 2>&1 | head -20'
```

A real HEIC shows `ftyp` followed by `heic`, `heix` or `mif1` in the first bytes. For genuinely unsupported variants, convert a copy on a desktop and keep the original.

**Preview works in Memories but not in Files (or the reverse):** Memories transcodes HEIC and video on its own, so it can work while the standard preview providers do not. Test in the plain Files app to check the providers.

## 10. After every container restart

- [ ] `nc-occ config:system:get enabledPreviewProviders` still shows your list
- [ ] `Imagick::queryFormats("HEIC")` still returns `HEIC`
