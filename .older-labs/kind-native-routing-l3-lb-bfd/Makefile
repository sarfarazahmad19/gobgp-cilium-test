SHELL := /bin/sh
.DEFAULT_GOAL := help

CLUSTER_NAME      ?= overlay-l3-bgp-bfd
CP_CONTAINER      ?= overlay-l3-bgp-bfd-control-plane
NETWORK_NAME      ?= bgp-net
CLIENT_NETWORK    ?= client-net
TRANSIT_NETWORK   ?= transit-net
KUBECONFIG        ?= $(PWD)/.kubeconfig/kubeconfig.yaml
KIND_IMAGE        ?= kindest/node:v1.33.0
CILIUM_VERSION    ?= 1.19.5
KIND_BIN          ?= /usr/local/bin/kind
HELM_BIN          ?= helm

export KUBECONFIG
export CP_CONTAINER
export NETWORK_NAME
export CLIENT_NETWORK
export TRANSIT_NETWORK
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
	@if docker network inspect $(CLIENT_NETWORK) >/dev/null 2>&1; then \
	  echo "network $(CLIENT_NETWORK) already exists"; \
	else \
	  docker network create --driver bridge --subnet 172.21.0.0/24 --gateway 172.21.0.1 $(CLIENT_NETWORK); \
	  echo "created network $(CLIENT_NETWORK) (gateway 172.21.0.1, FRR at 172.21.0.10)"; \
	fi
	@if docker network inspect $(TRANSIT_NETWORK) >/dev/null 2>&1; then \
	  echo "network $(TRANSIT_NETWORK) already exists"; \
	else \
	  docker network create --driver bridge --subnet 172.23.0.0/24 --gateway 172.23.0.254 $(TRANSIT_NETWORK); \
	  echo "created network $(TRANSIT_NETWORK) (172.23.0.0/24, gw 172.23.0.254)"; \
	fi

net-rm: ## Remove all docker networks (bgp-net + client-net + transit-net)
	docker network rm $(NETWORK_NAME) 2>/dev/null || true
	docker network rm $(CLIENT_NETWORK) 2>/dev/null || true
	docker network rm $(TRANSIT_NETWORK) 2>/dev/null || true

## ---- cluster lifecycle -----------------------------------------------

.PHONY: up cluster-up down status ps logs cilium-uninstall

up: cluster-up cilium-uninstall cilium-install kuberouter-apply lb-pool-apply svc-apply frr-up client-up ## Full bring-up: cluster + cilium + kube-router + LB pool + Service + both FRR speakers + test client
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

.PHONY: frr-up frr-down client-up client-down client-route-add client-test kuberouter-apply lb-pool-apply svc-apply

FRR2_CONTAINER  ?= frr-speaker-cluster
FRR1_CONTAINER  ?= frr-speaker-tor
FRR2_IP         ?= 172.19.0.10

.PHONY: frr-up frr1-up frr2-up frr-down frr1-down frr2-down
.PHONY: client-up client-down client-test client-route-add
.PHONY: kuberouter-apply kuberouter-status kuberouter-logs kuberouter-bgp kuberouter-bfd lb-pool-apply svc-apply

frr-up: net-create ## Start both FRR speakers (TOR + border)
	@echo "starting FRR speakers (TOR + border)..."
	docker compose up -d frr1 frr2
	@echo "FRR border vtysh: docker exec $(FRR2_CONTAINER) vtysh"
	@echo "FRR TOR vtysh:    docker exec $(FRR1_CONTAINER) vtysh"

frr1-up: net-create ## Start the FRR TOR speaker
	@echo "starting FRR TOR..."
	docker compose up -d frr1
	@echo "FRR TOR vtysh: docker exec $(FRR1_CONTAINER) vtysh"

frr2-up: net-create ## Start the FRR border speaker
	@echo "starting FRR border..."
	docker compose up -d frr2
	@echo "FRR border vtysh: docker exec $(FRR2_CONTAINER) vtysh"

frr-down: ## Stop both FRR speakers
	docker compose stop frr1 frr2 2>/dev/null || true
	docker compose rm -f frr1 frr2 2>/dev/null || true

frr1-down: ## Stop the FRR TOR speaker
	docker compose stop frr1 2>/dev/null || true
	docker compose rm -f frr1 2>/dev/null || true

frr2-down: ## Stop the FRR border speaker
	docker compose stop frr2 2>/dev/null || true
	docker compose rm -f frr2 2>/dev/null || true

client-up: net-create frr1-up client-route-add ## Start the test client (depends on FRR1 TOR for gateway)
	@echo "starting test client..."
	docker compose up -d client
	@echo "test-client shell: docker exec -it test-client sh"

client-route-add: ## Set FRR2 as default gateway on all kind nodes (replaces all static routes)
	@echo "setting FRR2 (172.19.0.10) as default gateway on all kind nodes..."
	-for node in $$(docker ps --filter "name=overlay-l3-bgp-bfd" --format '{{.Names}}' 2>/dev/null); do \
	  docker exec $$node sh -c "ip route flush 0/0 2>/dev/null; ip route add default via $(FRR2_IP)"; \
	done

