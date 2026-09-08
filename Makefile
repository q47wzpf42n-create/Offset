TARGET := MyDylib

include $(THEOS)/makefiles/common.mk

$(TARGET)_FILES := main.m
$(TARGET)_FRAMEWORKS := UIKit Foundation
$(TARGET)_CFLAGS := -fobjc-arc

include $(THEOS_MAKE_PATH)/library.mk