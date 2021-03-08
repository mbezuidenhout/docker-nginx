#!/bin/bash
set -euo pipefail

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
		echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
		exit 1
	fi
	local val="$def"
	if [ "${!var:-}" ]; then
		val="${!var}"
	elif [ "${!fileVar:-}" ]; then
		val="$(< "${!fileVar}")"
	fi
	export "$var"="$val"
	unset "$fileVar"
}

if [ -n "${RUN_GID:-}" ]; then
	echo "Changing process GID to ${RUN_GID}."
	if [ ! $(getent group ${RUN_GID}) ]; then
		export RUN_GROUP=custom-group
		addgroup -gid ${RUN_GID} ${RUN_GROUP}
	else
		export RUN_GROUP=$(getent group ${RUN_GID} | awk -F ":" '{ print $1 }')
	fi
fi

if [ -n "${RUN_UID:-}" ]; then
	echo "Changing process UID to ${RUN_UID}."
	if [ ! $(getent passwd ${RUN_UID}) ]; then
		export RUN_USER=custom-user
		adduser --gecos "" --home /var/www --ingroup ${RUN_GROUP} --no-create-home --disabled-password --disabled-login --uid ${RUN_UID} ${RUN_USER}
	else
		export RUN_USER=$(getent passwd ${RUN_UID} | awk -F ":" '{ print $1 }')
	fi
	sed -ri -e "s/^user.*$/user ${RUN_USER} ${RUN_GROUP};/" /etc/nginx/nginx.conf
	sed -ri -e "s/^worker_processes.*$/worker_processes auto;/" /etc/nginx/nginx.conf
fi

hostname="${SERVER_HOSTNAME:-localhost}"
: ${HTTPS_ENABLED:=false}
if [[ "$1" == nginx ]]; then
   	if [ "$(id -u)" = '0' ]; then
		user="${RUN_USER:-nginx}"
		group="${RUN_GROUP:-nginx}"
	else
		user="$(id -u)"
		group="$(id -g)"
	fi

	rm -f /etc/nginx/conf.d/default.conf

	if [ ! -e /etc/nginx/conf.d/php-fpm.conf ]; then
		cat > /etc/nginx/conf.d/php-fpm.conf << EOFFPM
upstream php-fpm {
	server ${PHP_FPM};
}
EOFFPM
	fi

	if [[ $HTTPS_ENABLED != "false" ]]; then
		if [ ! -e /etc/nginx/ssl/${hostname}.crt ] || [ ! -e /etc/nginx/ssl/${hostname}.key ]; then
			# if the certificates don't exist then make them
			mkdir -p /etc/nginx/ssl
			openssl req -days 356 -x509 -out /etc/nginx/ssl/${hostname}.crt -keyout /etc/nginx/ssl/${hostname}.key \
				-newkey rsa:2048 -nodes -sha256 \
				-subj '/CN='${hostname} -extensions EXT -config <( \
			printf "[dn]\nCN=${hostname}\n[req]\ndistinguished_name = dn\n[EXT]\nsubjectAltName=DNS:${hostname}\nkeyUsage=digitalSignature\nextendedKeyUsage=serverAuth")
		fi
		if [ ! -e /etc/nginx/ssl/dhparam.pem ]; then
			openssl dhparam -out /etc/nginx/ssl/dhparam.pem 4096
		fi

		if [ ! -e /etc/nginx/conf.d/http.conf ]; then
			cat > /etc/nginx/conf.d/http.conf << EOF301
server {
	listen 80;
	server_name ${hostname};
	return 301 https://\$host\$request_uri;
}
EOF301
		fi

		if [ ! -e /etc/nginx/conf.d/https.conf ]; then
			cat > /etc/nginx/conf.d/https.conf << EOFHTTPS
