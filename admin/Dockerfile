FROM node:22-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
ARG VITE_API_BASE_URL=http://localhost:8000
ENV VITE_API_BASE_URL=$VITE_API_BASE_URL
RUN npm run build

FROM nginx:1.27-alpine
COPY --from=build /app/dist /usr/share/nginx/html
# SPA routing + basic hardening headers
RUN printf 'server {\n listen 80;\n root /usr/share/nginx/html;\n add_header X-Frame-Options DENY;\n add_header X-Content-Type-Options nosniff;\n add_header Referrer-Policy no-referrer;\n location / { try_files $uri /index.html; }\n}\n' > /etc/nginx/conf.d/default.conf
EXPOSE 80
