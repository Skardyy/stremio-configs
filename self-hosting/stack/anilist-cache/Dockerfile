FROM nginx:alpine
RUN apk add --no-cache "nginx-module-njs=${NGINX_VERSION}-r${PKG_RELEASE}" \
  || apk add --no-cache nginx-module-njs
COPY njs/ /etc/nginx/njs/
