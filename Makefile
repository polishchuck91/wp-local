.PHONY: up down logs shell perm wait-db wp-download wp-config wp-install \
        wp-info wp-update wp-cache-flush wp-db-reset wp-reinstall wp-clean \
        wp-cli-info wp-salts wp-search-replace wp-fix-perms wp-cli-shell \
        site pma mailpit mailpit-open composer wp db health \
        wp-mail-test wp-mail-smtp

include .env

# -------- Settings --------
# Де живе WP всередині контейнерів (мапа ./wp -> /var/www/html у compose)
WP_PATH          := /var/www/html

# Імена сервісів з docker-compose.yml
DB_SERVICE       := db
PHP_SERVICE      := php
WPCLI_SERVICE    := wpcli

# --- Sensible defaults (можна перевизначити в .env) ---
DOMAIN              ?= wp.local
HTTP_PORT           ?= 8080
PMA_PORT            ?= 8081
MAILPIT_HTTP_PORT   ?= 8025
MAILPIT_SMTP_PORT   ?= 1025
DB_PREFIX           ?= wp_
PHP_MEMORY_LIMIT    ?= 512M
MAX_EXEC_TIME       ?= 300

# WP-CLI з підвищеними лімітами (якщо wp-cli.yml відсутній/ігнорується)
WPCLI_ENV        := -e WP_CLI_PHP_ARGS='-d memory_limit=$(PHP_MEMORY_LIMIT) -d max_execution_time=$(MAX_EXEC_TIME)'
# Запускаємо wpcli від root для стабільних прав на bind-монтах
WPCLI_USER       := --user root

# -------- Helpers --------
# Кросплатформний відкривач URL
OPEN := xdg-open
ifeq ($(shell uname),Darwin)
	OPEN := open
endif
ifeq ($(OS),Windows_NT)
	OPEN := start
endif

# Зручний макрос: запускає "wp ..." з правильним шляхом/прапорами всередині сервісу wpcli
# NOTE: не додавайте зайвий "wp" — entrypoint образу wpcli вже є "wp"
define WP
	docker compose run --rm $(WPCLI_USER) -w $(WP_PATH) $(WPCLI_ENV) $(WPCLI_SERVICE) \
	  --path=$(WP_PATH) --allow-root
endef

# -------- Lifecycle --------
up:
	docker compose up -d --build

down:
	docker compose down

logs:
	docker compose logs -f --tail=200

shell:
	# Інтерактивна оболонка в PHP контейнері
	docker compose exec $(PHP_SERVICE) sh

# Уникаємо помилки "possible container breakout" задаючи безпечний робочий каталог (-w /)
perm:
	docker compose exec -w / $(PHP_SERVICE) sh -lc "\
	  mkdir -p $(WP_PATH) && \
	  chown -R www-data:www-data $(WP_PATH) && \
	  find $(WP_PATH) -type d -exec chmod 775 {} \; && \
	  find $(WP_PATH) -type f -exec chmod 664 {} \;"

# Більш надійні права (setgid, щоб нові каталоги наслідували групу)
wp-fix-perms:
	docker compose exec -w / $(PHP_SERVICE) sh -lc "\
	  install -d -o www-data -g www-data -m 2775 $(WP_PATH) && \
	  chown -R www-data:www-data $(WP_PATH) && \
	  find $(WP_PATH) -type d -exec chmod 2775 {} \; && \
	  find $(WP_PATH) -type f -exec chmod 664 {} \;"

# Очікуємо готовність БД (root креденшіали з .env)
wait-db:
	docker compose exec -T $(DB_SERVICE) sh -lc '\
	  for i in $$(seq 1 60); do \
	    mysqladmin ping -h 127.0.0.1 -uroot -p$$MYSQL_ROOT_PASSWORD --silent && exit 0; \
	    echo "Waiting for DB ($$i/60)…"; sleep 1; \
	  done; \
	  echo "DB did not become ready in time" >&2; exit 1'

