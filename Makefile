.PHONY: up down logs shell perm wait-db wp-download wp-config wp-install \
        wp-info wp-update wp-cache-flush wp-db-reset wp-reinstall wp-clean \
        wp-cli-info wp-salts wp-search-replace wp-fix-perms wp-cli-shell

include .env

# -------- Settings --------
# Where WP lives inside containers (map ./wp -> /var/www/html in compose)
WP_PATH          := /var/www/html

# Compose services
DB_SERVICE       := db
PHP_SERVICE      := php
WPCLI_SERVICE    := wpcli

# Force WP-CLI to run with enough resources even if wp-cli.yml is missing/ignored
WPCLI_ENV        := -e WP_CLI_PHP_ARGS='-d memory_limit=$(PHP_MEMORY_LIMIT) -d max_execution_time=$(MAX_EXEC_TIME)'
# Run wpcli as root for reliable write perms on bind mounts
WPCLI_USER       := --user root

# Convenience macro: run "wp ..." with correct path/flags inside wpcli service
# NOTE: no extra "wp" token — the wpcli image entrypoint is already "wp"
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
	# interactive shell inside PHP container
	docker compose exec $(PHP_SERVICE) sh

# Avoid "possible container breakout" CWD error by forcing a safe working dir (-w /)
perm:
	docker compose exec -w / $(PHP_SERVICE) sh -lc "\
	  mkdir -p $(WP_PATH) && \
	  chown -R www-data:www-data $(WP_PATH) && \
	  find $(WP_PATH) -type d -exec chmod 775 {} \; && \
	  find $(WP_PATH) -type f -exec chmod 664 {} \;"

# More robust perms (setgid so new dirs inherit the group)
wp-fix-perms:
	docker compose exec -w / $(PHP_SERVICE) sh -lc "\
	  install -d -o www-data -g www-data -m 2775 $(WP_PATH) && \
	  chown -R www-data:www-data $(WP_PATH) && \
	  find $(WP_PATH) -type d -exec chmod 2775 {} \; && \
	  find $(WP_PATH) -type f -exec chmod 664 {} \;"

# Wait for DB to be truly ready (uses root creds from .env)
wait-db:
	docker compose exec -T $(DB_SERVICE) sh -lc '\
	  for i in $$(seq 1 60); do \
	    mysqladmin ping -h 127.0.0.1 -uroot -p$$MYSQL_ROOT_PASSWORD --silent && exit 0; \
	    echo "Waiting for DB ($$i/60)…"; sleep 1; \
	  done; \
	  echo "DB did not become ready in time" >&2; exit 1'

# -------- WordPress setup --------
# 1) Download WordPress core into $(WP_PATH)
wp-download: up wait-db perm
	$(WP) core download --force --skip-content

# 2) Create wp-config.php (no heredoc/TTY issues)
wp-config: wp-download
	$(WP) config create \
	  --dbname="$(DB_NAME)" --dbuser="$(DB_USER)" --dbpass="$(DB_PASSWORD)" --dbhost="$(DB_HOST)" \
	  --skip-check --force
	$(WP) config set WP_DEBUG true --raw
	$(WP) config set WP_DEBUG_LOG true --raw
	$(WP) config set WP_ENVIRONMENT_TYPE development --type=constant
	$(WP) config set WP_HOME "http://$(DOMAIN):$(HTTP_PORT)" --type=constant
	$(WP) config set WP_SITEURL "http://$(DOMAIN):$(HTTP_PORT)" --type=constant

# Optional: add fresh salts after config
wp-salts: wp-config
	$(WP) config shuffle-salts

# 3) Install site (depends on wp-config)
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

# Safely reset DB tables for the current WP (keeps DB schema/database)
# Requires wp-config.php to exist (so WP-CLI knows the DB)
wp-db-reset: wp-config
	$(WP) db reset --yes

# Full reinstall: reset DB then rerun core install (keeps wp-config.php)
wp-reinstall: wp-db-reset
	$(MAKE) wp-install

# Search/replace helper (pass FROM= and TO=)
# Example: make wp-search-replace FROM=http://wp.local:8080 TO=https://example.test
wp-search-replace:
	@if [ -z "$(FROM)" ] || [ -z "$(TO)" ]; then \
	  echo "Usage: make wp-search-replace FROM=http://old TO=http://new"; exit 2; \
	fi
	$(WP) search-replace '$(FROM)' '$(TO)' --skip-columns=guid --all-tables

# Helper: remove accidental nested wp/wp (if it ever happened)
wp-clean:
	rm -rf wp/wp