client-down: ## Stop the test client
	docker compose stop client 2>/dev/null || true
	docker compose rm -f client 2>/dev/null || true

client-test: ## Curl the LB VIP from the test client (verifies FRR forwarding)
	docker exec test-client sh -c 'curl -s http://172.19.0.200 | head -20'

kuberouter-apply: ## Apply kube-router DaemonSet (BGP + BFD speaker, no service proxy / firewall)
	@for node in $$(kubectl --kubeconfig $(KUBECONFIG) get nodes -o name 2>/dev/null | grep -v control-plane); do \
	  kubectl --kubeconfig $(KUBECONFIG) annotate $$node kube-router.io/node.asn=65001 --overwrite; \
	done
	kubectl --kubeconfig $(KUBECONFIG) apply -f manifests/kube-router.yaml
	kubectl --kubeconfig $(KUBECONFIG) -n kube-system rollout status ds/kube-router --timeout=120s

kuberouter-status: ## Show kube-router DaemonSet status
	@kubectl --kubeconfig $(KUBECONFIG) -n kube-system get ds/kube-router -o wide
	@kubectl --kubeconfig $(KUBECONFIG) -n kube-system get pods -l app=kube-router -o wide

kuberouter-logs: ## Tail kube-router logs across all pods
	@kubectl --kubeconfig $(KUBECONFIG) -n kube-system logs -l app=kube-router --tail=80 --max-log-requests=10

kuberouter-bgp: ## Show kube-router BGP neighbor state (gobgp inside the pod)
	@echo "Note: requires the kube-router pod to have gobgp in PATH (bundled with the image)."
	@kubectl --kubeconfig $(KUBECONFIG) -n kube-system exec -l app=kube-router -c kube-router -- \
	  gobgp neighbor 2>/dev/null || \
	  echo "gobgp not in PATH — try 'kubectl -n kube-system exec -it ds/kube-router -- sh' and inspect /var/lib/gobgp/"

kuberouter-bfd: ## Show kube-router BFD session state (if exposed by the image)
	@kubectl --kubeconfig $(KUBECONFIG) -n kube-system exec -l app=kube-router -c kube-router -- \
	  gobgp global rib 2>/dev/null || true
	@echo "---"
	@echo "BFD state is best inspected on the FRR side:  make frr2-bfd"
	@echo "kube-router's GoBGP doesn't always expose BFD via CLI — logs are the source of truth."

lb-pool-apply: ## Apply CiliumLoadBalancerIPPool for LB IPAM
	kubectl --kubeconfig $(KUBECONFIG) apply -f manifests/cilium-lb-pool.yaml

svc-apply: ## Apply the sample LoadBalancer Service + Deployment (go-httpbin)
	kubectl --kubeconfig $(KUBECONFIG) apply -f manifests/svc-lb.yaml

frr2-status: ## Show FRR border BGP neighbor state
	@docker exec $(FRR2_CONTAINER) vtysh -c "show bgp summary" 2>/dev/null || \
	  echo "FRR border not running — try 'make frr2-up' first"

frr2-routes: ## Show routes in FRR border RIB
	@docker exec $(FRR2_CONTAINER) vtysh -c "show bgp ipv4 unicast" 2>/dev/null || \
	  echo "FRR border not running — try 'make frr2-up' first"

frr2-bfd: ## Show FRR border BFD peer state (sub-second failover signal source)
	@docker exec $(FRR2_CONTAINER) vtysh -c "show bfd peers" 2>/dev/null || \
	  echo "FRR border not running or bfdd not enabled — check frr/daemons"

frr2-bfd-counter: ## Show FRR border BFD peer counters + detailed state
	@docker exec $(FRR2_CONTAINER) vtysh -c "show bfd peers brief" 2>/dev/null || \
	  echo "FRR border not running or bfdd not enabled — check frr/daemons"

frr2-route-fib: ## Show FRR border kernel FIB (BGP-installed routes)
	@docker exec $(FRR2_CONTAINER) ip route show proto bgp 2>/dev/null || \
	  echo "FRR border not running — try 'make frr2-up' first"

frr1-status: ## Show FRR TOR BGP neighbor state
	@docker exec $(FRR1_CONTAINER) vtysh -c "show bgp summary" 2>/dev/null || \
	  echo "FRR TOR not running — try 'make frr1-up' first"

frr1-routes: ## Show routes in FRR TOR RIB (should see LB VIP via FRR2)
	@docker exec $(FRR1_CONTAINER) vtysh -c "show bgp ipv4 unicast" 2>/dev/null || \
	  echo "FRR TOR not running — try 'make frr1-up' first"

frr1-route-fib: ## Show FRR TOR kernel FIB (BGP-installed routes)
	@docker exec $(FRR1_CONTAINER) ip route show proto bgp 2>/dev/null || \
	  echo "FRR TOR not running — try 'make frr1-up' first"

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
