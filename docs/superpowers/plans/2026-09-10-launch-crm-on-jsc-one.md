# Launch CRM on crm.jsc.one — Artifact-Authoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Scope note:** this plan covers only the *buildable artifacts* half of the
launch spec — forking the repo and authoring the three Dockerfiles plus
`docker-compose.yml`. It deliberately does **not** cover Cloudflare Tunnel
hostnames, the Google OAuth redirect URI, the Vercel AI Gateway account, the
Portainer stack creation, or secret generation — those are manual
third-party-dashboard steps only José can perform, and get walked through
separately via the `mattpocock-skills:wizard` skill once this plan's
artifacts exist and are pushed.

**Goal:** Fork `trycompai/crm`, add Docker build/run definitions for `app`,
`api`, and `agent`, and a `docker-compose.yml` wiring all four services
(including `postgres`) together — verified by building and running the full
stack locally before it's ever pushed to Portainer.

**Architecture:** Each service gets a multi-stage Dockerfile using
Turborepo's `turbo prune --docker` pattern (a pruned, cache-friendly copy of
just that service's workspace dependencies) — install stage, build stage,
minimal runtime stage with a non-root user, matching the house style already
established in `~/OS/resources/plausible/Dockerfile` (multi-stage, alpine
base, non-root final user, minimal final image). `docker-compose.yml` ties
them together on one internal network, with `postgres` using the official
`postgres:17-alpine` image already used in local dev.

**Tech Stack:** Bun 1.3.12, Turborepo 2.10.8 (`turbo prune --docker`),
`oven/bun` official Docker images, `postgres:17-alpine`.

**Spec:** `/Users/joesos/OS/projects/crm/docs/superpowers/specs/2026-09-10-launch-crm-on-jsc-one.md`

## Global Constraints

- Keep the forked CRM application source unmodified — only add new files
  (Dockerfiles, compose file, `.dockerignore`). No edits to `next.config.ts`
  or any existing app code, per the spec's "keep the fork close to upstream"
  intent.
