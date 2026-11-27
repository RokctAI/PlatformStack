# Sites runner: Next.js sites on the Master VPS

Hosts our Next.js sites on the VPS with no hand-written reverse proxy and no pm2.

## Add a site
1. Add an entry to `sites.json`:
   ```json
   {"name": "polaris", "repo": "https://github.com/RokctAI/polaris-web", "ref": "main",
    "domains": ["polaris.example.co.za"], "memory": "512m"}
   ```
2. Run `python3 platform/scripts/sites.py` and commit `sites.json`, `routes/routes.list` and
   `docker-compose.sites.yml` (CI fails if they are out of step).
3. Merge. deploy-master copies the files, builds the site image and starts it.
4. Point the domain's DNS (A record) at the VPS. The certificate is issued on its own
   within about 10 minutes of DNS pointing here; HTTP works before that, HTTPS after.

## What runs it
- Image: `platform/juvo-shell/Dockerfile`, the same build Vercel ran
  (`npm ci && bash scripts/compose.sh && npm run build`, then `next start`).
- Container `site-<name>` on `rokct_tenants`, memory capped, `restart: unless-stopped`.
- `rokct-ingress` writes `/etc/nginx/conf.d/10-sites.conf` from `routes/routes.list`
  (HTTP + ACME until the cert exists, then HTTPS redirect) and reloads itself.
- `hub-cert` issues and renews each domain's Let's Encrypt certificate.

## Rollback
Set the site's `ref` back to the previous commit SHA, regenerate, merge. Each ref is its own
image tag (`rokct/site-<name>:<ref>`), so an earlier image is reused without a rebuild.

## Secrets
Runtime env per site: `platform/sites/<name>.env` on the VPS (gitignored). Private repos need
`SITES_GIT_TOKEN` in Occultation `production.env`; deploy-master writes it to
`platform/sites/.git_token` (gitignored), used only for the fetch.

## Not done yet
Sites run all the time; there is no stop-when-idle. At about 150-250 MB per site, 9 sites
fit on an 8 GB VPS beside the hub. Start-on-demand is the next step if many more sites come.
