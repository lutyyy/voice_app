#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 執行 block；裡面丟出 Objective-C 例外時回傳 NO（Swift 無法 catch 這種例外，會直接閃退）
BOOL VCTry(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
