ARCHS = arm64
TARGET = iphone:clang:latest:13.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = RobloxExec
RobloxExec_FILES = Tweak.mm
RobloxExec_CFLAGS = -fobjc-arc -O2
RobloxExec_FRAMEWORKS = UIKit QuartzCore Foundation
RobloxExec_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk