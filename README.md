# bezuidenhout/nginx on docker.io
Official nginx image with UID/GID options

## Notes
The container creates a dhparam file which can take several minutes on a slower system.

# How to use
`docker run -d -e RUN_UID=1000 -e RUN_GID=1000 -e PHP_FPM="php-fpm-server:9000" -p 80:80 -p 443:443 -v /www:/var/www/html bezuidenhout/nginx`
