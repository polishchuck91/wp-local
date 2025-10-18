FROM wordpress:php8.3-fpm-alpine

# Встановлюємо системні залежності та збираємо PHP-розширення
RUN set -eux; \
  # базові dev-залежності для компіляції PHP-розширень
  apk add --no-cache \
    freetype-dev \
    libjpeg-turbo-dev \
    libpng-dev \
    libwebp-dev \
    icu-dev \
    oniguruma-dev \
    linux-headers; \
  \
  # окремо ставимо build deps у віртуальний пакет, щоб легко видалити
  apk add --no-cache --virtual .build-deps $PHPIZE_DEPS; \
  \
  # GD (FreeType/JPEG/WebP), intl, mbstring, mysqli, opcache
  docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
  docker-php-ext-install -j"$(nproc)" gd intl mbstring mysqli opcache; \
  \
  # Xdebug: оновлюємо канал, фіксуємо стабільну версію під PHP 8.3
  pecl channel-update pecl.php.net; \
  pecl install xdebug-3.3.2; \
  docker-php-ext-enable xdebug; \
  \
  # приберемо dev-залежності та кеш PECL
  apk del .build-deps; \
  rm -rf /tmp/pear ~/.pearrc

WORKDIR /var/www/html
