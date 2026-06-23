//
//  NSObject+Fixer.m
//  ApertureFixer
//
//

#import <objc/runtime.h>
#import <objc/message.h>
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <sys/sysctl.h>
#import "NSObject+Fixer.h"

// ---- macOS Sequoia (15) and later compatibility helpers ----
// These cover breakage introduced after the last supported release (macOS Sonoma). They are
// gated to macOS 15+ in +load so lower OSes, where the existing fixes suffice, are untouched.

static BOOL retro_osAtLeastSequoia(void) {
    // NSProcessInfo.operatingSystemVersion is capped to 10.x for apps built against old SDKs
    // (Aperture and iPhoto), so inside these apps it can never report macOS 15+. Read the
    // uncapped Darwin kernel version instead: Darwin 24 = macOS 15 (Sequoia), 25 = macOS 26, ...
    char release[256]; size_t size = sizeof(release);
    if (sysctlbyname("kern.osrelease", release, &size, NULL, 0) != 0) return NO;
    return atoi(release) >= 24;
}

static void retro_swizzle(const char *clsName, NSString *sel, SEL replacement) {
    Class cls = objc_getClass(clsName);
    if (!cls) return;
    Method a = class_getInstanceMethod(cls, NSSelectorFromString(sel));
    Method b = class_getInstanceMethod(cls, replacement);
    if (a && b) method_exchangeImplementations(a, b);
}

// ProKit's getRGBAImp raises when [color colorSpace] is outside its RGB allow-list, which
// excludes macOS 26's extended-range/HDR colorspaces. Report extended RGB spaces as plain sRGB.
static NSColorSpace *retro_remapColorSpace(NSColorSpace *cs) {
    if (cs && cs.colorSpaceModel == NSColorSpaceModelRGB) {
        CGColorSpaceRef cg = cs.CGColorSpace;
        if (cg) {
            CFStringRef nm = CGColorSpaceCopyName(cg);
            if (nm) {
                BOOL extended = CFStringFind(nm, CFSTR("xtended"), 0).location != kCFNotFound;
                CFRelease(nm);
                if (extended) return [NSColorSpace sRGBColorSpace];
            }
        }
    }
    return cs;
}

// The offending HDR color overrides -colorSpace in a private subclass, so install the remap on
// every NSColor subclass that defines its own -colorSpace (not just NSColor).
static void retro_installColorSpaceFix(Class cls) {
    unsigned n = 0; Method *ms = class_copyMethodList(cls, &n); BOOL owns = NO;
    for (unsigned i = 0; i < n; i++) if (method_getName(ms[i]) == @selector(colorSpace)) { owns = YES; break; }
    free(ms);
    if (!owns) return;
    Method m = class_getInstanceMethod(cls, @selector(colorSpace));
    if (!m) return;
    IMP orig = method_getImplementation(m);
    IMP rep = imp_implementationWithBlock(^NSColorSpace *(id self) {
        return retro_remapColorSpace(((NSColorSpace *(*)(id, SEL))orig)(self, @selector(colorSpace)));
    });
    method_setImplementation(m, rep);
}

static Class retro_proSegmentedCell(void) {
    static Class c; if (!c) c = objc_getClass("NSProSegmentedCell"); return c;
}

// HgFSReservation lives in iLifeSQLAccess, which is loaded after this fixer, so swizzling it from
// +load silently misses (the class isn't registered yet). Force the framework to load first, then
// swap acquireReservation for our stub. Safe to call more than once.
static void retro_installReservationFix(void) {
    Class cls = objc_getClass("HgFSReservation");
    if (!cls) {
        NSString *fw = [[NSBundle mainBundle].privateFrameworksPath
                        stringByAppendingPathComponent:@"iLifeSQLAccess.framework/Versions/A/iLifeSQLAccess"];
        if (fw) dlopen(fw.fileSystemRepresentation, RTLD_LAZY);
        cls = objc_getClass("HgFSReservation");
    }
    if (!cls) return;
    Method a = class_getInstanceMethod(cls, NSSelectorFromString(@"acquireReservation"));
    Method b = class_getInstanceMethod(cls, @selector(retro_acquireReservation));
    if (a && b) method_exchangeImplementations(a, b);
}

@implementation NSObject (Fixer)

+ (NSFont *)swizzled_proSystemFontWithFontName:(NSString *)name pointSize:(CGFloat)size fontAppearance:(id)appearance useSystemHelveticaAdjustments:(BOOL)adjustments {
	return [NSFont systemFontOfSize:size];
}

