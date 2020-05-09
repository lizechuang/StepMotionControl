//
//  StepMotionManager.m
//  MotionControl
//
//  Created by lee on 2020/4/30.
//  Copyright © 2020 lee. All rights reserved.
//

#import "StepMotionManager.h"
#import <CoreMotion/CoreMotion.h>
#import <CoreLocation/CoreLocation.h>
#import "StepMotionRequest.h"


// 设备传感器更新间隔 (秒)
#define ACCELERO_UPDATE_TIME 0.1

// 定位功能最小更新距离 (米)
#define LOCATION_UPDATE_MIN 1

@interface StepMotionManager ()<CLLocationManagerDelegate>

@property (nonatomic, strong) CLLocationManager *locationManager;
@property (nonatomic, strong) CMMotionManager *motionManager;

@property (nonatomic, retain) NSMutableArray *rawSteps; // 设备传感器采集的原始数组
@property (nonatomic, retain) NSMutableArray *presentSteps; // 步数数组
@property (nonatomic, copy) StepChangeBlock stepChangeBlock;

@end

@implementation StepMotionManager

static StepMotionManager *sharedManager;

+ (StepMotionManager *)sharedManager {
    @synchronized (self) {
        if (!sharedManager) {
            sharedManager = [[StepMotionManager alloc] init];
        }
    }
    return sharedManager;
}

//开始监控步数变化
- (void)startMonitorStepChanges:(StepChangeBlock)change {
    self.stepChangeBlock = change;
    self.step = 0;

    self.motionManager = [[CMMotionManager alloc] init];
    if (!self.motionManager.isAccelerometerAvailable || !self.motionManager.isGyroAvailable) {
        NSLog(@"加速计，陀螺仪传感器无法使用");
        return;
    } else {
        self.motionManager.accelerometerUpdateInterval = ACCELERO_UPDATE_TIME;
        self.motionManager.gyroUpdateInterval = ACCELERO_UPDATE_TIME;
    }

    if ([CLLocationManager locationServicesEnabled]) {
        self.locationManager = [[CLLocationManager alloc] init];
        self.locationManager.delegate = self;
        [self.locationManager requestAlwaysAuthorization];
        [self.locationManager requestWhenInUseAuthorization];
        self.locationManager.desiredAccuracy = kCLLocationAccuracyBest;
        self.locationManager.distanceFilter = LOCATION_UPDATE_MIN;
        [self.locationManager startUpdatingLocation];
    }
    
    [self startMotionManager];
}

//结束监控步数变化
- (void)endMonitorStepChanges {
    [self.motionManager stopAccelerometerUpdates];
    [self.motionManager stopGyroUpdates];
    [self.locationManager stopUpdatingLocation];
}

