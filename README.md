Deploying DeepSeek Harness (`dsh`) on Coolify with Git 

Why this repo?
**the official `deepseek-ai/deepseek-harness` repo ships no Dockerfile** — it runs via `npx @deepseek-ai/dsh web` and, for security, DSH refuses `--host 0.0.0.0` (loopback-only). 

## Recommended setup: Git-based Docker Compose app

### 1. Create your own repo

Fork [smanx/deepseek-harness-docker](https://github.com/smanx/deepseek-harness-docker) or create a fresh repo containing just this `docker-compose.yml` (the image is prebuilt, so no build needed):

```yaml
services:
  dsh:
    image: ghcr.io/tpattivo/dsh-docker:latest
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

If you have Coolify through Cloudflare Tunnel (using [this guide](https://coolify.io/docs/integrations/networking/cloudflare/tunnels/all-resource)), use http only, not http*__S__*.

### 5. Deploy

Hit **Deploy**. Verify in logs that DSH and the proxy start, then open the domain — you'll get the DSH Web UI. Add your API key in Settings → Models.

### 6. Usage
- Install skills and plugins needs `Full Access` agent permission
- Whenever you need to restart dsh, prefer a **full container restart** (Coolify UI → Restart, or on the host machine):
  ```bash
  docker restart <container-name>
  ```
  The `/__admin/` one-click **restart** only restarts the `dsh` process *inside* the container — that invalidates your browser session and is what used to trigger the "authentication required" lockout (see troubleshooting below). The patched proxy in this image now auto-recovers from it, but a container restart remains the reliable path.

#### Troubleshooting: "dsh web authentication required; reopen the URL printed by dsh web"

Since DSH 0.1.2, the Web UI is secured by a one-time **launch token** that the browser exchanges for a signed session cookie. Anything that restarts the `dsh` process inside the container (admin-page restart, plugin install, crash respawn) invalidates that cookie and prints a new token. The stock proxy only ever read the *first* token from the log, so after such a restart its cached token was stale and you got locked out.

This image patches `proxy/upstream-token.js` to re-scan the DSH log for the newest token and retry automatically, so the page should heal itself on reload. If you still hit the error:

1. **Full container restart** — fixes it every time: Coolify UI → Restart, or `docker restart <container-name>`.
2. **Or open the fresh token URL manually** — grab the newest token from the log and append it to your domain:
   ```bash
   docker exec <container-name> grep -oE 'token=[A-Za-z0-9._~-]{16,}' /app/.dsh-web.log | tail -1
   # → https://your-domain/?token=<value>
   ```

If it keeps recurring even after a container restart, check the container logs for `[upstream-token]` lines and re-diff `patches/upstream-token.js` against the base image's copy — upstream may have changed the token format.

#### Pre-baked dependencies & custom plugins
The custom Docker image is automatically built and pushed to **GitHub Container Registry (`ghcr.io/tpattivo/dsh-docker:latest`)** via GitHub Actions on every push to `main`.

This bakes all system (apt), Python (pip), and npm packages directly into the image:
- **Instant Coolify deployments**: Coolify just pulls the pre-built image in seconds without compiling or downloading packages on your VPS.
- **100% Consistent**: All Python tools and system binaries are guaranteed to be present on every redeployment.

For DSH web profile plugins (`dsh-better-sidebar`, `dshmarket`, etc.) and LLM provider configuration, you can run [install-some-stuff.sh](/install-some-stuff.sh) once inside the container (they persist in the `dsh-data` volume).

| Category | Packages | Baked in Dockerfile? |
|---|---|---|
| **System (apt)** | tesseract-ocr + eng/osd, ffmpeg, libreoffice (writer/calc/impress), poppler-utils | ✅ Yes |
| **Python (pip)** | 30 packages including openpyxl, pdfplumber, mammoth, python-pptx, pandas, pypdf, reportlab, pytesseract, azure-*, etc. | ✅ Yes |
| **npm (global)** | `docx`, `@firecrawl/anydoc` | ✅ Yes |
| **DSH plugins** | dsh-better-sidebar, dsh-mobile-hanui, dshmarket | Persists in `dsh-data` volume |
| **DSH settings** | LLM provider, agent default model, API key config | Persists in `dsh-data` volume |