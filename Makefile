.PHONY: build install publish-local update-local run list

build:
	./scripts/build-app.sh

install publish-local update-local:
	./scripts/install-local.sh

run:
	swift run PortManager

list:
	swift run PortManager --list