- (void)startMotionManager {
    @try {
        //判断CMMotionManager是否支持加速度计、陀螺仪
        if (!self.motionManager.accelerometerAvailable || !self.motionManager.gyroAvailable) {
            NSLog(@"CMMotionManager不支持加速度计、陀螺仪，无法获取相关数据");
            return;
        }

        if (self.rawSteps == nil) {
            self.rawSteps = [[NSMutableArray alloc] init];
        } else {
            [self.rawSteps removeAllObjects];
        }

        NSOperationQueue *queue = [[NSOperationQueue alloc] init];
        // 实时获取相关数据
        __weak typeof (self) weakSelf = self;
        [self.motionManager startGyroUpdatesToQueue:queue withHandler:^(CMGyroData * _Nullable gyroData, NSError * _Nullable error) {}];
        [self.motionManager startAccelerometerUpdatesToQueue:queue withHandler:^(CMAccelerometerData * _Nullable accelerometerData, NSError * _Nullable error) {
            if (!weakSelf.motionManager.isAccelerometerActive || !weakSelf.motionManager.isGyroActive) {
                NSLog(@"设备传感器状态错误");
                return;
            }
            //创建步数模型
            StepModel *stepModel = [[StepModel alloc] init];

            //三个方向加速度值
            stepModel.accelerationX =  accelerometerData.acceleration.x;
            stepModel.accelerationY =  accelerometerData.acceleration.y;
            stepModel.accelerationZ =  accelerometerData.acceleration.z;

            //旋转矢量
            stepModel.rotatingVectorX =  weakSelf.motionManager.gyroData.rotationRate.x;
            stepModel.rotatingVectorY =  weakSelf.motionManager.gyroData.rotationRate.y;
            stepModel.rotatingVectorZ =  weakSelf.motionManager.gyroData.rotationRate.z;

            double g = sqrt(pow(stepModel.accelerationX, 2) + pow(stepModel.accelerationY, 2) + pow(stepModel.accelerationZ, 2)) - 1;
            stepModel.g = g;

            stepModel.latitude = weakSelf.locationManager.location.coordinate.latitude;
            stepModel.longitude = weakSelf.locationManager.location.coordinate.longitude;
            //记录时间点
            stepModel.date = [NSDate date];
            NSDateFormatter *df = [[NSDateFormatter alloc] init];
            df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
            NSString *dateStr = [df stringFromDate:stepModel.date];
            df = nil;
            stepModel.record_time = dateStr;

            [weakSelf.rawSteps addObject:stepModel];

            // 每采集10条数据，大约1.0s的数据时，进行分析
            if (weakSelf.rawSteps.count == 10) {
                //原始数据缓存数组
                NSMutableArray *arrBuffer = [[NSMutableArray alloc] init];

                arrBuffer = [weakSelf.rawSteps copy];
                [weakSelf.rawSteps removeAllObjects];

                // 踩点数组
                NSMutableArray *tempSteps = [[NSMutableArray alloc] init];

                //遍历原始数据缓存数组数组
                for (int i = 1; i < arrBuffer.count - 2; i++) {
                    //如果数组个数大于3,继续,否则跳出循环,用连续的三个点,要判断其振幅是否一样
                    if (![arrBuffer objectAtIndex:i - 1] || ![arrBuffer objectAtIndex:i] ||![arrBuffer objectAtIndex:i + 1]) {
                        continue;
                    }
                    StepModel *bufferPrevious = (StepModel *)[arrBuffer objectAtIndex:i - 1];
                    StepModel *bufferCurrent = (StepModel *)[arrBuffer objectAtIndex:i];
                    StepModel *bufferNext = (StepModel *)[arrBuffer objectAtIndex:i + 1];
                    //控制震动幅度,根据震动幅度让其加入踩点数组
                    if (bufferCurrent.g < -0.12 && bufferCurrent.g < bufferPrevious.g && bufferCurrent.g < bufferNext.g) {
                        [tempSteps addObject:bufferCurrent];
                    }
                }

                //初始化数据
                if (weakSelf.presentSteps == nil) {
                    weakSelf.presentSteps = [[NSMutableArray alloc] init];
                }

                //踩点处理
                for (int j = 0; j < tempSteps.count; j++) {
                    StepModel *currentStep = (StepModel *)[tempSteps objectAtIndex:j];
                    if (weakSelf.motionManager.isAccelerometerActive && weakSelf.motionManager.isGyroActive) {
                        weakSelf.step++;
                        currentStep.step = (int)weakSelf.step;
                        [weakSelf.presentSteps addObject:currentStep];
                        if (weakSelf.stepChangeBlock) {
                            [weakSelf handleStepsDidChangeWithStepModel:currentStep];
                        }
                        NSLog(@"步数%ld", weakSelf.step);
                    }
                }
            }
        }];
    } @catch (NSException *exception) {
        NSLog(@"Exception: %@", exception);
        return;
    }
}

// 步数发生变化时处理逻辑
- (void)handleStepsDidChangeWithStepModel:(StepModel *)stepModel {
    self.stepChangeBlock(stepModel);
    StepMotionRequest *request = [[StepMotionRequest alloc] init];
    [request startWithStepModel:stepModel SuccessHandler:^(__kindof StepMotionRequest *request, id responseObj) {
        
    } failureHandler:^(__kindof StepMotionRequest *request, NSError *error) {
        
    }];
}


#pragma mark -CLLocationManagerDelegate
- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    NSLog(@"定位失败, 错误: %@",error);
    switch([error code]) {
        case kCLErrorDenied: { // 用户禁止了定位权限
        } break;
        default: break;
    }
}

@end