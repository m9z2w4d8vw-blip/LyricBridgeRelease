TARGET := iphone:clang:16.5:16.0
THEOS_PACKAGE_SCHEME = rootless
include $(THEOS)/makefiles/common.mk
TOOL_NAME = LyricBridgeResetDiagnostics
LyricBridgeResetDiagnostics_FILES = main.m
LyricBridgeResetDiagnostics_CFLAGS = -fobjc-arc
LyricBridgeResetDiagnostics_FRAMEWORKS = Foundation
LyricBridgeResetDiagnostics_INSTALL_PATH = /usr/libexec/LyricBridge
include $(THEOS_MAKE_PATH)/tool.mk
