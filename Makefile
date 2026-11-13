.PHONY: dist clean test

POWERSHELL ?= pwsh

dist: dist/setup.ps1

dist/setup.ps1: setup.ps1 scripts/build-dist.sh
	./scripts/build-dist.sh setup.ps1 dist/setup.ps1

test:
	$(POWERSHELL) -NoProfile -File tests/Test-ScopeRepairs.ps1

clean:
	rm -rf dist
