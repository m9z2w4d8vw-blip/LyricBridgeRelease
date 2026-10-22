#import <UIKit/UIKit.h>
FOUNDATION_EXPORT NSArray<NSString *> *LyricBridgeDiagnosticRoots(void);
FOUNDATION_EXPORT NSArray<NSURL *> *LyricBridgeDiagnosticFiles(void);
FOUNDATION_EXPORT void LyricBridgeClearDiagnosticLogs(void);
FOUNDATION_EXPORT void LyricBridgeExportDiagnosticLogs(UIViewController *presenter);
@interface LyricBridgeLogController : UIViewController
@end
