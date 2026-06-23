SHELL := /bin/sh
.DEFAULT_GOAL := help

CLUSTER_NAME      ?= overlay-l3-bgp
CP_CONTAINER      ?= overlay-l3-bgp-control-plane
NETWORK_NAME      ?= bgp-net
CLIENT_NETWORK    ?= client-net
KIND_NETWORK      ?= bgp-kind
KUBECONFIG        ?= $(PWD)/.kubeconfig/kubeconfig.yaml
KIND_IMAGE        ?= kindest/node:v1.33.0
CILIUM_VERSION    ?= 1.19.5
KIND_BIN          ?= /usr/local/bin/kind
HELM_BIN          ?= helm

export KUBECONFIG
export CP_CONTAINER
export NETWORK_NAME
export CLIENT_NETWORK
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
	  docker network create --driver bridge --subnet 172.19.0.0/16 $(NETWORK_NAME); \
	  echo "created network $(NETWORK_NAME)"; \
	fi
	@if docker network inspect $(KIND_NETWORK) >/dev/null 2>&1; then \
	  echo "network $(KIND_NETWORK) already exists"; \
	else \
	  docker network create --driver bridge --subnet 172.20.0.0/16 $(KIND_NETWORK); \
	  echo "created network $(KIND_NETWORK)"; \
	fi
	@if docker network inspect $(CLIENT_NETWORK) >/dev/null 2>&1; then \
	  echo "network $(CLIENT_NETWORK) already exists"; \
	else \
	  docker network create --driver bridge --subnet 172.21.0.0/24 --gateway 172.21.0.1 $(CLIENT_NETWORK); \
	  echo "created network $(CLIENT_NETWORK) (gateway 172.21.0.1, FRR at 172.21.0.10)"; \
	fi

net-rm: ## Remove all docker networks (bgp-net + client-net + kind cluster bridge)
	docker network rm $(NETWORK_NAME) 2>/dev/null || true
	docker network rm $(CLIENT_NETWORK) 2>/dev/null || true
	docker network rm $(KIND_NETWORK) 2>/dev/null || true

## ---- cluster lifecycle -----------------------------------------------

.PHONY: up cluster-up down status ps logs cilium-uninstall

up: cluster-up cilium-uninstall cilium-install bgp-auth-secret bgp-apply lb-pool-apply frr-up client-up ## Full bring-up: cluster + cilium + auth secret + BGP CRDs + LB pool + speaker + test client
	@echo
	@echo "all up. kubeconfig: $(KUBECONFIG)"
	@echo "export KUBECONFIG=$(KUBECONFIG)"

cluster-up: net-create ## Bring up just the kind cluster (attaches to bgp-net via kind-up.sh)
	docker compose run --rm kind
	@echo
	@echo "kubeconfig: $(KUBECONFIG)"
	@echo "export KUBECONFIG=$(KUBECONFIG)"

down: frr-down client-down ## Tear down the kind cluster (also stops the frr speaker and test client)
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

.PHONY: cilium-install cilium-status hubble-ui cilium-uninstall

cilium-install: ## Install/upgrade cilium on the cluster
	./scripts/install-cilium.sh

cilium-uninstall: ## Uninstall cilium from the cluster
	helm uninstall cilium --namespace kube-system --kubeconfig $(KUBECONFIG) --wait=false 2>/dev/null || true

cilium-status: ## Run cilium status
	kubectl -n kube-system exec deploy/cilium-operator -- cilium status --brief

hubble-ui: ## Port-forward hubble UI to http://localhost:12000
	kubectl -n kube-system port-forward svc/hubble-ui 12000:80

## ---- frr ------------------------------------------------------------

BGP_AUTH_PASSWORD ?= bgp-md5-secret-2026

.PHONY: frr-up frr-down client-up client-down client-route-add client-test bgp-apply bgp-auth-secret lb-pool-apply

frr-up: net-create ## Start the FRR BGP speaker container (background)
	@echo "starting FRR BGP speaker..."
	docker compose up -d frr
	@echo "FRR vtysh available via: docker exec frr-speaker vtysh"

frr-down: ## Stop the FRR BGP speaker container
	docker compose stop frr 2>/dev/null || true
	docker compose rm -f frr 2>/dev/null || true

client-up: net-create frr-up client-route-add ## Start the test client (depends on FRR for connectivity)
	@echo "starting test client..."
	docker compose up -d client
	@echo "test-client shell: docker exec -it test-client sh"

client-route-add: ## Add static routes on kind nodes for 172.21.0.0/24 via FRR (needed for DSR return path)
	@echo "adding return route to client-net on all nodes..."
	-for node in $$(docker ps --filter "name=overlay-l3-bgp" --format '{{.Names}}' 2>/dev/null); do \
	  docker exec $$node ip route replace 172.21.0.0/24 via 172.19.0.10 dev eth1; \
	done

client-down: ## Stop the test client
	docker compose stop client 2>/dev/null || true
	docker compose rm -f client 2>/dev/null || true

client-test: ## Curl the LB VIP from the test client (verifies FRR forwarding + DSR)
	docker exec test-client sh -c 'curl -s http://172.19.0.200 | head -20'

bgp-apply: ## Apply Cilium BGP CRDs (peer config + cluster config + advertisement)
	kubectl --kubeconfig $(KUBECONFIG) apply -f manifests/cilium-bgp.yaml
	kubectl --kubeconfig $(KUBECONFIG) wait --for=condition=established crd/ciliumbgpclusterconfigs.cilium.io --timeout=30s || true

bgp-auth-secret: ## Create/update the k8s Secret used for TCP MD5 BGP auth
	@echo "creating secret bgp-auth in kube-system (BGP TCP MD5 password)"
	kubectl --kubeconfig $(KUBECONFIG) create secret generic bgp-auth \
	  -n kube-system \
	  --from-literal=password=$(BGP_AUTH_PASSWORD) \
	  --dry-run=client -o yaml | kubectl --kubeconfig $(KUBECONFIG) apply -f -

lb-pool-apply: ## Apply CiliumLoadBalancerIPPool for LB IPAM
	kubectl --kubeconfig $(KUBECONFIG) apply -f manifests/cilium-lb-pool.yaml

frr-status: ## Show FRR BGP neighbor state
	@docker exec frr-speaker vtysh -c "show bgp summary" 2>/dev/null || \
	  echo "FRR container not running — try 'make frr-up' first"

frr-routes: ## Show routes learned by FRR from Cilium peers
	@docker exec frr-speaker vtysh -c "show bgp ipv4 unicast" 2>/dev/null || \
	  echo "FRR container not running — try 'make frr-up' first"

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
