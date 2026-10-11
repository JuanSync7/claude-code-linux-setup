# ============================================================================
#  Makefile — deployment interface for the Claude Code control plane
# ============================================================================
#
#  Start with:   make help
#
#  The walkthrough these targets implement, with every underlying command
#  spelled out and explained, is docs/QUICKSTART.md. The Makefile is the
#  convenience wrapper; the document is the specification.
#
#  PATHS come from the same place every cc-* script gets them: config.sh,
#  read through lib/cc-config.sh. CONFIG names the file (default ./config.sh;
#  `make config` creates it from the template). quickstart refuses a config
#  that is missing or does not set every key, installs it beside the policy so
#  the installed hooks and scripts read the same values, and refuses when a
#  static file - the policy, a unit, logrotate, sudoers - disagrees with it
#  (lib/cc-coupling.py). To move a path, change config.sh and the static files
#  together; a SBIN=/SHARE=/LOGDIR= on the command line that differs from
#  config.sh is refused, because it would be a second source of truth. ETC is
#  not a choice at all: /etc/claude-code is compiled into the claude binary.
#
#  DESTDIR stages the whole tree under a prefix without touching the live
#  host — for AMI image builds and, later, the RPM %install step:
#
#      make quickstart DESTDIR=/tmp/image-root
#
#  Root and bind-mount guards are skipped when DESTDIR is set, and file
#  ownership is the builder's — an image build runs as root anyway, and an
#  RPM sets ownership from %files %attr, not from the staging tree.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.ONESHELL:
.DEFAULT_GOAL := help

# --- paths, resolved through lib/cc-config.sh unless overridden --------------
MKROOT := $(dir $(lastword $(MAKEFILE_LIST)))
CONFIG ?= $(MKROOT)config.sh
cc_var = $(shell CC_CONFIG="$(CONFIG)" bash -c '. "$(MKROOT)lib/cc-config.sh" >/dev/null 2>&1 || true; printf "%s" "$$$(1)"')

# ETC is deliberately NOT overridable: /etc/claude-code is compiled into the
# claude binary, and a policy installed anywhere else is a policy no claude
# will ever read. quickstart/verify refuse loudly if you try.
override ETC := /etc/claude-code
SBIN    ?= $(call cc_var,CC_SBIN)
SHARE   ?= $(call cc_var,CC_SHARE)
LOGDIR  ?= $(call cc_var,CC_LOGDIR)
DESTDIR ?=
VERSION ?=

POLICY := settings/managed-settings.json
HOOKS  := hooks/cc-audit-hook.sh hooks/cc-secret-guard-hook.sh hooks/cc-denied-hook.sh hooks/cc-upgrade-guard-hook.sh hooks/cc-redact-hook.sh

.PHONY: help config check quickstart pin verify install install-ide test bump-audit dist

help: ## List targets
	@echo ""
	echo "Claude Code control plane — deployment targets"
	echo ""
	awk 'BEGIN{FS=":.*## "} /^[a-zA-Z_-]+:.*## /{printf "  make %-14s %s\n",$$1,$$2}' Makefile
	echo ""
	echo "Paths, from $(CONFIG) (move them there; CONFIG=<file> names another):"
	echo "  ETC=$(ETC)  (fixed by the product — informational only)"
	echo "  SBIN=$(SBIN)  SHARE=$(SHARE)  LOGDIR=$(LOGDIR)"
	echo ""
	echo "The specification behind these targets: docs/QUICKSTART.md"
	echo ""

config: ## Create config.sh from the template if it does not exist
	@if [ -f config.sh ]; then
	  echo "config.sh already exists — not touching it."
	else
	  cp config.example.sh config.sh
	  chmod 660 config.sh 2>/dev/null || true
	  echo "Created config.sh from config.example.sh — edit it for this site:"
	  echo "    $${EDITOR:-vi} config.sh"
	fi

