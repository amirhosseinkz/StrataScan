PROJECT := StrataScan.xcodeproj
SCHEME := StrataScan
DESTINATION ?= $(shell python3 tools/simulator-destination)
DERIVED_DATA ?= $(CURDIR)/DerivedData

.DEFAULT_GOAL := help

.PHONY: help bootstrap project build test test-core test-ios lint audit snapshots clean mock-server

help:
	@printf '%s\n' 'Targets: bootstrap project build test-core test-ios test lint audit snapshots clean mock-server'

bootstrap:
	@command -v xcodegen >/dev/null || { printf '%s\n' 'Install XcodeGen: brew install xcodegen'; exit 1; }
	@xcodegen --version

project: bootstrap
	xcodegen generate --spec project.yml

build: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -destination '$(DESTINATION)' -derivedDataPath '$(DERIVED_DATA)' build

test-core:
	swift test --package-path Packages/StrataCore

test-ios: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -destination '$(DESTINATION)' -derivedDataPath '$(DERIVED_DATA)' -enableCodeCoverage YES -parallel-testing-enabled NO test

test: test-core test-ios

lint:
	python3 tools/audit --lint-only

audit:
	python3 tools/audit --portfolio --run-core-tests --run-build --run-ios-tests

snapshots: project
	python3 tools/capture-screenshots --destination '$(DESTINATION)'

mock-server:
	node mock-server/src/server.js

clean:
	rm -rf DerivedData .ci Packages/StrataCore/.build
