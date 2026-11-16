#import "MusicBridge.h"
#import <ScriptingBridge/ScriptingBridge.h>
#import <AppKit/AppKit.h>

// Narrow declarations for Spotify desktop's public Apple Events dictionary.
// Duration is milliseconds; playerPosition is seconds. No private MediaRemote API.
@interface OruviSpotifyTrack : SBObject
@property (copy, readonly) NSString *id;
@property (copy, readonly) NSString *name;
@property (copy, readonly) NSString *artist;
@property (copy, readonly) NSString *album;
@property (copy, readonly) NSString *artworkUrl;
@property (readonly) NSInteger duration;
@end
@interface OruviSpotifyApplication : SBApplication
@property (readonly) OruviSpotifyTrack *currentTrack;
@property (readonly) NSInteger playerState;
@property double playerPosition;
@property BOOL shuffling;
@property BOOL repeating;
- (void)playpause;
- (void)nextTrack;
- (void)previousTrack;
@end
@interface OruviSpotifyState : NSObject <SBApplicationDelegate>
@property (strong) OruviSpotifyApplication *app;
@property (strong) NSError *error;
@property (copy) NSDictionary *options;
@property double optionsReadAt;
@end
@implementation OruviSpotifyState
- (instancetype)init {
    if ((self = [super init])) {
        self.app = (OruviSpotifyApplication *)[[SBApplication alloc] initWithBundleIdentifier:@"com.spotify.client"];
        self.app.delegate = self;
        self.app.timeout = 45;
        self.optionsReadAt = -INFINITY;
    }
    return self;
}
- (id)eventDidFail:(const AppleEvent *)event withError:(NSError *)error { self.error = error; return nil; }
@end
static OruviSpotifyState *Spotify(void) {
    static OruviSpotifyState *value; static dispatch_once_t once;
    dispatch_once(&once, ^{ value = [OruviSpotifyState new]; }); return value;
}
static NSString *SpotifyText(id value) { return [value isKindOfClass:NSString.class] ? value : @""; }
static NSDictionary *SpotifyFailure(OruviSpotifyState *state) {
    return @{ @"status": state.error.code == -1743 ? @"denied" : @"error",
              @"message": state.error.code == -1743 ? @"Autoriza Spotify en Privacidad y seguridad > Automatización." : @"Reconectando con Spotify…" };
}
NSDictionary *OruviReadSpotifySnapshot(void) {
    @autoreleasepool {
        // Do not initialize a scripting proxy unless Spotify is actually running.
        if ([NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.spotify.client"].count == 0) return @{ @"status": @"notRunning" };
        OruviSpotifyState *bridge = Spotify(); bridge.error = nil;
        if (!bridge.app || !bridge.app.isRunning) return @{ @"status": @"notRunning" };
        @try {
            NSInteger state = bridge.app.playerState;
            if (bridge.error) return SpotifyFailure(bridge);
            if (state == 'kPSS') return @{ @"status": @"stopped" };
            OruviSpotifyTrack *track = [bridge.app.currentTrack get];
            if (bridge.error) return SpotifyFailure(bridge);
            if (!track) return @{ @"status": @"transition" };
            NSString *identifier = SpotifyText(track.id), *title = SpotifyText(track.name);
            if (bridge.error) return SpotifyFailure(bridge);
            NSString *artist = SpotifyText(track.artist), *album = SpotifyText(track.album);
            double duration = MAX(0, track.duration) / 1000.0;
            if (bridge.error) return SpotifyFailure(bridge);
            NSString *artwork = SpotifyText(track.artworkUrl);
            if (bridge.error.code == -1743) return SpotifyFailure(bridge);
            bridge.error = nil; // Missing artwork is not a playback failure.
            double before = NSProcessInfo.processInfo.systemUptime;
            double position = bridge.app.playerPosition;
            double after = NSProcessInfo.processInfo.systemUptime;
            if (bridge.error) return SpotifyFailure(bridge);
            NSString *endID = SpotifyText(bridge.app.currentTrack.id);
            NSInteger endState = bridge.app.playerState;
            if (bridge.error) return SpotifyFailure(bridge);
            if (!identifier.length || !title.length || ![identifier isEqualToString:endID] || state != endState) return @{ @"status": @"transition" };
            NSMutableDictionary *result = [@{ @"status": @"ok", @"id": identifier, @"title": title, @"artist": artist, @"album": album,
                  @"duration": @(duration), @"position": @(isfinite(position) ? MAX(0, position) : 0),
                  @"sampleUptime": @((before + after) * 0.5), @"playing": @(state == 'kPSP'),
                  @"artworkURL": artwork, @"repeatOneSupported": @NO } mutableCopy];
            // Queue settings change much less often than position. An option read must
            // neither delay every sample nor turn valid playback metadata into an error.
            if (NSProcessInfo.processInfo.systemUptime - bridge.optionsReadAt >= 5) {
                BOOL shuffle = bridge.app.shuffling;
                BOOL repeated = !bridge.error && bridge.app.repeating;
                bridge.optionsReadAt = NSProcessInfo.processInfo.systemUptime;
                if (!bridge.error) {
                    bridge.options = @{ @"shuffle": @(shuffle), @"repeatMode": @(repeated ? 1 : 0) };
                }
            }
            if (bridge.options) [result addEntriesFromDictionary:bridge.options];
            return result;
        } @catch (NSException *exception) { return @{ @"status": @"error", @"message": @"Spotify no respondió." }; }
    }
}
NSDictionary *OruviSpotifyCommand(NSString *command, double position, BOOL checkPlayerState) {
    @autoreleasepool {
        if ([NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.spotify.client"].count == 0) return @{ @"status": @"notRunning" };
        OruviSpotifyState *bridge = Spotify(); bridge.error = nil;
        if (!bridge.app || !bridge.app.isRunning) return @{ @"status": @"notRunning" };
        @try {
            if (checkPlayerState) {
                NSInteger state = bridge.app.playerState;
                if (bridge.error) return SpotifyFailure(bridge);
                if (state == 'kPSS') return @{ @"status": @"stopped" };
            }
            if ([command isEqualToString:@"toggle"]) [bridge.app playpause];
            else if ([command isEqualToString:@"next"]) [bridge.app nextTrack];
            else if ([command isEqualToString:@"previous"]) [bridge.app previousTrack];
            else if ([command isEqualToString:@"seek"] && isfinite(position)) bridge.app.playerPosition = MAX(0, position);
            else if ([command isEqualToString:@"shuffle"]) {
                BOOL current = bridge.app.shuffling;
                if (!bridge.error) bridge.app.shuffling = !current;
                bridge.optionsReadAt = -INFINITY;
            }
            else if ([command isEqualToString:@"repeat"]) {
                BOOL current = bridge.app.repeating;
                if (!bridge.error) bridge.app.repeating = !current;
                bridge.optionsReadAt = -INFINITY;
            }
            else return @{ @"status": @"error", @"message": @"Control no compatible." };
            return bridge.error ? SpotifyFailure(bridge) : @{ @"status": @"ok" };
        } @catch (NSException *exception) { return @{ @"status": @"error", @"message": @"Spotify no pudo ejecutar el control." }; }
    }
}
void OruviResetSpotifyBridge(void) {
    if (![NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.spotify.client"].count) return;
    OruviSpotifyState *bridge = Spotify();
    bridge.error = nil;
    bridge.options = nil;
    bridge.optionsReadAt = -INFINITY;
}
BOOL OruviValidateSpotifyBindings(void) {
    // A missing app is an expected state, not evidence that live controls were tested.
    if (![NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.spotify.client"]) return NO;
    return [Spotify().app respondsToSelector:@selector(currentTrack)] && [Spotify().app respondsToSelector:@selector(playpause)];
}
