BINARY = webview-cli
SRC = main.swift
FRAMEWORKS = -framework WebKit -framework AppKit
SWIFTFLAGS = -O -target arm64-apple-macos12.0

.PHONY: build clean install

build: $(BINARY)

$(BINARY): $(SRC)
	swiftc $(SWIFTFLAGS) $(FRAMEWORKS) $(SRC) -o $(BINARY)

clean:
	rm -f $(BINARY)

install: $(BINARY)
	mkdir -p $(HOME)/bin
	cp $(BINARY) $(HOME)/bin/$(BINARY)
