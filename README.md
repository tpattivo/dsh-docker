Deploying DeepSeek Harness (`dsh`) on Coolify with Git 

Why this repo?
**the official `deepseek-ai/deepseek-harness` repo ships no Dockerfile** — it runs via `npx @deepseek-ai/dsh web` and, for security, DSH refuses `--host 0.0.0.0` (loopback-only). 

## Recommended setup: Git-based Docker Compose app

### 1. Create your own repo

Fork [smanx/deepseek-harness-docker](https://github.com/smanx/deepseek-harness-docker) or create a fresh repo containing just this `docker-compose.yml` (the image is prebuilt, so no build needed):

```yaml
services:
  dsh:
    build:
      context: .
      dockerfile: Dockerfile
    image: dsh-custom:latest
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
- Whenever you need to restart dsh:
  - Since you're on the `admin` variant:
Open `https://your-domain/__admin/` and use the one-click **restart** there. That's the intended management path for the admin image.
  - Use coolify UI or terminal on the host machine:
  ```bash
  docker restart <container-name>
  ```
#### Pre-baked dependencies & custom plugins
The [Dockerfile](/Dockerfile) automatically bakes the system (apt), Python (pip), and npm packages directly into the container image upon deployment, so you don't need to reinstall them every redeploy.

For DSH web profile plugins (`dsh-better-sidebar`, `dshmarket`, etc.) and LLM provider configuration, you can run [install-some-stuff.sh](/install-some-stuff.sh) once inside the container (they persist in the `dsh-data` volume).

| Category | Packages | Baked in Dockerfile? |
|---|---|---|
| **System (apt)** | tesseract-ocr + eng/osd, ffmpeg, libreoffice (writer/calc/impress), poppler-utils | ✅ Yes |
| **Python (pip)** | 30 packages including openpyxl, pdfplumber, mammoth, python-pptx, pandas, pypdf, reportlab, pytesseract, azure-*, etc. | ✅ Yes |
| **npm (global)** | `docx`, `@firecrawl/anydoc` | ✅ Yes |
| **DSH plugins** | dsh-better-sidebar, dsh-mobile-hanui, dshmarket | Persists in `dsh-data` volume |
| **DSH settings** | LLM provider, agent default model, API key config | Persists in `dsh-data` volume |