#import "DLSViewController.h"
#import <QuartzCore/QuartzCore.h>
#import <AssetsLibrary/AssetsLibrary.h>

#define BOTTOM_BAR_HEIGHT 53.0

@implementation DLSViewController {
    UIImageView *_imageView;
    UIView *_bottomBar;
    UILabel *_statusLabel;
    UIButton *_shutterButton;
    UIButton *_thumbnailButton;
    UIImageView *_thumbnailImageView;
    UIImage *_lastFrame;
    DLSMicroscope *_microscope;
    ALAssetsLibrary *_assetsLibrary;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    _assetsLibrary = [[ALAssetsLibrary alloc] init];

    CGRect bounds = self.view.bounds;
    // iPhone 4 portrait: 320 x 480
    // Image is 3:4 portrait → 320pt wide needs 427pt tall
    CGFloat viewfinderH = bounds.size.height - BOTTOM_BAR_HEIGHT;

    // --- Viewfinder (live feed) ---
    _imageView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, bounds.size.width, viewfinderH)];
    _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _imageView.contentMode = UIViewContentModeScaleAspectFit;
    _imageView.backgroundColor = [UIColor blackColor];
    [self.view addSubview:_imageView];

    // --- Status label (overlay on viewfinder, centered) ---
    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, (viewfinderH - 30) / 2.0,
                                                              bounds.size.width, 30)];
    _statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    _statusLabel.textColor = [UIColor whiteColor];
    _statusLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.6];
    _statusLabel.font = [UIFont boldSystemFontOfSize:14];
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.text = @"Connecting to microscope...";
    _statusLabel.layer.cornerRadius = 6.0;
    _statusLabel.clipsToBounds = YES;
    [self.view addSubview:_statusLabel];

    // --- Bottom bar ---
    CGFloat bottomY = bounds.size.height - BOTTOM_BAR_HEIGHT;
    _bottomBar = [[UIView alloc] initWithFrame:CGRectMake(0, bottomY,
                                                           bounds.size.width, BOTTOM_BAR_HEIGHT)];
    _bottomBar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    _bottomBar.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1.0];
    [self.view addSubview:_bottomBar];

    // Top edge line
    UIView *borderLine = [[UIView alloc] initWithFrame:CGRectMake(0, 0, bounds.size.width, 1)];
    borderLine.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    borderLine.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1.0];
    [_bottomBar addSubview:borderLine];

    // --- Shutter button (center, 40pt) ---
    CGFloat shutterSize = 40.0;
    CGFloat shutterX = (bounds.size.width - shutterSize) / 2.0;
    CGFloat shutterY = (BOTTOM_BAR_HEIGHT - shutterSize) / 2.0;
    _shutterButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _shutterButton.frame = CGRectMake(shutterX, shutterY, shutterSize, shutterSize);
    _shutterButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    _shutterButton.layer.cornerRadius = shutterSize / 2.0;
    _shutterButton.layer.borderWidth = 3.0;
    _shutterButton.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:1.0].CGColor;
    _shutterButton.backgroundColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    [_shutterButton addTarget:self action:@selector(shutterTapped) forControlEvents:UIControlEventTouchUpInside];
    [_bottomBar addSubview:_shutterButton];

    // Inner white circle
    CGFloat innerSize = shutterSize - 8.0;
    UIView *innerCircle = [[UIView alloc] initWithFrame:CGRectMake(4, 4, innerSize, innerSize)];
    innerCircle.layer.cornerRadius = innerSize / 2.0;
    innerCircle.backgroundColor = [UIColor whiteColor];
    innerCircle.userInteractionEnabled = NO;
    [_shutterButton addSubview:innerCircle];

    // --- Thumbnail button (bottom-left, 36pt) ---
    CGFloat thumbSize = 36.0;
    CGFloat thumbY = (BOTTOM_BAR_HEIGHT - thumbSize) / 2.0;
    _thumbnailButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _thumbnailButton.frame = CGRectMake(10, thumbY, thumbSize, thumbSize);
    _thumbnailButton.layer.cornerRadius = 4.0;
    _thumbnailButton.layer.borderWidth = 1.5;
    _thumbnailButton.layer.borderColor = [UIColor colorWithWhite:0.35 alpha:1.0].CGColor;
    _thumbnailButton.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
    _thumbnailButton.clipsToBounds = YES;
    [_thumbnailButton addTarget:self action:@selector(thumbnailTapped) forControlEvents:UIControlEventTouchUpInside];
    [_bottomBar addSubview:_thumbnailButton];

    // Image view inside thumbnail button
    _thumbnailImageView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, thumbSize, thumbSize)];
    _thumbnailImageView.contentMode = UIViewContentModeScaleAspectFill;
    _thumbnailImageView.clipsToBounds = YES;
    _thumbnailImageView.userInteractionEnabled = NO;
    [_thumbnailButton addSubview:_thumbnailImageView];

    // --- Start microscope ---
    _microscope = [[DLSMicroscope alloc] init];
    _microscope.delegate = self;
    [_microscope start];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return orientation == UIInterfaceOrientationPortrait;
}

#pragma mark - Actions

- (void)shutterTapped {
    [self captureFrame];
}

- (void)thumbnailTapped {
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"photos-redirect://"]];
}

- (void)captureFrame {
    if (!_lastFrame) return;

    // Flash animation
    UIView *flash = [[UIView alloc] initWithFrame:_imageView.frame];
    flash.backgroundColor = [UIColor whiteColor];
    flash.alpha = 0.0;
    [self.view insertSubview:flash aboveSubview:_imageView];

    [UIView animateWithDuration:0.1 animations:^{
        flash.alpha = 1.0;
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.2 animations:^{
            flash.alpha = 0.0;
        } completion:^(BOOL finished2) {
            [flash removeFromSuperview];
        }];
    }];

    // Save via ALAssetsLibrary
    _thumbnailImageView.image = _lastFrame;

    [_assetsLibrary writeImageToSavedPhotosAlbum:[_lastFrame CGImage]
                                     orientation:(ALAssetOrientation)_lastFrame.imageOrientation
                                 completionBlock:nil];
}

#pragma mark - DLSMicroscopeDelegate

- (void)microscopeDidReceiveFrame:(UIImage *)image {
    _lastFrame = image;
    _imageView.image = image;
    if (!_statusLabel.hidden) {
        _statusLabel.hidden = YES;
    }
}

- (void)microscopeDidUpdateStatus:(NSString *)status {
    _statusLabel.hidden = NO;
    _statusLabel.text = status;
}

- (void)microscopeDidPressSnapButton {
    [self captureFrame];
}

@end