# -------- WordPress setup --------
# 1) Завантаження ядра WordPress у $(WP_PATH)
wp-download: up wait-db perm
	$(WP) core download --force --skip-content

# 2) Створення wp-config.php
wp-config: wp-download
	# 1) Базовий wp-config.php
	$(WP) config create \
	  --dbname="$(DB_NAME)" --dbuser="$(DB_USER)" --dbpass="$(DB_PASSWORD)" --dbhost="$(DB_HOST)" \
	  --dbprefix="$(DB_PREFIX)" \
	  --skip-check --force

	# 2) Секретні ключі
	$(WP) config shuffle-salts

	# 3) Режим розробки / URL
	$(WP) config set WP_ENVIRONMENT_TYPE development --type=constant
	$(WP) config set WP_DEBUG true --raw
	$(WP) config set WP_DEBUG_LOG true --raw
	$(WP) config set WP_DEBUG_DISPLAY false --raw
	$(WP) config set SCRIPT_DEBUG true --raw
	$(WP) config set WP_HOME "http://$(DOMAIN):$(HTTP_PORT)" --type=constant
	$(WP) config set WP_SITEURL "http://$(DOMAIN):$(HTTP_PORT)" --type=constant

	# 4) Локальні зручності (опційно)
	$(WP) config set DISALLOW_FILE_EDIT true --raw
	$(WP) config set FS_METHOD "direct" --type=constant
	$(WP) config set WP_CACHE false --raw
	$(WP) config set WP_AUTO_UPDATE_CORE false --raw
	$(WP) config set WP_MEMORY_LIMIT "256M" --type=constant
	$(WP) config set WP_MAX_MEMORY_LIMIT "512M" --type=constant
	# (опційно) Явні налаштування БД:
	$(WP) config set DB_CHARSET "utf8mb4" --type=constant
	$(WP) config set DB_COLLATE "" --type=constant

	# 5) Mailpit (fallback для кастомного phpmailer_init або вашого коду)
	$(WP) config set WP_MAIL_SMTP_HOST "mailpit" --type=constant
	$(WP) config set WP_MAIL_SMTP_PORT $(MAILPIT_SMTP_PORT) --raw
	$(WP) config set WP_MAIL_SMTP_AUTH false --raw
	$(WP) config set WP_MAIL_SMTP_SECURE false --raw

	# 6) Mailpit через плагін WP Mail SMTP (рекомендується)
	$(WP) config set WPMS_ON true --raw
	$(WP) config set WPMS_MAIL_FROM "no-reply@wp.local" --type=constant
	$(WP) config set WPMS_MAIL_FROM_FORCE true --raw
	$(WP) config set WPMS_MAILER "smtp" --type=constant
	$(WP) config set WPMS_SMTP_HOST "mailpit" --type=constant
	$(WP) config set WPMS_SMTP_PORT $(MAILPIT_SMTP_PORT) --raw
	$(WP) config set WPMS_SMTP_AUTH false --raw
	# Порожній рядок означає "без TLS/SSL" для WP Mail SMTP:
	$(WP) config set WPMS_SSL "" --type=constant

	@echo "✓ wp-config.php готовий (dev + Mailpit)"

# Додатково: оновити солі коли завгодно
wp-salts: wp-config
	$(WP) config shuffle-salts

# 3) Встановлення сайту (після wp-config)
wp-install: wp-config
	$(WP) core install \
	  --url="http://$(DOMAIN):$(HTTP_PORT)" \
	  --title="WP Docker" \
	  --admin_user=admin --admin_password=admin --admin_email=admin@local.test \
	  --skip-email

# Info / maintenance
wp-info:
	$(WP) core version

wp-update:
	$(WP) core update

wp-cache-flush:
	$(WP) cache flush || true

