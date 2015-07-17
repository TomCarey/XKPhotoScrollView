//
//  XKDeviceRotationPhotoScrollViewController.m
//  XKPhotoScrollView
//
//  Created by Karl von Randow on 17/07/15.
//  Copyright (c) 2015 Karl von Randow. All rights reserved.
//

#import "XKDeviceRotationPhotoScrollViewController.h"

@import XKPhotoScrollView;

@implementation XKDeviceRotationPhotoScrollViewController

- (void)loadView
{
    XKPhotoScrollView *photoScrollView = [XKPhotoScrollView new];
    photoScrollView.backgroundColor = [UIColor blackColor];
    photoScrollView.currentIndexPath = self.indexPath;
    photoScrollView.dataSource = self.dataSource;
    photoScrollView.delegate = self.delegate;
    
    _photoScrollView = photoScrollView;
    self.view = photoScrollView;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSUInteger)supportedInterfaceOrientations
{
    return UIInterfaceOrientationMaskPortrait;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(orientationDidChangeNotification:) name:UIDeviceOrientationDidChangeNotification object:nil];
    
    [self.photoScrollView setOrientation:[UIDevice currentDevice].orientation animated:NO];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    
    [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIDeviceOrientationDidChangeNotification object:nil];
}

#pragma mark - Notifications

- (void)orientationDidChangeNotification:(NSNotification *)notification
{
    const UIDeviceOrientation orientation = [UIDevice currentDevice].orientation;
    
    if (_dismissOnPortrait && UIDeviceOrientationIsPortrait(orientation)) {
        [self dismissViewControllerAnimated:YES completion:NULL];
    } else {
        [self.photoScrollView setOrientation:orientation animated:YES];
    }
}

#pragma mark - Properties

- (void)setIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath != _indexPath) {
        _indexPath = indexPath;
        
        self.photoScrollView.currentIndexPath = indexPath;
    }
}

@end
