CLUSTER_NAME ?= bird2-lab
TOR1_IP      ?= 172.18.0.100
TOR2_IP      ?= 172.18.0.50
NETWORK      ?= kind
BIRD_IMAGE   ?= bird3-lab:latest
FRR_IMAGE    ?= frrouting/frr:v8.4.0

.PHONY: help up down build clean status bgp bfd routes bird3 tor

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

build: ## Build Bird3 Docker image
	docker build -t $(BIRD_IMAGE) images/bird3/

kind-cluster: ## Create Kind cluster (control-plane + 2 workers, no CNI)
	kind create cluster --name $(CLUSTER_NAME) --config kind/cluster.yaml

load-image: ## Load Bird3 image into Kind nodes
	kind load docker-image $(BIRD_IMAGE) --name $(CLUSTER_NAME)

cilium: ## Install Cilium with BGP control plane
	helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
	helm upgrade --install cilium cilium/cilium \
		--namespace kube-system \
		--set kubeProxyReplacement=true \
		--set routingMode=native \
		--set ipv4NativeRoutingCIDR=172.18.0.0/16 \
		--set bgpControlPlane.enabled=true \
		--wait

cilium-bgp: ## Apply Cilium BGP peering config
	kubectl apply -f bird3/cilium-bgp.yaml

tor1: ## Start TOR1 (FRR) on kind network
	-docker rm -f frr-tor-mock 2>/dev/null
	docker run -d \
		--name frr-tor-mock \
		--network $(NETWORK) \
		--ip $(TOR1_IP) \
		--privileged \
		--volume $(PWD)/tor/tor1.conf:/etc/frr/frr.conf \
		--volume $(PWD)/tor/daemons:/etc/frr/daemons \
		--cap-add=NET_ADMIN --cap-add=SYS_ADMIN \
		--sysctl net.ipv4.ip_forward=1 \
		$(FRR_IMAGE)
	docker exec frr-tor-mock iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

tor2: ## Start TOR2 (FRR) on kind network
	-docker rm -f frr-tor2-mock 2>/dev/null
	docker run -d \
		--name frr-tor2-mock \
		--network $(NETWORK) \
		--ip $(TOR2_IP) \
		--privileged \
		--volume $(PWD)/tor/tor2.conf:/etc/frr/frr.conf \
		--volume $(PWD)/tor/daemons:/etc/frr/daemons \
		--cap-add=NET_ADMIN --cap-add=SYS_ADMIN \
		--sysctl net.ipv4.ip_forward=1 \
		$(FRR_IMAGE)
	docker exec frr-tor2-mock iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

tor: tor1 tor2 ## Start both TORs

bird3: ## Deploy Bird3 DaemonSet
	kubectl apply -f bird3/configmap.yaml
	kubectl apply -f bird3/daemonset.yaml
	@echo "Waiting for Bird3 rollout..."
	@kubectl rollout status daemonset bird3-bfd -n kube-system --timeout=120s || true

up: build kind-cluster load-image cilium cilium-bgp tor bird3 ## Bring up entire lab
	@echo ""
	@echo "=== Lab Ready ==="
	@echo "Architecture: Cilium <--BGP--> Bird3 <--BGP+BFD--> TOR1+TOR2"
	@echo ""
	$(MAKE) status

down: ## Tear down everything
	kind delete cluster --name $(CLUSTER_NAME) 2>/dev/null || true
	docker rm -f frr-tor-mock frr-tor2-mock 2>/dev/null || true
	@echo "Lab torn down."

clean: down ## Full cleanup
	docker rmi $(BIRD_IMAGE) 2>/dev/null || true

status: bgp bfd routes ## Show all BGP, BFD, and route info

