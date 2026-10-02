TARGET = iphone:clang:16.5:15.0
ARCHS = arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = RCSwitch
RCSwitch_FILES = rcswitch3.x
RCSwitch_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
