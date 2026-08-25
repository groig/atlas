# Entry point for the containerised development environment.
# Run `make` (or `make help`) for the list of targets.

COMPOSE ?= docker compose

# Passed through to the image build so the container user matches the owner of
# the bind-mounted working tree.
export UID := $(shell id -u)
export GID := $(shell id -g)

# One-off mix commands run in a throwaway container: this works whether or not
# the environment is up, brings PostgreSQL up on its own, and publishes no
# ports, so it never collides with a running `make env-start`.
MIX_TEST := $(COMPOSE) run --rm -e MIX_ENV=test --entrypoint mix app

.DEFAULT_GOAL := help
.PHONY: help dirs env-start env-stop env-restart env-logs env-shell env-recreate \
        test precommit format migrate db-shell

help: ## List the available targets
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-13s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# Docker would otherwise create these named-volume mountpoints inside the
# bind-mounted working tree owned by root, which breaks host-side mix commands.
dirs:
	@mkdir -p deps _build assets/node_modules

env-start: dirs ## Build if needed and start the environment
	$(COMPOSE) up --build -d
	@echo "Track / Atlas is starting on http://localhost:4000 - follow it with 'make env-logs'"

env-stop: ## Stop the environment, keeping the database and track library
	$(COMPOSE) down

env-restart: ## Restart the environment
	$(MAKE) env-stop
	$(MAKE) env-start

env-logs: ## Follow the application log
	$(COMPOSE) logs -f app

env-shell: ## Open a shell in the running application container
	$(COMPOSE) exec app bash

env-recreate: dirs ## Delete all volumes (database AND track library) and rebuild from scratch
	@printf 'This deletes the imported track library and the database. Type yes to continue: '; \
	read -r reply; [ "$$reply" = yes ] || { echo "Aborted."; exit 1; }
	$(COMPOSE) down -v --remove-orphans
	$(COMPOSE) build --no-cache
	$(COMPOSE) up -d
	@echo "Track / Atlas is starting on http://localhost:4000 - follow it with 'make env-logs'"

test: ## Run the test suite
	$(MIX_TEST) test

precommit: ## Run the full precommit check (compile, unused deps, format, test)
	$(MIX_TEST) precommit

format: ## Format the code
	$(MIX_TEST) format

migrate: ## Run pending database migrations
	$(COMPOSE) exec app mix ecto.migrate

db-shell: ## Open a psql shell on the development database
	$(COMPOSE) exec db psql -U postgres track_analyzer_dev
