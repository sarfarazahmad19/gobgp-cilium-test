SHELL := /bin/sh
.DEFAULT_GOAL := help

CLUSTER_NAME      ?= gobgp
CP_CONTAINER      ?= gobgp-control-plane
NETWORK_NAME      ?= gobgp-net
KIND_NETWORK      ?= gobgp-kind
KUBECONFIG        ?= $(PWD)/.kubeconfig/kubeconfig.yaml
KIND_IMAGE        ?= kindest/node:v1.33.0
CILIUM_VERSION    ?= 1.19.5
KIND_BIN          ?= /usr/local/bin/kind
HELM_BIN          ?= helm

export KUBECONFIG
export CP_CONTAINER
export NETWORK_NAME
export KIND_NETWORK
export CILIUM_VERSION

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

## ---- network ---------------------------------------------------------

.PHONY: net-create net-rm
net-create: ## Create docker networks (idempotent)
	@if docker network inspect $(NETWORK_NAME) >/dev/null 2>&1; then \
	  echo "network $(NETWORK_NAME) already exists"; \
	else \
	  docker network create --driver bridge $(NETWORK_NAME); \
	  echo "created network $(NETWORK_NAME)"; \
	fi
	@if docker network inspect $(KIND_NETWORK) >/dev/null 2>&1; then \
	  echo "network $(KIND_NETWORK) already exists"; \
	else \
	  docker network create --driver bridge $(KIND_NETWORK); \
	  echo "created network $(KIND_NETWORK)"; \
	fi

net-rm: ## Remove both docker networks (gobgp-net + kind cluster bridge)
	docker network rm $(NETWORK_NAME) 2>/dev/null || true
	docker network rm $(KIND_NETWORK) 2>/dev/null || true

## ---- cluster lifecycle -----------------------------------------------

.PHONY: up cluster-up down status ps logs

up: cluster-up cilium-install gobgp-auth-secret gobgp-apply gobgp-up ## Full bring-up: cluster + cilium + auth secret + BGP CRDs + speaker
	@echo
	@echo "all up. kubeconfig: $(KUBECONFIG)"
	@echo "export KUBECONFIG=$(KUBECONFIG)"

cluster-up: net-create ## Bring up just the kind cluster (attaches to gobgp-net via kind-up.sh)
	docker compose run --rm kind
	@echo
	@echo "kubeconfig: $(KUBECONFIG)"
	@echo "export KUBECONFIG=$(KUBECONFIG)"

down: gobgp-down ## Tear down the kind cluster (also stops the gobgp speaker)
	$(KIND_BIN) delete cluster --name $(CLUSTER_NAME) || true

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

BGP_AUTH_PASSWORD ?= gobgp-md5-secret-2026

.PHONY: gobgp-up gobgp-down gobgp-apply gobgp-status gobgp-routes gobgp-auth-secret

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

gobgp-auth-secret: ## Create/update the k8s Secret used for TCP MD5 BGP auth
	@echo "creating secret gobgp-auth in kube-system (BGP TCP MD5 password)"
	kubectl --kubeconfig $(KUBECONFIG) create secret generic gobgp-auth \
	  -n kube-system \
	  --from-literal=password=$(BGP_AUTH_PASSWORD) \
	  --dry-run=client -o yaml | kubectl --kubeconfig $(KUBECONFIG) apply -f -

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
