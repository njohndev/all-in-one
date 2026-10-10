# Nextcloud HEIC Previews with ImageMagick (imagick) and Preview Generator

This guide sets up HEIC (and TIFF) thumbnails through the PHP `imagick` extension, then adds the Preview Generator app so previews are built ahead of time for Memories. It includes a check or test after each stage.

Replace these placeholders with your own values.

| Placeholder | Meaning |
|---|---|
| `<nextcloud container>` | Your Nextcloud container, e.g. `manual-install-nextcloud-aio-nextcloud-1` |
| `nc-occ` | Your alias for `docker exec --user www-data <nextcloud container> php occ` |
| `$DATA` | The data directory inside the container. Get it with the command in Step 1. |

## Step 1: Gather facts

```bash
nc-occ status
nc-occ config:system:get datadirectory
nc-occ config:system:get enabledPreviewProviders
nc-occ config:system:get preview_imaginary_url
```

Note the data directory. Inside your container it may be a path such as `/mnt/16tb/ncdata` rather than the AIO default `/mnt/ncdata`. Use whatever this command prints wherever `$DATA` appears below.

The Imaginary URL should be empty. If it isn't, finish the revert in `nextcloud_revert_imaginary.md` first.

## Step 2: Make sure ImageMagick is installed

In the AIO compose, `NEXTCLOUD_ADDITIONAL_APKS` installs Alpine packages into the Nextcloud container at startup. It should contain `imagemagick` with balanced quotes:

```
NEXTCLOUD_ADDITIONAL_APKS="imagemagick"
```

Check what the container supports:

```bash
docker exec <nextcloud container> sh -c 'magick -list format 2>/dev/null | grep -i heic || convert -list format | grep -i heic'
```

You want `HEIC` listed as `rw+` or at least `r`. If nothing is listed, change the variable to include the HEIC package and recreate the containers (a plain restart does not pick up env changes):

```
NEXTCLOUD_ADDITIONAL_APKS="imagemagick imagemagick-heic"
```

```bash
docker compose up -d --force-recreate
```

## Step 3: Verify the PHP imagick extension

Nextcloud uses the PHP extension, not the command line tool, so the command line working does not prove previews will work.

```bash
docker exec <nextcloud container> php -r 'var_dump(extension_loaded("imagick")); var_dump(Imagick::queryFormats("HEIC"));'
```

You want `bool(true)` and an array containing `HEIC`. If it returns an empty array or an error, the PHP extension is not linked against libheif, and previews will fail whatever the config says. In that case check `nextcloud.log` for the exact imagick error before going further.

Test a real conversion. **The output extension decides the format**, so use `.jpg`. An extension like `.mov` makes ImageMagick try to encode a video and fail with libx264 errors, even though the HEIC decoded fine. Phone HEICs can hold several images, and `[0]` forces the first one:

```bash
docker exec <nextcloud container> magick "$DATA/<user>/files/Photos/<file>.HEIC[0]" /tmp/test.jpg
docker exec <nextcloud container> ls -l /tmp/test.jpg
```

A non-empty JPEG means decoding works. A "policy" or "resource limit" error points to Step 4.

## Step 4: Check limits that block large HEICs

**ImageMagick policy.** A restrictive `policy.xml` can block big images:

```bash
docker exec <nextcloud container> sh -c 'find /etc -name policy.xml -exec grep -H -E "resource|memory|map|width|height|disk" {} \;'
```

**PHP memory.** In the AIO compose, `NEXTCLOUD_MEMORY_LIMIT` sets PHP's memory limit. Phone HEICs often need 512M or more:

```
NEXTCLOUD_MEMORY_LIMIT=512M
```

Recreate the containers after changing it. Check the effective value:

```bash
docker exec <nextcloud container> php -r 'echo ini_get("memory_limit"), PHP_EOL;'
```

## Step 5: Set the preview providers

Rebuild the list from scratch. `config:system:get` prints values without their index numbers, so rebuilding is more reliable than editing single entries:

```bash
nc-occ config:system:delete enabledPreviewProviders
i=0; for p in Image MarkDown MP3 TXT OpenDocument Movie Krita HEIC TIFF MKV MP4 AVI; do nc-occ config:system:set enabledPreviewProviders $i --value="OC\\Preview\\$p"; i=$((i+1)); done
nc-occ config:system:get enabledPreviewProviders
```

The output should list `OC\Preview\HEIC` and `OC\Preview\TIFF`, and no `OC\Preview\Imaginary` or `OC\Preview\ImaginaryPDF`. Add any other providers you used before to the `for` list.

If Imaginary entries reappear after a restart, something is rewriting the list. Stop the Imaginary container (`docker compose stop <imaginary service name>`) and redo this step.

## Step 6: Install and configure Preview Generator

Preview Generator builds previews in the background so thumbnails are ready before anyone scrolls the timeline.

```bash
nc-occ app:install previewgenerator
nc-occ app:list | grep -i previewgenerator
```

