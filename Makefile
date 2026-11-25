SHELL := /bin/bash
.DEFAULT_GOAL := help

IMAGE ?= ghcr.io/mythicc123/brewq-service:0.1.0
CLUSTER := brewq
CONTEXT := kind-$(CLUSTER)
KUBECTL := kubectl --context $(CONTEXT)
HELM := helm --kube-context $(CONTEXT)
CHART := charts/brewq

TRAEFIK_VERSION := 43.0.0
TRAEFIK_REPO := https://traefik.github.io/charts
METRICS_SERVER_VERSION := 3.14.0
METRICS_SERVER_REPO := https://kubernetes-sigs.github.io/metrics-server/
GATEWAY_API_VERSION := v1.7.0
GATEWAY_API_URL := https://github.com/kubernetes-sigs/gateway-api/releases/download/$(GATEWAY_API_VERSION)/standard-install.yaml
SCHEMA_CATALOG := https://raw.githubusercontent.com/datreeio/CRDs-catalog/04af58d740718c4dc719441bf39fb284c784f4a8
KUBECONFORM_CACHE ?=
TIMEOUT := 5m

.PHONY: help up down deploy load-image smoke test lint status

help:
	@printf '%s\n' \
		'make up          Create the cluster and install the platform' \
		'make deploy      Install or upgrade Brewq' \
		'make smoke       Check the public menu, version and order endpoints' \
		'make test        Run the in-cluster smoke test' \
		'make load-image  Load a local image tagged as IMAGE into kind' \
		'make lint        Lint and validate the chart in multiple configurations' \
		'make status      Show node, platform and app status' \
		'make down        Delete the Brewq kind cluster'

up:
	@set -e; clusters=$$(kind get clusters); \
	if ! grep -qx '$(CLUSTER)' <<< "$$clusters"; then \
		kind create cluster --name $(CLUSTER) --config kind/cluster.yaml --wait $(TIMEOUT); \
	fi
	$(KUBECTL) wait --for=condition=Ready nodes --all --timeout=$(TIMEOUT)
	@# Server-side apply avoids large last-applied annotations on the CRDs.
	$(KUBECTL) apply --server-side -f $(GATEWAY_API_URL)
	$(KUBECTL) wait --for=condition=Established \
		crd/gatewayclasses.gateway.networking.k8s.io crd/gateways.gateway.networking.k8s.io \
		crd/httproutes.gateway.networking.k8s.io --timeout=$(TIMEOUT)
	$(HELM) upgrade --install traefik traefik --repo $(TRAEFIK_REPO) \
		--version $(TRAEFIK_VERSION) --skip-crds -f platform/traefik-values.yaml \
		-n traefik --create-namespace --wait --timeout $(TIMEOUT)
	$(KUBECTL) apply -f platform/gateway.yaml
	$(HELM) upgrade --install metrics-server metrics-server --repo $(METRICS_SERVER_REPO) \
		--version $(METRICS_SERVER_VERSION) -f platform/metrics-server-values.yaml \
		-n kube-system --wait --timeout $(TIMEOUT)
	$(KUBECTL) wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io --timeout=$(TIMEOUT)
	$(KUBECTL) -n traefik wait --for=condition=Programmed gateway/edge --timeout=$(TIMEOUT)

down:
	kind delete cluster --name $(CLUSTER)

deploy:
	$(HELM) upgrade --install brewq $(CHART) -n brewq --create-namespace --wait --timeout $(TIMEOUT)

load-image:
	kind load docker-image --name $(CLUSTER) "$(IMAGE)"

smoke:
	@set -e; request() { \
		local path="$$1" response status; shift; \
		response=$$(curl --silent --show-error --noproxy brewq.localtest.me --max-time 15 \
			--write-out '\n%{http_code}' "$$@" "http://brewq.localtest.me$$path") || return; \
		status=$${response##*$$'\n'}; \
		printf '%s\n' "$${response%$$'\n'*}"; \
		case "$$status" in \
			2[0-9][0-9]) return 0 ;; \
			*) printf '%s returned HTTP %s\n' "$$path" "$$status" >&2; return 1 ;; \
		esac; \
	}; \
	request /menu; \
	request /version; \
	request /orders --request POST --header 'Content-Type: application/json' \
		--data '{"name":"Sam","drink":"flat white"}'

test:
	@# Argo CD renders the chart without recording a Helm release.
	@set -e -o pipefail; \
	release=$$($(HELM) list -n brewq --filter '^brewq$$' --short); \
	if [[ -n "$$release" ]]; then \
		$(HELM) test brewq -n brewq --logs --timeout $(TIMEOUT); \
	else \
		pod=$$($(HELM) template brewq $(CHART) -n brewq --show-only templates/tests/smoke.yaml | \
			$(KUBECTL) -n brewq create -f - -o name); \
		trap '$(KUBECTL) -n brewq delete "$$pod" --ignore-not-found' EXIT; \
		$(KUBECTL) -n brewq wait "$$pod" --for='jsonpath={.status.phase}=Succeeded' --timeout=90s || { \
			$(KUBECTL) -n brewq describe "$$pod"; \
			$(KUBECTL) -n brewq logs "$$pod"; \
			exit 1; \
		}; \
		$(KUBECTL) -n brewq logs "$$pod"; \
	fi

lint:
	helm lint $(CHART) --strict --kube-version 1.37.0
	@set -e -o pipefail; for values in default autoscaling.enabled=false httpRoute.enabled=false \
		'chaos.errorRate=0.3,chaos.latencyMs=400,chaos.leakMbPerMin=40,chaos.crashOnStart=true' \
		'chaos.errorRate=0,chaos.latencyMs=0,chaos.leakMbPerMin=0,chaos.crashOnStart=false'; do \
		printf '\nRendering %s\n' "$$values"; \
		args=(); \
		case "$$values" in \
			default) ;; \
			*) args=(--set "$$values") ;; \
		esac; \
		helm template brewq $(CHART) --namespace brewq --kube-version 1.37.0 "$${args[@]}" | \
			kubeconform -strict -summary -kubernetes-version 1.37.0 \
				$(if $(KUBECONFORM_CACHE),-cache "$(KUBECONFORM_CACHE)") \
				-schema-location default \
				-schema-location '$(SCHEMA_CATALOG)/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'; \
	done

status:
	$(KUBECTL) get nodes
	$(KUBECTL) -n traefik get deployment,service,gateway
	$(KUBECTL) -n kube-system get deployment metrics-server
	$(KUBECTL) -n brewq get deployment,pod,service,hpa,pdb,httproute
