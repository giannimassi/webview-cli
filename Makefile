BINARY = webview-cli
SRC = src/main.swift
FRAMEWORKS = -framework WebKit -framework AppKit
SWIFTFLAGS = -O -target arm64-apple-macos12.0

.PHONY: build clean install test

build: $(BINARY)

$(BINARY): $(SRC)
	swiftc $(SWIFTFLAGS) $(FRAMEWORKS) $(SRC) -o $(BINARY)

clean:
	rm -f $(BINARY)

install: $(BINARY)
	mkdir -p $(HOME)/bin
	cp $(BINARY) $(HOME)/bin/$(BINARY)

test: $(BINARY)
	@./$(BINARY) --help 2>&1 >/dev/null | head -1 | grep -q Usage && echo "PASS: --help prints usage to stderr" || (echo "FAIL: --help" && exit 1)
	@echo '{}' | ./$(BINARY) --a2ui --timeout 1 2>/dev/null | grep -q status && echo "PASS: a2ui smoke" || (echo "FAIL: a2ui smoke" && exit 1)
	@./$(BINARY) --url "not-a-valid-url" 2>/dev/null | grep -q '"error"' && echo "PASS: invalid URL emits error JSON" || (echo "FAIL: invalid URL" && exit 1)
	@echo "All smoke tests pass"