- (NSURL *)patched_URLForApplicationWithBundleIdentifier:(NSString *)bundleIdentifier {
    NSString *appBundleIdentifier = [NSBundle mainBundle].bundleIdentifier;
    if (!bundleIdentifier) {
        if ([appBundleIdentifier containsString:@"com.apple.iPhoto"]) {
            bundleIdentifier = @"com.apple.Aperture3";
        } else {
            bundleIdentifier = @"com.apple.iPhoto9";
        }
    }
    NSURL *urlForBundle = [self patched_URLForApplicationWithBundleIdentifier:bundleIdentifier];
    NSLog(@"this app is %@, looking for %@ at %@", appBundleIdentifier, bundleIdentifier, urlForBundle);
	return urlForBundle;
}

- (void)_addToolTipRects {
}

+ (void)load {
	Class class = [self class];
	
	// patch out +[NSProFont _proSystemFontWithFontName:pointSize:fontAppearance:useSystemHelveticaAdjustments]
	method_exchangeImplementations(class_getClassMethod(NSClassFromString(@"NSProFont"), NSSelectorFromString(@"_proSystemFontWithFontName:pointSize:fontAppearance:useSystemHelveticaAdjustments:")),
								   class_getClassMethod(class, @selector(swizzled_proSystemFontWithFontName:pointSize:fontAppearance:useSystemHelveticaAdjustments:)));

	method_exchangeImplementations(class_getInstanceMethod(NSClassFromString(@"NSWorkspace"), NSSelectorFromString(@"URLForApplicationWithBundleIdentifier:")),
								   class_getInstanceMethod(class, @selector(patched_URLForApplicationWithBundleIdentifier:)));
    
    method_exchangeImplementations(class_getInstanceMethod(NSClassFromString(@"RKPrintPanel"), NSSelectorFromString(@"_updatePageSizePopup")),
                                   class_getInstanceMethod(class, @selector(patched_updatePageSizePopup)));
    
    method_exchangeImplementations(class_getInstanceMethod(NSClassFromString(@"RKRedRockApp"), NSSelectorFromString(@"_delayedFinishLaunching")),
                                   class_getInstanceMethod(class, @selector(patched_delayedFinishLaunching)));
    
    method_exchangeImplementations(class_getInstanceMethod(NSClassFromString(@"RKRedRockApp"), NSSelectorFromString(@"_moveCommandSetsToSandboxLocation")),
                                   class_getInstanceMethod(class, @selector(patched_moveCommandSetsToSandboxLocation)));

    method_exchangeImplementations(class_getInstanceMethod(NSClassFromString(@"NSConcretePrintOperation"), NSSelectorFromString(@"runOperation")),
                                   class_getInstanceMethod(class, @selector(patched_runOperation)));
    
    method_exchangeImplementations(class_getInstanceMethod(NSClassFromString(@"RKPrinter"), NSSelectorFromString(@"paperWithID:")),
                                   class_getInstanceMethod(class, @selector(patched_paperWithID:)));
    
    method_exchangeImplementations(class_getInstanceMethod(NSClassFromString(@"IPPrinterPaperSelectionView"), NSSelectorFromString(@"updatePaperMenu")),
                                   class_getInstanceMethod(class, @selector(patched_updatePaperMenu)));

    // macOS Sequoia (15) and later — breakage introduced after macOS Sonoma. Lower OSes don't need these.
    if (!retro_osAtLeastSequoia()) return;

    // Swift exclusivity enforcement crashes when AppKit's SwiftUI-based rendering touches old
    // ProKit objects; disable it (set before the Swift runtime first checks).
    setenv("SWIFT_ENFORCE_EXCLUSIVITY", "off", 1);

    // SIGILL in CATransaction's display-link flush observer during modal/run-loop activity.
    Method displayLinkFlush = class_getClassMethod(objc_getClass("CATransaction"),
                                                   NSSelectorFromString(@"NS_setFlushesWithDisplayLink"));
    if (displayLinkFlush) method_setImplementation(displayLinkFlush, imp_implementationWithBlock(^(id _self){}));

    // Segmented-control appearance subsystem is binary-incompatible with ProKit's cells.
    retro_swizzle("NSSegmentedCell", @"_refreshVisualProvider", @selector(retro_refreshVisualProvider));
    retro_swizzle("NSSegmentedCell", @"_visualProvider", @selector(retro_visualProvider));
    retro_swizzle("NSSegmentedCell", @"_visualProviderIfExists", @selector(retro_visualProviderIfExists));

    // On macOS Sequoia the appearance-based provider is the only segmented-control provider, and
    // it throws from updateSegmentItemConfiguration: while a control is torn down during KVO
    // dealloc (the segment array/config is already empty: index 0 out of bounds in Aperture, a nil
    // -hasSuffix: argument in iPhoto). That exception aborts the launch AppleEvent so Aperture
    // never shows its window, and aborts iPhoto when opening an album. The per-item update is
    // meaningless on a dying control, so guard it and let teardown finish.
    retro_swizzle("NSSegmentedControlAppearanceBasedVisualProvider", @"updateSegmentItemConfiguration:", @selector(retro_updateSegmentItemConfiguration:));

    // Dead Carbon FSReservation -> rely on the still-working flock lock.
    retro_installReservationFix();

    // Modal session suppressed inside the launch transaction.
    retro_swizzle("NSApplication", @"runModalSession:", @selector(retro_runModalSession:));

    // Disable broken window restoration (kills the reopen-after-crash dialog).
    retro_swizzle("NSWindow", @"isRestorable", @selector(retro_isRestorable));
    retro_swizzle("NSPersistentUIManager", @"hasPersistentStateToRestore", @selector(retro_hasPersistentStateToRestore));
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"NSQuitAlwaysKeepsWindows"];
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
    for (NSString *dir in @[[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Saved Application State"], NSTemporaryDirectory()]) {
        [[NSFileManager defaultManager] removeItemAtPath:[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.savedState", bid]] error:nil];
    }

    // ProKit theme-index remap: facets decoded from the apps' nibs carry a stale themeIndex
    // (e.g. 1764) baked in when the app shipped, but ProKit now registers the ProThemeBits.car
    // store under a different (small, sequential) index. The mismatch makes every themed asset
    // lookup miss -> blank segment icons, wrong control metrics, "No theme registered" spam.
    // Redirect misses to the live registered store. See retro_themeStoreForThemeIndex:.
    {
        Class facet = objc_getClass("NSProThemeFacet");
        if (facet) {
            Method a = class_getClassMethod(facet, NSSelectorFromString(@"_themeStoreForThemeIndex:"));
            Method b = class_getClassMethod(objc_getClass("NSObject"), @selector(retro_themeStoreForThemeIndex:));
            if (a && b) method_exchangeImplementations(a, b);
        }
    }

    // Silence redesigned_text_cursor log spam.
    retro_swizzle("TUINSCursorUIController", @"invalidateCharacterCoordinates", @selector(retro_invalidateCharacterCoordinates));

    // NSColor extended/HDR colorspace remap, across every NSColor subclass that overrides -colorSpace.
    Class colorBase = objc_getClass("NSColor");
    if (colorBase) {
        int count = objc_getClassList(NULL, 0);
        Class *all = (Class *)malloc(sizeof(Class) * count);
        count = objc_getClassList(all, count);
        for (int i = 0; i < count; i++) {
            for (Class c = all[i]; c; c = class_getSuperclass(c)) {
                if (c == colorBase) { retro_installColorSpaceFix(all[i]); break; }
            }
        }
        free(all);
    }
}

- (void)patched_moveCommandSetsToSandboxLocation {
    NSLog(@"asked to move command sets to sandbox location, but Aperture is unboxed, skipping it");
}

- (id)patched_paperWithID:(id)arg1 {
    NSLog(@"patching paperWithID to prevent crashes");
    return nil;
}

- (void)patched_updatePaperMenu {
    NSLog(@"skipping updatePaperMenu to prevent crashes");
}

- (void)patched_runOperation {
    NSLog(@"patching runOperation");
    if ([NSThread isMainThread]) {
        NSLog(@"current thread is already main thread, calling runOperation as is");
        [self patched_runOperation];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            NSLog(@"running operation on main queue after dispatching to main queue");
            [self patched_runOperation];
        });
    }
}

- (void)patched_delayedFinishLaunching {
    NSLog(@"kick delayedFinishLaunching to the next run loop, so that the adjustments menu can populate");
    [self performSelector:@selector(patched_delayedFinishLaunching) withObject:nil afterDelay:0];
}

- (void)patched_updatePageSizePopup {
    NSLog(@"skipping updatePageSizePopup to prevent a crash");
}

- (BOOL)_hasRowHeaderColumn {
	return NO;
}

- (BOOL)_proIsSpinning {
    return NO;
}

- (void)_autoSizeView:(id)a :(id)b :(id)c :(id)d :(id)e {
    NSLog(@"Skipping _autoSizeView");
}

- (void)setShowingRollover:(id)showingRollover {
}

- (CGFloat)_drawingWidth {
    NSLog(@"Returning 0 _drawingWidth");
    return 0;
}

- (void)set_drawingWidth:(CGFloat)value {
    NSLog(@"Skipping set_drawingWidth");
}

- (BOOL)_proDelayedStartup {
    NSLog(@"Returning NO for _proDelayedStartup");
    return NO;
}

- (void)_setProDelayedStartup:(BOOL)value {
    NSLog(@"Skipping _setProDelayedStartup");
}

- (unsigned long long)_proAnimationIndex {
    return 0;
}

- (void)_setProAnimationIndex:(unsigned long long)arg1 {
}

- (void)_installHeartBeat:(id)heartbeat {
    NSLog(@"Skipping _installHeartBeat");
}

- (void)_alignSize:(id)size force:(id)force {
}

// ---- macOS 26 additions ----

// Modern AppKit queries these on segment items; ProKit's NSProSegmentItem doesn't implement
// them (and doesn't inherit NSSegmentItem). Provide safe NSObject fallbacks.
- (BOOL)_needsRecalc {
    return NO;
}

- (void)_setNeedsRecalc {
}

- (CGFloat)_displayWidth {
    if ([self respondsToSelector:@selector(width)]) {
        CGFloat w = ((CGFloat (*)(id, SEL))objc_msgSend)(self, @selector(width));
        if (w > 0) return w;
    }
    if ([self respondsToSelector:@selector(label)]) {
        NSString *l = ((id (*)(id, SEL))objc_msgSend)(self, @selector(label));
        if ([l isKindOfClass:[NSString class]] && l.length) {
            return [l sizeWithAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:[NSFont systemFontSize]]}].width + 16.0;
        }
    }
    return 0;
}

