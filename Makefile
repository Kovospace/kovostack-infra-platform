SHELL := /bin/bash
.DEFAULT_GOAL := help

# COMPOSE_FILE / COMPOSE_PROJECT_NAME come from .env, so plain `docker
# compose` already sees the whole merged stack.
COMPOSE := docker compose
BACKUP_DIR := backups

.PHONY: help up down restart ps logs config pull psql redis-cli zot-user secrets backup check

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

check: ## Validate the merged compose config without starting anything
	@$(COMPOSE) config --quiet && echo "compose config OK"

up: check ## Start (or update) the whole platform
	$(COMPOSE) up -d

down: ## Stop the platform, keep all data
	$(COMPOSE) down

restart: ## Restart one service: make restart S=zot
	$(COMPOSE) restart $(S)

ps: ## Show container status
	$(COMPOSE) ps

logs: ## Tail logs, optionally one service: make logs S=infisical
	$(COMPOSE) logs -f --tail=100 $(S)

config: ## Print the fully merged compose file
	$(COMPOSE) config

pull: ## Pull newer images, then recreate what changed
	$(COMPOSE) pull
	$(COMPOSE) up -d

psql: ## Open psql as superuser: make psql DB=infisical
	$(COMPOSE) exec postgres psql -U $${POSTGRES_USER:-postgres} -d $(or $(DB),postgres)

redis-cli: ## Open redis-cli
	$(COMPOSE) exec redis sh -c 'redis-cli -a "$$REDIS_PASSWORD"'

zot-user: ## Add a registry user: make zot-user U=ci P=secret
	@test -n "$(U)" -a -n "$(P)" || { echo "usage: make zot-user U=<user> P=<password>"; exit 1; }
	docker run --rm httpd:alpine htpasswd -nbB "$(U)" "$(P)" >> zot/config/htpasswd
	$(COMPOSE) restart zot

secrets: ## Print a fresh set of secrets for a new .env
	@echo "POSTGRES_PASSWORD=$$(openssl rand -hex 24)"
	@echo "REDIS_PASSWORD=$$(openssl rand -hex 24)"
	@echo "INFISICAL_DB_PASSWORD=$$(openssl rand -hex 24)"
	@echo "INFISICAL_ENCRYPTION_KEY=$$(openssl rand -hex 16)"
	@echo "INFISICAL_AUTH_SECRET=$$(openssl rand -base64 32)"

backup: ## Dump all databases to backups/
	@mkdir -p $(BACKUP_DIR)
	$(COMPOSE) exec -T postgres pg_dumpall -U $${POSTGRES_USER:-postgres} \
		| gzip > $(BACKUP_DIR)/postgres-$$(date +%Y%m%d-%H%M%S).sql.gz
	@echo "wrote $(BACKUP_DIR)/postgres-*.sql.gz"