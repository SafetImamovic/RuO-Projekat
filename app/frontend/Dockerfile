FROM nginx:alpine
# Šablon: entrypoint slike zamijeni ${NGINX_LOCAL_RESOLVERS} resolverom iz /etc/resolv.conf
# i zapiše rezultat u /etc/nginx/conf.d/default.conf.
ENV NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1
COPY nginx.conf /etc/nginx/templates/default.conf.template
COPY index.html /usr/share/nginx/html/index.html
