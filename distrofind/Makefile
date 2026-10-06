TARGET := iphone:clang:latest:16.0
ARCHS := arm64
FINALPACKAGE := 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := DistroFind
DistroFind_FILES := $(shell find Sources -name '*.m' -o -name '*.x' | sort)
DistroFind_CFLAGS := -fobjc-arc -ISources -Wno-deprecated-declarations
DistroFind_FRAMEWORKS := UIKit Foundation QuartzCore
DistroFind_LOGOS_DEFAULT_GENERATOR := internal

include $(THEOS_MAKE_PATH)/tweak.mk
