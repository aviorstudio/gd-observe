# Generated cookbook entrypoint. Change cookbook.toml and regenerate.
# Recipe data SHA256: 0116419c07eb520df1729fc000c8510bd2ade48ed36eeb3d047f83d163a1c81e
COOKBOOK_REF := 470cc6de09931b50dfe7a9f8f664d162e51fcb42
COOKBOOK_RECIPE := godot-addon
COOKBOOK_ROOT ?= .artifacts/cookbook/$(COOKBOOK_REF)
COOKBOOK_TEST_SUITES := lint unit security integration
COOKBOOK_EMPTY :=
COOKBOOK_SPACE := $(COOKBOOK_EMPTY) $(COOKBOOK_EMPTY)
cookbook_path = $(subst $(COOKBOOK_SPACE),\$(COOKBOOK_SPACE),$(1))
COOKBOOK_ENTRY := $(call cookbook_path,$(COOKBOOK_ROOT)/cookbook/recipes/$(COOKBOOK_RECIPE).mk)

ifeq ($(wildcard $(COOKBOOK_ENTRY)),)
.DEFAULT_GOAL := help
.PHONY: help setup
help:
	@printf '%s\n' 'make help' 'make setup' 'make fmt' 'make build' 'make test' 'make test:lint' 'make test:unit' 'make test:security' 'make test:integration' 'make clean'
	@printf '%s\n' 'Run make setup once to fetch the pinned cookbook and prepare dependencies.'
setup:
	@mkdir -p "$(COOKBOOK_ROOT)"
	@git -C "$(COOKBOOK_ROOT)" init -q
	@git -C "$(COOKBOOK_ROOT)" fetch --quiet --depth=1 https://github.com/nicodes/tools.git "$(COOKBOOK_REF)"
	@git -C "$(COOKBOOK_ROOT)" checkout --quiet --detach "$(COOKBOOK_REF)"
	@test "$$(git -C "$(COOKBOOK_ROOT)" rev-parse HEAD)" = "$(COOKBOOK_REF)"
	@$(MAKE) --no-print-directory setup
else
include $(COOKBOOK_ENTRY)
endif
