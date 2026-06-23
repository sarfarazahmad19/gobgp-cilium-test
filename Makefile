SHELL := /bin/sh
.DEFAULT_GOAL := help

CLUSTER_NAME      ?= gobgp
CP_CONTAINER      ?= gobgp-control-plane
NETWORK_NAME      ?= gobgp-net
KUBECONFIG        ?= $(PWD)/.kubeconfig/kubeconfig.yaml
KIND_IMAGE        ?= kindest/node:v1.33.0
CILIUM_VERSION    ?= 1.19.5
KIND_BIN          ?= /usr/local/bin/kind
HELM_BIN          ?= helm

export KUBECONFIG
export CP_CONTAINER
export NETWORK_NAME
export CILIUM_VERSION

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

## ---- network ---------------------------------------------------------

.PHONY: net-create net-rm
net-create: ## Create the gobgp-net docker network (idempotent)
	@if docker network inspect $(NETWORK_NAME) >/dev/null 2>&1; then \
	  echo "network $(NETWORK_NAME) already exists"; \
	else \
	  docker network create --driver bridge $(NETWORK_NAME); \
	  echo "created network $(NETWORK_NAME)"; \
	fi

net-rm: ## Remove the gobgp-net docker network
	docker network rm $(NETWORK_NAME) 2>/dev/null || true

## ---- cluster lifecycle -----------------------------------------------

.PHONY: up down status ps logs

up: net-create ## Bring up the kind cluster (creates cluster + attaches to gobgp-net)
	docker compose run --rm kind
	@echo
	@echo "kubeconfig: $(KUBECONFIG)"
	@echo "export KUBECONFIG=$(KUBECONFIG)"

down: ## Tear down the kind cluster
	docker compose run --rm kind sh /config/scripts/kind-down.sh

status: ## Show cluster status (nodes, pods, networks)
	@$(KIND_BIN) get nodes --name $(CLUSTER_NAME) 2>/dev/null || echo "no kind cluster"
	@docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' \
	  --filter "label=io.x-k8s.kind.cluster=$(CLUSTER_NAME)" 2>/dev/null
	@docker inspect $(CP_CONTAINER) \
	  --format '{{range $$k,$$v := .NetworkSettings.Networks}}{{$$k}} ({{$$v.IPAddress}}) {{end}}' \
	  2>/dev/null

ps: ## Show cluster containers and the controller
	@docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Networks}}'

logs: ## Tail the kind controller logs
	docker compose logs -f kind

## ---- cilium ---------------------------------------------------------

.PHONY: cilium-install cilium-status hubble-ui

cilium-install: ## Install/upgrade cilium on the cluster
	./scripts/install-cilium.sh

cilium-status: ## Run cilium status
	kubectl -n kube-system exec deploy/cilium-operator -- cilium status --brief

hubble-ui: ## Port-forward hubble UI to http://localhost:12000
	kubectl -n kube-system port-forward svc/hubble-ui 12000:80

## ---- gobgp ----------------------------------------------------------

.PHONY: gobgp-up gobgp-down gobgp-apply gobgp-status gobgp-routes

gobgp-up: net-create ## Start the GoBGP speaker container (background)
	@echo "starting gobgp speaker..."
	docker compose up -d gobgp
	@echo "gobgp gRPC API available at localhost:50051"

gobgp-down: ## Stop the GoBGP speaker container
	docker compose stop gobgp 2>/dev/null || true
	docker compose rm -f gobgp 2>/dev/null || true

gobgp-apply: ## Apply Cilium BGP CRDs (peer config + cluster config + advertisement)
	kubectl --kubeconfig $(KUBECONFIG) apply -f manifests/cilium-bgp.yaml
	kubectl --kubeconfig $(KUBECONFIG) wait --for=condition=established crd/ciliumbgpclusterconfigs.cilium.io --timeout=30s || true

gobgp-status: ## Show GoBGP neighbor state
	@docker exec gobgp-speaker /go/bin/gobgp neighbor 2>/dev/null || \
	  echo "gobgp container not running — try 'make gobgp-up' first"

gobgp-routes: ## Show routes learned by GoBGP from Cilium peers
	@docker exec gobgp-speaker /go/bin/gobgp global rib 2>/dev/null || \
	  echo "gobgp container not running — try 'make gobgp-up' first"

## ---- debug ----------------------------------------------------------

.PHONY: netshoot

netshoot: ## Run an ephemeral netshoot debug pod
	kubectl --kubeconfig $(KUBECONFIG) run netshoot --rm -it \
	  --restart=Never --image=nicolaka/netshoot -- /bin/bash

## ---- misc ------------------------------------------------------------

.PHONY: kubeconfig clean

kubeconfig: ## Print path to the kubeconfig
	@echo $(KUBECONFIG)

clean: down net-rm ## Tear down cluster + remove network
	rm -rf ./.kubeconfig/*
