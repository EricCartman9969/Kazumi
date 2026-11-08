# Headless Chromium + the resolver. Runs on x86_64 and arm64 (Apple silicon, most NAS).
FROM mcr.microsoft.com/playwright:v1.56.1-noble
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund
COPY server.js inject.js ./
ENV PORT=8787 HOST=0.0.0.0 MAX_PAGES=3
EXPOSE 8787
USER pwuser
CMD ["node", "server.js"]
