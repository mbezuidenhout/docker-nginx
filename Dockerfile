#
# NGINX Dockerfile
#

FROM nginx:latest
LABEL maintainer="Marius Bezuidenhout <marius.bezuidenhout@gmail.com>"

ENV PATH "/usr/local/bin:/usr/local/sbin:$PATH"
RUN apt-get update &&\
    apt-get install --no-install-recommends --assume-yes --quiet \
        ca-certificates openssl &&\
    apt-get clean &&\
    rm -rf /var/lib/apt/lists/* &&\
    ldconfig

EXPOSE 80 443

COPY docker-entrypoint.sh /usr/local/bin/
ENTRYPOINT ["docker-entrypoint.sh"]

CMD ["nginx", "-g", "daemon off;"]
