# syntax=docker/dockerfile:1

# ============================================================
# stage 1: deps — 의존성만 설치 (레이어 캐시 최적화)
# ============================================================
FROM node:24.19.0-slim AS deps
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

# ============================================================
# stage 2: builder — 소스 빌드
# NEXT_PUBLIC_* 는 빌드 타임에 번들로 인라인되므로 여기서 주입해야 한다.
# ============================================================
FROM node:24.19.0-slim AS builder
WORKDIR /app

ARG NEXT_PUBLIC_API_URL
ARG NEXT_PUBLIC_APP_ENV
ENV NEXT_PUBLIC_API_URL=${NEXT_PUBLIC_API_URL}
ENV NEXT_PUBLIC_APP_ENV=${NEXT_PUBLIC_APP_ENV}
ENV NEXT_TELEMETRY_DISABLED=1

COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN npm run build

# ============================================================
# stage 3: runner — standalone 산출물만 담은 최소 런타임 이미지
# ============================================================
FROM node:24.19.0-slim AS runner
WORKDIR /app

ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
ENV PORT=3000
ENV HOSTNAME=0.0.0.0

# 비루트 사용자
RUN groupadd --system --gid 1001 nodejs \
  && useradd --system --uid 1001 --gid nodejs nextjs

# output: "standalone" 산출물 + static + public 만 복사
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static
COPY --from=builder --chown=nextjs:nodejs /app/public ./public

USER nextjs
EXPOSE 3000

CMD ["node", "server.js"]
