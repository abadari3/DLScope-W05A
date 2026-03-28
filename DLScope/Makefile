ARCHS = armv7
TARGET = iphone:6.1:6.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = DLScope
DLScope_FILES = main.m DLSAppDelegate.m DLSViewController.m DLSMicroscope.m
DLScope_OBJCFLAGS = -fobjc-arc
DLScope_FRAMEWORKS = UIKit CoreGraphics ImageIO Foundation QuartzCore AssetsLibrary SystemConfiguration

include $(THEOS_MAKE_PATH)/application.mk
