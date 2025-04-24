FROM alpine:3.21 AS build
WORKDIR /tmp
RUN wget https://github.com/glpi-project/glpi/releases/download/10.0.18/glpi-10.0.18.tgz
RUN tar zxvf glpi-10.0.18.tgz

FROM nginx:1.28-alpine-slim
RUN apk add php83 php83-fpm
RUN apk add php83-dom php83-fileinfo php83-xml php83-json php83-simplexml php83-xmlreader \
    php83-xmlwriter php83-curl php83-gd php83-intl php83-mysqli php83-session php83-zlib \
    php83-bz2 php83-phar php83-zip php83-exif php83-ldap php83-openssl php83-opcache

# Adding PHP session security settings to php.ini
RUN echo "session.cookie_httponly = On" >> /etc/php83/php.ini && \
    echo "session.cookie_samesite = Lax" >> /etc/php83/php.ini && \
    echo "session.cookie_secure = Off" >> /etc/php83/php.ini

# Create necessary directories
RUN mkdir -p /var/www/html \
    && mkdir -p /etc/glpi \
    && mkdir -p /var/lib/glpi \
    && mkdir -p /var/log/glpi

# Copy GLPI files from build stage
COPY --from=build /tmp/glpi /var/www/html/

# Copy GLPI config and files to appropriate locations
RUN if [ -d /var/www/html/config ]; then \
        cp -r /var/www/html/config/* /etc/glpi/ || true; \
    fi && \
    if [ -d /var/www/html/files ]; then \
        cp -r /var/www/html/files/* /var/lib/glpi/ || true; \
    fi

# Create downstream.php configuration file
RUN mkdir -p /var/www/html/inc
COPY <<EOF /var/www/html/inc/downstream.php
<?php
define('GLPI_CONFIG_DIR', '/etc/glpi/');
if (file_exists(GLPI_CONFIG_DIR . '/local_define.php')) {
    require_once GLPI_CONFIG_DIR . '/local_define.php';
}
EOF

# Create local_define.php configuration file
COPY <<EOF /etc/glpi/local_define.php
<?php
define('GLPI_VAR_DIR', '/var/lib/glpi');
define('GLPI_LOG_DIR', '/var/log/glpi');
EOF

# Configure PHP-FPM to listen on TCP instead of socket
RUN mkdir -p /etc/php83/php-fpm.d/
COPY <<EOF /etc/php83/php-fpm.d/www.conf
[www]
user = nginx
group = nginx
listen = 127.0.0.1:9000
pm = dynamic
pm.max_children = 5
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
EOF

# Configure Nginx
RUN rm /etc/nginx/conf.d/default.conf
COPY <<EOF /etc/nginx/conf.d/glpi.conf
server {
    listen 80;
    listen [::]:80;
    
    server_name _;
    root /var/www/html;
    
    index index.php index.html;
    
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    
    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOF

# Set proper permissions
RUN chmod 755 /var/www/html/inc/downstream.php \
    && chmod 755 /etc/glpi/local_define.php \
    && chown -R nginx:nginx /var/www/html /etc/glpi /var/lib/glpi /var/log/glpi

# Create an entrypoint script to start both services properly
COPY <<EOF /entrypoint.sh
#!/bin/sh
# Start PHP-FPM
php-fpm83 &
# Start Nginx (and don't go into background)
nginx -g 'daemon off;'
EOF

RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]