wp-cli-info:
	docker compose run --rm $(WPCLI_USER) $(WPCLI_ENV) $(WPCLI_SERVICE) --info --allow-root

wp-cli-shell:
	docker compose run --rm $(WPCLI_USER) -w $(WP_PATH) $(WPCLI_ENV) $(WPCLI_SERVICE) shell

# Обережний reset таблиць поточної БД (залишає схему/базу)
# Вимагає існуючого wp-config.php
wp-db-reset: wp-config
	$(WP) db reset --yes

# Повна перевстановка: reset БД + повторна інсталяція ядра (wp-config.php лишається)
wp-reinstall: wp-db-reset
	$(MAKE) wp-install

# Пошук/заміна (передай FROM= і TO=)
# Приклад: make wp-search-replace FROM=http://wp.local:8080 TO=https://example.test
wp-search-replace:
	@if [ -z "$(FROM)" ] || [ -z "$(TO)" ]; then \
	  echo "Usage: make wp-search-replace FROM=http://old TO=http://new"; exit 2; \
	fi
	$(WP) search-replace '$(FROM)' '$(TO)' --skip-columns=guid --all-tables

# Допоміжне: прибрати випадковий вкладений wp/wp (якщо раптом трапиться)
wp-clean:
	rm -rf wp/wp

# -------- Convenience targets --------
# Відкрити сайт у браузері
site:
	@echo "Opening site at http://$(DOMAIN):$(HTTP_PORT)"
	@$(OPEN) "http://$(DOMAIN):$(HTTP_PORT)" >/dev/null 2>&1 || true

# Відкрити phpMyAdmin у браузері
pma:
	@echo "Opening phpMyAdmin at http://$(DOMAIN):$(PMA_PORT)"
	@$(OPEN) "http://$(DOMAIN):$(PMA_PORT)" >/dev/null 2>&1 || true

# Відкрити Mailpit UI у браузері (коротке ім’я + окремий open)
mailpit:
	@echo "Mailpit UI: http://$(DOMAIN):$(MAILPIT_HTTP_PORT)"
mailpit-open:
	@echo "Opening Mailpit at http://$(DOMAIN):$(MAILPIT_HTTP_PORT)"
	@$(OPEN) "http://$(DOMAIN):$(MAILPIT_HTTP_PORT)" >/dev/null 2>&1 || true

# Запуск Composer у відповідному сервісі
# Використання:
#   make composer CMD="install"
#   make composer CMD="require timber/timber"
composer:
	@if [ -z "$(CMD)" ]; then echo "Usage: make composer CMD=\"install|update|require ...\""; exit 2; fi
	docker compose run --rm composer $(CMD)

# Сира команда WP-CLI (інколи зручніше за макрос $(WP))
# Використання:
#   make wp ARGS="plugin list"
#   make wp ARGS="core version"
wp:
	@if [ -z "$(ARGS)" ]; then echo "Usage: make wp ARGS=\"...\""; exit 2; fi
	docker compose run --rm $(WPCLI_USER) -w $(WP_PATH) $(WPCLI_ENV) $(WPCLI_SERVICE) $(ARGS) --allow-root

# Швидка MySQL-шелл (root) усередині контейнера БД
db:
	docker compose exec $(DB_SERVICE) sh -lc 'mysql -uroot -p$$MYSQL_ROOT_PASSWORD'

# Перевірка стану БД
health:
	@echo "Checking DB health…"
	@docker compose ps $(DB_SERVICE)

# -------- Mailpit helpers --------
# Тестовий лист через wp_mail() (потрапить у Mailpit)
wp-mail-test:
	$(WP) eval 'wp_mail("you@example.com","Mailpit test ✔","Hello from WP! " . date("Y-m-d H:i:s"), ["Content-Type: text/html; charset=UTF-8"]); echo "Sent\n";'

# Встановити й активувати плагін WP Mail SMTP
wp-mail-smtp:
	$(WP) plugin install wp-mail-smtp --activate
