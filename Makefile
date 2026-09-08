TARGET := MyDylib
TARGET_IPHONEOS_DEPLOYMENT_VERSION := 13.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

$(TARGET)_FILES := main.m
$(TARGET)_FRAMEWORKS := UIKit Foundation
$(TARGET)_CFLAGS := -fobjc-arc

include $(THEOS_MAKE_PATH)/library.mk
