Deploying DeepSeek Harness (`dsh`) on Coolify with Git is a good fit, but there's one gotcha to know upfront: **the official `deepseek-ai/deepseek-harness` repo ships no Dockerfile** — it runs via `npx @deepseek-ai/dsh web` and, for security, DSH refuses `--host 0.0.0.0` (loopback-only). The standard solution is a community image that bundles DSH with a Node reverse proxy that handles external access, WebSocket forwarding, and git for DSH plugins.

## Recommended setup: Git-based Docker Compose app

### 1. Create your own repo

Fork [smanx/deepseek-harness-docker](https://github.com/smanx/deepseek-harness-docker) or create a fresh repo containing just this `docker-compose.yml` (the image is prebuilt, so no build needed):

```yaml
services:
  dsh:
    # admin variant: preinstalled latest DSH + git/pnpm/uv for plugins
    image: ghcr.io/smanx/deepseek-harness:admin-latest
    restart: unless-stopped
    environment:
      - PROXY_USERNAME=${PROXY_USERNAME:-}
      - PROXY_PASSWORD=${PROXY_PASSWORD:-}
      - NPM_CONFIG_REGISTRY=${NPM_CONFIG_REGISTRY:-https://registry.npmjs.org/}
    volumes:
      - dsh-data:/root/.dsh      # sessions & config
      - dsh-install:/opt/dsh     # DSH install (admin variant)

volumes:
  dsh-data:
  dsh-install:
```

Notes:
- **Git inside the container**: DSH plugins install via `dsh plugin add github:owner/repo`, which needs git + pnpm. The slim `latest` tag has neither — use `admin-latest` (full tools, git included) or `devtools-min-latest` (git + pnpm, smaller).
- Don't publish port `3080` to the host — let Coolify's proxy expose it (see step 4).
- The first run may be slow. The black with logo only screen may stay for a while.

### 2. Add it to Coolify

1. Coolify dashboard → your project → **Create New Resource** → **Public Repository** (paste your repo URL), or **GitHub App** if it's private.
2. Build pack: switch from Nixpacks to **Docker Compose**.
3. Base Directory: `/` · Docker Compose Location: `/docker-compose.yml`.

### 3. Set secrets

In **Configuration → Environment Variables**, set `PROXY_USERNAME` / `PROXY_PASSWORD` (enables HTTP Basic Auth — recommended since this will be publicly reachable; both must be set to activate it).

### 4. Domain

In the service's **Domains** field, enter `https://dsh.yourdomain.com:3080`. The suffix tells Coolify's proxy which container port to route to; visitors use normal 443. Point your DNS A record at your Coolify server.

If you have Coolify through Cloudflare Tunnel (using [this guide](https://coolify.io/docs/integrations/networking/cloudflare/tunnels/all-resource)), use http only, not httpS.

### 5. Deploy

Hit **Deploy**. Verify in logs that DSH and the proxy start, then open the domain — you'll get the DSH Web UI. Add your API key in Settings → Models.

### 6. Usage
- Install skills and plugins needs `Full Access` agent permission
- Whenever you need to restart dsh:
  - Since you're on the `admin` variant:
Open `https://your-domain/__admin/` and use the one-click **restart** there. That's the intended management path for the admin image.
  - Use coolify UI or terminal on the host machine:
  ```bash
  docker restart <container-name>
  ```
  