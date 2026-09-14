FROM node:24-alpine AS builder

WORKDIR /site

COPY package.json package-lock.json ./
RUN npm ci

COPY . .
RUN npm run build:firebase

FROM nginxinc/nginx-unprivileged:stable-alpine

COPY cloud-run/nginx.conf /etc/nginx/conf.d/default.conf
COPY cloud-run/security-headers.conf /etc/nginx/nextstop-security-headers.conf
COPY --from=builder /site/firebase-public /usr/share/nginx/html

EXPOSE 8080
