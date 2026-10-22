ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:16.2
THEOS_PACKAGE_SCHEME = rootless
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = LyricBridge
LyricBridge_FILES = LyricBridge.m SingSupport.m
LyricBridge_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -I$(THEOS_PROJECT_DIR)/SDK
LyricBridge_FRAMEWORKS = Foundation UIKit MediaPlayer
LyricBridge_LIBRARIES = substrate CoreLyrics
LyricBridge_LDFLAGS = -L$(THEOS_PROJECT_DIR)/SDK
SUBPROJECTS = LyricBridgePrefs
include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk

before-package::
	@find "$(THEOS_STAGING_DIR)" -type d -exec chmod 755 {} +
	@find "$(THEOS_STAGING_DIR)" -type f -exec chmod 644 {} +
	@find "$(THEOS_STAGING_DIR)" -type f -name '*.dylib' -exec chmod 755 {} +
	@find "$(THEOS_STAGING_DIR)" -type f -path '*/LyricBridgePrefs.bundle/LyricBridgePrefs' -exec chmod 755 {} +
	@[ -f "$(THEOS_STAGING_DIR)/DEBIAN/postrm" ] && chmod 755 "$(THEOS_STAGING_DIR)/DEBIAN/postrm" || true
