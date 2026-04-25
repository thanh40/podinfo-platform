.PHONY: all cluster deps lint deploy-kube-prometheus-stack deploy-podinfo verify verify-alert teardown

all: cluster deploy-kube-prometheus-stack deploy-podinfo verify verify-alert

NAMESPACE    ?= default
ENV          ?= dev
EXTRA_ARGS   ?=
CLUSTER_NAME ?= podinfo
CHARTS       := $(wildcard helm/*)

cluster:
	CLUSTER_NAME=$(CLUSTER_NAME) ./cluster/setup.sh

deps:
	@for chart in $(CHARTS); do \
		helm dependency update $$chart; \
	done

lint: deps
	@for chart in $(CHARTS); do \
		helm lint $$chart; \
		helm template $$(basename $$chart) $$chart --debug > /dev/null; \
		if [ -f $$chart/values-prod.yaml ]; then \
			helm template $$(basename $$chart) $$chart -f $$chart/values-prod.yaml --debug > /dev/null; \
		fi; \
	done

deploy-kube-prometheus-stack:
	kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
	# --rollback-on-failure (prod only): rolls back automatically if the release fails to reach
	# Running within the timeout, then exits non-zero to fail the pipeline.
	helm upgrade --install kube-prometheus-stack helm/kube-prometheus-stack \
		--namespace monitoring \
		$(if $(filter prod,$(ENV)),-f helm/kube-prometheus-stack/values-prod.yaml --rollback-on-failure,--wait) \
		--timeout 10m

deploy-podinfo:
	# --rollback-on-failure (prod only): rolls back automatically if the release fails to reach
	# Running within the timeout, then exits non-zero to fail the pipeline.
	helm upgrade --install podinfo helm/podinfo \
		--namespace $(NAMESPACE) \
		$(if $(filter prod,$(ENV)),-f helm/podinfo/values-prod.yaml --rollback-on-failure,--wait) \
		$(EXTRA_ARGS) \
		--timeout 3m

verify:
	kubectl rollout status deployment/podinfo-podinfo \
		--namespace $(NAMESPACE) --timeout=60s
	kubectl port-forward -n $(NAMESPACE) svc/podinfo-podinfo 9898:9898 & \
		PID=$$! && \
		sleep 3 && \
		curl --fail --silent http://localhost:9898/healthz && \
		echo " /healthz OK" && \
		kill $$PID

verify-alert:
	@echo "Deploying podinfo with short alert duration for testing..."
	$(MAKE) deploy-podinfo EXTRA_ARGS="--set prometheusRule.alertDuration=30s"
	@echo "Scaling podinfo to 0 replicas to trigger PodInfoDown alert..."
	kubectl scale deployment podinfo-podinfo --namespace $(NAMESPACE) --replicas=0
	@echo "Waiting for PodInfoDown alert to fire (up to 3 minutes)..."
	@pkill -f "port-forward.*9090" 2>/dev/null || true
	@kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
	@sleep 2
	@for i in $$(seq 1 18); do \
		RESULT=$$(curl -s 'http://localhost:9090/api/v1/alerts' | \
			python3 -c "import sys,json; alerts=[a for a in json.load(sys.stdin)['data']['alerts'] if a['labels'].get('alertname')=='PodInfoDown']; print('firing' if any(a['state']=='firing' for a in alerts) else 'pending')"); \
		echo "  [$$(expr $$i \* 10)s] $$RESULT"; \
		if [ "$$RESULT" = "firing" ]; then echo "FIRING ✓"; break; fi; \
		if [ $$i -eq 18 ]; then echo "NOT FIRING ✗"; fi; \
		sleep 10; \
	done
	@pkill -f "port-forward.*9090" 2>/dev/null || true
	@echo "Restoring podinfo to production defaults..."
	kubectl scale deployment podinfo-podinfo --namespace $(NAMESPACE) --replicas=1
	$(MAKE) deploy-podinfo

teardown:
	kind delete cluster --name $(CLUSTER_NAME)
