APP      = Mindtalk
CONFIG  ?= Debug
BUILD    = $(CURDIR)/build
APP_PATH = $(BUILD)/Build/Products/$(CONFIG)/$(APP).app

.PHONY: project build run open install clean

project:
	xcodegen generate --quiet

build: project
	xcodebuild -project $(APP).xcodeproj -scheme $(APP) -configuration $(CONFIG) \
	  -derivedDataPath $(BUILD) -destination 'platform=macOS,arch=arm64' build | tail -25

run: build
	@pkill -x $(APP) 2>/dev/null || true
	open "$(APP_PATH)"

open: project
	open $(APP).xcodeproj

install:
	$(MAKE) build CONFIG=Release
	@pkill -x $(APP) 2>/dev/null || true
	rm -rf /Applications/$(APP).app
	cp -R "$(BUILD)/Build/Products/Release/$(APP).app" /Applications/$(APP).app
	open -a /Applications/$(APP).app

clean:
	rm -rf $(BUILD) $(APP).xcodeproj
