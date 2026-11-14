# syntax=docker/dockerfile:1.4
# Branding builder and server for Living Atlas
# Supports building from local directory or git repository
# Supports both Brunch and Vite build systems

# ============================================
# GLOBAL BUILD ARGUMENTS
# ============================================
ARG NODE_VERSION=22
ARG NGINX_VERSION=1.30-alpine
ARG BUILD_SOURCE=local
ARG GIT_URL=""
ARG GIT_REF=master
ARG TARGET=production

# ============================================
# Stage 1: Source from local directory
# ============================================
FROM alpine:3.22 AS source-local

WORKDIR /source

# Copy branding source from build context
# Ansible will copy the local directory here
COPY . .

RUN echo "✅ Using local source" && \
    ls -la /source/ && \
    test -f package.json || (echo "❌ No package.json found!" && exit 1)

# ============================================
# Stage 2: Source from git repository
# ============================================
FROM alpine:3.22 AS source-git

ARG GIT_URL
ARG GIT_REF

RUN apk add --no-cache git && \
    if [ -z "$GIT_URL" ]; then \
    echo "❌ GIT_URL not provided for git source!"; \
    exit 1; \
    fi

WORKDIR /source

RUN echo "🔄 Cloning from git..." && \
    echo "   URL: $GIT_URL" && \
    echo "   Ref: $GIT_REF" && \
    git clone "$GIT_URL" . && \
    git checkout "$GIT_REF" && \
    echo "📦 Updating submodules (pinned commits)..." && \
    git submodule sync --recursive && \
    git submodule update --init --recursive --force && \
    echo "✅ Git clone completed" && \
    echo "📂 Submodule status:" && \
    git submodule status && \
    echo "📂 Directory structure (root):" && \
    ls -la /source/ && \
    echo "📂 Submodule content (check for build/js):" && \
    ls -R /source/commonui-bs3-2019/build 2>/dev/null || echo "⚠️ commonui-bs3-2019/build is missing"

# ============================================
# Stage 3: Select source based on BUILD_SOURCE
# ============================================
FROM source-${BUILD_SOURCE} AS source

# ============================================
# Stage 4: Base builder with Node.js
# ============================================
FROM node:${NODE_VERSION}-bookworm-slim AS builder-base

WORKDIR /build

# Install git for potential submodule operations
RUN apt-get update && \
    apt-get install -y --no-install-recommends git ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Copy source from selected stage
COPY --from=source /source /build

# ============================================
# Stage 5: Install dependencies
# ============================================
FROM builder-base AS dependencies

# Use cache mount for npm/yarn cache
RUN --mount=type=cache,target=/root/.npm \
    --mount=type=cache,target=/root/.cache/yarn \
    if [ -f "package-lock.json" ]; then \
    echo "📦 Installing dependencies with npm ci..."; \
    npm ci; \
    elif [ -f "yarn.lock" ]; then \
    echo "📦 Installing dependencies with yarn..."; \
    yarn install --frozen-lockfile; \
    else \
    echo "📦 Installing dependencies with npm install..."; \
    npm install; \
    fi && \
    echo "✅ Main dependencies installed"

# ============================================
# Stage 6: Production build
# ============================================
FROM dependencies AS builder-production

