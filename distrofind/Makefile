TARGET := iphone:clang:latest:16.0
ARCHS := arm64
FINALPACKAGE := 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := DistroFind
DistroFind_FILES := \
    ../tweak/Sources/Core/SGLog.m \
    ../tweak/Sources/Shared/Spotify/Spclient.x \
    ../tweak/Sources/Shared/DistroFind/DistroFindData.m \
    ../tweak/Sources/Shared/DistroFind/DistroFind.m \
    ../tweak/Sources/Shared/DistroFind/DistroFindServer.m \
    Sources/DistroFindCompanion.x \
    Sources/DFVisibleRowLookup.m \
    Sources/DFPerformanceGraph.m \
    Sources/DFPlayerArtistUI.x
DistroFind_CFLAGS := -fobjc-arc -I../tweak/Sources -ISources -Wno-deprecated-declarations
DistroFind_FRAMEWORKS := UIKit Foundation QuartzCore
DistroFind_LOGOS_DEFAULT_GENERATOR := internal

include $(THEOS_MAKE_PATH)/tweak.mk
