.PHONY: build run serve ask models test clean

CACHE_DIR := $(shell pwd)/.cache

build:
	@mkdir -p $(CACHE_DIR)
	CLANG_MODULE_CACHE_PATH=$(CACHE_DIR) SWIFT_MODULE_CACHE_PATH=$(CACHE_DIR) \
	swift build --disable-sandbox -Xswiftc -module-cache-path -Xswiftc $(CACHE_DIR)

run serve: build
	./bin/siri-harness serve --port 8080

ask: build
	./bin/siri-harness ask "What is Apple Intelligence in one sentence?"

models: build
	./bin/siri-harness models

test:
	@mkdir -p $(CACHE_DIR)
	CLANG_MODULE_CACHE_PATH=$(CACHE_DIR) SWIFT_MODULE_CACHE_PATH=$(CACHE_DIR) \
	swift test --disable-sandbox -Xswiftc -module-cache-path -Xswiftc $(CACHE_DIR)

clean:
	rm -rf .build $(CACHE_DIR)
