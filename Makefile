MAKEFLAGS += --warn-undefined-variables
SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := all
.DELETE_ON_ERROR:
.SUFFIXES:

.PHONY: audit
audit: tidy fmt
	go vet ./...
	go tool -modfile=go.tool.mod staticcheck ./...
	go tool -modfile=go.tool.mod govulncheck ./...
	golangci-lint run -v


.PHONY: build
build:

	goreleaser build --clean --single-target --snapshot

.PHONY: clean
clean:
ifneq (,$(wildcard ./dist))
	rm -rf dist/

endif

ifneq (,$(wildcard ./coverage))
	rm -rf coverage/

endif

.PHONY: container
container: tidy
	./scripts/build-container.sh

.PHONY: fmt
fmt:
	go tool -modfile=go.tool.mod golines --base-formatter=gofumpt -w .
	go tool -modfile=go.tool.mod gofumpt -l -w -extra .


.PHONY: gh-install
install: build

	cp dist/{{projectName}}_linux_amd64_v1/{{projectName}} .

	gh ext remove {{binaryName}}

	gh ext install .

	{{binaryName}} --version

.PHONY: lint
lint:
	golangci-lint run -v

.PHONY: modernize
modernize:
	go run golang.org/x/tools/gopls/internal/analysis/modernize/cmd/modernize@latest -fix -test ./...

.PHONY: test
test:
	go test -covermode=atomic -coverprofile=coverdata/coverage.out ./... && echo 'Coverage data collected'
	go tool cover -html=coverdata/coverage.out -o coverdata/coverage.html

.PHONY: test-container
test: container
	@mkdir -p coverdata
	@docker run --rm -v $(PWD)/coverdata:/app/coverdata esacteksab/{{imageName}}:$(shell cat .current-tag)
	@if [ -f "coverdata/coverage.out" ]; then \
		go tool cover -html=coverdata/coverage.out -o coverdata/coverage.html; \
		echo "Coverage report generated: coverage.html"; \
	else \
		echo "Error: Coverage file not found"; \
		exit 1; \
	fi

.PHONY: tidy
tidy:
	go mod tidy

.PHONY: update
update:
	go get -u ./...
	go get -u -modfile=go.tool.mod tool
	go mod tidy
