# Launch the CRM on crm.jsc.one — design

2026-09-10 · claude

## Problem

The CRM (`trycompai/crm`, evaluated locally through this session) needs a real
production home: JSC's own Postgres-backed CRM for client/deal management,
reachable at a `jsc.one` subdomain, with the eve research agent included from
day one. It needs to run on infrastructure José already owns and operates — a
Raspberry Pi running Docker/Portainer, already serving Umami and Plausible
through an existing Cloudflare Tunnel — without adding a second Pi, a new
hosting account beyond what's strictly required, or any step that needs
direct network/SSH access to the Pi (José is often working remotely, with only
Portainer's web UI reachable through the tunnel — no jump server, no port
forwarding).

## Design

### Source & build

`~/OS/projects/crm`'s `origin` points at the upstream `trycompai/crm` GitHub
repo — not José's to push to. The plan:

1. **Fork** `trycompai/crm` to José's own GitHub account.
2. Add three Dockerfiles (`Dockerfile.app`, `Dockerfile.api`,
   `Dockerfile.agent`) and one `docker-compose.yml` to the fork — multi-stage
   Bun builds, non-root final user, matching the house style already
   established in `~/OS/resources/plausible/Dockerfile` (multi-stage, alpine
   base where feasible, non-root, minimal final image).
3. **Portainer's Stacks feature** (not "Images → Build a new image" — that
   path has a known, currently-open upload bug, portainer/portainer#12424,
   where files selected via "Select Files" don't reliably land in the build
   context) builds directly from the fork's git URL. Portainer clones the
   repo itself and builds on the Pi — no file transfer from José's machine to
   the Pi, no registry, no SSH.

The Pi is confirmed 8GB RAM (corrected mid-session from an initial 4GB
assumption) — real headroom for 4 containers plus the existing Umami/Plausible
load. José's own Mac is Apple Silicon (arm64), the same architecture family as
the Pi, though this is moot once building happens on the Pi directly rather
than being cross-compiled elsewhere.

### Containers

Four services, one `docker-compose.yml`, one internal Docker network so
services reach each other by service name (`api` → `postgres:5432`, `api` →
`agent:2000`) with nothing but the two public hostnames below exposed to the
tunnel:

| Service | Base | Runs |
|---|---|---|
| `app` | Bun, multi-stage | `next start` |
| `api` | Bun, multi-stage | `bun dist/main.js` (`start:prod`) |
| `agent` | Bun, multi-stage | `eve build` then `bun scripts/start.ts` (`apps/agent`'s own `start` script) |
| `postgres` | `postgres:17-alpine` (official image, matches local dev `docker-compose.yml`) | — |

The `agent` service needs a `SandboxBackend` selection for isolated code
execution (per eve's self-host guide: Docker, microsandbox, or a custom
adapter). **Decision: Docker, via the host's Docker socket mounted into the
`agent` container** (`/var/run/docker.sock`) — the standard
"Docker-outside-of-Docker" pattern, simpler and lower-overhead than true
Docker-in-Docker, and consistent with the Pi already running everything
through Docker/Portainer. This is a real, named security trade-off, not a
free choice: a container with the host's Docker socket can control every
other container on that host, including `postgres` and `api` — effectively
root-equivalent host access. Accepted here because the Pi is single-operator
infrastructure already trusted with Umami/Plausible and the rest of this
stack; revisit toward `microsandbox` (no host Docker access needed) if the
agent's tool-execution surface ever needs to be treated as less trusted than
the rest of the stack.

The `agent`'s Workflow state (`.eve/.workflow-data` by default, per eve's
self-host docs) must be mounted on a persistent volume — container restarts
would otherwise lose in-flight agent runs.

### Routing

Two public hostnames added to José's **existing** Cloudflare Tunnel (the one
already serving Umami/Plausible under `squigle.space` — a single tunnel isn't
bound to one zone; public-hostname routing can point at any domain in the
same Cloudflare account):

- `crm.jsc.one` → `app` container
- `crm-api.jsc.one` → `api` container

The `agent` container is **not** publicly exposed — only `api` talks to it,
over the internal Docker network, via `AGENT_URL=http://agent:2000`.

`AUTH_COOKIE_DOMAIN=.jsc.one` so the session cookie the API mints is readable
by the app across the two subdomains (per the CRM's own README: "if the two
are on different subdomains of one parent, set `AUTH_COOKIE_DOMAIN`").

### Secrets

| Variable | Value | Notes |
|---|---|---|
| `BETTER_AUTH_SECRET` | fresh, generated for production | Not the local-dev value already in `~/OS/projects/crm/.env` |
| `DATABASE_URL` | `postgresql://postgres:postgres@postgres:5432/crm?schema=public` | Points at the `postgres` service by name, not `localhost` |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | the existing client (`622681293502-...`) | Add `https://crm-api.jsc.one/api/auth/callback/google` as a new Authorized redirect URI on that same client — no second OAuth client needed |
| `ALLOWED_SIGN_IN` | `jose@jsc.one` | |
| `API_URL` | `https://crm-api.jsc.one` | |
| `APP_URL` | `https://crm.jsc.one` | |
| `AUTH_COOKIE_DOMAIN` | `.jsc.one` | |
| `AGENT_URL` | `http://agent:2000` | Internal, not public |
| `AGENT_BRIDGE_SECRET` | fresh, shared between `api` and `agent` | Lets a signed-in rep talk to the agent from the record sheet; also authorises the API's dispatch-poke and Context-key checks |
| `AI_GATEWAY_API_KEY` | from a new Vercel account, JSC-scoped | See "Model credential" below |
| `CRON_SECRET` | fresh | Point a scheduler at `POST /internal/sync/mailboxes` per the README's deploy note, if mailbox sync matters for this launch — otherwise can be deferred |

### Model credential

The CRM's default agent model is `zai/glm-5.2-fast` (`packages/db/src/settings.ts:11`)
— Vercel AI Gateway's own `provider/model` routing syntax. Per eve's
self-host docs, an `AI_GATEWAY_API_KEY` works from any host, not just
Vercel-hosted apps — confirmed via Vercel's own AI Gateway docs ("you can use
the AI Gateway with just an API key from any environment"). Decision made
this session: use AI Gateway rather than switching to a direct provider key,
specifically to keep the CRM's built-in Settings-page model-switching
feature working as designed, rather than hardcoding a provider in `agent.ts`
(a real deviation from upstream, not a config toggle).

Vercel account is JSC-scoped (`jose@jsc.one`), used *only* to generate the
API key and hold a payment method — no project gets deployed there, no
hosting footprint.

## Explicitly deferred / out of scope for this launch

- Apple Mail send-as parity (parked earlier this session, unrelated to this launch).
- `CRON_SECRET` / mailbox-sync scheduling — only needed if this launch wants
  that feature live immediately; can ship without it and add later.
- Anything about moving the *agent itself* to Vercel hosting — explicitly
  rejected this session in favor of self-hosting it as the 4th Pi container.

## Testing this out

Once the stack is live: sign in at `crm.jsc.one` with `jose@jsc.one`,
confirm a record's Agent tab reaches the self-hosted agent (not a "not
configured" state), and confirm the model-switching Settings page can
actually change the model and have a new agent session pick it up — this is
the concrete proof the AI Gateway credential is wired correctly end to end.
