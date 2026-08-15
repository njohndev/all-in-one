# Comprehensive Proxmox Migration Guide: Dockerised Nextcloud
**Target Hardware:** Intel i5-13500 (Alder Lake iGPU) & 16TB Dedicated Data HDD
**Target OS:** Ubuntu Server 24.04 LTS VM on Proxmox VE (q35 Architecture)

---

### Step 1: Create the Ubuntu Server VM in Proxmox
1. Log into your Proxmox Web GUI and click **Create VM** (top right).
2. **General:** Set **VM ID** (e.g., `100`) and **Name** (e.g., `nextcloud-server`).
3. **OS:** Select your uploaded **Ubuntu Server 24.04 LTS ISO**.
4. **System:** Check the **Qemu Agent** box. Change the **Machine** type from default `i440fx` to **q35** (required for native PCI-Express routing).
5. **Disks:** Allocate **60GB to 100GB** on your NVMe storage for the OS and Nextcloud database templates.
6. **CPU:** Set **Sockets** to `1` and **Cores** to `6`. Change the Type to **host** (crucial for iGPU passthrough). Leave PCPU completely blank.
7. **Memory:** Assign **4GB to 6GB RAM**.
8. Complete the wizard, start the VM, and install Ubuntu Server via the console interface. Ensure you check the box to **"Install OpenSSH Server"** during the installation setup.

---

### Step 2: Pass the 16TB HDD to the VM
1. Physically plug your 16TB drive into your Proxmox server hardware.
2. Open the **Proxmox Host shell** and find the drive's unique serial ID:
   ```bash
   ls -l /dev/disk/by-id/
   ```
3. Locate your 16TB drive (e.g., `ata-WDC_WD161KRYZ-...`). Copy the **exact filename string** (do not include partition tags like `-part1`).
4. Bind the raw drive to your VM (assuming your VM ID is `100`):
   ```bash
   qm set 100 -scsi1 /dev/disk/by-id/your-exact-16tb-disk-id
   ```

---

### Step 3: Enable iGPU Passthrough for the i5-13500
1. On the **Proxmox Host shell**, open your GRUB configuration file:
   ```bash
   nano /etc/default/grub
   ```
2. Update the kernel command line to enable IOMMU tracking paths:
   ```text
   GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"
   ```
3. Save (`Ctrl+O`, `Enter`, `Ctrl+X`) and update your system boot configuration parameters:
   ```bash
   update-grub
   ```
4. In the Proxmox Web GUI, select your **VM (100)** -> **Hardware** -> **Add** -> **PCI Device**.
5. Select **Raw Device**, then find the device labeled **Alder Lake** (ID `0000:00:02.0`).
6. Check **All Functions**, **ROM-Bar**, and **PCI-Express** (this will now be fully clickable thanks to the q35 machine setup). Leave "Primary GPU" **unchecked**.
7. **Reboot the physical Proxmox host** to safely apply changes.

---

### Step 4: Prepare the Ubuntu VM & Mount the 16TB Drive
Log into your new Ubuntu VM via SSH.

1. **Install Docker and GPU Compute Runtimes:**
   ```bash
   sudo apt update && sudo apt install -y docker.io docker-compose-v2 ocl-icd-libopencl1 intel-opencl-icd intel-level-zero-gpu level-zero clinfo
   ```
2. **Configure Host Permissions:**
   ```bash
   sudo usermod -aG docker,video,render $USER
   ```
   *(Close your SSH session and log back in to apply group changes).*
