MAKEFLAGS += --warn-undefined-variables
SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := all
.DELETE_ON_ERROR:
.SUFFIXES:

.PHONY: audit
audit: tidy format
	go vet ./...
	go tool -modfile=go.tool.mod staticcheck ./...
	go tool -modfile=go.tool.mod govulncheck ./...

.PHONY: clean
clean:
ifneq (,$(wildcard ./dist))
	rm -rf dist/
endif

.PHONY: build
build:
	goreleaser build --clean --single-target --snapshot

.PHONY: format
format:
	go tool -modfile=go.tool.mod gofumpt -l -w -extra .

.PHONY: lint
lint:
	golangci-lint run -v

.PHONY: tidy
tidy:
	go mod tidy

.PHONY: test
test: tidy
	go test ./... -cover