// Force ProKit's NSProSegmentedCell down the legacy (no visual-provider) path. Modern AppKit's
// appearance-based segment subsystem is binary-incompatible with ProKit's cells (heap corruption
// during nib decode); with no provider, AppKit falls back to ProKit's own cell drawing.
- (void)retro_refreshVisualProvider {
    if (retro_proSegmentedCell() && [self isKindOfClass:retro_proSegmentedCell()]) return;
    [self retro_refreshVisualProvider];
}

- (id)retro_visualProvider {
    if (retro_proSegmentedCell() && [self isKindOfClass:retro_proSegmentedCell()]) return nil;
    return [self retro_visualProvider];
}

- (id)retro_visualProviderIfExists {
    if (retro_proSegmentedCell() && [self isKindOfClass:retro_proSegmentedCell()]) return nil;
    return [self retro_visualProviderIfExists];
}

// See the swizzle site: the appearance-based provider throws while a segmented control is being
// deallocated and its segments are already gone. Swallow it so teardown can't abort the process.
- (void)retro_updateSegmentItemConfiguration:(id)configuration {
    @try {
        [self retro_updateSegmentItemConfiguration:configuration];
    } @catch (NSException *exception) {
        // Benign: the control is being torn down and its segments are already gone. Swallow
        // quietly (this can fire on every view switch, so don't log).
    }
}