# The one prebuilt file ALA's commonui-bs5-2019 expects and nobody ships.
#
# Its gulpfile reads source/vendor/bootstrap/dist/js/bootstrap.bundle.js. That vendor
# directory is Bootstrap's own repository, which does not commit dist/, so the gulp build
# dies in 30 ms with "File not found with singular glob: .../bootstrap.bundle.js", takes
# build:bs5 down with it and the image ships with no /bs5 at all: every .mustache answers
# 404 and the ala-bootstrap5 apps (alerts > 5.2.4, logger > 4.5.0, collectory > 6.2.2)
# render unstyled with "$ is not defined". That is what happened on the CI portal from
# build 534 to 538, and it went unnoticed because nothing fails.
#
# The bundle is the published build of the very version the submodule pins, so it is taken
# from npm rather than rebuilt here: Bootstrap's own build would pull its whole toolchain
# for one file. Everything else the gulpfile needs (jquery, fontawesome, the scss) is in
# the checkout already. Skipped when the file is there, and NOT fatal when it cannot be
# fetched (no network, a version npm does not have): the portal still comes up, just
# without /bs5, which is the same trade-off as the build:bs5 step below.
RUN BS=commonui-bs5-2019/source/vendor/bootstrap; \
    if [ -d "$BS" ] && [ ! -f "$BS/dist/js/bootstrap.bundle.js" ]; then \
    V="$(node -p "require('./$BS/package.json').version" 2>/dev/null)"; \
    echo "🔧 bootstrap ${V:-?}: vendoring dist/js/bootstrap.bundle.js from npm"; \
    if [ -n "$V" ] && (cd /tmp && npm pack "bootstrap@$V" >/dev/null 2>&1) && \
    tar xzf "/tmp/bootstrap-$V.tgz" -C /tmp && \
    mkdir -p "$BS/dist/js" && \
    cp /tmp/package/dist/js/bootstrap.bundle.js "$BS/dist/js/"; then \
    echo "✅ bootstrap bundle in place"; \
    else \
    echo "⚠️  could not vendor the bootstrap bundle: commonui-bs5-2019 will not build and"; \
    echo "⚠️  this branding ships WITHOUT /bs5 (ala-bootstrap5 apps render unstyled)."; \
    fi; \
    rm -rf /tmp/package /tmp/bootstrap-*.tgz; \
    fi

# Detect the build system the same way base-branding's deploy.sh does: brunch projects
# build with `brunch build --production` (output: public/), everything else is treated as
# Vite and uses the package.json build script (output: dist/, normalized below). This is
# resilient to a stale/half-migrated package.json "build" script (e.g. a brunch checkout
# whose build script was edited to `vite build` without vite installed).
# The exit code of the build is kept and reported. It used to hang off the same && chain
# as the `ls` below, and `a && b || ls dist` means a failed build is swallowed whenever an
# earlier step left an output directory behind. base-branding's `build` script ends in
# `&& npm run build:bs5`, so the two vite builds would write dist/, build:bs5 would die on
# the missing bootstrap bundle, npm would exit non-zero and the `ls dist/` fallback turned
# the whole step green: the image shipped without /bs5 and the log said "Build completed".
# Still not fatal, for the reason the build:bs5 step below gives, but it says so now.
RUN echo "🔨 Building for production..." && \
    if grep -q '"brunch"' package.json; then \
    echo "🔧 Brunch detected -> brunch build --production"; \
    npx brunch build --production; \
    else \
    echo "🔧 Vite/other detected -> npm run build"; \
    npm run build; \
    fi; \
    rc=$?; \
    if [ "$rc" -ne 0 ]; then \
    echo "⚠️  the build script exited $rc: what it had written is kept, what came after it"; \
    echo "⚠️  (build:bs5, among others) did NOT run. See the error above."; \
    else \
    echo "✅ Build completed"; \
    fi; \
    echo "📂 Build output:"; \
    ls -la public/ 2>/dev/null || ls -la dist/ 2>/dev/null || { echo "❌ No build output found!"; exit 1; }