- `agent` container needs `/var/run/docker.sock` mounted (Docker-outside-of-
  Docker, per the spec's explicit sandbox-backend decision) — not
  Docker-in-Docker, not `--privileged`.
- `agent`'s workflow state directory (`.eve/.workflow-data`) must be on a
  named volume so it survives container restarts.
- Every image build must be verified by actually building it — this Mac is
  arm64, the same architecture family as the target Pi, so a local build here
  is a real verification, not just a syntax check.
- Package names in the workspace (for `turbo prune`): `app`, `api`, `agent`.
  Root `packageManager` is `bun@1.3.12`.

---

### Task 1: Fork the repo and verify remotes

**Files:** none (git/GitHub operations only)

- [ ] **Step 1: Fork via gh CLI**

Run: `cd ~/OS/projects/crm && gh repo fork trycompai/crm --remote=false`

This creates `JOESOS4/crm` on GitHub (confirmed authenticated as `JOESOS4`
with `repo` scope) without touching the local clone's remotes yet.

- [ ] **Step 2: Add the fork as a new remote, keep upstream reachable**

```bash
git remote rename origin upstream
git remote add origin https://github.com/JOESOS4/crm.git
git remote -v
```

Expected: `upstream` points at `trycompai/crm` (fetch-only in practice,
since it's not writable), `origin` points at `JOESOS4/crm`.

- [ ] **Step 3: Push the current branch to the fork**

```bash
git push -u origin release
```

Expected: push succeeds, `release` now exists on `JOESOS4/crm`, including the
two commits already made this session (email-standardization work is in a
*different* repo, unrelated — the commits here are the spec/plan docs for
this launch).

- [ ] **Step 4: Verify**

Run: `gh repo view JOESOS4/crm --json defaultBranchRef,url`
Expected: repo exists, reachable, `release` branch present.

---

### Task 2: Root `.dockerignore`

**Files:**
- Create: `.dockerignore`

**Interfaces:** none — this only affects what Docker's build context includes.

- [ ] **Step 1: Write `.dockerignore`**

```
node_modules
**/node_modules
.git
.next
**/.next
dist
**/dist
.turbo
**/.turbo
.eve
**/.eve
.output
**/.output
*.log
.env
.env.*
!.env.example
out
**/out
```

- [ ] **Step 2: Verify it's picked up**

Run: `docker build --no-cache -f /dev/null . 2>&1 | head -1 || true` is not a
real check — instead verify by context size after Task 3's Dockerfile exists:
`du -sh .` vs. the size Docker reports as "transferring context" during that
build. Deferred to Task 3's own build step, since `.dockerignore` has no
independent test until something actually builds.

- [ ] **Step 3: Commit**

```bash
git add .dockerignore
git commit -m "chore: add .dockerignore for Docker builds"
```

---

### Task 3: `Dockerfile.api`

**Files:**
- Create: `Dockerfile.api`

**Interfaces:**
- Produces: an image that serves the NestJS/tRPC API on `PORT` (default
  `3001`), reading `DATABASE_URL`, `BETTER_AUTH_SECRET`, and the other env
  vars from the spec's Secrets table at runtime (not baked into the image).

- [ ] **Step 1: Write `Dockerfile.api`**

```dockerfile
# syntax=docker/dockerfile:1

FROM oven/bun:1.3-alpine AS pruner
WORKDIR /app
RUN bun add -g turbo@2.10.8
COPY . .
RUN turbo prune api --docker

FROM oven/bun:1.3-alpine AS installer
WORKDIR /app
COPY --from=pruner /app/out/json/ .
RUN bun install --frozen-lockfile
COPY --from=pruner /app/out/full/ .
RUN bun add -g turbo@2.10.8
RUN turbo run build --filter=api

FROM oven/bun:1.3-alpine AS runner
WORKDIR /app
RUN addgroup --system --gid 1001 crm && \
    adduser --system --uid 1001 crm
COPY --from=installer --chown=crm:crm /app .
USER crm
EXPOSE 3001
ENV PORT=3001
CMD ["bun", "apps/api/dist/main.js"]
```

- [ ] **Step 2: Build it locally to verify**

Run: `docker build -f Dockerfile.api -t crm-api:local .`
Expected: build succeeds (this pulls real dependencies and runs a real
`turbo run build --filter=api`, so failure here means a real problem, not a
syntax issue). If `turbo run build --filter=api` fails because `@crm/db`'s
Prisma client wasn't generated, add `RUN bunx turbo run db:generate --filter=@crm/db`
immediately before the `turbo run build --filter=api` line in the installer
stage, rebuild, and confirm it passes — `packages/db`'s `postinstall` script
runs `prisma generate` automatically on `bun install`, but verify this
actually fires inside the container (Bun's `postinstall` handling in
non-interactive Docker installs is exactly the kind of thing to confirm
rather than assume).

- [ ] **Step 3: Commit**

```bash
git add Dockerfile.api
git commit -m "feat: add Dockerfile for the api service"
```

---

### Task 4: `Dockerfile.app`

**Files:**
- Create: `Dockerfile.app`

**Interfaces:**
- Produces: an image that serves the Next.js app via `next start` on `PORT`
  (default `3000`), reading `API_URL`, `NEXT_PUBLIC_API_URL`, `APP_URL` at
  build time (per `turbo.json`'s `build.env` list for this task) and
  `BETTER_AUTH_SECRET`/etc. at runtime.

- [ ] **Step 1: Write `Dockerfile.app`**

```dockerfile
# syntax=docker/dockerfile:1

FROM oven/bun:1.3-alpine AS pruner
WORKDIR /app
RUN bun add -g turbo@2.10.8
COPY . .
RUN turbo prune app --docker

FROM oven/bun:1.3-alpine AS installer
WORKDIR /app
COPY --from=pruner /app/out/json/ .
RUN bun install --frozen-lockfile
COPY --from=pruner /app/out/full/ .
RUN bun add -g turbo@2.10.8
ARG API_URL
ARG APP_URL
ARG NEXT_PUBLIC_API_URL
ENV API_URL=$API_URL
ENV APP_URL=$APP_URL
ENV NEXT_PUBLIC_API_URL=$NEXT_PUBLIC_API_URL
RUN turbo run build --filter=app

FROM oven/bun:1.3-alpine AS runner
WORKDIR /app
RUN addgroup --system --gid 1001 crm && \
    adduser --system --uid 1001 crm
COPY --from=installer --chown=crm:crm /app .
USER crm
WORKDIR /app/apps/app
EXPOSE 3000
ENV PORT=3000
CMD ["bun", "run", "start"]
```

- [ ] **Step 2: Build it locally to verify**

Run:
```bash
docker build -f Dockerfile.app \
  --build-arg API_URL=https://crm-api.jsc.one \
  --build-arg APP_URL=https://crm.jsc.one \
  --build-arg NEXT_PUBLIC_API_URL=https://crm-api.jsc.one \
  -t crm-app:local .
```
Expected: build succeeds, `next build` completes. Same Prisma-generation
caveat as Task 3 applies if the app also imports `@crm/db` types at build
time — check the build log for a Prisma-related failure specifically before
assuming any other kind of error.

- [ ] **Step 3: Commit**

```bash
git add Dockerfile.app
git commit -m "feat: add Dockerfile for the app service"
```

---

### Task 5: `Dockerfile.agent`

**Files:**
- Create: `Dockerfile.agent`

**Interfaces:**
- Produces: an image running the eve agent's built output on port `2000`
  (matching `AGENT_PORT` default), reading `AI_GATEWAY_API_KEY`,
  `AGENT_BRIDGE_SECRET`, `DATABASE_URL` at runtime.
- Consumes: `/var/run/docker.sock` mounted at runtime (declared in Task 6's
  compose file, not in this Dockerfile — a Dockerfile can't mount a host
  socket, only `docker-compose.yml`'s `volumes:` can).

- [ ] **Step 1: Write `Dockerfile.agent`**

```dockerfile
# syntax=docker/dockerfile:1

FROM oven/bun:1.3-alpine AS pruner
WORKDIR /app
RUN bun add -g turbo@2.10.8
COPY . .
RUN turbo prune agent --docker

FROM oven/bun:1.3-alpine AS installer
WORKDIR /app
COPY --from=pruner /app/out/json/ .
RUN bun install --frozen-lockfile
COPY --from=pruner /app/out/full/ .
RUN bun add -g turbo@2.10.8
RUN turbo run build --filter=agent

FROM oven/bun:1.3-alpine AS runner
WORKDIR /app
RUN apk add --no-cache docker-cli
RUN addgroup --system --gid 1001 crm && \
    adduser --system --uid 1001 crm
COPY --from=installer --chown=crm:crm /app .
USER crm
WORKDIR /app/apps/agent
EXPOSE 2000
ENV AGENT_PORT=2000
CMD ["bun", "scripts/start.ts"]
```

Note: this stage does **not** add `crm` to a `docker` group or grant socket
access itself — that permission comes entirely from how the socket is
mounted in `docker-compose.yml` (Task 6). `docker-cli` is installed here only
so the agent process *can* issue Docker commands once it has socket access;
installing the CLI alone grants nothing without the mount.

- [ ] **Step 2: Build it locally to verify**

Run: `docker build -f Dockerfile.agent -t crm-agent:local .`
Expected: build succeeds, `eve build` (invoked via `turbo run build --filter=agent`,
per `apps/agent/package.json`'s `"build": "eve build"`) completes without
error.

- [ ] **Step 3: Commit**

```bash
git add Dockerfile.agent
git commit -m "feat: add Dockerfile for the agent service"
```

---

### Task 6: `docker-compose.yml`

**Files:**
- Create: `docker-compose.prod.yml` (named distinctly from the existing
  local-dev `docker-compose.yml`, which only runs Postgres — this one runs
  the full stack)

**Interfaces:**
- Consumes: the three images from Tasks 3-5 (`crm-api:local`, `crm-app:local`,
  `crm-agent:local` locally; Portainer will instead build these itself from
  the same three Dockerfiles once this is pushed — the `build:` sections
  below are what make that possible without any change to this file).

- [ ] **Step 1: Write `docker-compose.prod.yml`**

```yaml
services:
  postgres:
    image: postgres:17-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: crm
    volumes:
      - crm-postgres-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 10

  api:
    build:
      context: .
      dockerfile: Dockerfile.api
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      DATABASE_URL: postgresql://postgres:postgres@postgres:5432/crm?schema=public
      PORT: "3001"
      AGENT_URL: http://agent:2000
      BETTER_AUTH_SECRET: ${BETTER_AUTH_SECRET}
      ALLOWED_SIGN_IN: ${ALLOWED_SIGN_IN}
      GOOGLE_CLIENT_ID: ${GOOGLE_CLIENT_ID}
      GOOGLE_CLIENT_SECRET: ${GOOGLE_CLIENT_SECRET}
      API_URL: ${API_URL}
      APP_URL: ${APP_URL}
      AUTH_COOKIE_DOMAIN: ${AUTH_COOKIE_DOMAIN}
      AGENT_BRIDGE_SECRET: ${AGENT_BRIDGE_SECRET}
      CRON_SECRET: ${CRON_SECRET}

  app:
    build:
      context: .
      dockerfile: Dockerfile.app
      args:
        API_URL: ${API_URL}
        APP_URL: ${APP_URL}
        NEXT_PUBLIC_API_URL: ${API_URL}
    restart: unless-stopped
    depends_on:
      - api
    environment:
      PORT: "3000"

  agent:
    build:
      context: .
      dockerfile: Dockerfile.agent
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      DATABASE_URL: postgresql://postgres:postgres@postgres:5432/crm?schema=public
      AGENT_PORT: "2000"
      AI_GATEWAY_API_KEY: ${AI_GATEWAY_API_KEY}
      AGENT_BRIDGE_SECRET: ${AGENT_BRIDGE_SECRET}
    volumes:
      - crm-agent-workflow-data:/app/apps/agent/.eve/.workflow-data
      - /var/run/docker.sock:/var/run/docker.sock

volumes:
  crm-postgres-data:
  crm-agent-workflow-data:
```

**Known gap, deliberately not solved here:** mounting `/var/run/docker.sock`
into the `agent` container while it runs as the non-root `crm` user (Task 5)
will likely hit a permission error — the socket's group ownership on the
host must match a group the container's user belongs to, and that GID varies
per host (commonly, but not always, the `docker` group). This plan doesn't
know the Pi's actual GID, so it can't hardcode a fix. Flag this explicitly
for the wizard-skill pass: after the Portainer stack is first deployed, check
the `agent` container's logs for a socket-permission error, and if present,
either add `group_add: ["<pi's docker GID>"]` to the `agent` service here
(find the GID via `stat -c '%g' /var/run/docker.sock` on the Pi through
Portainer's console feature) or fall back to `user: root` for that one
service as a simpler, less-ideal fix. Don't assume this works untested.

- [ ] **Step 2: Verify the compose file's syntax**

Run: `docker compose -f docker-compose.prod.yml config --quiet`
Expected: no output, exit code 0 (a non-zero exit or any printed error means
invalid YAML or an undefined interpolation).

- [ ] **Step 3: Verify the full stack actually comes up locally**

```bash
export BETTER_AUTH_SECRET=$(openssl rand -base64 32)
export ALLOWED_SIGN_IN=jose@jsc.one
export GOOGLE_CLIENT_ID=placeholder
export GOOGLE_CLIENT_SECRET=placeholder
export API_URL=http://localhost:3001
export APP_URL=http://localhost:3000
export AUTH_COOKIE_DOMAIN=""
export AGENT_BRIDGE_SECRET=$(openssl rand -base64 32)
export CRON_SECRET=$(openssl rand -base64 32)
export AI_GATEWAY_API_KEY=placeholder

docker compose -f docker-compose.prod.yml up --build -d
sleep 20
docker compose -f docker-compose.prod.yml ps
curl -s -o /dev/null -w "api: %{http_code}\n" http://localhost:3001/health
curl -s -o /dev/null -w "app: %{http_code}\n" http://localhost:3000
docker compose -f docker-compose.prod.yml logs agent --tail=30
```

Expected: all 4 containers show `running`/`healthy`, `api` health check
returns `200`, `app` returns `200`. The agent's real functionality can't be
fully verified with placeholder credentials — but confirm from its logs that
it *starts* (reaches "server listening" or equivalent) rather than
crash-looping, which is the real question this step answers: does the image
run at all, not whether the placeholder API key actually works.

- [ ] **Step 4: Tear down**

```bash
docker compose -f docker-compose.prod.yml down -v
```

- [ ] **Step 5: Commit**

```bash
git add docker-compose.prod.yml
git commit -m "feat: add production docker-compose stack"
```

---

### Task 7: Push to the fork

**Files:** none (git operation only)

- [ ] **Step 1: Push all commits**

```bash
git push origin release
```

- [ ] **Step 2: Verify on GitHub**

Run: `gh repo view JOESOS4/crm --json url --jq .url` then confirm via
`gh api repos/JOESOS4/crm/contents/docker-compose.prod.yml --jq .name`
that the file is visible on the pushed branch.

Expected: `docker-compose.prod.yml` (plus the three Dockerfiles and
`.dockerignore`) are present on `JOESOS4/crm`'s `release` branch — this is
the URL the manual Portainer-stack step (handled separately, via the wizard
skill) will point at.

## Self-review notes

- **Spec coverage:** source/build (Tasks 1-2, 7), all 4 containers (Tasks
  3-6), the Docker-socket sandbox decision (Task 5's Dockerfile comment +
  Task 6's volume mount), `AUTH_COOKIE_DOMAIN`/secrets wiring (Task 6's
  environment block) — all present. Manual provisioning (tunnel, OAuth,
  Vercel, Portainer stack creation itself) explicitly out of scope per the
  header, deferred to the wizard-skill pass.
- **Placeholder scan:** none — every Dockerfile and the compose file are
  complete, runnable content, not sketches.
- **Type/interface consistency:** service names (`postgres`, `api`, `app`,
  `agent`) match exactly between `docker-compose.prod.yml`'s service
  definitions and the internal hostnames used in `DATABASE_URL`/`AGENT_URL`
  in the environment blocks.
