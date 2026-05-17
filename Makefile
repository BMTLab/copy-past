# ╔══════════════════════════════════════════════════════════════════════╗
# ║                       copy & past : Makefile                         ║
# ║                                                                      ║
# ║   Tasks for development, testing, and installation.                  ║
# ║   Run `make` (or `make help`) to list every available target.        ║
# ║                                                                      ║
# ║   Requires GNU make. On *BSD, install `gmake` and use it instead.    ║
# ║   On macOS the system `make` is GNU make 3.81+, no action needed.    ║
# ╚══════════════════════════════════════════════════════════════════════╝

# ─── Project metadata ────────────────────────────────────────────────────
PROJECT_NAME    := copy-past
PROJECT_VERSION := 1.2.0 # x-release-please-version
SCRIPTS         := copy.sh past.sh


# ─── Install configuration ───────────────────────────────────────────────
# PREFIX defaults to a per-user XDG-friendly location to avoid sudo.
# Override for a system-wide install: make install PREFIX=/usr/local
PREFIX  ?= $(HOME)/.local
BIN_DIR := $(PREFIX)/bin

# 'symlink' keeps live edits picked up by the installed names;
# 'copy' is hermetic, which is preferable for read-only systems
# or when packaging the project for a distro.
INSTALL_MODE ?= symlink


# ─── Tooling (overridable from the environment or CLI) ───────────────────
SHELL       := bash
BATS        ?= bats
SHELLCHECK  ?= shellcheck
SHFMT       ?= shfmt
INSTALL_BIN ?= install

SHFMT_FLAGS      := -i 2 -ci -bn
SHELLCHECK_FLAGS := -S warning -e SC2155


# ─── Platform detection ──────────────────────────────────────────────────
UNAME_S := $(shell uname -s 2>/dev/null || echo Unknown)
ifeq ($(UNAME_S),Linux)
  PLATFORM := linux
else ifeq ($(UNAME_S),Darwin)
  PLATFORM := macos
else ifneq (,$(filter %BSD,$(UNAME_S)))
  PLATFORM := bsd
else ifneq (,$(filter MINGW% MSYS% CYGWIN%,$(UNAME_S)))
  PLATFORM := windows
else
  PLATFORM := unknown
endif

# Use sudo only when writing into protected system directories.
# Empty SUDO expands to nothing in recipes,
# so user-local installs never prompt for a password.
#
# We compute this with $(filter) on directory prefixes
# rather than $(shell case … esac),
# because $(shell) uses /bin/sh and tends to choke
# on the quoting required for a multi-line case statement.
NEEDS_SUDO := $(or \
  $(filter /usr/% /opt/% /sbin/% /bin/%,$(BIN_DIR)),\
  $(filter /usr/local%,$(BIN_DIR)))
SUDO := $(if $(NEEDS_SUDO),sudo,)


