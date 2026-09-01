SHELL := /bin/bash

CONFIGURATION ?= debug
SWIFT_BIN_PATH = $(shell swift build -c $(CONFIGURATION) --show-bin-path)
APP_BUILD_DIR := .build/apps
MAIN_APP := $(APP_BUILD_DIR)/PhotoDeFrigifier.app
LAB_APP := $(APP_BUILD_DIR)/Provider Access Lab.app

.DEFAULT_GOAL := help

.PHONY: help doctor bootstrap resolve build build-main build-lab build-release test \
	format format-check plist-check check package package-main package-lab \
	validate-bundles run run-lab open-project clean

help: ## Show common project operations.
	@printf "PhotoDeFrigifier operations\n\n"
	@printf "  make doctor            Verify required Apple/Swift tools\n"
	@printf "  make bootstrap         Verify tools and resolve Swift packages\n"
	@printf "  make build             Build both executables (debug by default)\n"
	@printf "  make build-release     Build both executables in release mode\n"
	@printf "  make test              Run unit tests\n"
	@printf "  make format            Format Swift sources and Package.swift\n"
	@printf "  make format-check      Check Swift formatting without edits\n"
	@printf "  make check             Run formatting, plist, tests, and build checks\n"
	@printf "  make package           Assemble and sign both native app bundles\n"
	@printf "  make validate-bundles  Package and verify both app bundles\n"
	@printf "  make run               Package and launch PhotoDeFrigifier\n"
	@printf "  make run-lab           Package and launch Provider Access Lab\n"
	@printf "  make open-project      Open the Swift package in Xcode\n"
	@printf "  make clean             Remove Swift and assembled app build output\n"

doctor: ## Verify the local development toolchain.
	@command -v xcodebuild >/dev/null || { printf "Missing xcodebuild\n"; exit 1; }
	@command -v swift >/dev/null || { printf "Missing swift\n"; exit 1; }
	@command -v xcrun >/dev/null || { printf "Missing xcrun\n"; exit 1; }
	@command -v codesign >/dev/null || { printf "Missing codesign\n"; exit 1; }
	@command -v plutil >/dev/null || { printf "Missing plutil\n"; exit 1; }
	@xcodebuild -version
	@swift --version
	@xcrun swift-format --version

bootstrap: doctor resolve ## Prepare a fresh checkout.

resolve: ## Resolve Swift package dependencies.
	swift package resolve

build: ## Build all products using CONFIGURATION (default: debug).
	swift build -c $(CONFIGURATION)

build-main: ## Build only the production app executable.
	swift build -c $(CONFIGURATION) --product PhotoDeFrigifierApp

build-lab: ## Build only the Provider Access Lab executable.
	swift build -c $(CONFIGURATION) --product ProviderAccessLab

build-release: ## Build all products with release optimizations.
	swift build -c release

test: ## Run unit tests.
	swift test

format: ## Apply swift-format to source and test code.
	xcrun swift-format format --in-place --recursive Sources Tests Package.swift

format-check: ## Fail if Swift code is not formatted.
	xcrun swift-format lint --strict --recursive Sources Tests Package.swift

plist-check: ## Validate native app property lists.
	plutil -lint Config/PhotoDeFrigifier-Info.plist Config/ProviderAccessLab-Info.plist

check: format-check plist-check test build ## Run the standard local quality gate.

package: package-main package-lab ## Assemble both native app bundles.

package-main: build-main plist-check ## Assemble and ad-hoc sign PhotoDeFrigifier.app.
	rm -rf "$(MAIN_APP)"
	mkdir -p "$(MAIN_APP)/Contents/MacOS" "$(MAIN_APP)/Contents/Resources"
	cp "$(SWIFT_BIN_PATH)/PhotoDeFrigifierApp" "$(MAIN_APP)/Contents/MacOS/PhotoDeFrigifierApp"
	cp "Config/PhotoDeFrigifier-Info.plist" "$(MAIN_APP)/Contents/Info.plist"
	cp "docs/PLAN_DETAILS.md" "$(MAIN_APP)/Contents/Resources/PLAN_DETAILS.md"
	codesign --force --sign - "$(MAIN_APP)"

package-lab: build-lab plist-check ## Assemble and ad-hoc sign Provider Access Lab.app.
	rm -rf "$(LAB_APP)"
	mkdir -p "$(LAB_APP)/Contents/MacOS"
	cp "$(SWIFT_BIN_PATH)/ProviderAccessLab" "$(LAB_APP)/Contents/MacOS/ProviderAccessLab"
	cp "Config/ProviderAccessLab-Info.plist" "$(LAB_APP)/Contents/Info.plist"
	codesign --force --sign - "$(LAB_APP)"

validate-bundles: package ## Verify assembled app signatures and property lists.
	plutil -lint "$(MAIN_APP)/Contents/Info.plist" "$(LAB_APP)/Contents/Info.plist"
	codesign --verify --deep --strict "$(MAIN_APP)"
	codesign --verify --deep --strict "$(LAB_APP)"

run: package ## Assemble both apps and launch the production app.
	open "$(MAIN_APP)"

run-lab: package-lab ## Assemble and launch Provider Access Lab.
	open "$(LAB_APP)"

open-project: ## Open the Swift package in Xcode.
	xed .

clean: ## Remove build products.
	swift package clean
	rm -rf "$(APP_BUILD_DIR)"