3. **Mount the 16TB Drive:**
   ```bash
   sudo mkdir -p /mnt/nextcloud-data
   sudo blkid
   ```
   Copy the `UUID="..."` string of your 16TB partition. Then open the filesystem table:
   ```bash
   sudo nano /etc/fstab
   ```
   Add this line to the bottom (replace `ext4` with your drive's actual filesystem format like `ntfs-3g` or `exfat` if applicable):
   ```text
   UUID=your-copied-16tb-uuid-here /mnt/nextcloud-data ext4 defaults 0 2
   ```
   Mount it immediately and verify layout sizing with `df -h`:
   ```bash
   sudo mount -a
   ```

---

### Step 5: Identify GPU IDs and System Permission Nodes
Run these commands inside the Ubuntu VM to confirm the graphics layers match your hardware configuration and map permissions correctly.

1. **Confirm iGPU Passthrough:**
   ```bash
   clinfo -l
   ```
   **Expected Output:** `Platform #0: Intel(R) OpenCL Graphics` -> `Device #0: Intel(R) UHD Graphics 770`.

2. **Extract the Host Render Group ID:**
   ```bash
   getent group render | cut -d: -f3
   ```
   *Note down this number (e.g., `103` or `104`). You will need this for the `group_add` property in your Docker configuration below to allow the container to pass device security checks.*

---

### Step 6: Migrate Nextcloud and Update Docker Compose
1. **On your old server hardware:** Turn on maintenance mode and stop the containers:
   ```bash
   docker exec -it -u www-data nextcloud-aio-nextcloud php occ maintenance:mode --on
   docker compose down
   ```
2. **Transfer Configurations:** `rsync` your configuration directories, environment files, and database folder over to the new VM's local NVMe space (e.g., `$HOME/server/`). *Do not sync the massive 16TB data pool across the network since the physical drive is now directly plugged into Proxmox.*
3. On the new VM, open your `docker-compose.yml` file and integrate your configuration parameters:

```yaml
  nextcloud-aio-nextcloud:
    image: ghcr.io/nextcloud-releases/aio-nextcloud:latest
    init: true
    restart: unless-stopped
    volumes:
      - nextcloud_aio_nextcloud:/var/www/html:rw

    # =========================================================================
    # INTEL HARDWARE VIDEO ACCELERATION DIRECT DEVICE PASSTHROUGH
    # =========================================================================
    devices:
      - /dev/dri:/dev/dri # Passes Intel Quick Sync (QSV) graphics layers
    group_add:
      - "104" # CHANGE THIS to match the exact render group GID found in Step 5
    # =========================================================================

    environment:
      - NEXTCLOUD_DATA_DIR=/mnt/16tb/ncdata
      
      # Retained internal dependencies (intel-media-driver, libva-utils, ffmpeg)
      - NEXTCLOUD_ADDITIONAL_APKS=intel-media-driver libva-utils ffmpeg
```

---

### Step 7: SSL Certificate Generation & Security Verification
Ensure your Nginx container is running and correctly mapping the `/var/www/certbot` workspace folder for Webroot challenge verification before running these tasks.

1. **Generate the Let's Encrypt Certificate manually via Webroot mode:**
   ```bash
   docker compose --profile certbot run --rm certbot certonly \
     --webroot \
     --webroot-path=/var/www/certbot \
     -d domain.com \
     --email your-email@example.com \
     --agree-tos --no-eff-email
   ```

2. **Verify Expiration Timeline and Domain SSL Validity:**
   ```bash
   curl -Iv https://domain.com 2>&1 | grep -E "start date|expire date"
   ```

---

### Step 8: Launch, Verify, and Complete App Setup
1. Spin up your updated container stack on the new VM:
   ```bash
   docker compose up -d
   ```
2. Disable maintenance mode inside the container to bring Nextcloud back online:
   ```bash
   docker exec -it -u www-data nextcloud-aio-nextcloud php occ maintenance:mode --off
   ```
3. **Verify Container GPU Integration:** Execute the `libva-utils` diagnostics pipeline directly inside the application namespace:
   ```bash
   docker exec -it nextcloud-aio-nextcloud vainfo
   ```
   *Expected Outcome:* While headless display layers like Wayland or X11 will gracefully report fallback errors, the stack will bind natively via `drm` displaying `va_openDriver() returns 0` alongside your active Intel iHD driver profile parameters.

4. **Activate Hardware Transcoding in Nextcloud Web UI:**
   * Open your web interface and head to **Administration Settings** → **Memories** → **Video Transcoding**.
   * Toggle the transcoder scheme configuration dropdown to **Internal (FFmpeg)**.
   * Enable the **Hardware Acceleration** checkbox and select **VA-API** as your hardware engine framework.

5. **Configure Automatic Certificate Renewal Execution:**
   Open the host cron runtime configurations workspace:
   ```bash
   crontab -e
   ```
   Add this execution criteria definition block at the bottom of the system file (this criteria evaluates daily at midnight and noon, silently renewing expiring keys and hot-reloading your Nginx instance configuration):
   ```text
   0 0,12 * * * cd \$HOME/server && docker compose --profile certbot run --rm certbot renew && docker compose exec nginx nginx -s reload
   ```
