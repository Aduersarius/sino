SDK    := $(shell xcrun --show-sdk-path)
TARGET := arm64-apple-macos14.0
APP    := Sino.app
BIN    := $(APP)/Contents/MacOS/Sino
SRC    := Sources/Sampler.swift Sources/SinoApp.swift Sources/SMC.c

.PHONY: all run dump clean

all: $(BIN)

$(BIN): $(SRC) Sources/Bridging.h Sources/SMC.h Info.plist Assets/AppIcon.icns
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	swiftc -parse-as-library -Osize \
		-sdk $(SDK) -target $(TARGET) \
		-import-objc-header Sources/Bridging.h \
		-framework SwiftUI -framework AppKit -framework IOKit \
		-o $(BIN) $(SRC)
	cp Info.plist $(APP)/Contents/Info.plist
	cp Assets/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	printf 'APPL????' > $(APP)/Contents/PkgInfo
	codesign -s - --force --deep $(APP) >/dev/null

run: all
	open $(APP)

dump: all
	$(BIN) --dump

clean:
	rm -rf $(APP)