quickstart: ## Governance only: config + policy + hooks + statusline + guide + log dirs (root)
	@# Guards first. Each one exists because getting it wrong is silent.
	# The config every installed hook and script will read. The loader refuses
	# one that does not set every key; say how to fix it rather than guess.
	if ! cfgerr=$$(CC_CONFIG="$(CONFIG)" bash -c '. "$(MKROOT)lib/cc-config.sh"' 2>&1); then
	  echo "ERROR   $(CONFIG) cannot be used as this site's config:" >&2
	  printf '        %s\n' "$$cfgerr" >&2
	  echo "        Create it with: make config   (then edit it), or pass CONFIG=<file>." >&2
	  exit 1
	fi
	if [ -n "$(filter ETC=%,$(MAKEOVERRIDES))" ]; then
	  echo "ERROR   ETC cannot be overridden — /etc/claude-code is compiled into the" >&2
	  echo "        claude binary. A policy anywhere else is never read." >&2
	  exit 1
	fi
	for kv in SBIN="$(SBIN)" SHARE="$(SHARE)" LOGDIR="$(LOGDIR)"; do
	  v="$${kv#*=}"
	  case "$$v" in /?*) ;; *)
	    echo "ERROR   $${kv%%=*}='$$v' is empty or not an absolute path — run make from" >&2
	    echo "        the repo root, or check config.sh / the command-line override." >&2
	    exit 1 ;;
	  esac
	done
	if [ -z "$(DESTDIR)" ] && [ "$$(id -u)" -ne 0 ]; then
	  echo "ERROR   quickstart writes to $(ETC) and $(SBIN) — run it as root," >&2
	  echo "        or set DESTDIR=/some/stage to build an image tree instead." >&2
	  exit 1
	fi
	if [ -z "$(DESTDIR)" ] && awk -v t="$(ETC)/managed-settings.json" '$$5==t{f=1} END{exit !f}' /proc/self/mountinfo 2>/dev/null; then
	  echo "BLOCKED $(ETC)/managed-settings.json is a bind mount in this shell's namespace" >&2
	  echo "        (an admin session is active here). Installing now would write the fleet" >&2
	  echo "        policy THROUGH the mount, over the admin policy. Use a plain root shell." >&2
	  exit 1
	fi
	if [ -z "$(DESTDIR)" ] && [ ! -x /usr/bin/python3 ]; then
	  echo "ERROR   /usr/bin/python3 is missing and the hooks depend on it." >&2
	  echo "        Fix:  dnf -y install python36" >&2
	  exit 1
	fi
	# This host may skip the python guard under DESTDIR, but the cross-check
	# below still needs an interpreter on the BUILD host.
	if ! command -v python3 >/dev/null 2>&1; then
	  echo "ERROR   python3 is required on THIS host to cross-check the policy paths" >&2
	  echo "        (needed even with DESTDIR).  Fix:  dnf -y install python36" >&2
	  exit 1
	fi
	# A command-line path that differs from config.sh would install where the
	# installed scripts and hooks, which read config.sh, never look.
	for kv in SBIN="$(SBIN)=$(call cc_var,CC_SBIN)" SHARE="$(SHARE)=$(call cc_var,CC_SHARE)" \
	          LOGDIR="$(LOGDIR)=$(call cc_var,CC_LOGDIR)"; do
	  k="$${kv%%=*}"; v="$${kv#*=}"; got="$${v%%=*}"; want="$${v#*=}"
	  if [ "$$got" != "$$want" ]; then
	    echo "ERROR   $$k=$$got, but $(CONFIG) sets $$want. Change it in config.sh, not here." >&2
	    exit 1
	  fi
	done
	# The policy, units, logrotate and sudoers are read by programs that do not
	# source config.sh, so each spells its paths and contact literally: they
	# must name what config.sh sets, or they point at nothing.
	if ! cpl=$$(CC_CONFIG="$(CONFIG)" bash -c '. "$(MKROOT)lib/cc-config.sh" && export $${!CC_@} && python3 "$(MKROOT)lib/cc-coupling.py" "$(MKROOT)."' 2>&1); then
	  echo "ERROR   a static file disagrees with $(CONFIG):" >&2
	  printf '        %s\n' "$$cpl" >&2
	  echo "        Edit the file to match config.sh (it is not read from config.sh at run time)." >&2
	  exit 1
	fi
	# The installer's policy gates - valid JSON, no placeholders, autoMode keeps
	# $$defaults, hook paths, the version floor - run here too, so the short path
	# cannot ship a policy the full one would refuse. An image build has no
	# package on THIS host to compare the floor with, so there it only warns.
	if ! gates=$$(CC_CONFIG="$(CONFIG)" bash "$(MKROOT)bin/cc-install.sh" --gates-only $(if $(DESTDIR),--allow-below-floor) 2>&1); then
	  printf '%s\n' "$$gates" >&2
	  echo "ERROR   the installer's policy gates refused this tree (above). Nothing was placed." >&2
	  exit 1
	fi
