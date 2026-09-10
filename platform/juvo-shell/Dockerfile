# Generic image for a VPS-hosted RokctAI Next.js shell (first user: juvo, the
# delivery platform shell in RokctAI/delivery-frontend). The shell repo ships no
# Dockerfile: it is built the way Vercel builds it (vercel.json buildCommand),
# `bash scripts/compose.sh && npm run build`, composing offline from the SDK
# cache committed under .rokct/cache/. Reuse for any shell that follows that
# model by pointing SHELL_REPO / SHELL_REF at it.
#
#   docker build --build-arg SHELL_REF=<commit sha> -t rokct/juvo-shell .
#
# SHELL_REF is fetched by name, so a branch, tag or full commit SHA all work;
# pin a SHA for reproducible images. Private repos: pass a BuildKit secret
# named git_token (`--secret id=git_token,src=<file>`); it is read only for the
# fetch and never lands in a layer. NEXT_PUBLIC_* values are inlined at build
# time by Next.js, so anything the shell needs public goes in as a build arg
# (NEXT_PUBLIC_SITE_URL below); everything else is runtime env (env_file).

# --- Stage 1: fetch + compose + build ---------------------------------------
FROM node:24-bookworm-slim AS builder

ARG SHELL_REPO=https://github.com/RokctAI/delivery-frontend.git
ARG SHELL_REF=main
ARG NEXT_PUBLIC_SITE_URL=""
ENV NEXT_PUBLIC_SITE_URL=${NEXT_PUBLIC_SITE_URL} \
    NEXT_TELEMETRY_DISABLED=1

# python3: scripts/compose.sh runs the vendored SDK installers with it.
# git: to fetch the shell at the pinned ref.
RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends git ca-certificates python3 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN --mount=type=secret,id=git_token,required=false \
    git init -q . \
    && git remote add origin "${SHELL_REPO}" \
    && if [ -s /run/secrets/git_token ]; then \
         git -c http.extraheader="Authorization: Bearer $(cat /run/secrets/git_token)" fetch -q --depth 1 origin "${SHELL_REF}"; \
       else \
         git fetch -q --depth 1 origin "${SHELL_REF}"; \
       fi \
    && git checkout -q FETCH_HEAD \
    && rm -rf .git

# Same three commands as the shell's own CI "Compose Offline + Build" job.
RUN npm ci --no-audit --no-fund \
    && bash scripts/compose.sh \
    && npm run build \
    && npm prune --omit=dev --no-audit --no-fund

# --- Stage 2: runtime --------------------------------------------------------
FROM node:24-bookworm-slim AS runtime

ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME=0.0.0.0

WORKDIR /app
COPY --from=builder --chown=node:node /app/package.json /app/package-lock.json ./
COPY --from=builder --chown=node:node /app/node_modules ./node_modules
COPY --from=builder --chown=node:node /app/.next ./.next
COPY --from=builder --chown=node:node /app/public ./public
COPY --from=builder --chown=node:node /app/next.config.mjs ./

USER node
EXPOSE 3000
CMD ["npm", "run", "start"]
