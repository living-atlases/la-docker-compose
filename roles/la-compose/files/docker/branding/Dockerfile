# syntax=docker/dockerfile:1.4
# Branding builder and server for Living Atlas
# Supports building from local directory or git repository
# Supports both Brunch and Vite build systems

# ============================================
# GLOBAL BUILD ARGUMENTS
# ============================================
ARG NODE_VERSION=18
ARG NGINX_VERSION=1.27-alpine
ARG BUILD_SOURCE=local
ARG GIT_URL=""
ARG GIT_REF=master
ARG TARGET=production

# ============================================
# Stage 1: Source from local directory
# ============================================
FROM alpine:3.19 AS source-local

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
FROM alpine:3.19 AS source-git

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
    if [ -f "yarn.lock" ]; then \
    echo "📦 Installing dependencies with yarn..."; \
    yarn install --frozen-lockfile; \
    elif [ -f "package-lock.json" ]; then \
    echo "📦 Installing dependencies with npm ci..."; \
    npm ci; \
    else \
    echo "📦 Installing dependencies with npm install..."; \
    npm install; \
    fi && \
    echo "✅ Main dependencies installed"

# ============================================
# Stage 6: Production build
# ============================================
FROM dependencies AS builder-production

RUN echo "🔨 Building for production..." && \
    if [ -f "yarn.lock" ]; then \
    yarn build; \
    else \
    npm run build; \
    fi && \
    echo "✅ Build completed" && \
    echo "📂 Build output:" && \
    ls -la public/ 2>/dev/null || ls -la dist/ 2>/dev/null || (echo "❌ No build output found!" && exit 1)

# Normalize output directory to /build/public
RUN if [ -d "dist" ] && [ ! -d "public" ]; then \
    echo "📝 Normalizing dist/ to public/"; \
    mv dist public; \
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