server {
	listen              *:443 ssl http2;
	server_name         ${hostname};
	ssl_certificate	    /etc/nginx/ssl/${hostname}.crt;
	ssl_certificate_key /etc/nginx/ssl/${hostname}.key;
	ssl_dhparam         /etc/nginx/ssl/dhparam.pem;
	ssl_protocols       TLSv1.1 TLSv1.2;
	ssl_prefer_server_ciphers on;
	ssl_ciphers         'ECDH+AESGCM:ECDH+AES256:ECDH+AES128:DH+3DES:!ADH:!AECDH:!MD5';
	ssl_session_cache   shared:SSL:20m;
	ssl_session_timeout 10m;
	server_tokens       off;
	add_header          Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
	add_header          X-Frame-Options "SAMEORIGIN";
	add_header          X-XSS-Protection "1; mode=block";
	add_header          X-Content-Type-Options nosniff;
	root                /var/www/html;

	gzip                on;
	gzip_vary           on;
	gzip_buffers        16 8k;
	gzip_types          text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;
	gzip_min_length     512;
	gzip_proxied        no-cache no-store private expired auth;
	gzip_disable        "MSIE [1-6]\.";
	gunzip              on;

	location = /favicon.ico {
		log_not_found off;
		access_log off;
	}

	location = /robots.txt {
		allow all;
		log_not_found off;
		access_log off;
	}

	location / {
		try_files \$uri \$uri/ /index.php?\$args;
		index  index.php index.html index.htm;
	}

	location ~ \.php$ {
		fastcgi_pass   php-fpm;
		fastcgi_index  index.php;
		fastcgi_param  SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
		include        fastcgi_params;
		add_header Cache-Control "no-cache, no-store";
		expires 0;
		add_header Pragma no-cache;
	}

	location ~ /\. {
		deny  all;
	}

	location ~* \.(js|css|png|jpg|jpeg|gif|ico)$ {
 		charset utf-8;
 		charset_types *;
		expires max;
		log_not_found off;
	}

	location ~* /(?:uploads|files)/.*\.php$ {
		deny all;
	}
}
EOFHTTPS
		fi
	else
		if [ ! -e /etc/nginx/conf.d/http.conf ]; then
			cat > /etc/nginx/conf.d/http.conf << EOFHTTP
server {
	listen          80;
	server_name     ${hostname};
	server_tokens   off;
	add_header      Strict-Transport-Security max-age=63072000;
	add_header      X-Frame-Options "SAMEORIGIN";
	add_header      X-XSS-Protection "1; mode=block";
	add_header      X-Content-Type-Options nosniff;
	root            /var/www/html;

	gzip            on;
	gzip_vary       on;
	gzip_buffers    16 8k;
	gzip_types      text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;
	gzip_min_length 512;
	gzip_proxied    no-cache no-store private expired auth;
	gzip_disable    "MSIE [1-6]\.";
	gunzip          on;

	location = /favicon.ico {
		log_not_found off;
		access_log off;
	}

	location = /robots.txt {
		allow all;
		log_not_found off;
		access_log off;
	}

	location / {
		try_files \$uri \$uri/ /index.php?\$args;
		index  index.php index.html index.htm;
	}

	location ~ \.php$ {
		fastcgi_pass   php-fpm;
		fastcgi_index  index.php;
		fastcgi_param  SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
		include        fastcgi_params;
		add_header Cache-Control "no-cache, no-store";
		expires 0;
		add_header Pragma no-cache;
	}

	location ~ /\. {
		deny  all;
	}

	location ~* \.(js|css|png|jpg|jpeg|gif|ico)$ {
 		charset utf-8;
 		charset_types *;
		expires max;
		log_not_found off;
	}

	location ~* /(?:uploads|files)/.*\.php$ {
		deny all;
	}
}
EOFHTTP
		fi
	fi

	# now that we're definitely done writing configuration, let's clear out the relevant envrionment variables (so that stray "phpinfo()" calls don't leak secrets from our code)
	for e in "${envs[@]}"; do
		unset "$e"
	done
fi

exec "$@"
