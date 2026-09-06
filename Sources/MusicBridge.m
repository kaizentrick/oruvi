#import "MusicBridge.h"
#import <AppKit/AppKit.h>
#import <ScriptingBridge/ScriptingBridge.h>

// Narrow interface from Music's public scripting dictionary. No private media APIs.
@interface LumaMusicArtwork : SBObject
@property (copy) id rawData;
@property (copy) id data;
@end
@interface LumaMusicTrack : SBObject
@property (copy, readonly) NSString *persistentID;
@property (copy) NSString *name;
@property (copy) NSString *artist;
@property (copy) NSString *album;
@property (readonly) double duration;
- (SBElementArray *)artworks;
@end
@interface LumaMusicApplication : SBApplication
@property (readonly) NSInteger playerState;
@property double playerPosition;
@property (readonly) LumaMusicTrack *currentTrack;
@property BOOL shuffleEnabled;
@property NSInteger songRepeat;
- (void)playpause;
- (void)nextTrack;
- (void)previousTrack;
@end
@interface LumaBridgeState : NSObject <SBApplicationDelegate>
@property (strong) LumaMusicApplication *app;
@property (strong) NSError *error;
@property double optionsReadAt;
@property (copy) NSDictionary *options;
@end
@implementation LumaBridgeState
- (instancetype)init {
    if ((self = [super init])) {
        self.app = (LumaMusicApplication *)[[SBApplication alloc] initWithBundleIdentifier:@"com.apple.Music"];
        self.app.delegate = self;
        self.app.timeout = 45; // 0.75 s per Apple Event; fail early instead of queuing indefinitely.
    }
    return self;
}
- (id)eventDidFail:(const AppleEvent *)event withError:(NSError *)error { self.error = error; return nil; }
@end
static LumaBridgeState *PlaybackBridge(void) {
    static LumaBridgeState *bridge; static dispatch_once_t once;
    dispatch_once(&once, ^{ bridge = [LumaBridgeState new]; }); return bridge;
}
static LumaBridgeState *ArtworkBridge(void) {
    // Separate application proxy and queue: a cover timeout cannot stall the playback clock.
    static LumaBridgeState *bridge; static dispatch_once_t once;
    dispatch_once(&once, ^{ bridge = [LumaBridgeState new]; }); return bridge;
}
static NSString *Text(id value) { return [value isKindOfClass:NSString.class] ? value : @""; }
static NSString *Identity(NSString *identifier, NSString *title) {
    return identifier.length ? identifier : [@"stream:" stringByAppendingString:title];
}
static NSDictionary *Failure(LumaBridgeState *bridge) {
    BOOL denied = bridge.error.code == -1743;
    return @{ @"status": denied ? @"denied" : @"error", @"errorCode": @(bridge.error.code),
              @"message": denied ? @"Autoriza Música en Privacidad y seguridad > Automatización." : @"Reconectando con Música…" };
}
NSDictionary<NSString *, id> *LumaReadMusicSnapshot(void) {
    @autoreleasepool {
        LumaBridgeState *bridge = PlaybackBridge(); bridge.error = nil;
        if (![bridge.app isRunning]) return @{ @"status": @"notRunning" };
        @try {
            NSInteger state = bridge.app.playerState;
            if (bridge.error) return Failure(bridge);
            if (state == 'kPSS') return @{ @"status": @"stopped" };
            // Resolve the dynamic current-track specifier on EVERY sample. Never use an
            // indefinite metadata cache keyed only by a possibly reused streaming ID.
            LumaMusicTrack *track = [bridge.app.currentTrack get];
            if (bridge.error) return Failure(bridge);
            if (!track) return @{ @"status": @"transition" };
            NSString *title = Text(track.name);
            if (bridge.error) return Failure(bridge);
            if (!title.length) return @{ @"status": @"transition" };
            NSString *identifier = Text(track.persistentID);
            if (bridge.error) return Failure(bridge);
            NSString *artist = Text(track.artist);
            if (bridge.error) return Failure(bridge);
            NSString *album = Text(track.album);
            if (bridge.error) return Failure(bridge);
            double duration = track.duration;
            if (bridge.error) return Failure(bridge);
            // Queue options are not timing-critical. Cache them briefly instead of adding
            // two IPC round trips to every sample; invalidate after an explicit control.
            if (NSProcessInfo.processInfo.systemUptime - bridge.optionsReadAt >= 5 || !bridge.options) {
                BOOL shuffled = bridge.app.shuffleEnabled;
                NSInteger repeated = bridge.app.songRepeat;
                if (!bridge.error) {
                    bridge.options = @{ @"shuffle": @(shuffled), @"repeatMode": @(repeated == 'kAll' ? 1 : (repeated == 'kRp1' ? 2 : 0)) };
                    bridge.optionsReadAt = NSProcessInfo.processInfo.systemUptime;
                }
                if (bridge.error.code == -1743) return Failure(bridge);
                bridge.error = nil;
            }
            double before = NSProcessInfo.processInfo.systemUptime;
            double position = bridge.app.playerPosition;
            double after = NSProcessInfo.processInfo.systemUptime;
            if (bridge.error) return Failure(bridge);
            // Reject a mixed snapshot when Music changes track during the property reads.
            LumaMusicTrack *current = [bridge.app.currentTrack get];
            if (bridge.error) return Failure(bridge);
            NSString *endTitle = Text(current.name);
            if (bridge.error) return Failure(bridge);
            NSString *endID = Text(current.persistentID);
            if (bridge.error) return Failure(bridge);
            NSInteger endState = bridge.app.playerState;
            if (bridge.error) return Failure(bridge);
            if (![title isEqualToString:endTitle] || ![identifier isEqualToString:endID] || endState != state)
                return @{ @"status": @"transition" };
            NSMutableDictionary *snapshot = [@{ @"status": @"ok", @"id": Identity(identifier, title), @"title": title, @"artist": artist,
                      @"album": album, @"duration": @(isfinite(duration) ? MAX(0, duration) : 0),
                      @"position": @(isfinite(position) ? MAX(0, position) : 0),
                      @"sampleUptime": @((before + after) * 0.5), @"roundTrip": @(after - before),
                      @"playing": @(endState == 'kPSP') } mutableCopy];
            if (bridge.options) [snapshot addEntriesFromDictionary:bridge.options];
            return snapshot;
        } @catch (NSException *exception) { return @{ @"status": @"error", @"message": @"Reconectando con Música…" }; }
    }
}
NSDictionary<NSString *, id> *LumaMusicCommand(NSString *command, double position) {
    @autoreleasepool {
        LumaBridgeState *bridge = PlaybackBridge(); bridge.error = nil;
        if (![bridge.app isRunning]) return @{ @"status": @"notRunning" };
        @try {
            if ([command isEqualToString:@"toggle"]) [bridge.app playpause];
            else if ([command isEqualToString:@"next"]) [bridge.app nextTrack];
            else if ([command isEqualToString:@"previous"]) [bridge.app previousTrack];
            else if ([command isEqualToString:@"seek"] && isfinite(position)) bridge.app.playerPosition = MAX(0, position);
            else if ([command isEqualToString:@"shuffle"]) {
                BOOL old = bridge.app.shuffleEnabled;
                if (!bridge.error) bridge.app.shuffleEnabled = !old;
                bridge.optionsReadAt = 0;
            }
            else if ([command isEqualToString:@"repeat"]) {
                NSInteger old = bridge.app.songRepeat;
                if (!bridge.error) bridge.app.songRepeat = old == 'kRpO' ? 'kAll' : (old == 'kAll' ? 'kRp1' : 'kRpO');
                bridge.optionsReadAt = 0;
            }
            else return @{ @"status": @"error", @"message": @"Comando no válido." };
            return bridge.error ? Failure(bridge) : @{ @"status": @"ok" };
        } @catch (NSException *exception) { return @{ @"status": @"error", @"message": @"Música no pudo ejecutar el control." }; }
    }
}
static NSData *ArtworkBytes(id raw) {
    NSData *data = nil;
    if ([raw isKindOfClass:NSData.class]) data = raw;
    else if ([raw isKindOfClass:NSAppleEventDescriptor.class]) data = [(NSAppleEventDescriptor *)raw data];
    else if ([raw isKindOfClass:NSImage.class]) data = [(NSImage *)raw TIFFRepresentation];
    return data.length > 0 && data.length <= 8 * 1024 * 1024 ? data : nil;
}
NSData *LumaReadMusicArtwork(NSString *expectedID, NSString *expectedTitle) {
    @autoreleasepool {
        LumaBridgeState *bridge = ArtworkBridge(); bridge.error = nil;
        if (![bridge.app isRunning]) return nil;
        @try {
            LumaMusicTrack *track = [bridge.app.currentTrack get];
            if (bridge.error || !track) return nil;
            NSString *title = Text(track.name);
            if (bridge.error || ![title isEqualToString:expectedTitle]) return nil;
            NSString *identifier = Identity(Text(track.persistentID), title);
            if (bridge.error || ![identifier isEqualToString:expectedID]) return nil;
            SBElementArray *artworks = [track artworks];
            if (bridge.error || artworks.count == 0 || bridge.error) return nil;
            LumaMusicArtwork *artwork = [artworks objectAtIndex:0];
            NSData *data = ArtworkBytes(artwork.rawData);
            if (bridge.error) return nil;
            if (!data) data = ArtworkBytes(artwork.data);
            return bridge.error ? nil : data;
        } @catch (NSException *exception) { return nil; }
    }
}
void LumaResetMusicBridge(void) { PlaybackBridge().error = nil; PlaybackBridge().options = nil; PlaybackBridge().optionsReadAt = 0; }
BOOL LumaValidateMusicBindings(void) {
    LumaMusicApplication *app = PlaybackBridge().app;
    return app != nil && [app respondsToSelector:@selector(playerState)] && [app respondsToSelector:@selector(playerPosition)] &&
           [app respondsToSelector:@selector(currentTrack)] && [app respondsToSelector:@selector(playpause)] && [app respondsToSelector:@selector(nextTrack)];
}
