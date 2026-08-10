XRAY_VERSION=26.7.28

# Переменные окружения для локальной разработки.
#   .env       — общие значения для всех (можно коммитить)
#   .env.local — личные значения, перекрывают .env (в .gitignore)
# Формат: KEY=value, без кавычек. '#' начинает комментарий, '$' пишется как '$$'.
# Пример:
#   PRIVATE_REPO=harbor.example.ru/routeros
#   DOCKERHUB_REPO=myuser
#   TEST_URL=https://example.com/sub/fwu3923fsife
#   TEST_XRAY_XMUX={"maxConcurrency":16,"maxConnections":8}
#   SOCKS_PORT=10800
#   TUN_IP=172.31.200.10
-include .env
-include .env.local

# Проверка, что переменная задана: $(call require_var,ИМЯ,пример-значения)
define require_var
@if [ -z '$($(1))' ]; then \
	echo "ERROR: $(1) не задан."; \
	echo "Задайте его в .env (общее) или .env.local (личное, перекрывает .env):"; \
	echo "    $(1)=$(2)"; \
	echo "или передайте напрямую: make <цель> $(1)=..."; \
	exit 1; \
fi
endef

# Те же файлы целиком пробрасываются в контейнер: всё, что в них лежит
# (CHECK_URL, LOCAL_NETS, IGNORE_RFC_PRIVATE_NETS, TUN_IP, ...), попадёт в окружение.
# Порядок важен: .env.local идёт последним и перекрывает .env.
ENV_FILE_ARGS := $(foreach f,$(wildcard .env) $(wildcard .env.local),--env-file $(f))

# TEST_XRAY_XMUX задаётся в .env / .env.local и уходит в контейнер как XRAY_XMUX
# (см. цель test). Значения по умолчанию нет: если не задан, XRAY_XMUX будет пустым,
# и генераторы конфига подставят "xmux": null, т.е. мультиплексирование выключено.


build-to-file-arm64:
	docker buildx build \
		--no-cache \
		--platform linux/arm64 \
		--build-arg XRAY_VERSION=${XRAY_VERSION} \
		-o type=docker,dest=docker-xray-vless-arm64.tar \
		.

build-to-file-arm:
	docker buildx build \
		--no-cache \
		--platform linux/arm \
		--build-arg XRAY_VERSION=${XRAY_VERSION} \
		-o type=docker,dest=docker-xray-vless-arm.tar \
		.

build-to-file-amd64:
	docker buildx build \
		--no-cache \
		--platform linux/amd64 \
		--build-arg XRAY_VERSION=${XRAY_VERSION} \
		-o type=docker,dest=docker-xray-vless-amd64.tar \
		.

test:
	$(call require_var,TEST_URL,https://example.com/sub/fwu3923fsife)
	docker buildx build \
		--tag docker-xray-vless:latest \
		--build-arg XRAY_VERSION=${XRAY_VERSION} \
		.

	docker run \
		-v ./scripts:/opt/develop \
		--privileged \
		$(ENV_FILE_ARGS) \
		-e URL='$(TEST_URL)' \
		-e XRAY_XMUX='$(TEST_XRAY_XMUX)' \
		-it docker-xray-vless sh

build-push-private:
	$(call require_var,PRIVATE_REPO,harbor.example.ru/routeros)
	docker buildx build \
		--platform linux/amd64,linux/arm64,linux/arm/v7 \
		--tag ${PRIVATE_REPO}/docker-xray-vless:latest \
		--tag ${PRIVATE_REPO}/docker-xray-vless:${XRAY_VERSION} \
		--build-arg XRAY_VERSION=${XRAY_VERSION} \
		--push \
		.

build-push-docker:
	$(call require_var,DOCKERHUB_REPO,myuser)
	docker buildx build \
		--platform linux/amd64,linux/arm64,linux/arm/v7 \
		--tag ${DOCKERHUB_REPO}/docker-xray-vless:latest \
		--tag ${DOCKERHUB_REPO}/docker-xray-vless:${XRAY_VERSION} \
		--build-arg XRAY_VERSION=${XRAY_VERSION} \
		--push \
		.