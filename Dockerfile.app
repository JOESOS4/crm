# syntax=docker/dockerfile:1

FROM oven/bun:1.3-alpine AS pruner
WORKDIR /app
RUN bun add -g turbo@2.10.8
COPY . .
RUN turbo prune app --docker

FROM oven/bun:1.3-alpine AS installer
WORKDIR /app
COPY --from=pruner /app/out/json/ .
RUN bun install --frozen-lockfile --ignore-scripts
COPY --from=pruner /app/out/full/ .
ARG DATABASE_URL=postgresql://build:build@localhost:5432/build
ENV DATABASE_URL=$DATABASE_URL
RUN bun install --frozen-lockfile
RUN bun add -g turbo@2.10.8
ARG API_URL
ARG APP_URL
ARG NEXT_PUBLIC_API_URL
ENV API_URL=$API_URL
ENV APP_URL=$APP_URL
ENV NEXT_PUBLIC_API_URL=$NEXT_PUBLIC_API_URL
RUN turbo run build --filter=app || true
RUN test -d apps/app/.next && \
    test -f apps/app/.next/BUILD_ID && \
    test -d apps/app/.next/static/$(cat apps/app/.next/BUILD_ID)

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
