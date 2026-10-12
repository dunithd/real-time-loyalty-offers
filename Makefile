# Kestrel Market — the Makefile is the interface.
#
# QD3M build, in demo-criticality order:
#   Phase 0  Environment     catalog + PGD/PGAA + Kafka + ClickHouse + WHPG
#   Phase 1  Qualify found.   schema + seed + tiered replication; events -> Iceberg
#   Phase 2  Audience         WarehousePG CTAS -> offer_audience (Iceberg)
#   Phase 3  Discover/Decide  ClickHouse session features + one-query decision + insert
#   Phase 4  Deliver/redeem   engagement events + redemption transaction
#   Phase 5  Measure          lift (north weaker) + live funnel
#
# Phases are Compose profiles on one included project. The catalog tier (MinIO,
# Lakekeeper, its Postgres) has no profile and is shared.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

COMPOSE := docker compose
export DOCKER_BUILDKIT := 1

# Profile groups. The Qualify->Decide spine is catalog + pgaa + events +
# clickhouse. WHPG runs on its own (heavy, and owns host 5432).
SPINE := --profile pgaa --profile events --profile clickhouse --profile app
TOOLS := $(COMPOSE) --profile tools run --rm -T tools

HERO_MEMBER  ?= 100042
HERO_SESSION ?= sess-hero-0001
HERO_OFFER   ?= 1

.PHONY: help
help: ## Show this help
	@echo "Kestrel Market — QD3M Converged Analytics demo"
	@echo
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "First run:  make build && make up && make setup"
	@echo "            make backfill && make audience"
	@echo "Rehearse:   make reset   (between takes)"

# ── env guards ───────────────────────────────────────────────────────────────
.PHONY: check-token
check-token:
	@test -f .env || { echo "ERROR: .env missing (cp .env.example .env, add your EDB token)"; exit 1; }
	@grep -q '^EDB_SUBSCRIPTION_TOKEN=.\+' .env || { echo "ERROR: set EDB_SUBSCRIPTION_TOKEN in .env"; exit 1; }

# ── build ────────────────────────────────────────────────────────────────────
.PHONY: build
build: check-token ## Build all images (PGD/PGAA, Connect, generator, tools; WHPG via build-whpg)
	$(COMPOSE) $(SPINE) --profile tools build

.PHONY: build-whpg
build-whpg: ## Build the WarehousePG image (FROM the prebaked whpg7_cdw:latest base)
	$(COMPOSE) --profile whpg build

.PHONY: build-app
build-app: ## Build the demo-app image (React UI + FastAPI backend)
	$(COMPOSE) --profile app build

.PHONY: build-duckdb
build-duckdb: ## Build the interactive DuckDB CLI image (iceberg + httpfs pre-baked)
	$(COMPOSE) --profile cli build duckdb

# DuckDB attach preamble (reused to resolve the latest dated tables and in-session).
define DUCKDB_ATTACH
LOAD iceberg; LOAD httpfs; CREATE SECRET minio (TYPE s3, KEY_ID 'minioadmin', SECRET 'minioadmin', REGION 'us-east-1', ENDPOINT 'minio:9000', URL_STYLE 'path', USE_SSL false); ATTACH 'kestrel' AS lake (TYPE iceberg, ENDPOINT 'http://lakekeeper:8181/catalog', AUTHORIZATION_TYPE 'none', ACCESS_DELEGATION_MODE 'none');
endef
export DUCKDB_ATTACH