# Bootstrap 5 assets, when the branding source offers them.
#
# ala-bootstrap5 apps (alerts > 5.2.4, logger > 4.5.0, collectory > 6.2.2) fetch
# {assets,banner,footer}.mustache from their branding; the Bootstrap 3 build only has the
# .html ones. Without this the mustache answer 404, the app renders with no CSS at all and
# its console shows "$ is not defined" -- and nothing fails, so the build stays green.
#
# base-branding's `build:bs5` writes dist/bs5/ and must run AFTER the main build: it reuses
# the vite output and only adds the Bootstrap 5 directory. Optional on purpose -- a brunch
# fork or an older branding has no such script, and those portals keep Bootstrap 3 apps.
#
# NOT fatal, on purpose. build:bs5 needs commonui-bs5-2019/build to exist already: ALA
# stopped committing it, Bootstrap 5 does not commit its own dist/ either, and the gulp
# build that would produce both cannot run from the sources this image copies (no .git,
# no vendor dist). base-branding says so in scripts/build-commonui.mjs, where the no-git
# path reuses "the build made on that checkout when there is one". So this image ships
# /bs5 only when whoever prepared the checkout built it first, and a portal that publishes
# its Bootstrap 5 build elsewhere (header_and_footer_baseurl_bs5) never needs it here.
# Failing the image over an optional directory takes the whole portal down: build #534 did
# exactly that and left host 1 with no services at all.
RUN if node -e "process.exit(require('./package.json').scripts?.['build:bs5'] ? 0 : 1)" 2>/dev/null; then \
    echo "🔨 build:bs5 found -> building the Bootstrap 5 assets..."; \
    if npm run build:bs5 && [ -d dist/bs5 ]; then \
    echo "✅ Bootstrap 5 assets built:"; \
    ls -la dist/bs5/; \
    else \
    echo "⚠️  build:bs5 produced no dist/bs5: this branding ships WITHOUT /bs5, so an"; \
    echo "⚠️  ala-bootstrap5 app pointed at it renders unstyled (404 on the .mustache)."; \
    fi; \
    else \
    echo "ℹ️  no build:bs5 script: Bootstrap 5 assets not built"; \
    fi

# Normalize output directory to /build/public.
# The second branch is for brunch: it leaves public/ in place, so dist/bs5 (written by
# build:bs5 above) is not moved with it and the Bootstrap 5 assets would be dropped.
# The comment stays out of the RUN: a # line inside a backslash continuation is a parser
# hazard, not a shell comment.
RUN if [ -d "dist" ] && [ ! -d "public" ]; then \
    echo "📝 Normalizing dist/ to public/"; \
    mv dist public; \
    fi && \
    if [ -d "dist/bs5" ] && [ ! -d "public/bs5" ]; then \
    echo "📝 Moving dist/bs5 next to the brunch output"; \
    mv dist/bs5 public/bs5; \
    fi && \
    ls -la public/

# ============================================
# Stage 7: Development mode with hot-reload
# ============================================
FROM dependencies AS development

EXPOSE 3000 5173

# Check which build system is in use
RUN if grep -q '"brunch"' package.json; then \
    echo "🔧 Brunch detected - will use 'brunch watch --server'"; \
    elif grep -q '"vite"' package.json; then \
    echo "🔧 Vite detected - will use 'npm run dev'"; \
    else \
    echo "⚠️  Unknown build system"; \
    fi

# Default command for development
CMD if grep -q '"brunch"' package.json; then \
    echo "🚀 Starting Brunch dev server..."; \
    npx brunch watch --server --host 0.0.0.0; \
    else \
    echo "🚀 Starting Vite dev server..."; \
    npm run dev -- --host 0.0.0.0; \
    fi

# ============================================
# Stage 8: Production runtime with Nginx
# ============================================
FROM nginx:${NGINX_VERSION} AS production

# Copy built assets from builder
COPY --from=builder-production /build/public /usr/share/nginx/html

# Copy nginx config (copied to build context by Ansible)
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget --quiet --tries=1 --spider http://localhost/ || exit 1

# Labels
LABEL org.opencontainers.image.title="ALA Branding Service"
LABEL org.opencontainers.image.description="Living Atlas branding assets served with Nginx"

CMD ["nginx", "-g", "daemon off;"]

# ============================================
# Final stage selection
# ============================================
FROM ${TARGET} AS final
