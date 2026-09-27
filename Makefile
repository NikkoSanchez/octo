.PHONY: build test app run release setup doctor privacy
build:
	swift build
test:
	swift test
app:
	./Scripts/build-app.sh
run: app
	open build/Octo.app
release:
	./Scripts/build-app.sh release

setup:
	./Scripts/setup.sh
doctor:
	./Scripts/setup.sh --check
privacy:
	python3 Scripts/check-private-data.py --worktree
