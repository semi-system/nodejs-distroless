ARG NODE_MAJOR=22
FROM node:${NODE_MAJOR}-bookworm-slim AS node

# The npm bundled with Node.js ships dependencies with known CVEs. Fetch the
# newest npm instead and upgrade the bundled dependencies it has not bumped
# yet; NAME@MAJOR moves one to a newer major when only that has the fix.
# Drop an entry from the list once npm ships the fix itself.
FROM cgr.dev/chainguard/wolfi-base:latest AS npm
ARG CACHE_BUST=local
ARG NPM_MAJOR=12
ARG NPM_DEPENDENCY_OVERRIDES="ip-address undici glob@14 minimatch@11"
COPY scripts/fetch-npm.sh /usr/local/bin/fetch-npm
RUN test -n "$CACHE_BUST" && \
    apk add --no-cache ca-certificates curl jq openssl && \
    NPM_MAJOR="$NPM_MAJOR" NPM_DEPENDENCY_OVERRIDES="$NPM_DEPENDENCY_OVERRIDES" \
      sh /usr/local/bin/fetch-npm /npm

FROM cgr.dev/chainguard/wolfi-base:latest

ARG NODE_MAJOR
ARG CACHE_BUST=local

RUN test -n "$CACHE_BUST" && \
    apk upgrade --no-cache && \
    apk add --no-cache \
      build-base \
      ca-certificates \
      git \
      python-3

# Node.js and corepack come from the official Docker image (the GPG-verified
# nodejs.org release). The headers let node-gyp build native addons without
# downloading them.
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules/corepack/ /usr/local/lib/node_modules/corepack/
COPY --from=node /usr/local/include/node/ /usr/local/include/node/
COPY --from=npm /npm/ /usr/local/lib/node_modules/npm/
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm && \
    ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx && \
    if [ -e /usr/local/lib/node_modules/corepack/dist/corepack.js ]; then \
      ln -s ../lib/node_modules/corepack/dist/corepack.js /usr/local/bin/corepack; \
    fi && \
    node --version | grep -E "^v${NODE_MAJOR}\." && \
    npm --version

ENV npm_config_nodedir=/usr/local
WORKDIR /app
CMD ["node"]
