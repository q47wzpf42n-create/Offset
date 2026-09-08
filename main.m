#import <UIKit/UIKit.h>
#import <substrate.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <stdatomic.h>
#include <math.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>

// ─────────────────────────────────────────────
// MARK: - Constants
// ─────────────────────────────────────────────

static const uint8_t kTarget[4]      = {0x62, 0x6F, 0x64, 0x79}; // "body"
static const uint8_t kReplacement[4] = {0x68, 0x65, 0x61, 0x64}; // "head"

#define SWIPE_MIN_DISTANCE  5.0f
#define LOG_TAG             "[SwipeOffsetPatcher]"
#define TARGET_BUNDLE_ID    @"com.dts.freefireth"

// ─────────────────────────────────────────────
// MARK: - Atomic State
// ─────────────────────────────────────────────

static _Atomic(bool) gPatchApplied   = false;  // patch done, gate permanently closed
static _Atomic(bool) gPatchTriggered = false;  // swipe received, patch in-flight or done
static _Atomic(bool) gSwipeConsumed  = false;  // first qualifying swipe consumed

// ─────────────────────────────────────────────
// MARK: - Touch Tracking
// ─────────────────────────────────────────────

typedef struct {
    CGPoint origin;
    CGPoint current;
    BOOL    active;
} SwipeTracker;

static SwipeTracker gTracker = {{0,0},{0,0},NO};

// ─────────────────────────────────────────────
// MARK: - Memory Scanner
// ─────────────────────────────────────────────

