//
//  AppDelegate.m
//  ScribbleTest
//
//  Created by Isaac Neumann on 1/28/25.
//

#import "AppDelegate.h"
#import "ScreensaverView.h"

@interface AppDelegate ()

@property (strong) NSWindow *window;
@property (strong) NSTimer *animationTimer; // Add a timer property

@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    // 1) Create a window just like before:
    NSRect frame = NSMakeRect(0, 0, 800, 600);
    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskResizable | NSWindowStyleMaskClosable;

    self.window = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:style
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = @"Scribble Preview";
    
    // 2) Allow it to go fullscreen:
    [self.window setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];
    
    // 3) Create your ScribbleView:
    ScribbleView *view = [[ScribbleView alloc] initWithFrame:frame isPreview:NO];
    [self.window setContentView:view];
    
    // 4) Make the window key and visible:
    [self.window makeKeyAndOrderFront:nil];
    
    // 5) Toggle to fullscreen:
    [self.window toggleFullScreen:nil];
    
    // 6) Start the built-in screensaver animation:
    [view startAnimation];
}


- (void)applicationWillTerminate:(NSNotification *)aNotification {
    // Stop animation properly
    ScribbleView *view = (ScribbleView *)self.window.contentView;
    [view stopAnimation];
}


@end
