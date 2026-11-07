# Testudo: one universal-free arm64 build for macOS 27. Needs Xcode; no
# CMake, no Homebrew, no other tools. `make -j` compiles the C libraries once
# and only rebuilds what changed.

TARGET   := arm64-apple-macos27.0
BUILD    := build
OBJ      := $(BUILD)/obj
APP      := $(BUILD)/Testudo.app
BIN      := $(APP)/Contents/MacOS/Testudo

MOZJPEG  := jcapimin jcapistd jccoefct jccolor jcdctmgr jchuff jcext jcicc jcinit \
            jcmainct jcmarker jcmaster jcomapi jcparam jcphuff jcprepct jcsample jctrans \
            jdapimin jdapistd jdatadst jdatasrc jdcoefct jdcolor jddctmgr jdhuff jdicc \
            jdinput jdmainct jdmarker jdmaster jdmerge jdphuff jdpostct jdsample jdtrans \
            jerror jfdctflt jfdctfst jfdctint jidctflt jidctfst jidctint jidctred jquant1 \
            jquant2 jutils jmemmgr jmemnobs jsimd_none

C_SOURCES := Core/testudo_core.c \
             $(MOZJPEG:%=Vendor/mozjpeg/%.c) \
             $(wildcard Vendor/libimagequant/*.c) \
             $(wildcard Vendor/libwebp/src/dec/*.c Vendor/libwebp/src/enc/*.c Vendor/libwebp/src/dsp/*.c \
                        Vendor/libwebp/src/utils/*.c Vendor/libwebp/src/mux/*.c Vendor/libwebp/src/demux/*.c \
                        Vendor/libwebp/sharpyuv/*.c) \
             $(wildcard Vendor/libdeflate/lib/*.c Vendor/libdeflate/lib/arm/*.c) \
             Vendor/lodepng/lodepng.c

OBJECTS  := $(C_SOURCES:%.c=$(OBJ)/%.o)
SWIFT    := $(wildcard Sources/*.swift)

# -ffile-prefix-map keeps this folder's path (and so your username) out of the app.
CFLAGS   := -target $(TARGET) -Os -DNDEBUG -w -ffunction-sections -fdata-sections \
            -ffile-prefix-map=$(CURDIR)=. \
            -DLODEPNG_NO_COMPILE_DISK -DLODEPNG_NO_COMPILE_CPP \
            -ICore -IVendor/mozjpeg -IVendor/libimagequant -IVendor/libwebp -IVendor/libwebp/src \
            -IVendor/libdeflate -IVendor/lodepng

SWIFTFLAGS := -target $(TARGET) -swift-version 5 -Osize -wmo -parse-as-library -module-name Testudo \
              -import-objc-header Core/testudo_core.h -file-prefix-map $(CURDIR)=. \
              -Xlinker -dead_strip -Xlinker -dead_strip_dylibs

.PHONY: all app dmg clean
all: dmg

$(OBJ)/%.o: %.c
	@mkdir -p $(@D)
	@xcrun clang $(CFLAGS) -c $< -o $@

$(BIN): $(OBJECTS) $(SWIFT) Core/testudo_core.h
	@mkdir -p $(@D) $(APP)/Contents/Resources
	@xcrun swiftc $(SWIFTFLAGS) $(SWIFT) $(OBJECTS) -o $@
	@xcrun strip -x $@

app: $(BIN) Resources/Info.plist Resources/AppIcon.icns Resources/Testudo.entitlements
	@cp Resources/Info.plist $(APP)/Contents/Info.plist
	@printf 'APPL????' > $(APP)/Contents/PkgInfo
	@cp Resources/AppIcon.icns $(APP)/Contents/Resources/
	@cat LICENSE THIRD-PARTY-NOTICES.md > $(APP)/Contents/Resources/Licenses.txt
	@codesign --force --sign - --options runtime --entitlements Resources/Testudo.entitlements $(APP)
	@echo "Built $$(du -sh $(APP) | cut -f1)  $(APP)"

dmg: app
	@zsh make-dmg.sh $(APP) $(BUILD)/Testudo.dmg

clean:
	rm -rf $(BUILD)
