# Imagen para los microservicios Node/TypeScript del hotel (hotel-ms-usuarios y hotel-ms-reservas).
# Se construye con el repositorio del microservicio como contexto: ver docker-compose.yml.
FROM node:22-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build && npm prune --omit=dev

FROM node:22-alpine
ENV NODE_ENV=production
WORKDIR /app
COPY --from=build /app/package*.json ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
USER node
CMD ["node", "dist/src/index.js"]