If it's already installed, `app:install` reports that and you can continue. Set the preview sizes. These values are the ones the app's documentation recommends for the Nextcloud web UI and Memories, so previews that match what the app asks for are reused rather than regenerated:

```bash
nc-occ config:app:set previewgenerator squareSizes --value="32 256"
nc-occ config:app:set previewgenerator widthSizes  --value="256 384"
nc-occ config:app:set previewgenerator heightSizes --value="256"
```

Optionally limit the largest preview and its quality to save disk space and CPU:

```bash
nc-occ config:system:set preview_max_x --value=2048 --type=integer
nc-occ config:system:set preview_max_y --value=2048 --type=integer
nc-occ config:system:set jpeg_quality --value=60 --type=integer
```

If you change the sizes after previews already exist, previews of the old sizes stay on disk until you clear them (Step 7).

## Step 7: Scan, clear stale previews, and generate

Run these in order. Each command depends on the one before.

**7a. Clear stale previews (only if you had failed or blank ones).** Previews attempted while Imaginary was active, or while imagick was failing, can be cached as empty files. Find the preview folder and clear it:

```bash
docker exec <nextcloud container> sh -c 'ls -d '"$DATA"'/appdata_*/preview'
docker exec <nextcloud container> sh -c 'rm -rf '"$DATA"'/appdata_*/preview/*'
```

Previews are a cache, so this is safe, but the rebuild takes time on a large library. To clear one file only, use its numeric file ID (shown as `fileid=` in the web UI URL): `rm -rf $DATA/appdata_*/preview/<fileid>`.

If you cleared previews by hand, the database still lists them. The next step fixes that. If the preview folder looks different on your Nextcloud version (newer releases track previews differently), tell me what `ls` shows before deleting anything.

**7b. Scan the app data folder.** This resyncs the file cache for the `appdata_*` folder, which is where previews live. Run it after any manual change to the preview folder:

```bash
nc-occ files:scan-app-data
```

Add `preview` to limit it to the preview folder: `nc-occ files:scan-app-data preview`.

**7c. Scan user files.** This makes sure Nextcloud knows about every photo:

```bash
nc-occ files:scan --all
```

Or for a single user: `nc-occ files:scan <user>`. Photos only: `nc-occ files:scan <user> --path="<user>/files/Photos"`.

**7d. Index Memories.**

```bash
nc-occ memories:index --force
```

**7e. Generate previews.**

```bash
nc-occ preview:generate-all -vvv
```

This is a one-off bulk run and can take a long time on a large library, so run it inside `tmux` or `screen`, or detach it. `-vvv` shows each file and the error for any that fail. To generate only for one user or path, use `nc-occ preview:generate-all -vvv <user>` (check `nc-occ preview:generate-all --help` for the options on your version).

## Step 8: Keep previews generated automatically

New photos need previews too. `preview:pre-generate` processes only files added since the last run, so it is cheap to run often. Schedule it on the host with cron (every 10 minutes is typical):

```
*/10 * * * * docker exec --user www-data <nextcloud container> php occ preview:pre-generate
```

Let the first `preview:generate-all` finish before enabling this, so the two don't run at once. Check that the scheduler works by uploading a photo and running the command by hand:

```bash
nc-occ preview:pre-generate -vvv
```

## Step 9: Test end to end

1. **Disk check.** Previews should now exist for HEIC files:
   ```bash
   docker exec <nextcloud container> sh -c 'ls '"$DATA"'/appdata_*/preview | head'
   ```
2. **Log check.** There should be no new imagick, HEIC or memory errors:
   ```bash
   docker exec <nextcloud container> sh -c 'tail -n 200 '"$DATA"'/nextcloud.log | grep -iE "heic|imagick|preview|memory"'
   ```
3. **UI check.** Open a HEIC photo in Files and in Memories, and reload the timeline. Thumbnails should appear.
4. **Provider check.** Confirm the list is still correct after a restart:
   ```bash
   docker compose restart <nextcloud service name>
   nc-occ config:system:get enabledPreviewProviders
   ```

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `Imagick::queryFormats("HEIC")` returns an empty array | The PHP extension lacks libheif support. Check `nextcloud.log` for the exact error. |
| `magick` fails with libx264 or "width not divisible by 2" | The output file had a video extension like `.mov`. Use `.jpg`. |
| "policy" or "resource limit" error | ImageMagick's `policy.xml` is blocking large images (Step 4). |
| Out-of-memory errors in the log | Raise `NEXTCLOUD_MEMORY_LIMIT` and recreate the containers. |
| Previews are blank after the fix | Stale cached previews. Redo Step 7 from 7a. |
| Thumbnails exist in the folder but Memories shows none | Run `files:scan-app-data` and `memories:index --force` again. |
| Imaginary providers reappear after a restart | Something is rewriting `config.php`. Stop the Imaginary container and redo Step 5. |
| `preview:generate-all` skips HEIC files | `OC\Preview\HEIC` is missing from `enabledPreviewProviders`. Redo Step 5. |
