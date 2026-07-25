.PHONY: build dmg install publish-local update-local run list

build:
	./scripts/build-app.sh

dmg:
	./scripts/build-dmg.sh

install publish-local update-local:
	./scripts/install-local.sh

run:
	swift run portman

list:
	swift run portman --list
