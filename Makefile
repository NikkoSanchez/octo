.PHONY: setup test build smoke app run release install
setup:
	corepack pnpm install
test:
	corepack pnpm test
build:
	corepack pnpm build
smoke:
	corepack pnpm smoke
# Octo Dev (build/Octo Dev.app): the development copy, with its own chats.
app:
	mkdir -p build && node apps/desktop/scripts/package.mjs dev "$(CURDIR)/build/Octo Dev.app"
run:
	./scripts/run-dev.sh
# Octo (build/Octo.app); install puts it in ~/Applications as the app you use.
release:
	mkdir -p build && node apps/desktop/scripts/package.mjs release "$(CURDIR)/build/Octo.app"
install:
	./scripts/install-app.sh
