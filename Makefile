.PHONY: dist clean

dist: dist/setup.ps1

dist/setup.ps1: setup.ps1 scripts/build-dist.sh
	./scripts/build-dist.sh setup.ps1 dist/setup.ps1

clean:
	rm -rf dist
