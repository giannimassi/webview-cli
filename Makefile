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
	@python3 scripts/check-js-syntax.py || (echo "FAIL: embedded JS has syntax errors (see above)" && exit 1)
	@node scripts/runtime-smoke.mjs || (echo "FAIL: runtime smoke (see above) — embedded JS functionally broken" && exit 1)
	@node scripts/editor-runtime-smoke.mjs || (echo "FAIL: editor runtime smoke (see above) — editor JS functionally broken" && exit 1)
	@./$(BINARY) --help 2>&1 >/dev/null | head -1 | grep -q Usage && echo "PASS: --help prints usage to stderr" || (echo "FAIL: --help" && exit 1)
	@echo '{}' | ./$(BINARY) --a2ui --timeout 1 2>/dev/null | grep -q status && echo "PASS: a2ui smoke" || (echo "FAIL: a2ui smoke" && exit 1)
	@./$(BINARY) --url "not-a-valid-url" 2>/dev/null | grep -q '"error"' && echo "PASS: invalid URL emits error JSON" || (echo "FAIL: invalid URL" && exit 1)
	@./$(BINARY) --markdown --timeout 1 2>&1 | grep -q '"error"' && ! ./$(BINARY) --markdown --timeout 1 2>&1 | grep -qi "unknown" && echo "PASS: --markdown alone fails at runtime (URL required), not at parse" || (echo "FAIL: --markdown alone" && exit 1)
	@./$(BINARY) --markdown --comments --edits --timeout 1 2>&1 | grep -q '"error"' && ! ./$(BINARY) --markdown --comments --edits --timeout 1 2>&1 | grep -qi "unknown" && echo "PASS: --markdown --comments --edits fail at runtime (URL required), not at parse" || (echo "FAIL: --markdown --comments --edits" && exit 1)
	@./$(BINARY) --markdown --a2ui 2>&1 | grep -q "mutually exclusive" && echo "PASS: --markdown --a2ui rejects with error" || (echo "FAIL: --markdown --a2ui mutual exclusion" && exit 1)
	@strings $(BINARY) | grep -q micromark && echo "PASS: micromark embedded in binary" || (echo "FAIL: micromark not found" && exit 1)
	@strings $(BINARY) | grep -q renderMarkdown && echo "PASS: renderMarkdown function embedded in binary" || (echo "FAIL: renderMarkdown not found" && exit 1)
	@echo '{"surfaceUpdate":{"components":[{"id":"root","component":{"Column":{"children":{"explicitList":["doc","btn"]}}}},{"id":"doc","component":{"MarkdownDoc":{"fieldName":"review","text":"# Hi\n\nHello."}}},{"id":"btn","component":{"Button":{"label":{"literalString":"OK"},"action":{"name":"ok"}}}}]}}{"beginRendering":{"root":"root"}}' | ./$(BINARY) --a2ui --timeout 1 2>&1 | grep -qv '"error"' && echo "PASS: MarkdownDoc renders without error" || (echo "FAIL: MarkdownDoc errored" && exit 1)
	@echo '# Hi' | ./$(BINARY) --markdown --timeout 1 2>/dev/null | grep -qv '"error"' && echo "PASS: --markdown stdin test with heading renders" || (echo "FAIL: --markdown stdin rendering" && exit 1)
	@printf '' | ./$(BINARY) --markdown --timeout 1 2>/dev/null | grep -q 'no markdown provided on stdin' && echo "PASS: empty markdown stdin yields error message" || (echo "FAIL: empty markdown stdin" && exit 1)
	@./$(BINARY) --editor 2>&1 | grep -q "requires a path" && echo "PASS: --editor with no path rejects" || (echo "FAIL: --editor no path" && exit 1)
	@./$(BINARY) --editor /tmp --a2ui 2>&1 | grep -q "mutually exclusive" && echo "PASS: --editor --a2ui rejects" || (echo "FAIL: --editor --a2ui mutual exclusion" && exit 1)
	@./$(BINARY) --editor /tmp --markdown 2>&1 | grep -q "mutually exclusive" && echo "PASS: --editor --markdown rejects" || (echo "FAIL: --editor --markdown mutual exclusion" && exit 1)
	@strings $(BINARY) | grep -q "__editorBoot" && echo "PASS: editor JS embedded in binary" || (echo "FAIL: editor JS not embedded" && exit 1)
	@bash scripts/editor-smoke.sh ./$(BINARY) || (echo "FAIL: editor smoke (see above)" && exit 1)
	@echo "All smoke tests pass"
