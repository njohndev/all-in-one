# Memories go-vod fix (Nextcloud AIO manual-install, Proxmox VM)

Error shown in Memories admin:

```
go-vod 127.0.0.1:47788 - Unhealthy (failed to connect: cURL error 7 ... http://127.0.0.1:47788/health)
```

Seen after migrating to a Proxmox VM and upgrading Nextcloud/Memories (Memories 10.2.0, go-vod 0.6.3).
Error 7 only means nothing is listening on the port, so go-vod was not staying up.

```bash
C=manual-install-nextcloud-aio-nextcloud-1
alias nc-occ='docker exec -u www-data $C php occ'
```

## 1. Root cause (proven): NEXTCLOUD_HOST env var breaks go-vod

Symptom in `/tmp/go-vod/<id>.log`, even though the JSON config looked correct:

```
Invalid config: Key: 'Config.NextcloudURL' Error:Field validation for 'NextcloudURL' failed on the 'http_url' tag
```

The AIO container sets `NEXTCLOUD_HOST=nextcloud-aio-nextcloud` (a bare hostname). go-vod reads that
environment variable and it overrides `nextcloudUrl` from the config file, so URL validation fails.

How it was isolated: running go-vod with `env -i` started fine; unsetting variables one at a time showed
only `NEXTCLOUD_HOST` made the error go away.

Do NOT change `NEXTCLOUD_HOST` in compose.yaml: `/entrypoint.sh` uses it as a hostname
(`dig "$NEXTCLOUD_HOST"`), so a URL there would break the container.

Fix: a wrapper that unsets the variable only for go-vod. It lives in the persistent volume.

```bash
docker exec -u www-data $C sh -c 'cat > /var/www/html/go-vod-wrapper.sh <<"EOF"
#!/bin/sh
unset NEXTCLOUD_HOST
exec /var/www/html/custom_apps/memories/bin-ext/go-vod-amd64 "$@"
EOF
chmod +x /var/www/html/go-vod-wrapper.sh'

nc-occ config:system:set memories.vod.path --value="/var/www/html/go-vod-wrapper.sh"
docker exec $C sh -c 'pkill -f go-vod; rm -f /tmp/go-vod.pid /tmp/go-vod.lock /tmp/go-vod-*-*'
```

Then reload Administration settings, then Memories, or play a video.
(`pgrep -a go-vod` will show the `bin-ext/go-vod-amd64` path, because the wrapper `exec`s it.)

## 2. Needed for playback (proven): set memories.vod.nc_url

Memories builds the go-vod `nextcloudUrl` from the system key `memories.vod.nc_url`
(not `vod.nextcloud_url`, which is unused). If it is unset, Memories falls back to
`http://localhost:80`. go-vod then starts, but playback fails:

```
ffmpeg-error: Error opening input file http://localhost:80/index.php/apps/memories/api/stream/...
Error opening input files: Connection refused
```

The Nextcloud container only runs PHP-FPM (Apache is a separate container), so nothing listens on port 80
there. Set it to the public address:

```bash
nc-occ config:system:set memories.vod.nc_url --value="https://nextcloud.example.com"
```

The container must be able to reach that address (`docker exec $C curl -sI https://nextcloud.example.com`).
If the public name does not resolve from inside, add a hosts/DNS entry or `extra_hosts` for it.

## 3. Execute bit on bin-ext (a real blocker for direct runs; likely re-extracted by app update)

After an app update/reinstall the files in `bin-ext` were `-rw-r--r--`, and running the binary directly
gave `Permission denied`. Memories itself runs a copy in `/tmp` (`/tmp/go-vod-<id>-<ver>-<hash>`), so it was
not isolated whether Memories needed the bit on its own. It matters now anyway, since the wrapper execs the
`bin-ext` binary by path.

```bash
docker exec $C ls -l /var/www/html/custom_apps/memories/bin-ext/
docker exec $C chmod +x /var/www/html/custom_apps/memories/bin-ext/go-vod-amd64 \
                        /var/www/html/custom_apps/memories/bin-ext/go-vod-aarch64
docker exec $C chmod +x /var/www/html/custom_apps/memories/bin-ext/eperl-*
```

Re-run after any Memories update or reinstall.

## Verify

```bash
docker exec $C sh -c 'pgrep -a go-vod; curl -s http://127.0.0.1:47788/health'
```

Then play a video in Memories.

## Debug recipe (if it breaks again)

```bash
# the config Memories generates and go-vod's log (append-only; judge by timestamps)
docker exec $C sh -c 'cat /tmp/go-vod/*.json; tail -20 /tmp/go-vod/*.log'

# does the binary start with a clean environment?
docker exec -u www-data $C sh -c 'env -i /tmp/go-vod-*-0.6.3-* /tmp/go-vod/*.json 2>&1 | head -3'

# which env var breaks it? (ignore unrelated hits like PATH)
docker exec -u www-data $C sh -c '
B=$(ls /tmp/go-vod-*-0.6.3-* | head -1); F=$(ls /tmp/go-vod/*.json | head -1)
for v in $(env | cut -d= -f1); do
  env -u "$v" timeout 2 $B $F 2>&1 | grep -q "Invalid config" || echo "culprit: $v"
done'
```

## Notes

- `memories:video-setup` no longer exists in current Memories versions.
- `config:app` and `config:system` are separate stores. `config:list memories` shows app config only.
- After any Memories update/reinstall: re-run the `chmod +x`, and check `memories.vod.path` still points at the wrapper.
- Hardware transcoding is a separate step: `group_add` in compose.yaml must be the VM's render GID
  (`getent group render | cut -d: -f3`), `/dev/dri` must exist in the VM, and `vainfo` must work inside the
  container before enabling VA-API.
