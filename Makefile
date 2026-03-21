IMAGE   := proxy-install-test
CONTAINER := proxy-test

.PHONY: build up exec test test-cli test-smoke test-uninstall down clean

build:
	docker build --platform linux/amd64 -f Dockerfile.test -t $(IMAGE) .

up: build
	-docker rm -f $(CONTAINER) 2>/dev/null
	docker run -d \
		--platform linux/amd64 \
		--name $(CONTAINER) \
		--privileged \
		-v /sys/fs/cgroup:/sys/fs/cgroup:rw \
		$(IMAGE)
	@echo "Waiting for systemd..."
	@for i in $$(seq 1 15); do \
		STATUS=$$(docker exec $(CONTAINER) systemctl is-system-running 2>/dev/null); \
		[ "$$STATUS" = "running" ] || [ "$$STATUS" = "degraded" ] && break; \
		sleep 1; \
	done
	@echo "Container ready."

exec: up
	docker exec -it $(CONTAINER) bash

test: up
	docker exec -it $(CONTAINER) bash /opt/proxy-install.sh

test-cli: up
	docker exec -it $(CONTAINER) bash /opt/proxy-install.sh \
		--host test.example.com \
		--tls-domain example.com \
		--bot-ip 10.0.0.1

test-smoke: up
	@echo "=== Running install ==="
	docker exec $(CONTAINER) bash /opt/proxy-install.sh \
		--host test.example.com \
		--tls-domain example.com \
		--bot-ip 10.0.0.1
	@echo "=== Smoke tests ==="
	docker exec $(CONTAINER) systemctl is-active telemt
	docker exec $(CONTAINER) systemctl is-active 3proxy
	docker exec $(CONTAINER) test -f /opt/proxy-agent/env
	docker exec $(CONTAINER) test -f /etc/telemt/telemt.toml
	docker exec $(CONTAINER) test -f /etc/3proxy/3proxy.cfg
	docker exec $(CONTAINER) test -f /etc/sysctl.d/99-proxy-install.conf
	docker exec $(CONTAINER) test -f /etc/security/limits.d/99-proxy-install.conf
	docker exec $(CONTAINER) id proxy-agent
	@echo "=== All smoke tests passed ==="

test-uninstall: test-smoke
	@echo "=== Running uninstall ==="
	docker exec $(CONTAINER) bash /opt/proxy-install.sh --uninstall
	@echo "=== Uninstall checks ==="
	docker exec $(CONTAINER) bash -c '! systemctl is-active telemt 2>/dev/null'
	docker exec $(CONTAINER) bash -c '! test -f /usr/local/bin/telemt'
	docker exec $(CONTAINER) bash -c '! test -d /etc/telemt'
	docker exec $(CONTAINER) bash -c '! test -d /opt/proxy-agent'
	docker exec $(CONTAINER) bash -c '! test -f /etc/sysctl.d/99-proxy-install.conf'
	@echo "=== Uninstall tests passed ==="

down:
	-docker rm -f $(CONTAINER) 2>/dev/null

clean: down
	-docker rmi $(IMAGE) 2>/dev/null
