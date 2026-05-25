PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
TARGET ?= tms
CONFIG ?= .tmux-layout.yml

TMS := $(CURDIR)/bin/tms
LINK := $(BINDIR)/$(TARGET)
CONFIG_EXAMPLE := $(CURDIR)/.tmux-layout.example.yml

.PHONY: help install uninstall config test check

help:
	@printf '%s\n' \
		'Targets:' \
		'  make install   Link bin/tms into $(BINDIR)' \
		'  make uninstall Remove $(LINK)' \
		'  make config    Create $(CONFIG) from the example when missing' \
		'  make test      Run the Ruby test suite' \
		'  make check     Run tests and syntax checks'

install:
	@mkdir -p "$(BINDIR)"
	@ln -sfn "$(TMS)" "$(LINK)"
	@printf 'Linked %s -> %s\n' "$(LINK)" "$(TMS)"

uninstall:
	@rm -f "$(LINK)"
	@printf 'Removed %s\n' "$(LINK)"

config:
	@if [ -e "$(CONFIG)" ]; then \
		printf 'Keeping existing %s\n' "$(CONFIG)"; \
	else \
		cp "$(CONFIG_EXAMPLE)" "$(CONFIG)"; \
		printf 'Created %s from %s\n' "$(CONFIG)" "$(CONFIG_EXAMPLE)"; \
	fi

test:
	@ruby test/tms_test.rb

check: test
	@ruby -c lib/tms.rb
	@ruby -c bin/tms
