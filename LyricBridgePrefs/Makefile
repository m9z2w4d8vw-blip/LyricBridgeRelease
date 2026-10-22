include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = LyricBridgePrefs
LyricBridgePrefs_FILES = LyricBridgeSettings.m LyricBridgeDiagnostics.m
LyricBridgePrefs_FRAMEWORKS = UIKit QuartzCore
LyricBridgePrefs_PRIVATE_FRAMEWORKS = Preferences
LyricBridgePrefs_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/SDK
LyricBridgePrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
