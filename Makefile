.PHONY: build test app run install release setup doctor privacy ghostty
ghostty:
	./Scripts/build-ghostty.sh
build: ghostty
	swift build
test: ghostty
	swift test
# Octo Dev (build/Octo Dev.app): the development copy, with its own chats.
app:
	./Scripts/build-app.sh
run:
	./Scripts/run-dev.sh
# Octo (build/Octo.app); install puts it in ~/Applications as the app you use.
release:
	./Scripts/build-app.sh release
install:
	./Scripts/install-app.sh

setup:
	./Scripts/setup.sh
doctor:
	./Scripts/setup.sh --check
privacy:
	python3 Scripts/check-private-data.py --worktree
