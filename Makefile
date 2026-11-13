.PHONY: dist clean test test-static

POWERSHELL ?= pwsh

dist: dist/setup.ps1

dist/setup.ps1: setup.ps1 scripts/build-dist.sh
	./scripts/build-dist.sh setup.ps1 dist/setup.ps1

test:
	$(POWERSHELL) -NoProfile -File tests/Invoke-Tests.ps1

test-static:
	python3 -m unittest discover -s tests -p 'test_*.py' -v

clean:
	rm -rf dist
