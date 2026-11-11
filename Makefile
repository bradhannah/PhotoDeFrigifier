SHELL := /bin/bash

CONFIGURATION ?= debug
SWIFT_BIN_PATH = $(shell swift build -c $(CONFIGURATION) --show-bin-path)
APP_BUILD_DIR := .build/apps
MAIN_APP := $(APP_BUILD_DIR)/PhotoDeFrigifier.app
SKILLS := $(notdir $(wildcard skills/*))
# Sign with an Apple Development identity if you have one, so macOS remembers the Photos permission between builds.
# Ad-hoc signing ("-") works, but macOS may ask for Photos access again after each rebuild.
SIGN_IDENTITY ?= -

.DEFAULT_GOAL := help

.PHONY: help doctor build build-release test format format-check plist-check check package validate-bundle run \
	install-skills uninstall-skills open-project clean

help: ## Show common project operations.
	@printf "PhotoDeFrigifier\n\n"
	@printf "  make run               Build, package and open the app\n"
	@printf "  make test              Run unit tests\n"
	@printf "  make check             Formatting, plist, tests and build\n"
	@printf "  make package           Assemble and sign .build/apps/PhotoDeFrigifier.app\n"
	@printf "  make install-skills    Link skills/* into ~/.claude/skills so every Claude session can use them\n"
	@printf "  make uninstall-skills  Remove those links\n"
	@printf "  make clean             Remove build output\n"

doctor: ## Verify the local development toolchain.
	@command -v xcodebuild >/dev/null || { printf "Missing xcodebuild\n"; exit 1; }
	@command -v swift >/dev/null || { printf "Missing swift\n"; exit 1; }
	@command -v codesign >/dev/null || { printf "Missing codesign\n"; exit 1; }
	@xcodebuild -version
	@swift --version

build: ## Build all products using CONFIGURATION (default: debug).
	swift build -c $(CONFIGURATION)

build-release: ## Build with release optimizations.
	swift build -c release

test: ## Run unit tests.
	swift test

format: ## Apply swift-format to source and test code.
	xcrun swift-format format --in-place --recursive Sources Tests Package.swift

format-check: ## Fail if Swift code is not formatted.
	xcrun swift-format lint --strict --recursive Sources Tests Package.swift

plist-check: ## Validate the app property list.
	plutil -lint Config/PhotoDeFrigifier-Info.plist

check: plist-check test build ## Run the standard local quality gate.

package: build plist-check ## Assemble and sign PhotoDeFrigifier.app.
	@if [ "$(SIGN_IDENTITY)" != "-" ] && ! security find-identity -v -p codesigning | grep -qF "$(SIGN_IDENTITY)"; then \
		printf "No signing certificate matching \"%s\" in your keychain.\n" "$(SIGN_IDENTITY)"; \
		printf "Create one in Xcode › Settings › Accounts › (your Apple ID) › Manage Certificates › + › Apple Development,\n"; \
		printf "or build without SIGN_IDENTITY (ad-hoc signing). The existing app was left as it was.\n"; \
		exit 1; \
	fi
	rm -rf "$(MAIN_APP)"
	mkdir -p "$(MAIN_APP)/Contents/MacOS" "$(MAIN_APP)/Contents/Resources"
	cp "$(SWIFT_BIN_PATH)/PhotoDeFrigifierApp" "$(MAIN_APP)/Contents/MacOS/PhotoDeFrigifierApp"
	cp "Config/PhotoDeFrigifier-Info.plist" "$(MAIN_APP)/Contents/Info.plist"
	codesign --force --sign "$(SIGN_IDENTITY)" "$(MAIN_APP)"

validate-bundle: package ## Verify the assembled app signature and property list.
	plutil -lint "$(MAIN_APP)/Contents/Info.plist"
	codesign --verify --deep --strict "$(MAIN_APP)"

run: package ## Assemble and launch the app.
	open "$(MAIN_APP)"

install-skills: ## Symlink each skill folder into ~/.claude/skills.
	@mkdir -p "$(HOME)/.claude/skills"
	@for s in $(SKILLS); do \
		dest="$(HOME)/.claude/skills/$$s"; \
		if [ -e "$$dest" ] && [ ! -L "$$dest" ]; then printf "skip %s (a real folder already exists there)\n" "$$s"; continue; fi; \
		ln -sfn "$(CURDIR)/skills/$$s" "$$dest" && printf "linked %s\n" "$$s"; \
	done

uninstall-skills: ## Remove the skill symlinks created by install-skills.
	@for s in $(SKILLS); do \
		dest="$(HOME)/.claude/skills/$$s"; \
		if [ -L "$$dest" ]; then rm "$$dest" && printf "unlinked %s\n" "$$s"; fi; \
	done

open-project: ## Open the Swift package in Xcode.
	xed .

clean: ## Remove build products.
	swift package clean
	rm -rf "$(APP_BUILD_DIR)"