static size_t scanRegionForPattern(
    mach_port_t     task,
    vm_address_t    regionBase,
    vm_size_t       regionSize,
    vm_prot_t       origProt,
    uintptr_t      *outHitAddress
) {
    if ((origProt & VM_PROT_READ) == 0) return 0;

    uint8_t *buf = (uint8_t *)malloc(regionSize);
    if (!buf) return 0;

    vm_size_t bytesRead = 0;
    kern_return_t kr = vm_read_overwrite(
        task, regionBase, regionSize,
        (vm_address_t)buf, &bytesRead
    );

    size_t hits = 0;

    if (kr == KERN_SUCCESS && bytesRead >= 4) {
        for (vm_size_t i = 0; i <= bytesRead - 4; i++) {
            if (memcmp(buf + i, kTarget, 4) == 0) {
                uintptr_t patchAddr = (uintptr_t)(regionBase + i);

                // page-align for vm_protect
                vm_address_t pageBase = patchAddr & ~((vm_address_t)(PAGE_SIZE - 1));
                vm_size_t    pageLen  = PAGE_SIZE;

                // unlock
                kr = vm_protect(task, pageBase, pageLen, FALSE,
                                VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
                if (kr != KERN_SUCCESS) continue;

                // write replacement
                kr = vm_write(task, patchAddr,
                              (vm_offset_t)kReplacement, 4);

                // restore
                vm_protect(task, pageBase, pageLen, FALSE, origProt);

                if (kr == KERN_SUCCESS) {
                    hits++;
                    if (outHitAddress && hits == 1) *outHitAddress = patchAddr;
                    NSLog(@"%s Patched 0x626F6479->0x68656164 @ 0x%lx",
                          LOG_TAG, (unsigned long)patchAddr);
                }
            }
        }
    }

    free(buf);
    return hits;
}

// ─────────────────────────────────────────────
// MARK: - Full Address Space Walk
// ─────────────────────────────────────────────

static void performFullScan(void) {
    if (atomic_load(&gPatchApplied)) return;

    mach_port_t          task  = mach_task_self();
    vm_address_t         addr  = 0;
    vm_size_t            size  = 0;
    natural_t            depth = 0;
    size_t               totalHits = 0;

    struct vm_region_submap_info_64 info;
    mach_msg_type_number_t          count = VM_REGION_SUBMAP_INFO_COUNT_64;

    while (vm_region_recurse_64(task, &addr, &size, &depth,
                                (vm_region_recurse_info_t)&info,
                                &count) == KERN_SUCCESS) {

        if (info.is_submap) {
            depth++;
            addr += size;
            count = VM_REGION_SUBMAP_INFO_COUNT_64;
            continue;
        }

        // Only scan readable, non-zero regions
        if (size > 0 && (info.protection & VM_PROT_READ)) {
            uintptr_t firstHit = 0;
            size_t hits = scanRegionForPattern(task, addr, size,
                                               info.protection, &firstHit);
            totalHits += hits;
        }

        addr  += size;
        count  = VM_REGION_SUBMAP_INFO_COUNT_64;
    }

    if (totalHits > 0) {
        atomic_store(&gPatchApplied, true);
        NSLog(@"%s Scan complete -- %zu offset(s) patched. Gate closed.",
              LOG_TAG, totalHits);
    } else {
        NSLog(@"%s Scan complete -- pattern not found in address space.", LOG_TAG);
        // Reset trigger so the next qualifying swipe can retry
        atomic_store(&gPatchTriggered, false);
        atomic_store(&gSwipeConsumed,  false);
    }
}

// ─────────────────────────────────────────────
// MARK: - Swipe Geometry
// ─────────────────────────────────────────────

typedef struct {
    CGFloat dx;
    CGFloat dy;
    CGFloat magnitude;
    BOOL    isUpward;      // dy < 0 in UIKit screen space (origin top-left)
    BOOL    exceedsThreshold;
} SwipeVector;

static SwipeVector computeVector(CGPoint from, CGPoint to) {
    SwipeVector v;
    v.dx        = to.x - from.x;
    v.dy        = to.y - from.y;           // negative = upward in UIKit
    v.magnitude = sqrtf(v.dx * v.dx + v.dy * v.dy);
    v.isUpward  = (v.dy < 0) && (fabsf(v.dy) > fabsf(v.dx)); // vertical-dominant
    v.exceedsThreshold = v.magnitude > SWIPE_MIN_DISTANCE;
    return v;
}

// ─────────────────────────────────────────────
// MARK: - UIWindow Hook
// ─────────────────────────────────────────────

%hook UIWindow

- (void)sendEvent:(UIEvent *)event {
    %orig;

    // Gate: once patched or swipe already consumed, do nothing
    if (atomic_load(&gPatchApplied))  return;
    if (atomic_load(&gSwipeConsumed)) return;

    if (event.type != UIEventTypeTouches) return;

    NSSet<UITouch *> *touches = [event touchesForWindow:self];
    if (!touches.count) return;

    for (UITouch *touch in touches) {
        switch (touch.phase) {

            case UITouchPhaseBegan: {
                gTracker.origin  = [touch locationInView:nil];
                gTracker.current = gTracker.origin;
                gTracker.active  = YES;
                break;
            }

            case UITouchPhaseMoved: {
                if (!gTracker.active) break;
                gTracker.current = [touch locationInView:nil];

                SwipeVector v = computeVector(gTracker.origin, gTracker.current);

                // Condition: upward, dominant axis, > 5px
                if (v.isUpward && v.exceedsThreshold) {
                    // Consume this swipe -- one shot
                    bool expected = false;
                    if (atomic_compare_exchange_strong(&gSwipeConsumed, &expected, true)) {
                        atomic_store(&gPatchTriggered, true);
                        NSLog(@"%s Upward swipe %.1fpx -- triggering scan",
                              LOG_TAG, v.magnitude);

                        // Fire async so we don't block the touch pipeline
                        dispatch_async(
                            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
                            ^{ performFullScan(); }
                        );
                    }
                }
                break;
            }

            case UITouchPhaseCancelled:
            case UITouchPhaseEnded: {
                gTracker.active = NO;
                break;
            }

            default: break;
        }
    }
}

%end

// ─────────────────────────────────────────────
// MARK: - Constructor
// ─────────────────────────────────────────────

%ctor {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if ([bundleID isEqualToString:TARGET_BUNDLE_ID]) {
            NSLog(@"%s Loaded in target app (%@) -- pattern: 626F6479 -> 68656164 | trigger: upward swipe >%.0fpx",
                  LOG_TAG, bundleID, SWIPE_MIN_DISTANCE);
            %init;
        } else {
            NSLog(@"%s Loaded into different app (%@). Ignored.", LOG_TAG, bundleID);
        }
    }
}
