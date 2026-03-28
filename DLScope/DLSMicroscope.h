#import <Foundation/Foundation.h>
#import <UIKit/UIImage.h>

@protocol DLSMicroscopeDelegate <NSObject>
- (void)microscopeDidReceiveFrame:(UIImage *)image;
- (void)microscopeDidUpdateStatus:(NSString *)status;
@optional
- (void)microscopeDidPressSnapButton;
@end

@interface DLSMicroscope : NSObject
@property (nonatomic, assign) id<DLSMicroscopeDelegate> delegate;
- (void)start;
- (void)stop;
@end