# Place everything the policy names, then the policy itself, then the record.
	install -d -m 0755 "$(DESTDIR)$(ETC)" "$(DESTDIR)$(SBIN)" "$(DESTDIR)$(SHARE)"
	install -d -m 0755 "$(DESTDIR)$(LOGDIR)"
	install -d -m 1733 "$(DESTDIR)$(LOGDIR)/activity" "$(DESTDIR)$(LOGDIR)/denied"
	install -m 0644 lib/cc-config.sh "$(DESTDIR)$(ETC)/cc-config.sh"
	install -m 0644 "$(CONFIG)" "$(DESTDIR)$(ETC)/config.sh"
	install -m 0755 $(HOOKS) "$(DESTDIR)$(SBIN)/"
	install -m 0755 share/statusline.sh "$(DESTDIR)$(SHARE)/statusline.sh"
	install -m 0644 docs/ENGINEER-GUIDE.md "$(DESTDIR)$(SHARE)/ENGINEER-GUIDE.md"
	install -m 0644 "$(POLICY)" "$(DESTDIR)$(ETC)/managed-settings.json"
	( cd "$(DESTDIR)$(ETC)" && sha256sum managed-settings.json > managed-settings.json.sha256 )
	if [ -n "$(DESTDIR)" ]; then
	  echo ""
	  echo "Staged under $(DESTDIR) — nothing on THIS host changed. Bake or package from there."
	else
	  echo ""
	  echo "Done. This host is now policy-governed (docs/QUICKSTART.md §2 manifest)."
	  echo "Next:   make verify"
	  echo "        make pin VERSION=x.y.z    # if the CLI itself comes from dnf (Method A)"
	fi

pin: ## Method A: install the CC_PKG RPM at VERSION and versionlock it (root)
	@if [ -n "$(DESTDIR)" ]; then
	  echo "ERROR   pin drives dnf on the live host and does not honour DESTDIR." >&2
	  echo "        For images, run it inside the image build (kickstart %post or chroot)." >&2
	  exit 1
	fi
	if [ "$$(id -u)" -ne 0 ]; then
	  echo "ERROR   pin runs dnf — run it as root." >&2
	  exit 1
	fi
	if [ "$(origin VERSION)" != "command line" ] || [ -z "$(VERSION)" ]; then
	  echo "usage: make pin VERSION=x.y.z      # explicit, on the command line —" >&2
	  echo "       an inherited \$$VERSION from the environment is refused on purpose" >&2
	  exit 2
	fi
	pkg='$(call cc_var,CC_PKG)'; repo='$(call cc_var,CC_PKG_REPO_ID)'
	baseurl='$(call cc_var,CC_RPM_BASEURL)'; gpgkey='$(call cc_var,CC_RPM_GPGKEY)'
	if [ -z "$$pkg" ] || [ -z "$$repo" ] || [ -z "$$baseurl" ] || [ -z "$$gpgkey" ]; then
	  echo "ERROR   config.sh does not load, or sets no CC_PKG / CC_PKG_REPO_ID /" >&2
	  echo "        CC_RPM_BASEURL / CC_RPM_GPGKEY. Run: make config" >&2
	  exit 1
	fi
	if [ ! -f "/etc/yum.repos.d/$$repo.repo" ]; then
	  printf '[%s]\nname=Claude Code\nbaseurl=%s\nenabled=1\ngpgcheck=1\ngpgkey=%s\n' \
	    "$$repo" "$$baseurl" "$$gpgkey" > "/etc/yum.repos.d/$$repo.repo"
	  echo "wrote /etc/yum.repos.d/$$repo.repo"
	fi
	dnf -y install python3-dnf-plugin-versionlock python36
	# Delete BEFORE install: on a host already locked to another version, the
	# old lock excludes the new package from the transaction and the install
	# fails first. Same order as bin/cc-update.sh. (Brief unlocked window if
	# the install then fails — acceptable on a first build or a gated re-pin.)
	dnf versionlock delete "$$pkg" >/dev/null 2>&1 || true
	dnf -y install "$$pkg-$(VERSION)"
	# Lock by NAME: versionlock records the exact installed epoch:ver-rel, so a
	# vendor respin (-2 release) is covered without guessing the release here.
	dnf versionlock add "$$pkg"
	install -d -m 0755 $(ETC)
	echo "$(VERSION)" > $(ETC)/approved-version
	echo ""
	echo "$$pkg $(VERSION) installed and locked. Next:   make quickstart"

