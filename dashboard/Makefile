# Verify against the system /usr/bin/python3 the hosts run, not a newer one.
PY ?= /usr/bin/python3
DEMO ?= $(CURDIR)/.demo

.PHONY: verify e2e demo
verify:            ## the gate: every test on the system Python, e2e included
	$(PY) -m unittest discover -s tests -t .

e2e:               ## the CLI, server and browser tests alone
	$(PY) -m unittest discover -s tests/e2e -t .

demo:              ## build a synthetic fleet in .demo/ and serve it on loopback
	rm -rf $(DEMO) && $(PY) tools/demo.py $(DEMO) >/dev/null
	$(PY) -m fleetdash -c $(DEMO)/config.json ingest >/dev/null
	$(PY) -m fleetdash -c $(DEMO)/config.json serve
