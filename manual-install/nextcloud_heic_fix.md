# Fixing Missing HEIC Thumbnails in Nextcloud Memories

Missing thumbnails for **HEIC** files in Nextcloud Memories happen because Nextcloud **disables HEIC preview generation by default**. Since HEIC conversion relies on `ImageMagick` (which historically had metadata security vulnerabilities), Nextcloud requires you to explicitly opt-in. 

Follow these steps to enable HEIC thumbnails and regenerate the missing previews.

## Step 1: Verify the Server has HEIC Support
Nextcloud uses your server's underlying system packages to read HEIC files. 
* **Nextcloud Docker/AIO:** `ImageMagick` with HEIC support is already built-in. 
* **Bare Metal (Ubuntu/Debian):** Verify the PHP extension and libraries are installed by running:
  ```bash
  sudo apt install imagemagick php-imagick libheif-examples
  ```

## Step 2: Add HEIC to `config.php`
You need to explicitly tell Nextcloud to handle HEIC previews. 

1. Open your Nextcloud `config/config.php` file.
2. Look for the `enabledPreviewProviders` array. If it doesn't exist, create it.
3. Add `'OC\\Preview\\HEIC'` to the array:

```php
'enabledPreviewProviders' => [
    'OC\\Preview\\JPEG',
    'OC\\Preview\\PNG',
    'OC\\Preview\\GIF',
    'OC\\Preview\\HEIC', // <-- Ensure this line is present
],
```

## Step 3: Run the `occ` Generation Commands
Once the config file is updated, Nextcloud will automatically generate previews for *newly* uploaded HEIC photos. To generate thumbnails for your **existing** files, run these commands via your terminal:

1. **Scan the filesystem** to ensure Nextcloud sees all files accurately:
   ```bash
   sudo -u www-data php occ files:scan --all
   ```
2. **Force-generate missing previews** for your images (if you use the `previewgenerator` app):
   ```bash
   sudo -u www-data php occ preview:generate-all
   ```
3. **Index the Memories app** so the timeline reflects the changes:
   ```bash
   sudo -u www-data php occ memories:index
   ```

> **Note:** Replace `sudo -u www-data php` with your specific setup command if you use Docker (e.g., `docker exec --user www-data nextcloud-aio-nextcloud php`).
