ARG BUN_IMAGE=oven/bun:1.4.2-slim
FROM ${BUN_IMAGE} AS build
WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile
COPY . .
RUN bun run check && bun run test && bun run build

FROM ${BUN_IMAGE} AS dependencies
WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile --production

FROM ${BUN_IMAGE} AS runtime
WORKDIR /app
ENV NODE_ENV=production HOST=0.0.0.0 PORT=3000 RD_DATABASE=/data/rd.sqlite3
COPY --from=dependencies /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY server.ts package.json ./
RUN mkdir -p /data && chown bun:bun /data
USER bun
VOLUME ["/data"]
EXPOSE 3000
HEALTHCHECK CMD ["bun", "-e", "const r=await fetch('http://127.0.0.1:'+process.env.PORT+'/healthz');process.exit(r.ok?0:1)"]
CMD ["bun", "server.ts"]
