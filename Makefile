APP      = Mindtalk
CONFIG  ?= Debug
BUILD    = $(CURDIR)/build
APP_PATH = $(BUILD)/Build/Products/$(CONFIG)/$(APP).app

.PHONY: project build run open install clean

project:
	xcodegen generate --quiet

build: project
	xcodebuild -project $(APP).xcodeproj -scheme $(APP) -configuration $(CONFIG) \
	  -derivedDataPath $(BUILD) -destination 'platform=macOS,arch=arm64' build

# `open` answers before the app is up, and refuses a second instance of an app that is
# still quitting. The waiting and the checking live in scripts/relaunch.sh: `quit` proves
# no instance is left, so any pid `launch` finds afterwards is the one just started.
run: build
	@zsh scripts/relaunch.sh quit $(APP)
	@zsh scripts/relaunch.sh launch $(APP) "$(APP_PATH)"

open: project
	open $(APP).xcodeproj

install:
	$(MAKE) build CONFIG=Release
	@zsh scripts/relaunch.sh quit $(APP)
	rm -rf /Applications/$(APP).app
	cp -R "$(BUILD)/Build/Products/Release/$(APP).app" /Applications/$(APP).app
	@zsh scripts/relaunch.sh launch $(APP) /Applications/$(APP).app

clean:
	rm -rf $(BUILD) $(APP).xcodeproj
