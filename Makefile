.PHONY: up down logs shell perm wait-db wp-download wp-config wp-install \
        wp-info wp-update wp-cache-flush wp-db-reset wp-reinstall wp-clean \
        wp-cli-info wp-salts wp-search-replace wp-fix-perms wp-cli-shell \
        site pma mailpit mailpit-open composer composer-run wp db health \
        wp-mail-test wp-mail-smtp wp-urls wp-admin

include .env

# -------- Settings --------
WP_PATH          := /var/www/html
WORKDIR          := /var/www/html

# Services
DB_SERVICE       := db
PHP_SERVICE      := php
WPCLI_SERVICE    := wpcli

# Defaults
DOMAIN              ?= wp.local
HTTP_PORT           ?= 8080
PMA_PORT            ?= 8081
MAILPIT_HTTP_PORT   ?= 8025
MAILPIT_SMTP_PORT   ?= 1025
DB_PREFIX           ?= wp_
PHP_MEMORY_LIMIT    ?= 512M
MAX_EXEC_TIME       ?= 300

# WP-CLI env
WPCLI_ENV        := -e WP_CLI_PHP_ARGS='-d memory_limit=$(PHP_MEMORY_LIMIT) -d max_execution_time=$(MAX_EXEC_TIME)'
WPCLI_USER       := --user root

# -------- Helpers --------
OPEN := xdg-open
ifeq ($(shell uname),Darwin)
	OPEN := open
endif
ifeq ($(OS),Windows_NT)
	OPEN := start
endif

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
	docker compose exec $(PHP_SERVICE) sh

# Permissions
perm:
	docker compose exec -w / $(PHP_SERVICE) sh -lc "\
	  mkdir -p $(WP_PATH) && \
	  chown -R www-data:www-data $(WP_PATH) && \
	  find $(WP_PATH) -type d -exec chmod 775 {} \; && \
	  find $(WP_PATH) -type f -exec chmod 664 {} \;"

# ===== Composer (in php) =====
composer: composer-install

composer-install:
	docker compose exec $(PHP_SERVICE) sh -lc "cd $(WORKDIR) && composer install --no-interaction"

composer-update:
	docker compose exec $(PHP_SERVICE) sh -lc "cd $(WORKDIR) && composer update --no-interaction"

# make composer-require pkg="vendor/package[:version]"
composer-require:
ifndef pkg
	$(error Вкажи пакет: make composer-require pkg="vendor/package[:version]")
endif
	docker compose exec $(PHP_SERVICE) sh -lc "cd $(WORKDIR) && composer require --no-interaction $(pkg)"

composer-dump:
	docker compose exec $(PHP_SERVICE) sh -lc "cd $(WORKDIR) && composer dump-autoload -o"

# Arbitrary composer command: make composer-run CMD="show -p"
composer-run:
ifndef CMD
	$(error Usage: make composer-run CMD="install|update|require ...")
endif
	docker compose exec $(PHP_SERVICE) sh -lc "cd $(WORKDIR) && composer $(CMD)"

# Stronger perms (setgid)
wp-fix-perms:
	docker compose exec -w / $(PHP_SERVICE) sh -lc "\
	  install -d -o www-data -g www-data -m 2775 $(WP_PATH) && \
	  chown -R www-data:www-data $(WP_PATH) && \
	  find $(WP_PATH) -type d -exec chmod 2775 {} \; && \
	  find $(WP_PATH) -type f -exec chmod 664 {} \;"

# Wait DB
wait-db:
	docker compose exec -T $(DB_SERVICE) sh -lc '\
	  for i in $$(seq 1 60); do \
	    mysqladmin ping -h 127.0.0.1 -uroot -p$$MYSQL_ROOT_PASSWORD --silent && exit 0; \
	    echo "Waiting for DB ($$i/60)…"; sleep 1; \
	  done; \
	  echo "DB did not become ready in time" >&2; exit 1'

# -------- WordPress setup --------
wp-download: up wait-db perm
	$(WP) core download --force --skip-content