# ─── Colours (auto-disabled when NO_COLOR is set) ────────────────────────
ifeq ($(strip $(NO_COLOR)),)
  C_RESET  := \033[0m
  C_BOLD   := \033[1m
  C_DIM    := \033[2m
  C_RED    := \033[31m
  C_GREEN  := \033[32m
  C_YELLOW := \033[33m
  C_CYAN   := \033[36m
endif


# ─── Reusable log helpers (callable via $(call …)) ───────────────────────
define log_step
	@printf '  $(C_CYAN)→$(C_RESET) %s\n' $(1)
endef

define log_ok
	@printf '  $(C_GREEN)✓$(C_RESET) %s\n' $(1)
endef

define log_warn
	@printf '  $(C_YELLOW)!$(C_RESET) %s\n' $(1)
endef

define log_err
	@printf '  $(C_RED)✗$(C_RESET) %s\n' $(1) >&2
endef


# ─── Phony declarations & defaults ───────────────────────────────────────
.DEFAULT_GOAL := help
MAKEFLAGS     += --no-print-directory

.PHONY: help info version check-deps \
        lint format format-check check all \
        test test-verbose test-watch \
        install uninstall reinstall \
        clean demo


# ════════════════════════════════════════════════════════════════════════
# Help & info
# ════════════════════════════════════════════════════════════════════════

help:  ## Show this help (default target)
	@printf '\n  $(C_BOLD)$(PROJECT_NAME)$(C_RESET) $(C_DIM)v$(PROJECT_VERSION)$(C_RESET)\n'
	@printf '  $(C_DIM)Tiny clipboard helpers for Wayland & X11 terminals.$(C_RESET)\n\n'
	@printf '  $(C_BOLD)Usage:$(C_RESET) make $(C_CYAN)<target>$(C_RESET) [VAR=value ...]\n\n'
	@printf '  $(C_BOLD)Targets:$(C_RESET)\n'
	@awk 'BEGIN { FS = ":.*?## " } \
	      /^[a-zA-Z][a-zA-Z0-9_-]*:.*?## / { \
	        printf "    $(C_CYAN)%-16s$(C_RESET) %s\n", $$1, $$2 \
	      }' $(MAKEFILE_LIST) \
	  | sed -e 's|$$(BIN_DIR)|$(BIN_DIR)|g' \
	        -e 's|$$(INSTALL_MODE)|$(INSTALL_MODE)|g'
	@printf '\n  $(C_BOLD)Variables:$(C_RESET)\n'
	@printf '    PREFIX           Install prefix (current: $(C_DIM)%s$(C_RESET))\n' '$(PREFIX)'
	@printf '    INSTALL_MODE     symlink|copy (current: $(C_DIM)%s$(C_RESET))\n' '$(INSTALL_MODE)'
	@printf '    NO_COLOR         Set to disable coloured output\n\n'

info:  ## Show resolved build configuration
	@printf '\n  $(C_BOLD)Configuration$(C_RESET)\n\n'
	@printf '    Project          %s v%s\n' '$(PROJECT_NAME)' '$(PROJECT_VERSION)'
	@printf '    Platform         %s ($(UNAME_S))\n' '$(PLATFORM)'
	@printf '    Shell            %s\n' '$(SHELL)'
	@printf '    Prefix           %s\n' '$(PREFIX)'
	@printf '    Bin dir          %s\n' '$(BIN_DIR)'
	@printf '    Install mode     %s\n' '$(INSTALL_MODE)'
	@printf '    sudo required    %s\n' '$(if $(SUDO),yes,no)'
	@printf '    Scripts          %s\n\n' '$(SCRIPTS)'

version:  ## Print the project version (machine-readable)
	@printf '%s\n' '$(PROJECT_VERSION)'


# ════════════════════════════════════════════════════════════════════════
# Dependencies
# ════════════════════════════════════════════════════════════════════════

# Required at runtime by the scripts themselves.
RUNTIME_TOOLS      := bash sed
# At least one of these is required for the scripts to function.
CLIPBOARD_BACKENDS := wl-copy xclip xsel
# Required only by `make check` / `make test`.
DEV_TOOLS          := bats shellcheck shfmt xxd

check-deps:  ## Check runtime + dev tooling availability
	@printf '\n  $(C_BOLD)Runtime$(C_RESET)\n'
	@missing_runtime=0; \
	for t in $(RUNTIME_TOOLS); do \
		if command -v "$$t" > /dev/null 2>&1; then \
			printf '    $(C_GREEN)✓$(C_RESET) %s\n' "$$t"; \
		else \
			printf '    $(C_RED)✗$(C_RESET) %s (required)\n' "$$t"; \
			missing_runtime=$$((missing_runtime + 1)); \
		fi; \
	done; \
	printf '\n  $(C_BOLD)Clipboard backends$(C_RESET) $(C_DIM)(at least one required)$(C_RESET)\n'; \
	found_backend=0; \
	for t in $(CLIPBOARD_BACKENDS); do \
		if command -v "$$t" > /dev/null 2>&1; then \
			printf '    $(C_GREEN)✓$(C_RESET) %s\n' "$$t"; \
			found_backend=$$((found_backend + 1)); \
		else \
			printf '    $(C_DIM)·$(C_RESET) %s\n' "$$t"; \
		fi; \
	done; \
	if [ $$found_backend -eq 0 ]; then \
		printf '    $(C_YELLOW)!$(C_RESET) no clipboard backend installed\n'; \
	fi; \
	printf '\n  $(C_BOLD)Dev tooling$(C_RESET)\n'; \
	missing_dev=0; \
	for t in $(DEV_TOOLS); do \
		if command -v "$$t" > /dev/null 2>&1; then \
			printf '    $(C_GREEN)✓$(C_RESET) %s\n' "$$t"; \
		else \
			printf '    $(C_YELLOW)!$(C_RESET) %s (needed for `make check`)\n' "$$t"; \
			missing_dev=$$((missing_dev + 1)); \
		fi; \
	done; \
	printf '\n'; \
	if [ $$missing_runtime -gt 0 ]; then \
		printf '  $(C_RED)✗ missing required runtime tools$(C_RESET)\n\n' >&2; \
		exit 1; \
	fi; \
	if [ $$missing_dev -gt 0 ] || [ $$found_backend -eq 0 ]; then \
		printf '  $(C_YELLOW)! optional dependencies missing$(C_RESET)\n\n'; \
	else \
		printf '  $(C_GREEN)✓ all dependencies satisfied$(C_RESET)\n\n'; \
	fi


# ════════════════════════════════════════════════════════════════════════
# Quality
# ════════════════════════════════════════════════════════════════════════

lint:  ## Run shellcheck on copy.sh / past.sh
	$(call log_step,'shellcheck')
	@$(SHELLCHECK) $(SHELLCHECK_FLAGS) $(SCRIPTS)
	$(call log_ok,'shellcheck clean')

format:  ## Apply shfmt formatting in-place
	$(call log_step,'shfmt -w')
	@$(SHFMT) $(SHFMT_FLAGS) -w $(SCRIPTS)
	$(call log_ok,'formatted')

format-check:  ## Verify shfmt formatting without writing
	$(call log_step,'shfmt -d')
	@if ! $(SHFMT) $(SHFMT_FLAGS) -d $(SCRIPTS); then \
		printf '  $(C_RED)✗$(C_RESET) shfmt diff detected (run `make format`)\n' >&2; \
		exit 1; \
	fi
	$(call log_ok,'shfmt clean')


# ════════════════════════════════════════════════════════════════════════
# Tests
# ════════════════════════════════════════════════════════════════════════

test:  ## Run the full bats suite
	$(call log_step,'bats')
	@$(BATS) tests/bats/

test-verbose:  ## Run bats with verbose / on-failure-print output
	@$(BATS) --verbose-run --print-output-on-failure tests/bats/

test-watch:  ## Re-run bats on every change (needs `entr` or `fswatch`)
	@if command -v entr > /dev/null 2>&1; then \
		printf '  $(C_CYAN)→$(C_RESET) watching with entr (Ctrl-C to stop)\n'; \
		find $(SCRIPTS) tests -type f | entr -c $(BATS) tests/bats/; \
	elif command -v fswatch > /dev/null 2>&1; then \
		printf '  $(C_CYAN)→$(C_RESET) watching with fswatch (Ctrl-C to stop)\n'; \
		fswatch -o $(SCRIPTS) tests | xargs -n1 -I{} $(BATS) tests/bats/; \
	else \
		printf '  $(C_RED)✗$(C_RESET) need `entr` or `fswatch` for watch mode\n' >&2; \
		exit 1; \
	fi


# ════════════════════════════════════════════════════════════════════════
# CI gate
# ════════════════════════════════════════════════════════════════════════

check: lint format-check test  ## Lint + formatting + tests (CI gate)
	@printf '\n  $(C_GREEN)✓ all checks passed$(C_RESET)\n\n'

all: check  ## Alias for `make check`


# ════════════════════════════════════════════════════════════════════════
# Install / uninstall
# ════════════════════════════════════════════════════════════════════════

install:  ## Install copy/past into $(BIN_DIR) ($(INSTALL_MODE) mode)
	@printf '\n  $(C_BOLD)Installing $(PROJECT_NAME) into$(C_RESET) %s\n' '$(BIN_DIR)'
	@if [ '$(PLATFORM)' = 'windows' ]; then \
		printf '  $(C_YELLOW)!$(C_RESET) clipboard backends are unusual on Windows; consider WSL\n'; \
	fi
	@if [ ! -d '$(BIN_DIR)' ]; then \
		printf '  $(C_CYAN)→$(C_RESET) creating %s\n' '$(BIN_DIR)'; \
		$(SUDO) mkdir -p '$(BIN_DIR)'; \
	fi
	@chmod +x $(SCRIPTS)
	@case '$(INSTALL_MODE)' in \
		symlink) \
			printf '  $(C_CYAN)→$(C_RESET) symlinking copy.sh → %s/copy\n' '$(BIN_DIR)'; \
			$(SUDO) ln -sf '$(CURDIR)/copy.sh' '$(BIN_DIR)/copy'; \
			printf '  $(C_CYAN)→$(C_RESET) symlinking past.sh → %s/past\n' '$(BIN_DIR)'; \
			$(SUDO) ln -sf '$(CURDIR)/past.sh' '$(BIN_DIR)/past'; \
			;; \
		copy) \
			printf '  $(C_CYAN)→$(C_RESET) copying copy.sh → %s/copy\n' '$(BIN_DIR)'; \
			$(SUDO) $(INSTALL_BIN) -m 0755 copy.sh '$(BIN_DIR)/copy'; \
			printf '  $(C_CYAN)→$(C_RESET) copying past.sh → %s/past\n' '$(BIN_DIR)'; \
			$(SUDO) $(INSTALL_BIN) -m 0755 past.sh '$(BIN_DIR)/past'; \
			;; \
		*) \
			printf '  $(C_RED)✗$(C_RESET) unknown INSTALL_MODE=%s (use symlink|copy)\n' '$(INSTALL_MODE)' >&2; \
			exit 2; \
			;; \
	esac
	@printf '\n  $(C_GREEN)✓ installed copy and past into$(C_RESET) %s\n' '$(BIN_DIR)'
	@case ":$$PATH:" in \
		*":$(BIN_DIR):"*) ;; \
		*) printf '  $(C_YELLOW)!$(C_RESET) %s is not on $$PATH; add it to your shell rc\n' '$(BIN_DIR)' ;; \
	esac
	@printf '\n'

uninstall:  ## Remove copy/past from $(BIN_DIR)
	@printf '\n  $(C_BOLD)Uninstalling $(PROJECT_NAME) from$(C_RESET) %s\n' '$(BIN_DIR)'
	@for f in copy past; do \
		target='$(BIN_DIR)'/"$$f"; \
		if [ -e "$$target" ] || [ -L "$$target" ]; then \
			printf '  $(C_CYAN)→$(C_RESET) removing %s\n' "$$target"; \
			$(SUDO) rm -f "$$target"; \
		else \
			printf '  $(C_DIM)·$(C_RESET) %s (not present)\n' "$$target"; \
		fi; \
	done
	@printf '\n  $(C_GREEN)✓ uninstalled$(C_RESET)\n\n'

reinstall: uninstall install  ## Uninstall then install


# ════════════════════════════════════════════════════════════════════════
# Misc
# ════════════════════════════════════════════════════════════════════════

clean:  ## Remove transient artifacts
	$(call log_step,'cleaning')
	@rm -rf .bats-tmp tests/.tmp
	$(call log_ok,'clean')

demo:  ## Round-trip demo (writes & reads via the local scripts)
	@printf '\n  $(C_BOLD)Demo$(C_RESET) $(C_DIM)(uses your real clipboard)$(C_RESET)\n\n'
	@printf '    $(C_DIM)$$ printf %%s "hello copy-past" | bash copy.sh$(C_RESET)\n'
	@printf '%s' 'hello copy-past' | bash copy.sh
	@printf '    $(C_DIM)$$ bash past.sh$(C_RESET)\n'
	@printf '    '; bash past.sh; printf '\n\n'

### End of file
