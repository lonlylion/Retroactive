//
//  AppKitShim.m
//  Retroactive
//
//  A minimal AppKit compatibility shim for ProKit-based apps (Aperture/iPhoto) on modern macOS.
//
//  macOS still registers these classes at runtime, but no longer exports their _OBJC_CLASS_$_
//  link symbols, so ProKit fails to bind against AppKit at load. This shim re-exports the real
//  AppKit and supplies just those three symbols, aliased (see build.tool) onto faithful classes
//  so there is no duplicate-class clash with the still-registered real classes. It deliberately
//  contains NO runtime patching — all swizzles live in ApertureFixer.
//

#import <AppKit/AppKit.h>

// NSFlippableView is a top-origin (flipped) NSView container.
@interface RetroFlippableView : NSView
@end
@implementation RetroFlippableView
- (BOOL)isFlipped { return YES; }
@end

// NSRegion is an opaque NSObject (ProKit only references it as a classref).
@interface RetroRegion : NSObject
@end
@implementation RetroRegion
@end

// NSToolbarClippedItemsIndicator is the toolbar overflow chevron, an NSPopUpButton subclass.
@interface RetroToolbarClippedItemsIndicator : NSPopUpButton
@end
@implementation RetroToolbarClippedItemsIndicator
@end