// Carbon FSReservation is unusable on modern macOS: on macOS 26 FSReservationAcquire returns
// paramErr, and on macOS Sequoia it blocks (driving the bogus "Time Machine is backing up" wait
// that never finishes, so the library never opens). Don't call through to it at all — the real
// Aperture<->iPhoto cross-app lock is the separate flock-based HgPIDFile, which still works, so
// just report the reservation as acquired.
- (BOOL)retro_acquireReservation {
    return YES;
}

// runModalSession: is suppressed inside the finish-launching CA transaction, so the caller's
// poll loop spins forever (nothing pumps the runloop, so the completion that ends the modal
// never fires). Pump the runloop ourselves so the session can progress and end.
- (NSModalResponse)retro_runModalSession:(NSModalSession)session {
    NSModalResponse response = [self retro_runModalSession:session];
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.005, true);
    return response;
}

// This app's window restoration is broken on macOS 26 and triggers the "reopen windows after
// crash" dialog that blocks the main window. Disable restoration.
- (BOOL)retro_isRestorable {
    return NO;
}

- (BOOL)retro_hasPersistentStateToRestore {
    return NO;
}

// Silence the redesigned_text_cursor log spam on macOS 26.
- (void)retro_invalidateCharacterCoordinates {
}

// Class method on NSProThemeFacet (swizzled). When a facet asks for a theme store by a stale
// index that isn't registered, fall back to the live registered store so themed assets (segment
// icons, control metrics) resolve instead of coming back empty. We remember the *index* that last
// resolved and re-look-it-up fresh each time (rather than caching a store object, which can go
// stale across theme reloads and crash). This calls the original implementation, so no recursion.
+ (id)retro_themeStoreForThemeIndex:(NSUInteger)index {
    static NSUInteger goodIndex = 0;
    static BOOL haveGoodIndex = NO;
    id store = [self retro_themeStoreForThemeIndex:index];
    if (store) {
        goodIndex = index;
        haveGoodIndex = YES;
        return store;
    }
    if (haveGoodIndex && index != goodIndex) {
        return [self retro_themeStoreForThemeIndex:goodIndex];
    }
    return nil;
}

@end