.PHONY: duckdb
duckdb: ## Neutral-engine lakehouse walkthrough — DuckDB on Iceberg; prints copy-paste queries
	@$(COMPOSE) --profile cli build duckdb >/dev/null 2>&1 || true
	@echo "resolving the latest audience / lift tables in Iceberg ..."
	@AUD=$$($(COMPOSE) --profile cli run --rm -T duckdb -noheader -list -c "$$DUCKDB_ATTACH SELECT name FROM (SHOW ALL TABLES) WHERE schema='kestrel_analytics' AND name LIKE 'offer_audience%' ORDER BY name DESC LIMIT 1;" 2>/dev/null | tr -d '\r' | tail -1); \
	 LIFT=$$($(COMPOSE) --profile cli run --rm -T duckdb -noheader -list -c "$$DUCKDB_ATTACH SELECT name FROM (SHOW ALL TABLES) WHERE schema='kestrel_analytics' AND name LIKE 'offer_lift_daily%' ORDER BY name DESC LIMIT 1;" 2>/dev/null | tr -d '\r' | tail -1); \
	 printf '\n\033[1m═══ DuckDB · Kestrel lakehouse (copy-paste these) ═══\033[0m\n\n'; \
	 printf '\033[2m-- the whole governed catalog: PGAA core, Kafka-sink events, PGAA-CTAS analytics\033[0m\n'; \
	 printf 'SHOW ALL TABLES;\n\n'; \
	 printf '\033[2m-- history landed by PGAA (the Qualify foundation)\033[0m\n'; \
	 printf "SELECT region, count(*) AS members FROM lake.kestrel_core.members GROUP BY 1 ORDER BY 2 DESC;\n"; \
	 printf "SELECT count(*) AS orders FROM lake.kestrel_core.orders;\n"; \
	 printf "SELECT c.name AS category, count(*) AS lines\n  FROM lake.kestrel_core.order_lines ol\n  JOIN lake.kestrel_core.categories c USING (category_id)\n  GROUP BY 1 ORDER BY 2 DESC LIMIT 5;\n\n"; \
	 printf '\033[2m-- clickstream landed by the Kafka Connect sink\033[0m\n'; \
	 printf "SELECT count(*) AS digital_events FROM lake.kestrel_events.digital_events;\n\n"; \
	 if [ -n "$$AUD" ]; then \
	   printf '\033[2m-- the campaign AUDIENCE WarehousePG/PGAA wrote back to Iceberg (CTAS)\033[0m\n'; \
	   printf "SELECT is_control, count(*) AS members, round(avg(propensity),3) AS avg_propensity\n  FROM lake.kestrel_analytics.%s GROUP BY 1;\n" "$$AUD"; \
	   printf "SELECT * FROM lake.kestrel_analytics.%s WHERE member_id = 100042;  -- the hero\n\n" "$$AUD"; \
	 else \
	   printf '\033[33m-- (no offer_audience_* table yet — run: make audience)\033[0m\n\n'; \
	 fi; \
	 if [ -n "$$LIFT" ]; then \
	   printf '\033[2m-- campaign LIFT by region (north weakest), also read from Iceberg\033[0m\n'; \
	   printf "SELECT region, treated_redemption_rate, control_redemption_rate, lift\n  FROM lake.kestrel_analytics.%s ORDER BY lift DESC;\n\n" "$$LIFT"; \
	 fi; \
	 printf '\033[1m═════════════════════════════════════════════════════\033[0m\n'
	@echo "launching DuckDB (.quit or Ctrl-D to exit) ..."
	@$(COMPOSE) --profile cli run --rm duckdb

.PHONY: up-app
up-app: ## Start the demo-app UI (storefront + marketing) on http://localhost:8080
	$(COMPOSE) --profile app up -d
	@echo "demo-app → http://localhost:8080  (/ shopper · /marketing dashboard)"

# ── up / down ────────────────────────────────────────────────────────────────
.PHONY: up
up: check-token ## Start the full stack: catalog + PGD/PGAA + Kafka + ClickHouse + demo-app UI
	$(COMPOSE) $(SPINE) up -d
	@echo "Spine starting. Watch health: make health"
	@echo "Demo-app UI → http://localhost:8080  (/ shopper · /marketing dashboard)"

.PHONY: up-core
up-core: check-token ## Start just catalog + PGD/PGAA
	$(COMPOSE) --profile pgaa up -d

.PHONY: up-whpg
up-whpg: ## Start the WarehousePG cluster (catalog + cdw/sdw1/sdw2); owns host 5432
	$(COMPOSE) --profile whpg up -d
	@echo "WHPG initialising (gpinitsystem under emulation is slow); watch: docker logs -f cdw"

.PHONY: down
down: ## Stop everything, keep volumes
	$(COMPOSE) $(SPINE) --profile whpg --profile tools --profile register down

.PHONY: down-v
down-v: ## Stop everything and delete volumes (full wipe)
	$(COMPOSE) $(SPINE) --profile whpg --profile tools --profile register down -v

# ── setup (Phase 1 foundation) ───────────────────────────────────────────────
.PHONY: setup
setup: ## Phase 1: create Iceberg event tables, register sink connectors, seed + tier PGD
	$(TOOLS) create_event_tables.py
	$(COMPOSE) --profile events --profile register run --rm --no-deps register-connectors
	$(TOOLS) setup_core.py

.PHONY: setup-whpg
setup-whpg: ## Register the catalog + PGAA read-handles in WarehousePG
	WHPG_HOST=cdw $(TOOLS) setup_whpg.py

# ── events ───────────────────────────────────────────────────────────────────
.PHONY: backfill
backfill: ## Backfill historical clickstream to Kafka -> Iceberg (browse signal)
	$(COMPOSE) --profile events run --rm event-generator history --events 40000

