# homelab-template

A GitOps starter for a single Docker host: push to `main` and your apps are deployed automatically.

- **[doco-cd](https://github.com/kimdre/doco-cd)** deploys every Docker Compose project in `apps/` from this repository.
- **[Traefik](https://traefik.io/)** is the reverse proxy, with Let's Encrypt certificates, an IP allowlist and optional mTLS client certificates.
- **[SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age)** encrypt secrets so they can be committed safely.
- **[just](https://github.com/casey/just)** provides recipes for local operations.

## How it works

```
GitHub repo ──webhook──▶ doco-cd ──▶ .doco-cd.yaml
                            │          ├─ doco-cd/compose.updater.yaml  (redeploys the updater)
                            │          └─ apps/*/compose.yaml           (auto-discovered, depth 1)
                            │
GitHub repo ◀──polls──  doco-cd-updater ──▶ .doco-cd.updater.yaml
                                             └─ doco-cd/compose.main.yaml (redeploys doco-cd itself)
```

Two doco-cd instances update each other, so a version bump of doco-cd (for example from Dependabot) also gets rolled out by Git:

- **doco-cd** (`doco-cd/compose.main.yaml`) receives GitHub webhooks and deploys `.doco-cd.yaml`: the updater instance plus every directory in `apps/` that contains a compose file.
- **doco-cd-updater** (`doco-cd/compose.updater.yaml`) polls the repository and deploys the `updater` target (`.doco-cd.updater.yaml`), which is the main doco-cd instance.

Secrets live next to each app as `secrets.enc.env` (SOPS-encrypted dotenv). doco-cd decrypts them at deploy time with the age key mounted as a Docker secret.

## Repository layout

```
.doco-cd.yaml               # deploy targets for the main doco-cd instance
.doco-cd.updater.yaml       # deploy target for the updater instance
.sops.yaml                  # SOPS creation rules (your age public key)
.github/dependabot.yml      # keeps image tags in compose files up to date
doco-cd/                    # both doco-cd instances + their secrets
apps/
  justfile                  # local operations (start/stop, encrypt, doco-cd API)
  mtls.just                 # mTLS CA and client certificate management
  traefik/                  # example app: the reverse proxy
    traefik.yml             # static config
    config/                 # dynamic config (middlewares, TLS options, external routes)
```

## Prerequisites

On the Docker host:

- Docker with the Compose plugin
- `just`, `sops`, `age`, `openssl`, `jq`
- DNS records for your hostnames (for example `*.example.com`) pointing at the host, with ports 80 and 443 reachable for the Let's Encrypt HTTP challenge
- A shared Docker network for Traefik: `docker network create proxy`
- Data directories under `/opt/docker-data/` (or change the volume paths in the compose files)

## Setup

1. **Create your repository** with "Use this template" on GitHub. A private repository is recommended.

2. **Generate an age key** on the Docker host:
   ```sh
   mkdir -p ~/.age
   age-keygen -o ~/.age/sops_age_key.txt
   age-keygen -y ~/.age/sops_age_key.txt   # prints your public key (age1...)
   ```
   Back up the private key somewhere safe. Without it you can't decrypt your secrets.

3. **Replace the placeholders.** Search for them with:
   ```sh
   grep -rn -e 'CHANGE ME' -e 'example.com' -e 'YOUR_' -e 'REPLACE_ME' .
   ```

   | Placeholder | Where | Replace with |
   |---|---|---|
   | `age1REPLACE_ME` | `.sops.yaml`, `apps/justfile` | your age public key |
   | `/path/to/.age/sops_age_key.txt` | `doco-cd/compose.*.yaml` | absolute path to the age private key on the host |
   | `YOUR_GITHUB_USER/YOUR_HOMELAB_REPO` | `doco-cd/compose.updater.yaml` | your repository |
   | `example.com` | Traefik labels, `apps/justfile`, `apps/traefik/config/*.yml` | your domain |
   | `admin@example.com` | `apps/traefik/traefik.yml` | your Let's Encrypt account email |
   | `192.168.1.0/24` | `apps/traefik/traefik.yml`, `apps/traefik/config/http-middlewares.yml` | your LAN subnet |
   | `Etc/UTC` | `doco-cd/compose.*.yaml` | your timezone |

   In `apps/justfile`, `SOPS_AGE_KEY_FILE` defaults to `~/.age/sops_age_key.txt` and can be overridden with an environment variable of the same name.

4. **Create the doco-cd secrets:**
   ```sh
   cp doco-cd/secrets.env.example doco-cd/secrets.env
   # fill in API_SECRET, GIT_ACCESS_TOKEN, WEBHOOK_SECRET
   cd apps
   just encrypt ../doco-cd/secrets.env > ../doco-cd/secrets.enc.env
   rm ../doco-cd/secrets.env
   ```
   Both doco-cd instances use this file. Commit `secrets.enc.env` and push.

5. **Bootstrap** on the Docker host (clone the repository first):
   ```sh
   cd apps
   just docker-up traefik
   just system-start          # starts doco-cd; from now on Git drives deployments
   ```

6. **Add a GitHub webhook** (repository → Settings → Webhooks):
   - Payload URL: `https://doco-cd.example.com/v1/webhook`
   - Content type: `application/json`
   - Secret: the `WEBHOOK_SECRET` from step 4
   - Events: just the push event

## Adding an app

Create `apps/<name>/compose.yaml`. doco-cd picks it up on the next push. Expose it through Traefik with labels:

```yaml
networks:
  proxy:
    external: true

services:
  whoami:
    image: traefik/whoami:v1.11
    container_name: whoami
    restart: unless-stopped
    networks:
      - proxy
    labels:
      traefik.enable: "true"
      traefik.http.services.whoami.loadbalancer.server.port: 80

      traefik.http.routers.whoami-http.entrypoints: web
      traefik.http.routers.whoami-http.middlewares: redirect-to-https@file
      traefik.http.routers.whoami-http.rule: Host(`whoami.example.com`)

      traefik.http.routers.whoami-https.entrypoints: web-secure
      traefik.http.routers.whoami-https.middlewares: secured@file   # LAN-only; drop for public access
      traefik.http.routers.whoami-https.rule: Host(`whoami.example.com`)
      # traefik.http.routers.whoami-https.tls.options: mtls-clients@file   # require a client cert
```

**Secrets for an app:** write a dotenv file and encrypt it next to the compose file:

```sh
cd apps
just encrypt myapp/.env > myapp/secrets.enc.env && rm myapp/.env
```

Then reference the variables in `compose.yaml` (`${MY_SECRET}`) or load them with `env_file: secrets.enc.env`.

**Non-Docker devices** such as a router or NAS can be routed through Traefik's file provider. See `apps/traefik/config/example-external.yml`.

To disable an app without deleting it, move it out of `apps/` or deeper than one level (for example `apps/_disabled/<name>`).

## Useful recipes

Run them from `apps/`:

| Recipe | What it does |
|---|---|
| `just` | list all recipes |
| `just docker-up <dir>` / `just docker-down <dir>` | start/stop one app locally, decrypting its `secrets.enc.env` |
| `just start-all` / `just stop-all` | start/stop every app (stops doco-cd first) |
| `just dcdstart` / `just dcdstop` | start/stop the main doco-cd |
| `just dcdl` / `just dcdul` | follow doco-cd / doco-cd-updater logs |
| `just encrypt <file>` | SOPS-encrypt a dotenv file to stdout |
| `just api-projects` | list projects through the doco-cd API |
| `just api-project <name> [start\|stop\|restart]` | show or control one project |

## mTLS client certificates (optional)

Instead of (or as well as) the IP allowlist, you can require a client certificate on a router. Each client gets its own intermediate CA, so you can revoke one device without reissuing the others.

```sh
cd apps
just mtls-ca-init               # one time: root CA (key stored SOPS-encrypted in traefik/mtls-ca/)
just mtls-client-add laptop     # issue a cert and regenerate traefik/config/tls-options.yml
just mtls-client-export laptop  # write laptop.p12 + print its import password
just mtls-client-list
just mtls-client-revoke laptop
```

Commit the generated files after each step (the recipes print which ones). Then enable mTLS on a router with `tls.options: mtls-clients@file`. Import the `.p12` on the device and delete the local copy.

## Security notes

- Never commit `.env`, `secrets.env` or `*.p12`. `.gitignore` covers the usual names.
- Only commit encrypted files: `*.enc.env`, `*.enc`.
- doco-cd has access to the Docker socket. Keep its UI behind `secured@file` or something stronger.
