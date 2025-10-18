FROM wordpress:php8.3-fpm-alpine

# ------------------------------------------------------------
# System & PHP extensions (runtime + build deps)
# ------------------------------------------------------------
RUN set -eux; \
  # Runtime пакети (залишаються у фінальному образі)
  apk add --no-cache \
    icu-libs \
    libjpeg-turbo \
    libpng \
    libwebp \
    freetype \
    git \
    unzip \
    zip \
    bash \
    shadow \
    tini; \
  \
  # Build deps для компіляції PHP-розширень
  apk add --no-cache --virtual .build-deps \
    $PHPIZE_DEPS \
    freetype-dev \
    libjpeg-turbo-dev \
    libpng-dev \
    libwebp-dev \
    icu-dev \
    oniguruma-dev \
    linux-headers \
    libzip-dev; \
  \
  # GD (FreeType/JPEG/WebP), intl, mbstring, mysqli, exif, zip, opcache
  docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
  docker-php-ext-install -j"$(nproc)" gd intl mbstring mysqli exif zip opcache; \
  \
  # Xdebug (стабільна версія для PHP 8.3)
  pecl channel-update pecl.php.net; \
  pecl install xdebug-3.3.2; \
  docker-php-ext-enable xdebug; \
  \
  # Прибираємо build deps та кеш PECL
  apk del .build-deps; \
  rm -rf /tmp/pear ~/.pearrc

# ------------------------------------------------------------
# Composer (копіюємо з офіційного образу)
# ------------------------------------------------------------
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

# Кеш і дефолти для Composer усередині контейнера
ENV COMPOSER_HOME=/tmp/composer \
    COMPOSER_ALLOW_SUPERUSER=1 \
    COMPOSER_MEMORY_LIMIT=-1
RUN set -eux; \
  mkdir -p "$COMPOSER_HOME"; \
  chown -R www-data:www-data "$COMPOSER_HOME"; \
  composer --version

# ------------------------------------------------------------
# PHP ini: зручні дефолти для дев-середовища
# ------------------------------------------------------------
RUN set -eux; \
  { \
    echo 'memory_limit=512M'; \
    echo 'max_execution_time=300'; \
    echo 'upload_max_filesize=64M'; \
    echo 'post_max_size=64M'; \
    echo 'opcache.enable=1'; \
    echo 'opcache.validate_timestamps=1'; \
    echo 'opcache.revalidate_freq=0'; \
  } > /usr/local/etc/php/conf.d/zz-dev.ini; \
  { \
    echo 'zend_extension=/usr/local/lib/php/extensions/no-debug-non-zts-*/xdebug.so'; \
    echo 'xdebug.mode=develop,debug'; \
    echo 'xdebug.start_with_request=trigger'; \
    # discover_client_host краще працює на Linux (Docker Desktop/bridge)
    echo 'xdebug.discover_client_host=1'; \
    # залишимо client_host як fallback (Docker Desktop на macOS/Windows)
    echo 'xdebug.client_host=host.docker.internal'; \
    echo 'xdebug.client_port=9003'; \
  } > /usr/local/etc/php/conf.d/zz-xdebug.ini

WORKDIR /var/www/html
ENTRYPOINT ["tini","--","docker-entrypoint.sh"]
CMD ["php-fpm"]