.PHONY: live
live: ## Stream live clickstream (Ctrl-C to stop); EPS=50 SECONDS=0
	$(COMPOSE) --profile events run --rm event-generator live --eps $${EPS:-50} --seconds $${SECONDS:-0}

.PHONY: hero
hero: ## Inject the hero's live session (strong chilled-desserts intent)
	$(COMPOSE) --profile events run --rm event-generator hero

# ── Phase 2: audience ────────────────────────────────────────────────────────
.PHONY: audience
audience: ## Build the campaign audience on WarehousePG (CTAS to Iceberg) + summary
	WHPG_HOST=cdw $(TOOLS) build_audience.py

# ── Phase 3: decide ──────────────────────────────────────────────────────────
.PHONY: session-features
session-features: ## Show the hero session features in ClickHouse
	@$(call ch_query_file,clickhouse/queries/session_features.sql,--param_session_id=$(HERO_SESSION))

.PHONY: decide
decide: ## Run the one-query decision for the hero (no write)
	@$(call ch_query_file,clickhouse/queries/rank_offer.sql,--param_member_id=$(HERO_MEMBER) --param_session_id=$(HERO_SESSION))

.PHONY: record-decision
record-decision: ## Run the decision and INSERT it into PGD (ClickHouse, 2-step)
	@clickhouse/record_decision.sh $(HERO_MEMBER) $(HERO_SESSION)

.PHONY: bench-decide
bench-decide: ## Run the decision query 20x, print min/median/p95 (measured, goes on screen)
	@clickhouse/bench_decide.sh $(HERO_MEMBER) $(HERO_SESSION) 20

# ── Phase 4: deliver ─────────────────────────────────────────────────────────
.PHONY: engagement
engagement: ## Emit impression + tap for the hero's live assignment
	$(TOOLS) emit_engagement.py

.PHONY: redeem
redeem: ## Run the redemption transaction for the hero (to COMMIT)
	docker exec -i kestrel-pgd /usr/lib/edb-pge/17/bin/psql -U postgres -d kestrel < pgd/redeem.sql

# ── Phase 5: measure ─────────────────────────────────────────────────────────
.PHONY: lift
lift: ## Compute lift by region on WarehousePG (north weaker) + CTAS to Iceberg
	WHPG_HOST=cdw $(TOOLS) build_lift.py

.PHONY: funnel
funnel: ## Live funnel: assigned -> shown -> tapped -> redeemed
	@$(call ch_query_file,clickhouse/queries/funnel.sql,--param_offer_id=$(HERO_OFFER))

# ── reset / inspect ──────────────────────────────────────────────────────────
.PHONY: reset
reset: ## Return to a known pre-recording state (reseed PGD, clear hot tables, rebuild audience + engagement)
	$(TOOLS) setup_core.py
	-docker exec -i kestrel-clickhouse clickhouse-client -q "TRUNCATE TABLE IF EXISTS default.digital_events_hot; TRUNCATE TABLE IF EXISTS default.offer_engagement_hot"
	$(TOOLS) build_audience.py
	-$(MAKE) --no-print-directory seed-engagement
	@echo "reset complete — hot tables cleared, audience + funnel rebuilt"

.PHONY: seed-engagement
seed-engagement: ## Seed realistic campaign impressions/taps into the hot tier (funnel)
	@docker exec -i kestrel-clickhouse clickhouse-client --multiquery < clickhouse/seed_engagement.sql
	@echo "engagement seeded"

.PHONY: health
health: ## Container health for the spine
	@$(COMPOSE) $(SPINE) ps

.PHONY: status
status: ## All Kestrel containers
	@docker ps --filter "name=kestrel-" --filter "name=cdw" --filter "name=sdw" \
	  --format 'table {{.Names}}\t{{.Status}}'

.PHONY: psql
psql: ## psql into PGD (kestrel)
	docker exec -it kestrel-pgd /usr/lib/edb-pge/17/bin/psql -U postgres -d kestrel

.PHONY: ch
ch: ## clickhouse-client
	docker exec -it kestrel-clickhouse clickhouse-client

.PHONY: psql-whpg
psql-whpg: ## psql into the WHPG coordinator (kestrel)
	docker exec -it cdw /usr/edb/whpg7/bin/psql -U gpadmin -d kestrel -h /tmp

# Helper: run a ClickHouse query file over HTTP through the container.
# $(1) = sql file, $(2) = extra clickhouse-client args (params).
define ch_query_file
docker exec -i kestrel-clickhouse clickhouse-client $(2) --multiquery < $(1)
endef