bgp: ## Show BGP status across all components
	@echo "=========================================="
	@echo "  Cilium BGP Peers"
	@echo "=========================================="
	-kubectl exec -n kube-system ds/cilium -- cilium-dbg bgp peers 2>/dev/null || \
	 kubectl exec -n kube-system ds/cilium -- cilium bgp peers 2>/dev/null
	@echo ""
	@echo "=========================================="
	@echo "  Bird3 BGP Protocols (per node)"
	@echo "=========================================="
	@for pod in $$(kubectl get pods -n kube-system -l app=bird3-bfd -o name); do \
		node=$$(kubectl get $$pod -n kube-system -o jsonpath='{.spec.nodeName}'); \
		echo "--- $$node ---"; \
		kubectl exec -n kube-system $$pod -c bird3 -- birdc -s /var/run/bird.ctl show protocols 2>&1; \
		echo ""; \
	done
	@echo "=========================================="
	@echo "  Bird3 BGP Routes (per node)"
	@echo "=========================================="
	@for pod in $$(kubectl get pods -n kube-system -l app=bird3-bfd -o name); do \
		node=$$(kubectl get $$pod -n kube-system -o jsonpath='{.spec.nodeName}'); \
		echo "--- $$node ---"; \
		kubectl exec -n kube-system $$pod -c bird3 -- birdc -s /var/run/bird.ctl show route 2>&1; \
		echo ""; \
	done
	@echo "=========================================="
	@echo "  TOR1 ($(TOR1_IP)) BGP Summary"
	@echo "=========================================="
	@docker exec frr-tor-mock vtysh -c 'show ip bgp summary' 2>/dev/null | grep -v "Can't open"
	@echo ""
	@echo "=========================================="
	@echo "  TOR1 BGP Routes"
	@echo "=========================================="
	@docker exec frr-tor-mock vtysh -c 'show ip bgp' 2>/dev/null | grep -v "Can't open"
	@echo ""
	@echo "=========================================="
	@echo "  TOR2 ($(TOR2_IP)) BGP Summary"
	@echo "=========================================="
	@docker exec frr-tor2-mock vtysh -c 'show ip bgp summary' 2>/dev/null | grep -v "Can't open"
	@echo ""
	@echo "=========================================="
	@echo "  TOR2 BGP Routes"
	@echo "=========================================="
	@docker exec frr-tor2-mock vtysh -c 'show ip bgp' 2>/dev/null | grep -v "Can't open"

bfd: ## Show BFD status across all components
	@echo "=========================================="
	@echo "  Bird3 BFD Sessions (per node)"
	@echo "=========================================="
	@for pod in $$(kubectl get pods -n kube-system -l app=bird3-bfd -o name); do \
		node=$$(kubectl get $$pod -n kube-system -o jsonpath='{.spec.nodeName}'); \
		echo "--- $$node ---"; \
		kubectl exec -n kube-system $$pod -c bird3 -- birdc -s /var/run/bird.ctl show bfd sessions 2>&1; \
		echo ""; \
	done
	@echo "=========================================="
	@echo "  TOR1 ($(TOR1_IP)) BFD Peers"
	@echo "=========================================="
	@docker exec frr-tor-mock vtysh -c 'show bfd peers brief' 2>/dev/null | grep -v "Can't open"
	@echo ""
	@echo "=========================================="
	@echo "  TOR2 ($(TOR2_IP)) BFD Peers"
	@echo "=========================================="
	@docker exec frr-tor2-mock vtysh -c 'show bfd peers brief' 2>/dev/null | grep -v "Can't open"

test-lb: ## Deploy nginx LoadBalancer service for testing BGP advertisements
	kubectl apply -f test/lb-nginx.yaml
	@echo ""
	@echo "Waiting for LoadBalancer IP..."
	@until kubectl get svc nginx-lb -n lb-test -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null | grep -q .; do sleep 2; done
	@echo "nginx-lb external IP: $$(kubectl get svc nginx-lb -n lb-test -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
	@echo "Verify with: $(MAKE) bgp"

test-lb-down: ## Remove test LB resources
	kubectl delete -f test/lb-nginx.yaml 2>/dev/null || true

routes: ## Show kernel routing tables
	@echo "=========================================="
	@echo "  Cilium BGP Routes"
	@echo "=========================================="
	-kubectl exec -n kube-system ds/cilium -- cilium-dbg bgp routes 2>/dev/null || \
	 kubectl exec -n kube-system ds/cilium -- cilium bgp routes 2>/dev/null || \
	 echo "(no Cilium BGP route command available)"
	@echo ""
	@echo "=========================================="
	@echo "  Cilium Service VIPs"
	@echo "=========================================="
	-kubectl get svc -A -o wide 2>/dev/null | grep -E "LoadBalancer|EXTERNAL-IP" || true