verify: ## Read-only checks that a host is governed as §2 requires
	@fail=0
	ok()  { printf '  ok      %s\n' "$$1"; }
	bad() { printf '  FAIL    %s\n' "$$1"; fail=1; }
	note(){ printf '  note    %s\n' "$$1"; }
	P="$(ETC)/managed-settings.json"
	BOUND=0
	if awk -v t="$$P" '$$5==t{f=1} END{exit !f}' /proc/self/mountinfo 2>/dev/null; then
	  BOUND=1
	  note "an admin bind mount is active in THIS shell — the file at $$P is the"
	  note "ADMIN policy here. Hash comparison skipped; verify from a plain shell."
	fi
	if [ -f "$$P" ]; then ok "policy present at $$P"; else bad "policy missing at $$P"; fi
	if [ -f "$$P" ]; then
	  po="$$(stat -c %U "$$P")"; pm="$$(stat -c %a "$$P")"
	  [ "$$po" = root ] && ok "policy owned by root" || bad "policy owned by $$po, not root — anyone who owns it owns the fleet rules"
	  if (( 8#$$pm & 8#022 )); then bad "policy writable by group/other ($$pm)"; else ok "policy not writable by others ($$pm)"; fi
	fi
	if [ "$$BOUND" -eq 0 ] && [ -f "$$P" ] && [ -r "$$P" ]; then
	  if [ "$$(sha256sum < "$$P")" = "$$(sha256sum < $(POLICY))" ]; then
	    ok "policy matches this checkout's $(POLICY)"
	  else
	    bad "policy DIFFERS from this checkout's $(POLICY) — drift, or an old release"
	  fi
	fi
	for h in $(notdir $(HOOKS)); do
	  f="$(SBIN)/$$h"
	  if [ ! -f "$$f" ]; then bad "hook missing: $$f"; continue; fi
	  [ -x "$$f" ] && ok "hook executable: $$f" || bad "hook NOT executable: $$f (calls proceed UNAUDITED with a warning)"
	  o="$$(stat -c %U "$$f")"
	  [ "$$o" = root ] && ok "hook owned by root: $$h" || bad "hook owned by $$o, not root: $$f"
	  m="$$(stat -c %a "$$f")"
	  if (( 8#$$m & 8#022 )); then bad "hook group/world-writable ($$m): $$f"; else ok "hook not writable by others: $$h"; fi
	done
	if [ -f "$(SHARE)/statusline.sh" ]; then
	  ok "statusline present"
	  so="$$(stat -c %U "$(SHARE)/statusline.sh")"; sm="$$(stat -c %a "$(SHARE)/statusline.sh")"
	  [ "$$so" = root ] && ok "statusline owned by root" || bad "statusline owned by $$so, not root"
	  if (( 8#$$sm & 8#022 )); then bad "statusline writable by group/other ($$sm)"; else ok "statusline not writable by others ($$sm)"; fi
	else
	  bad "statusline missing: $(SHARE)/statusline.sh (policy names it)"
	fi
	# Check the log dirs the INSTALLED hooks actually write to: they read the
	# installed config, so ask it — a divergence from LOGDIR must not verify green.
	ad="$$(bash -c '. "$(ETC)/cc-config.sh" >/dev/null 2>&1 && printf %s "$$CC_ACTIVITY_LOG_DIR"')"
	dn="$$(bash -c '. "$(ETC)/cc-config.sh" >/dev/null 2>&1 && printf %s "$$CC_DENIED_LOG_DIR"')"
	if [ -z "$$ad" ] || [ -z "$$dn" ]; then
	  bad "$(ETC)/cc-config.sh or its config.sh is missing or incomplete — the hooks log nothing"
	  ad="$(LOGDIR)/activity"; dn="$(LOGDIR)/denied"
	fi
	[ "$$ad" = "$(LOGDIR)/activity" ] || note "installed hooks write to $$ad, not $(LOGDIR)/activity — checking where they write"
	for dd in "$$ad" "$$dn"; do
	  if [ -d "$$dd" ]; then
	    m="$$(stat -c %a "$$dd")"
	    [ "$$m" = 1733 ] && ok "$$dd is 1733" || bad "$$dd is $$m, expected 1733"
	  else
	    bad "log dir missing: $$dd (hook writes fail SILENTLY — no evidence trail)"
	  fi
	done
	[ -x /usr/bin/python3 ] && ok "/usr/bin/python3 present (hooks depend on it)" || bad "/usr/bin/python3 missing:  dnf -y install python36"
	if command -v claude >/dev/null 2>&1; then
	  v="$$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
	  ok "claude on PATH: $${v:-unknown} ($$(command -v claude))"
	  if [ -f "$(ETC)/approved-version" ] && [ -n "$$v" ]; then
	    a="$$(cat "$(ETC)/approved-version")"
	    [ "$$v" = "$$a" ] && ok "version matches approved-version ($$a)" || note "version $$v != approved-version $$a (user-local install? see QUICKSTART §6)"
	  fi
	else
	  note "no claude on PATH — governance files can precede the CLI (make pin, or user-local install)"
	fi
	# Exit contract, for scripted callers: 0 verified, 1 failed, 2 ran inside
	# an admin session where the fleet policy is not the file visible here —
	# NOT verified, re-run from a plain shell.
	[ "$$fail" -eq 0 ] || exit 1
	[ "$$BOUND" -eq 0 ] || { note "exit 2: unverifiable from this shell (admin bind mount) — not a pass"; exit 2; }
	exit 0

check: ## Dry-run the FULL control-plane installer (delegates to cc-install.sh)
	@bash bin/cc-install.sh --check

install: ## FULL control plane: everything quickstart does + timers, logrotate, profile.d (root)
	@bash bin/cc-install.sh --apply

install-ide: ## Full control plane + VSCodium defaults (see docs/IDE-INTEGRATION.md)
	@bash bin/cc-install.sh --apply --with-ide

test: ## Run the self-test suite (some tests need root, others skip)
	@bash tests/test-cc-scripts.sh

bump-audit: ## Version-bump audit: pin coherence + every standing probe (docs/OPERATIONS.md Part 7)
	@bash bin/cc-bump-audit.sh

dist: ## Tarball of tracked files, for hosts without the share or repo access
	@V="$$(git describe --always --dirty 2>/dev/null || echo release)"
	git archive --format=tar.gz --prefix="claude-code-$$V/" -o "claude-code-$$V.tar.gz" HEAD -- . ':!internal'
	echo "wrote claude-code-$$V.tar.gz"
	echo "Excluded: config.sh (untracked, never ships) and internal/ (the site record —"
	echo "the deployment needs none of it; clone the repo if you want the history)."
