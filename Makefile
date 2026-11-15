APP      = Mindtalk
CONFIG  ?= Debug
BUILD    = $(CURDIR)/build
APP_PATH = $(BUILD)/Build/Products/$(CONFIG)/$(APP).app

.PHONY: project build build-log run open install clean

project:
	xcodegen generate --quiet

build: project
	xcodebuild -project $(APP).xcodeproj -scheme $(APP) -configuration $(CONFIG) \
	  -derivedDataPath $(BUILD) -destination 'platform=macOS,arch=arm64' build | tail -25

build-log: project
	@mkdir -p $(BUILD)
	-xcodebuild -project $(APP).xcodeproj -scheme $(APP) -configuration $(CONFIG) \
	  -derivedDataPath $(BUILD) -destination 'platform=macOS,arch=arm64' build \
	  > $(BUILD)/build-raw.log 2>&1
	@grep -E "^[^ ].*(error|warning):|BUILD (SUCCEEDED|FAILED)|The following build commands failed" $(BUILD)/build-raw.log \
	  | sed -E "s|$(CURDIR)/||g" | awk '!seen[$$0]++' > $(BUILD)/build-log.txt
	@echo "$(BUILD)/build-log.txt: $$(grep -c 'error:' $(BUILD)/build-log.txt) errors, \
$$(grep -c 'warning:' $(BUILD)/build-log.txt) warnings (everything else in build-raw.log)"

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
