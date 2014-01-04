/*
	This file is part the backup utility Mathusalem for Mac OS X.
	Copyright (C) 2008-2009 Pierre-Olivier Latour <info@pol-online.net>
	
	This program is free software: you can redistribute it and/or modify
	it under the terms of the GNU General Public License as published by
	the Free Software Foundation, either version 3 of the License, or
	(at your option) any later version.
	
	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.
	
	You should have received a copy of the GNU General Public License
	along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

#import <Foundation/Foundation.h>

#define kBackupPasswordKeychainService			@"Mathusalem Backup Password"

#define kBackupControllerErrorDomain			@"BackupControllerErrorDomain"
#define kBackupControllerFatalErrorKey			@"BackupControllerFatalErrorKey" //NSNumber - BOOL
#define kBackupControllerPathsKey				@"BackupControllerPathsKey" //NSArray of NSString

#define kBackupScannerUserInfoKey_DiskImage		@"diskImage" //NSNumber - BOOL
#define kBackupScannerUserInfoKey_Compressed	@"compressed" //NSNumber - BOOL
#define kBackupScannerUserInfoKey_Segment		@"segment" //NSNumber - NSInteger
#define kBackupScannerUserInfoKey_Atomic		@"atomic" //NSNumber - BOOL
#define kBackupScannerUserInfoKey_FullBackup	@"fullBackup" //NSNumber - BOOL
#define kBackupScannerUserInfoKey_PasswordMD5	@"passwordMD5" //NSData

#define kBackupScannerUserInfoKey_StartDate		@"startDate" //NSDate
#define kBackupScannerUserInfoKey_EndDate		@"endDate" //NSDate
#define kBackupScannerUserInfoKey_Differences	@"differences" //NSDictionary of NSArray of NSString

typedef enum {
	kBackupControllerStatus_Segment_Begin = -2,
	kBackupControllerStatus_Segment_End = -1,
	kBackupControllerStatus_Idle = 0,
	kBackupControllerStatus_AccessingDestination,
	kBackupControllerStatus_CheckingDestination,
	kBackupControllerStatus_ScanningSource,
	kBackupControllerStatus_CopyingFiles,
	kBackupControllerStatus_CreatingArchive,
	kBackupControllerStatus_ExtractingArchive,
	kBackupControllerStatus_CreatingDiskImage,
	kBackupControllerStatus_MountingDiskImage,
	kBackupControllerStatus_DownloadingFile,
	kBackupControllerStatus_UploadingFile,
	kBackupControllerStatus_DeletingFile,
	kBackupControllerStatus_RunningExecutable
} BackupControllerStatus;

typedef enum {
	kBackupControllerErrorCode_None = 0,
	kBackupControllerErrorCode_Scanning,
	kBackupControllerErrorCode_RetrievingItemInfo,
	kBackupControllerErrorCode_SettingItemPermissions,
	kBackupControllerErrorCode_MovingItem,
	kBackupControllerErrorCode_DeletingItem,
	kBackupControllerErrorCode_CopyingItem,
	kBackupControllerErrorCode_CreatingDirectory,
	kBackupControllerErrorCode_WritingFile,
	kBackupControllerErrorCode_CreatingArchive,
	kBackupControllerErrorCode_ExtractingArchive,
	kBackupControllerErrorCode_CreatingDiskImage,
	kBackupControllerErrorCode_MountingDiskImage,
	kBackupControllerErrorCode_UnmountingDiskImage,
	kBackupControllerErrorCode_ReadingBOMFile,
	kBackupControllerErrorCode_RetrievingBOMEntry,
	kBackupControllerErrorCode_CheckingDestination,
	kBackupControllerErrorCode_DownloadingFile,
	kBackupControllerErrorCode_UploadingFile,
	kBackupControllerErrorCode_DeletingFile,
	kBackupControllerErrorCode_RunningExecutable,
	kBackupControllerErrorCode_CheckingLocalDiskSpace
} BackupControllerErrorCode;

@class BackupController, FileTransferController;

@protocol BackupControllerDelegate <NSObject>
@required
- (BOOL) backupControllerShouldAbort:(BackupController*)controller;
- (BOOL) backupControllerShouldAbortCurrentFileTransfer:(BackupController*)controller; //This will trigger a call to -backupController:shouldRetryFileTransferWithURL:
- (void) backupController:(BackupController*)controller didUpdateStatus:(BackupControllerStatus)status currentValue:(NSUInteger)value maxValue:(NSUInteger)max;
- (void) backupController:(BackupController*)controller errorDidOccur:(NSError*)error;
- (BOOL) backupController:(BackupController*)controller shouldRetryFileTransferWithURL:(NSURL*)url;
@end

@protocol BackupOperationDelegate <BackupControllerDelegate>
@required
- (void) backupController:(BackupController*)controller didStartCommand:(NSString*)command parameters:(NSDictionary*)parameters;
- (void) backupController:(BackupController*)controller didFinishCommand:(NSString*)command parameters:(NSDictionary*)parameters result:(id)result;
@end

@interface BackupController : NSObject
{
@private
	id<BackupControllerDelegate>	_delegate;
	NSString*						_scratchDir;
	
	BackupControllerStatus			_currentStatus;
	FileTransferController*			_transferController;
}
+ (BackupController*) sharedBackupController;
+ (NSOperation*) backupOperationWithCommand:(NSString*)command parameters:(NSDictionary*)parameters delegate:(id<BackupOperationDelegate>)delegate;

@property(assign) id<BackupControllerDelegate> delegate;
@property(copy) NSString* scratchDirectory; //Temporary directory for the current user by default

- (id) scan:(NSDictionary*)parameters; //NSArray of ItemInfo (see DirectoryScanner.h) or nil on error
- (id) diff:(NSDictionary*)parameters; //NSDictionary (see DirectoryScanner.h) or nil on error
- (id) sync:(NSDictionary*)parameters; //NSNumber - BOOL or nil on fatal error
- (id) backup:(NSDictionary*)parameters; //NSNumber - BOOL or nil on fatal error
- (id) update:(NSDictionary*)parameters; //NSNumber - BOOL or nil on fatal error
- (id) list:(NSDictionary*)parameters; //NSArray of NSDate / NSNull or nil on error
- (id) info:(NSDictionary*)parameters; //DirectoryScanner or nil on error
- (id) restore:(NSDictionary*)parameters; //NSNumber - BOOL or nil on fatal error
- (id) delete:(NSDictionary*)parameters; //NSNumber - BOOL or nil on fatal error
@end
