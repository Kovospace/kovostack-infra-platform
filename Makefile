SHELL := /bin/bash
.DEFAULT_GOAL := help

# COMPOSE_FILE / COMPOSE_PROJECT_NAME come from .env, so plain `docker
# compose` already sees the whole merged stack.
COMPOSE := docker compose
BACKUP_DIR := backups

.PHONY: help up down restart ps logs config pull psql redis-cli zot-user secrets backup check check-edge cluster-check doctor

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

check: ## Validate the merged compose config without starting anything
	@$(COMPOSE) config --quiet && echo "compose config OK"

check-edge: ## Render the edge SNI config with the real hostnames and validate it
	@$(COMPOSE) run --rm --no-deps -T edge nginx -t
	@$(COMPOSE) run --rm --no-deps -T edge nginx -T 2>/dev/null | grep -q ssl_preread || { \
		echo "ERROR: nginx started without the stream config."; \
		echo "The template must be named *.conf.stream-template — see edge/sni.conf.stream-template."; \
		exit 1; }
	@echo
	@echo "--- rendered SNI map (empty value = a hostname missing from .env) ---"
	@$(COMPOSE) run --rm --no-deps -T --entrypoint /bin/sh edge -c \
		'/docker-entrypoint.d/20-envsubst-on-templates.sh >/dev/null 2>&1; \
		 sed -n "/^map/,/^}/p" /etc/nginx/stream-conf.d/sni.conf'

cluster-check: ## Find an address where the cluster ingress NodePorts are reachable from a container
	@cands="$$(grep -E '^CLUSTER_INGRESS_IP=' .env 2>/dev/null | cut -d= -f2 | cut -d' ' -f1) \
		$$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $$2}' | cut -d/ -f1 | tr '\n' ' ') \
		10.0.2.2 172.17.0.1"; \
	cands=$$(echo $$cands | tr ' ' '\n' | awk 'NF && !seen[$$0]++' | tr '\n' ' '); \
	echo "candidates: $$cands"; echo; \
	$(COMPOSE) run --rm --no-deps -T -e CANDS="$$cands" --entrypoint /bin/sh edge -c \
		'for ip in $$CANDS; do for p in 30080 30443; do \
			if nc -z -w 2 "$$ip" "$$p"; then echo "  reachable    $$ip:$$p"; \
			else echo "  unreachable  $$ip:$$p"; fi; done; done'; \
	echo; \
	echo "Both ports must be reachable on one address. If none is:"; \
	echo "  - is the ingress up?   kubectl -n kube-system get svc"; \
	echo "  - are the NodePorts 30080/30443? they are hardcoded in"; \
	echo "    edge/sni.stream-template and proxy/conf.d/00-cluster.conf"; \
	echo "  - rootless docker cannot reach the host's loopback — use the VM's own IP"; \
	echo; \
	echo "Then set CLUSTER_INGRESS_IP in .env and:"; \
	echo "    docker compose up -d --force-recreate edge proxy"

doctor: ## Diagnose the docker socket that nginx-proxy and acme need
	@sock=$$(grep -E '^DOCKER_HOST_PATH=' .env 2>/dev/null | cut -d= -f2); \
	sock=$${sock:-/var/run/docker.sock}; \
	endpoint=$$(docker context inspect -f '{{.Endpoints.docker.Host}}' 2>/dev/null); \
	real=$${endpoint#unix://}; \
	echo "cli endpoint : $$endpoint"; \
	echo "DOCKER_HOST  : $${DOCKER_HOST:-<unset>}"; \
	echo "mounting     : $$sock"; \
	if [ -n "$$real" ] && [ "$$real" != "$$sock" ]; then \
		echo; echo "MISMATCH: the stack mounts a different socket than your CLI talks to."; \
		echo "nginx-proxy and acme would query the wrong (or an unreadable) daemon."; \
		echo "Fix by putting this in .env, then: docker compose up -d --force-recreate proxy acme"; \
		echo; echo "    DOCKER_HOST_PATH=$$real"; echo; \
		case "$$real" in /run/user/*) \
			echo "Rootless docker detected. Also check privileged ports, which rootless"; \
			echo "cannot bind by default (the edge container needs 80/443):"; \
			echo "    current net.ipv4.ip_unprivileged_port_start = $$(cat /proc/sys/net/ipv4/ip_unprivileged_port_start 2>/dev/null)"; \
			echo "    if that is above 80:  echo 'net.ipv4.ip_unprivileged_port_start=0' | sudo tee /etc/sysctl.d/99-rootless.conf && sudo sysctl --system";; \
		esac; \
		exit 1; \
	fi; \
	if [ ! -S "$$sock" ]; then \
		echo "host socket  : MISSING or not a socket"; \
		echo; echo "-> Set DOCKER_HOST_PATH in .env to the path shown as 'cli endpoint'."; \
		echo "   Do not start the stack first: a bind mount of a missing path makes"; \
		echo "   docker create a DIRECTORY there, which is then wrong forever."; \
		exit 1; \
	fi; \
	echo "host socket  : OK  $$(ls -l $$sock)"; \
	echo -n "from container: "; \
	out=$$(docker run --rm -v "$$sock:/var/run/docker.sock:ro" --entrypoint sh \
		nginxproxy/acme-companion:$${ACME_COMPANION_VERSION:-2.8} -c \
		'curl -s --unix-socket /var/run/docker.sock http://localhost/version'); \
	if [ -n "$$out" ]; then echo "$$out" | head -c 120; echo; \
	else echo "UNREACHABLE — acme cannot query docker; check socket permissions"; exit 1; fi

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