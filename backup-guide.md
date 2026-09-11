Your DSH state lives in **two named volumes** — and a bit in Coolify's config. Here's the complete picture:

## What to back up

| Item | Where | Contains |
|---|---|---|
| `dsh-data` volume | `/root/.dsh` | Sessions, profiles, plugin config, everything important |
| `dsh-install` volume | `/opt/dsh` | (admin variant) DSH install files + version state |
| Coolify env vars | Coolify UI | `PROXY_USERNAME`, `PROXY_PASSWORD`, `NPM_CONFIG_REGISTRY` |
| Your git repo | GitHub | `docker-compose.yml` — trivial to recreate |

The `dsh-data` volume is the critical one; plugins themselves are re-downloadable from npm.

## Backup

Run on your Coolify host (or via Coolify's container terminal):

```bash
mkdir -p ~/dsh-backups && cd ~/dsh-backups

docker run --rm \
  -v <your-project>_dsh-data:/data:ro \
  -v $PWD:/backup alpine \
  tar czf /backup/dsh-data-$(date +%F-%H%M).tar.gz -C /data .

docker run --rm \
  -v <your-project>_dsh-install:/data:ro \
  -v $PWD:/backup alpine \
  tar czf /backup/dsh-install-$(date +%F-%H%M).tar.gz -C /data .
```

Find the exact volume names with `docker volume ls | grep dsh` (Coolify prefixes them with your project/service name).

**Note:** no need to stop the service for a backup — DSH writes are infrequent, and tar of a live volume is fine for a personal instance. For a paranoid backup, stop the service first in Coolify.

## Restore

1. In Coolify, **stop** the DSH service.
2. Pick the compose project name of the service (`docker inspect <container> | grep com.docker.compose.project`).
3. Restore into the existing (now empty or outdated) volumes — a temporary container writing into them:

```bash
# restore dsh-data
docker run --rm \
  -v <project>_dsh-data:/data \
  -v $PWD:/backup alpine \
  sh -c "cd /data && rm -rf .[^.]* * 2>/dev/null; tar xzf /backup/dsh-data-2026-09-11-2200.tar.gz"

# restore dsh-install (admin variant)
docker run --rm \
  -v <project>_dsh-install:/data \
  -v $PWD:/backup alpine \
  sh -c "cd /data && rm -rf .[^.]* * 2>/dev/null; tar xzf /backup/dsh-install-2026-09-11-2200.tar.gz"
```

4. **Start** the service in Coolify. Logs should show DSH coming up with your old sessions/config intact, Plugin Market and plugins present.

## Migration to a new server

Same procedure — transfer the two `.tar.gz` files (e.g., `scp` or `rsync`), recreate the compose service in Coolify on the new host (deploy once so volumes get created), then restore into the volumes as above. No need to match versions, since the admin variant re-installs/manages DSH from the state in `dsh-install`.

**Tips:** add the env vars to your repo as `coolify.env.example` or export them from the Coolify UI; and consider encrypting backups (`gpg -c file.tar.gz`) if they contain API keys stored in DSH settings.