wp-config: wp-download
	$(WP) config create \
	  --dbname="$(DB_NAME)" --dbuser="$(DB_USER)" --dbpass="$(DB_PASSWORD)" --dbhost="$(DB_HOST)" \
	  --dbprefix="$(DB_PREFIX)" \
	  --skip-check --force
	$(WP) config shuffle-salts
	$(WP) config set WP_ENVIRONMENT_TYPE development --type=constant
	$(WP) config set WP_DEBUG true --raw
	$(WP) config set WP_DEBUG_LOG true --raw
	$(WP) config set WP_DEBUG_DISPLAY false --raw
	$(WP) config set SCRIPT_DEBUG true --raw
	$(WP) config set WP_HOME "http://$(DOMAIN):$(HTTP_PORT)" --type=constant
	$(WP) config set WP_SITEURL "http://$(DOMAIN):$(HTTP_PORT)" --type=constant
	$(WP) config set DISALLOW_FILE_EDIT true --raw
	$(WP) config set FS_METHOD "direct" --type=constant
	$(WP) config set WP_CACHE false --raw
	$(WP) config set WP_AUTO_UPDATE_CORE false --raw
	$(WP) config set WP_MEMORY_LIMIT "256M" --type=constant
	$(WP) config set WP_MAX_MEMORY_LIMIT "512M" --type=constant
	$(WP) config set DB_CHARSET "utf8mb4" --type=constant
	$(WP) config set DB_COLLATE "" --type=constant
	# Mailpit baseline
	$(WP) config set WP_MAIL_SMTP_HOST "mailpit" --type=constant
	$(WP) config set WP_MAIL_SMTP_PORT $(MAILPIT_SMTP_PORT) --raw
	$(WP) config set WP_MAIL_SMTP_AUTH false --raw
	$(WP) config set WP_MAIL_SMTP_SECURE false --raw
	# WP Mail SMTP plugin constants
	$(WP) config set WPMS_ON true --raw
	$(WP) config set WPMS_MAIL_FROM "no-reply@wp.local" --type=constant
	$(WP) config set WPMS_MAIL_FROM_FORCE true --raw
	$(WP) config set WPMS_MAILER "smtp" --type=constant
	$(WP) config set WPMS_SMTP_HOST "mailpit" --type=constant
	$(WP) config set WPMS_SMTP_PORT $(MAILPIT_SMTP_PORT) --raw
	$(WP) config set WPMS_SMTP_AUTH false --raw
	$(WP) config set WPMS_SSL "" --type=constant
	@echo "✓ wp-config.php готовий (dev + Mailpit)"

wp-salts: wp-config
	$(WP) config shuffle-salts

wp-install: wp-config
	$(WP) core install \
	  --url="http://$(DOMAIN):$(HTTP_PORT)" \
	  --title="WP Docker" \
	  --admin_user=admin --admin_password=admin --admin_email=admin@local.test \
	  --skip-email

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

wp-db-reset: wp-config
	$(WP) db reset --yes

wp-reinstall: wp-db-reset
	$(MAKE) wp-install

wp-search-replace:
	@if [ -z "$(FROM)" ] || [ -z "$(TO)" ]; then \
	  echo "Usage: make wp-search-replace FROM=http://old TO=http://new"; exit 2; \
	fi
	$(WP) search-replace '$(FROM)' '$(TO)' --skip-columns=guid --all-tables

wp-clean:
	rm -rf wp/wp

# -------- Convenience --------
site:
	@echo "Opening site at http://$(DOMAIN):$(HTTP_PORT)"
	@$(OPEN) "http://$(DOMAIN):$(HTTP_PORT)" >/dev/null 2>&1 || true

pma:
	@echo "Opening phpMyAdmin at http://$(DOMAIN):$(PMA_PORT)"
	@$(OPEN) "http://$(DOMAIN):$(PMA_PORT)" >/dev/null 2>&1 || true

mailpit:
	@echo "Mailpit UI: http://$(DOMAIN):$(MAILPIT_HTTP_PORT)"
mailpit-open:
	@echo "Opening Mailpit at http://$(DOMAIN):$(MAILPIT_HTTP_PORT)"
	@$(OPEN) "http://$(DOMAIN):$(MAILPIT_HTTP_PORT)" >/dev/null 2>&1 || true

# Raw WP-CLI
# make wp ARGS="plugin list"
# make wp ARGS="core version"
wp:
	@if [ -z "$(ARGS)" ]; then echo "Usage: make wp ARGS=\"...\""; exit 2; fi
	docker compose run --rm $(WPCLI_USER) -w $(WP_PATH) $(WPCLI_ENV) $(WPCLI_SERVICE) $(ARGS) --allow-root

db:
	docker compose exec $(DB_SERVICE) sh -lc 'mysql -uroot -p$$MYSQL_ROOT_PASSWORD'

health:
	@echo "Checking DB health…"
	@docker compose ps $(DB_SERVICE)

# -------- Mailpit helpers --------
wp-mail-test:
	$(WP) eval 'wp_mail("you@example.com","Mailpit test ✔","Hello from WP! " . date("Y-m-d H:i:s"), ["Content-Type: text/html; charset=UTF-8"]); echo "Sent\n";'

wp-mail-smtp:
	$(WP) plugin install wp-mail-smtp --activate

# -------- Extras (нові, зручно мати під рукою) --------
# Оновити home/siteurl за .env (коли міняєш DOMAIN/PORT після інсталяції)
wp-urls:
	$(WP) option update home "http://$(DOMAIN):$(HTTP_PORT)"
	$(WP) option update siteurl "http://$(DOMAIN):$(HTTP_PORT)"

# Швидке посилання в адмінку (нагадування)
wp-admin:
	@echo "Admin: http://$(DOMAIN):$(HTTP_PORT)/wp-admin/  (admin / admin)"
