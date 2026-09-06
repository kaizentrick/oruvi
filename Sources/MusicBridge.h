#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Snapshot, commands and reset share one serial playback queue. Never start audio implicitly.
NSDictionary<NSString *, id> *LumaReadMusicSnapshot(void);
NSDictionary<NSString *, id> *LumaMusicCommand(NSString *command, double position);
/// Call only on a separate serial artwork queue. A stalled cover never blocks playback reads.
NSData * _Nullable LumaReadMusicArtwork(NSString *expectedID, NSString *expectedTitle);
void LumaResetMusicBridge(void);
BOOL LumaValidateMusicBindings(void);
NS_ASSUME_NONNULL_END
