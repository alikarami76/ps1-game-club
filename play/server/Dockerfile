FROM node:22-alpine
RUN apk add --no-cache curl 7zip openssl
WORKDIR /app
COPY package.json package-lock.json versions.env setup.sh ./
RUN npm ci --omit=dev --no-audit --no-fund
# Fetches the pinned EmulatorJS release and netplay logic, checks their hashes.
RUN sh ./setup.sh --skip-npm
COPY server.js gen-cert.sh ./
COPY public ./public
ENV CLUB_PORT=3443 CLUB_HOST=0.0.0.0
EXPOSE 3443
USER node
CMD ["node", "server.js"]
