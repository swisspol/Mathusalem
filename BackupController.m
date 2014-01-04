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

#import <dirent.h>
#import <sys/stat.h>

#import "BackupController.h"
#import "FileTransferController.h"
#import "DiskImageController.h"
#import "DirectoryScanner.h"
#import "Task.h"
#import "NSData+Encryption.h"
#import "NSData+GZip.h"
#import "Keychain.h"
#import "NSURL+Parameters.h"

#define __FAST_FILE_SCHEME__ 1
#define __FORWARD_FILETRANSFERCONTROLLER_ERRORS__ 0

#define kBackupPrefix				@"Revision-"
#define kBackupFormat				kBackupPrefix "%05i"
#define kSegmentFormat				@"-Part-%03i"
#define kBOMFileExtension			@"xml.gz"

#define kDittoToolPath				@"/usr/bin/ditto"

#define kDiskSpaceMargin			1 //percents

#define CHECK_IMMEDIATE_ABORT() { if([_delegate backupControllerShouldAbort:self]) goto Exit; }

#define MAKE_TMP_PATH() [_scratchDir stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]]

#define UPDATE_STATUS(_STATUS_, _VALUE_, _MAX_)		{ \
														_currentStatus = _STATUS_; \
														[_delegate backupController:self didUpdateStatus:_currentStatus currentValue:_VALUE_ maxValue:_MAX_]; \
													}

#define REPORT_SCANNING_ERROR(_PATHS_, _FATAL_)		{ \
														if(_delegate) { \
															NSDictionary* info = [NSDictionary dictionaryWithObjectsAndKeys:_PATHS_, kBackupControllerPathsKey, [NSNumber numberWithBool:_FATAL_], kBackupControllerFatalErrorKey, nil]; \
															[_delegate backupController:self errorDidOccur:[NSError errorWithDomain:kBackupControllerErrorDomain code:kBackupControllerErrorCode_Scanning userInfo:info]]; \
														} \
													}

#define REPORT_GENERIC_ERROR(_CODE_, _ERROR_, _FATAL_, _PATH_, _OTHER_PATH_)	{ \
																					if(_delegate) { \
																						NSArray* paths = [NSArray arrayWithObjects:_PATH_, _OTHER_PATH_, nil]; \
																						NSDictionary* info = [NSDictionary dictionaryWithObjectsAndKeys:paths, kBackupControllerPathsKey, [NSNumber numberWithBool:_FATAL_], kBackupControllerFatalErrorKey, _ERROR_, NSUnderlyingErrorKey, nil]; \
																						[_delegate backupController:self errorDidOccur:[NSError errorWithDomain:kBackupControllerErrorDomain code:_CODE_ userInfo:info]]; \
																					} \
																				}

@interface NSFileManager (BackupController)
@end

@interface BackupController () <FileTransferControllerDelegate>
- (NSDictionary*) _diffDirectories:(NSDictionary*)parameters reverse:(BOOL)reverse;
- (DirectoryScanner*) _scannerForRevision:(NSUInteger)revision fileTransferController:(FileTransferController*)transferController;
@end

@implementation NSFileManager (BackupController)

- (BOOL) copyFileUnlockedAtPath:(NSString*)srcPath toPath:(NSString*)dstPath error:(NSError**)error
{
	static NSDictionary*		attributes = nil;
	
	if(![self copyItemAtPath:srcPath toPath:dstPath error:error])
	return NO;
	
	if([[[self attributesOfItemAtPath:dstPath error:NULL] objectForKey:NSFileImmutable] boolValue]) {
		if(attributes == nil)
		attributes = [[NSDictionary dictionaryWithObject:[NSNumber numberWithBool:NO] forKey:NSFileImmutable] retain];
		
		[self setAttributes:attributes ofItemAtPath:dstPath error:error];
	}
	
	return YES;
}

@end

@implementation BackupController

@synthesize delegate=_delegate, scratchDirectory=_scratchDir;

+ (BackupController*) sharedBackupController
{
	static BackupController*	controller = nil;
	
	if(controller == nil)
	controller = [BackupController new];
	
	return controller;
}

+ (NSOperation*) backupOperationWithCommand:(NSString*)command parameters:(NSDictionary*)parameters delegate:(id<BackupOperationDelegate>)delegate
{
	BackupController*			controller;
	NSMutableDictionary*		arguments;
	
	controller = [[BackupController new] autorelease];
	[controller setDelegate:delegate];
	
	arguments = [NSMutableDictionary dictionaryWithDictionary:parameters];
	[arguments setObject:command forKey:@""];
	
	return [[[NSInvocationOperation alloc] initWithTarget:controller selector:@selector(_runOperation:) object:arguments] autorelease];
}

- (void) _runOperation:(NSMutableDictionary*)arguments
{
	NSString*					command;
	id							result;
	
	command = [[[arguments objectForKey:@""] retain] autorelease];
	[arguments removeObjectForKey:@""];
	
	[(id<BackupOperationDelegate>)[self delegate] backupController:self didStartCommand:command parameters:arguments];
	@try {
		result = [self performSelector:NSSelectorFromString([command stringByAppendingString:@":"]) withObject:arguments];
	}
	@catch(NSException* localException) {
		NSLog(@"<IGNORED EXCEPTION DURING '%@' OPERATION>\n%@", command, localException);
		result = nil;
	}
	[(id<BackupOperationDelegate>)[self delegate] backupController:self didFinishCommand:command parameters:arguments result:result];
}

- (id) init
{
	if((self = [super init]))
	_scratchDir = [NSTemporaryDirectory() copy];
	
	return self;
}

- (void) dealloc
{
	[_scratchDir release];
	
	[super dealloc];
}

- (BOOL) fileManager:(NSFileManager*)fileManager shouldProceedAfterError:(NSError*)error removingItemAtPath:(NSString*)path
{
	return YES;
}

- (id) scan:(NSDictionary*)parameters
{
	NSArray*					array;
	DirectoryScanner*			scanner;
	NSDictionary*				results;
	
	//Create a directory scanner with passed parameters
	scanner = [[DirectoryScanner alloc] initWithRootDirectory:[parameters objectForKey:@"source"] scanMetadata:NO];
	[scanner setSortPaths:YES];
	[scanner setExcludeHiddenItems:[[parameters objectForKey:@"excludeHidden"] boolValue]];
	[scanner setExclusionPredicate:[DirectoryScanner exclusionPredicateWithPaths:[parameters objectForKey:@"excludePath"] names:[parameters objectForKey:@"excludeName"]]];
	
	//Scan root and subdirectories
	results = [scanner scanRootDirectory];
	if(results) {
		if((array = [results objectForKey:kDirectoryScannerResultKey_ErrorPaths]))
		REPORT_SCANNING_ERROR(array, NO);
		array = [scanner subpathsOfRootDirectory];
	}
	else {
		REPORT_SCANNING_ERROR([NSArray arrayWithObject:[parameters objectForKey:@"source"]], YES);
		array = nil;
	}
	
	//Clean up
	[scanner release];
	
	return [array description];
}

- (NSDictionary*) _diffDirectories:(NSDictionary*)parameters reverse:(BOOL)reverse
{
	DirectoryScanner*			scanner;
	DirectoryScanner*			otherScanner;
	NSDictionary*				results;
	NSArray*					array;
	
	//Create a directory scanner with passed parameters for the source directory
	scanner = [[DirectoryScanner alloc] initWithRootDirectory:[parameters objectForKey:@"source"] scanMetadata:NO];
	[scanner setSortPaths:YES];
	[scanner setExcludeHiddenItems:[[parameters objectForKey:@"excludeHidden"] boolValue]];
	[scanner setExclusionPredicate:[DirectoryScanner exclusionPredicateWithPaths:[parameters objectForKey:@"excludePath"] names:[parameters objectForKey:@"excludeName"]]];
	
	//Create a directory scanner with passed parameters for the target directory
	otherScanner = [[DirectoryScanner alloc] initWithRootDirectory:[parameters objectForKey:@"target"] scanMetadata:NO];
	[otherScanner setSortPaths:YES];
	[otherScanner setExcludeHiddenItems:[[parameters objectForKey:@"excludeHidden"] boolValue]];
	[otherScanner setExclusionPredicate:[DirectoryScanner exclusionPredicateWithPaths:[parameters objectForKey:@"excludePath"] names:[parameters objectForKey:@"excludeName"]]];
	
	//Scan source root and subdirectories
	results = [scanner scanRootDirectory];
	if(results) {
		if((array = [results objectForKey:kDirectoryScannerResultKey_ErrorPaths]))
		REPORT_SCANNING_ERROR(array, NO);
		
		//Scan target root and subdirectories
		results = [otherScanner scanRootDirectory];
		if(results) {
			if((array = [results objectForKey:kDirectoryScannerResultKey_ErrorPaths]))
			REPORT_SCANNING_ERROR(array, NO);
			
			//Compare the two scanners
			results = (reverse ? [otherScanner compare:scanner options:kDirectoryScannerOption_OnlyReportTopLevelRemovedItems] : [scanner compare:otherScanner options:kDirectoryScannerOption_OnlyReportTopLevelRemovedItems]);
		}
		else
		REPORT_SCANNING_ERROR([NSArray arrayWithObject:[parameters objectForKey:@"target"]], YES);
	}
	else
	REPORT_SCANNING_ERROR([NSArray arrayWithObject:[parameters objectForKey:@"source"]], YES);
	
	//Clean up
	[otherScanner release];
	[scanner release];
	
	return results;
}

- (id) diff:(NSDictionary*)parameters
{
	return [self _diffDirectories:parameters reverse:YES];
}

- (id) sync:(NSDictionary*)parameters
{
	NSString*					sourcePath = [[parameters objectForKey:@"source"] stringByStandardizingPath];
	NSString*					targetPath = [[parameters objectForKey:@"target"] stringByStandardizingPath];
	BOOL						success = YES;
	NSAutoreleasePool*			localPool = nil;
	NSFileManager*				manager;
	NSDictionary*				results;
	NSArray*					array;
	DirectoryItem*				item;
	NSError*					error;
	NSUInteger					count,
								index;
	
	//Create our custom file manager
	manager = [[NSFileManager new] autorelease];
	[manager setDelegate:self];
	
	do {
		CHECK_IMMEDIATE_ABORT();
		
		//Create a local autorelease pool
		[localPool release];
		localPool = [NSAutoreleasePool new];
		
		//Get differences between source & target
		results = [self _diffDirectories:parameters reverse:NO];
		if(results == nil) {
			[localPool release];
			goto Exit;
		}
		
		//Nothing to do if source and target are identical
		if(![results count])
		break;
		
		//Prepare
		count = [[results objectForKey:kDirectoryScannerResultKey_RemovedItems] count] + [[results objectForKey:kDirectoryScannerResultKey_ModifiedItems_Data] count] + [[results objectForKey:kDirectoryScannerResultKey_AddedItems] count];
		index = 0;
		UPDATE_STATUS(kBackupControllerStatus_CopyingFiles, index, count);
		
		//Delete all removed items
		array = [results objectForKey:kDirectoryScannerResultKey_RemovedItems];
		for(item in array) {
			CHECK_IMMEDIATE_ABORT();
			
			++index;
			UPDATE_STATUS(kBackupControllerStatus_CopyingFiles, index, count);
			
			if(![manager removeItemAtPath:[targetPath stringByAppendingPathComponent:[item path]] error:&error]) {
				success = NO;
				REPORT_GENERIC_ERROR(kBackupControllerErrorCode_DeletingItem, error, NO, [targetPath stringByAppendingPathComponent:[item path]], nil);
			}
		}
		
		//Delete then copy all modified items
		array = [results objectForKey:kDirectoryScannerResultKey_ModifiedItems_Data];
		for(item in array) {
			CHECK_IMMEDIATE_ABORT();
			
			++index;
			UPDATE_STATUS(kBackupControllerStatus_CopyingFiles, index, count);
			
			if(![manager removeItemAtPath:[targetPath stringByAppendingPathComponent:[item path]] error:&error]) {
				success = NO;
				REPORT_GENERIC_ERROR(kBackupControllerErrorCode_DeletingItem, error, NO, [targetPath stringByAppendingPathComponent:[item path]], nil);
				continue;
			}
			if(![manager copyFileUnlockedAtPath:[sourcePath stringByAppendingPathComponent:[item path]] toPath:[targetPath stringByAppendingPathComponent:[item path]] error:&error]) {
				success = NO;
				REPORT_GENERIC_ERROR(kBackupControllerErrorCode_CopyingItem, error, NO, [sourcePath stringByAppendingPathComponent:[item path]], [targetPath stringByAppendingPathComponent:[item path]]);
			}
		}
		
		//Copy all added items
		array = [results objectForKey:kDirectoryScannerResultKey_AddedItems];
		for(item in array) {
			CHECK_IMMEDIATE_ABORT();
			
			++index;
			UPDATE_STATUS(kBackupControllerStatus_CopyingFiles, index, count);
			
			if([item isDirectory]) {
				if(![manager createDirectoryAtPath:[targetPath stringByAppendingPathComponent:[item path]] withIntermediateDirectories:NO attributes:nil error:&error]) {
					success = NO;
					REPORT_GENERIC_ERROR(kBackupControllerErrorCode_CreatingDirectory, error, NO, [targetPath stringByAppendingPathComponent:[item path]], nil);
				}
			}
			else {
				if(![manager copyFileUnlockedAtPath:[sourcePath stringByAppendingPathComponent:[item path]] toPath:[targetPath stringByAppendingPathComponent:[item path]] error:&error]) {
					success = NO;
					REPORT_GENERIC_ERROR(kBackupControllerErrorCode_CopyingItem, error, NO, [sourcePath stringByAppendingPathComponent:[item path]], [[targetPath stringByAppendingPathComponent:[item path]] UTF8String]);
				}
			}
		}
		
		UPDATE_STATUS(kBackupControllerStatus_Idle, 0, 0);
	} while([[parameters objectForKey:kBackupScannerUserInfoKey_Atomic] boolValue]); //In atomic mode, keep syncing until there are no differences
	[localPool release];
	localPool = nil;
	
	return [NSNumber numberWithBool:success];

Exit:
	return nil;
}

- (void) fileTransferControllerDidStart:(FileTransferController*)controller
{
	UPDATE_STATUS(_currentStatus, 0, [controller transferSize]);
}

- (void) fileTransferControllerDidFail:(FileTransferController*)controller withError:(NSError*)error
{
#if __FORWARD_FILETRANSFERCONTROLLER_ERRORS__
	REPORT_GENERIC_ERROR(_currentStatus, error, NO, nil, nil);
#else
	NSLog(@"%@ Failed with error:\n%@\n%@", controller, error, [error userInfo]);
#endif
}

- (BOOL) fileTransferControllerShouldAbort:(FileTransferController*)controller
{
	return [_delegate backupControllerShouldAbortCurrentFileTransfer:self];
}

- (void) fileTransferControllerDidUpdateProgress:(FileTransferController*)controller
{
	UPDATE_STATUS(_currentStatus, [controller transferProgress] * [controller transferSize], [controller transferSize]);
}

- (DirectoryScanner*) _scannerForRevision:(NSUInteger)revision fileTransferController:(FileTransferController*)transferController
{
	NSFileManager*				manager = [NSFileManager defaultManager];
	DirectoryScanner*			scanner = nil;
	NSString*					path;
	NSError*					error;
	NSString*					string;
	id							results;
	BOOL						success;
	
	//Do we have a revision explicitely specified?
	if(revision > 0) {
		path = [[NSString stringWithFormat:kBackupFormat, revision] stringByAppendingPathExtension:kBOMFileExtension];
		
		//Download the BOM file
#if __FAST_FILE_SCHEME__
		if([transferController isMemberOfClass:[LocalTransferController class]])
		string = [[[transferController baseURL] path] stringByAppendingPathComponent:path];
		else
#endif
		{
			string = MAKE_TMP_PATH();
			do {
				UPDATE_STATUS(kBackupControllerStatus_DownloadingFile, 0, 0);
				success = [transferController downloadFileFromPath:path toPath:string];
				UPDATE_STATUS(kBackupControllerStatus_Idle, 0, 0);
			} while(!success && ![_delegate backupControllerShouldAbort:self] && [_delegate backupController:self shouldRetryFileTransferWithURL:[transferController absoluteURLForRemotePath:path]]);
			if(success == NO) {
				if(![_delegate backupControllerShouldAbort:self])
				REPORT_GENERIC_ERROR(kBackupControllerErrorCode_DownloadingFile, nil, YES, path, string);
				goto Exit;
			}
		}
		
		CHECK_IMMEDIATE_ABORT();
		
		//Recreate the directory scanner from it
		@try {
			scanner = [[DirectoryScanner alloc] initWithFile:string];
		}
		@catch(NSException* localException) {
			NSLog(@"%s: %@", __FUNCTION__, localException);
			scanner = nil;
		}
#if __FAST_FILE_SCHEME__
		if(![transferController isMemberOfClass:[LocalTransferController class]])
#endif
		{
			if(![manager removeItemAtPath:string error:&error])
			REPORT_GENERIC_ERROR(kBackupControllerErrorCode_DeletingItem, error, NO, string, nil);
		}
		if(scanner == nil) {
			REPORT_GENERIC_ERROR(kBackupControllerErrorCode_ReadingBOMFile, nil, YES, path, nil);
			goto Exit;
		}
	}
	else {
		//Get the list of all files
#if __FAST_FILE_SCHEME__
		if([transferController isMemberOfClass:[LocalTransferController class]]) {
			results = [manager contentsOfDirectoryAtPath:[[transferController baseURL] path] error:&error];
			if(results == nil) {
				REPORT_GENERIC_ERROR(kBackupControllerErrorCode_Scanning, error, YES, [[transferController baseURL] path], nil);
				goto Exit;
			}
		}
		else
#endif
		{
			UPDATE_STATUS(kBackupControllerStatus_CheckingDestination, 0, 0);
			results = [transferController contentsOfDirectoryAtPath:nil];
			UPDATE_STATUS(kBackupControllerStatus_Idle, 0, 0);
			if(results == nil) {
				if(![_delegate backupControllerShouldAbort:self])
				REPORT_GENERIC_ERROR(kBackupControllerErrorCode_CheckingDestination, nil, YES, [[transferController absoluteURLForRemotePath:nil] absoluteString], nil);
				goto Exit;
			}
			results = [results allKeys];
		}
		
		//Order the list by inverse alphabetical order so that most recent files are first
		results = [[results sortedArrayUsingSelector:@selector(compare:)] reverseObjectEnumerator];
		
		//Retrieve the first BOM file in the list
		scanner = (DirectoryScanner*)kCFNull;
		for(path in results) {
			if(![path hasSuffix:kBOMFileExtension])
			continue;
			
			//Download the BOM file
#if __FAST_FILE_SCHEME__
			if([transferController isMemberOfClass:[LocalTransferController class]])
			string = [[[transferController baseURL] path] stringByAppendingPathComponent:path];
			else
#endif
			{
				string = MAKE_TMP_PATH();
				do {
					UPDATE_STATUS(kBackupControllerStatus_DownloadingFile, 0, 0);
					success = [transferController downloadFileFromPath:path toPath:string];
					UPDATE_STATUS(kBackupControllerStatus_Idle, 0, 0);
				} while(!success && ![_delegate backupControllerShouldAbort:self] && [_delegate backupController:self shouldRetryFileTransferWithURL:[transferController absoluteURLForRemotePath:path]]);
				if(success == NO) {
					if(![_delegate backupControllerShouldAbort:self])
					REPORT_GENERIC_ERROR(kBackupControllerErrorCode_DownloadingFile, nil, YES, path, string);
					goto Exit;
				}
			}
			
			CHECK_IMMEDIATE_ABORT();
			
			//Recreate the directory scanner from it
			@try {
				scanner = [[DirectoryScanner alloc] initWithFile:string];
			}
			@catch(NSException* localException) {
				NSLog(@"%s: %@", __FUNCTION__, localException);
				scanner = nil;
			}
#if __FAST_FILE_SCHEME__
			if(![transferController isMemberOfClass:[LocalTransferController class]])
#endif
			{
				if(![manager removeItemAtPath:string error:&error])
				REPORT_GENERIC_ERROR(kBackupControllerErrorCode_DeletingItem, error, NO, string, nil);
			}
			if(scanner == nil) {
				REPORT_GENERIC_ERROR(kBackupControllerErrorCode_ReadingBOMFile, nil, YES, string, nil);
				goto Exit;
			}
			
			break;
		}
	}
	
Exit:
	return [scanner autorelease];
}

static NSURL* _URLFromDestination(id destination)
{
	if([destination isKindOfClass:[NSString class]]) {
		if([destination rangeOfString:@"://"].location == NSNotFound)
		destination = [NSURL fileURLWithPath:[destination stringByStandardizingPath]];
		else
		destination = [NSURL URLWithString:destination];
	}
	else if(![destination isKindOfClass:[NSURL class]])
	return nil;
	
	return [[Keychain sharedKeychain] URLWithPasswordForURL:destination];
}

static NSComparisonResult _PathSortFunction(NSString* path1, NSString* path2, void* context)
{
	return [path1 compare:path2 options:(NSCaseInsensitiveSearch | NSNumericSearch | NSForcedOrderingSearch)];
}

static NSComparisonResult _ItemInfoSortFunction(DirectoryItem* info1, DirectoryItem* info2, void* context)
{
	return _PathSortFunction([info1 path], [info2 path], NULL);
}

- (void) _makeFileReadOnly:(NSString*)path
{
	const char*					filePath = [path UTF8String];
	struct stat					stats;
	
	if(lstat(filePath, &stats) == 0) {
		if(chmod(filePath, (stats.st_mode & ALLPERMS) & ~(S_IWUSR | S_IWGRP | S_IWOTH)) != 0)
		REPORT_GENERIC_ERROR(kBackupControllerErrorCode_SettingItemPermissions, nil, NO, [NSString stringWithUTF8String:filePath], nil);
	}
	else
	REPORT_GENERIC_ERROR(kBackupControllerErrorCode_RetrievingItemInfo, nil, NO, [NSString stringWithUTF8String:filePath], nil);
}

static inline BOOL _EqualData(NSData* data1, NSData* data2)
{
	if(data1 == data2)
	return YES;
	
	if(data1 && data2 && [data1 isEqualToData:data2])
	return YES;
	
	return NO;
}

static BOOL _RunExecutable(NSString* path, ...)
{
	NSMutableArray*				arguments = [NSMutableArray array];
	va_list						list;
	NSString*					string;
	
	va_start(list, path);
	while(1) {
		string = va_arg(list, id);
		if(string)
		[arguments addObject:string];
		else
		break;
	}
	va_end(list);
	
	string = [[path pathExtension] lowercaseString];
	if([string isEqualToString:@"app"])
	path = [path stringByAppendingFormat:@"/Contents/MacOS/%@", [[path lastPathComponent] stringByDeletingPathExtension]]; //FIXME: Get real executable name from Info.plist
	else if([string isEqualToString:@"applescript"] || [string isEqualToString:@"scpt"]) {
		[arguments insertObject:path atIndex:0];
		path = @"/usr/bin/osascript";
	}
	
	return ([Task runWithToolPath:path arguments:arguments inputString:nil timeOut:0.0] ? YES : NO);
}

static inline NSString* _GetVolumeName(NSString* path)
{
	return [[path pathComponents] objectAtIndex:([path hasPrefix:@"/Volumes/"] ? 2 : 1)];
}

- (id) backup:(NSDictionary*)parameters
{
	NSString*					sourcePath = [[parameters objectForKey:@"source"] stringByStandardizingPath];
	NSURL*						destinationURL = _URLFromDestination([parameters objectForKey:@"destination"]);
	NSString*					destinationString = ([destinationURL isFileURL] ? [destinationURL path] : [[NSURL URLWithScheme:[destinationURL scheme] user:nil password:nil host:[destinationURL host] port:[[destinationURL port] unsignedShortValue] path:[destinationURL path]] absoluteString]);
	NSString*					password = [parameters objectForKey:@"password"];
	NSMutableArray*				snapshotFiles = [NSMutableArray array];
	NSMutableArray*				uploadedFiles = [NSMutableArray array];
	NSAutoreleasePool*			localPool = nil;
	DirectoryScanner*			scanner = nil;
	BOOL						success = YES;
	id							result = nil;
	NSUInteger					segments = 0;
	NSFileManager*				manager;
	NSMutableDictionary*		allResults;
	NSString*					backupName;
	NSDictionary*				results;
	NSArray*					array;
	NSError*					error;
	DirectoryItem*				item;
	NSString*					path;
	NSString*					snapshotPath;
	NSString*					archivePath;
	NSString*					backupPath;
	NSUInteger					count,
								index;
	unsigned long long			size;
	BOOL						completed;
	NSMutableArray*				arguments;
	NSUInteger					segmentSize;
	NSString*					string;
	
	//Run pre-backup executable if any
	if((path = [parameters objectForKey:@"preExecutable"])) {
		UPDATE_STATUS(kBackupControllerStatus_RunningExecutable, 0, 0);
		completed = _RunExecutable(path, sourcePath, destinationString, nil);
		UPDATE_STATUS(kBackupControllerStatus_Idle, 0, 0);
		if(completed == NO) {
			REPORT_GENERIC_ERROR(kBackupControllerErrorCode_RunningExecutable, nil, YES, path, nil);
			return nil;
		}
	}
	
	//Create our custom file manager
	manager = [[NSFileManager new] autorelease];
	[manager setDelegate:self];
	
	//Create a transfer controller to this URL
	UPDATE_STATUS(kBackupControllerStatus_AccessingDestination, 0, 0);
	_transferController = [FileTransferController fileTransferControllerWithURL:destinationURL];
	UPDATE_STATUS(kBackupControllerStatus_Idle, 0, 0);
	if(_transferController == nil)
	goto Exit;
	[_transferController setDelegate:self];
	
	CHECK_IMMEDIATE_ABORT();
	
	//Retrieve last scanner
	scanner = [self _scannerForRevision:0 fileTransferController:_transferController];
	if(scanner == nil)
	goto Exit;
	
	//Create a new one if there wasn't any (i.e. initial backup case)
	if(scanner == (DirectoryScanner*)kCFNull) {
		scanner = [[[DirectoryScanner alloc] initWithRootDirectory:sourcePath scanMetadata:NO] autorelease];
		if(scanner == nil) {
			REPORT_GENERIC_ERROR(kBackupControllerErrorCode_Scanning, nil, YES, sourcePath, nil);
			goto Exit;
		}
		[scanner setSortPaths:YES];
	}
	//Otherwise make sure it is compatible
	else if(sourcePath) {
		if(([[parameters objectForKey:@"diskImage"] boolValue] != [[scanner userInfoForKey:kBackupScannerUserInfoKey_DiskImage] boolValue]) || ([[parameters objectForKey:@"compressed"] boolValue] != [[scanner userInfoForKey:kBackupScannerUserInfoKey_Compressed] boolValue]) || !_EqualData([[password dataUsingEncoding:NSUTF8StringEncoding] md5Digest], [scanner userInfoForKey:kBackupScannerUserInfoKey_PasswordMD5])) {
			REPORT_GENERIC_ERROR(kBackupControllerErrorCode_ReadingBOMFile, nil, YES, nil, nil);
			goto Exit;
		}
	}
	
	//If we are not running in update mode, copy all backup settings to scanner
	if(sourcePath) {
		[scanner setExcludeHiddenItems:[[parameters objectForKey:@"excludeHidden"] boolValue]];
		[scanner setExclusionPredicate:[DirectoryScanner exclusionPredicateWithPaths:[parameters objectForKey:@"excludePath"] names:[parameters objectForKey:@"excludeName"]]];
		[scanner setUserInfo:[parameters objectForKey:@"atomic"] forKey:kBackupScannerUserInfoKey_Atomic];
		[scanner setUserInfo:[parameters objectForKey:@"fullBackup"] forKey:kBackupScannerUserInfoKey_FullBackup];
		[scanner setUserInfo:[parameters objectForKey:@"diskImage"] forKey:kBackupScannerUserInfoKey_DiskImage];
		[scanner setUserInfo:[parameters objectForKey:@"compressed"] forKey:kBackupScannerUserInfoKey_Compressed];
		[scanner setUserInfo:[parameters objectForKey:@"segment"] forKey:kBackupScannerUserInfoKey_Segment];
		[scanner setUserInfo:[[password dataUsingEncoding:NSUTF8StringEncoding] md5Digest] forKey:kBackupScannerUserInfoKey_PasswordMD5];
	}
	
	//Check if we need to create segmented archives
	segmentSize = [[scanner userInfoForKey:kBackupScannerUserInfoKey_Segment] integerValue];
	
	//Sparse disk images cannot be segmented
	if((segmentSize > 0) && [[scanner userInfoForKey:kBackupScannerUserInfoKey_DiskImage] boolValue] && ![[scanner userInfoForKey:kBackupScannerUserInfoKey_Compressed] boolValue])
	goto Exit;
	
	//Only disk images can have passwords
	if(password && ![[scanner userInfoForKey:kBackupScannerUserInfoKey_DiskImage] boolValue])
	goto Exit;
	
	//Remember start date
	[scanner setUserInfo:[NSDate date] forKey:kBackupScannerUserInfoKey_StartDate];
	
	CHECK_IMMEDIATE_ABORT();
	
	//Update scanner
	UPDATE_STATUS(kBackupControllerStatus_ScanningSource, 0, 0);
	if([scanner revision] > 0)
	results = [scanner scanAndCompareRootDirectory:(kDirectoryScannerOption_BumpRevision | kDirectoryScannerOption_OnlyReportTopLevelRemovedItems)];
	else {
		results = [scanner scanRootDirectory];
		if(results) {
			results = [NSMutableDictionary dictionaryWithDictionary:results];
			[(NSMutableDictionary*)results setValue:[scanner subpathsOfRootDirectory] forKey:kDirectoryScannerResultKey_AddedItems];
		}
	}
	UPDATE_STATUS(kBackupControllerStatus_Idle, 0, 0);
	if(results == nil) {
		REPORT_GENERIC_ERROR(kBackupControllerErrorCode_Scanning, nil, YES, [scanner rootDirectory], nil);
		goto Exit;
	}
	if((array = [results objectForKey:kDirectoryScannerResultKey_ErrorPaths]))
	REPORT_SCANNING_ERROR(array, NO);
	
	//Check if are in dry-run mode
	if([[parameters objectForKey:@"dryRun"] boolValue]) {
		[(NSMutableDictionary*)results removeObjectForKey:kDirectoryScannerResultKey_ErrorPaths];
		_transferController = nil;
		result = results;
		goto Done;
	}
	
	CHECK_IMMEDIATE_ABORT();
	
	//Check if there are any changes
	if([results objectForKey:kDirectoryScannerResultKey_RemovedItems] || [results objectForKey:kDirectoryScannerResultKey_ModifiedItems_Data] || [results objectForKey:kDirectoryScannerResultKey_AddedItems]) {
		allResults = nil;
		
		//Fix results to contain all items when in full-backup mode
		if([[scanner userInfoForKey:kBackupScannerUserInfoKey_FullBackup] boolValue])
		results = [NSDictionary dictionaryWithObject:[scanner subpathsOfRootDirectory] forKey:kDirectoryScannerResultKey_AddedItems];
		else if([scanner revision] > 1) {
			allResults = [NSMutableDictionary dictionary];
			[allResults setObject:[NSMutableArray array] forKey:kDirectoryScannerResultKey_ModifiedItems_Data];
			[allResults setObject:[NSMutableArray array] forKey:kDirectoryScannerResultKey_AddedItems];
			[allResults setObject:[NSMutableArray array] forKey:kDirectoryScannerResultKey_RemovedItems];
		}
		
		//Build backup name & archive path
		backupName = [NSString stringWithFormat:kBackupFormat, [scanner revision]];
#if __FAST_FILE_SCHEME__
		if([_transferController isMemberOfClass:[LocalTransferController class]])
		archivePath = [[[_transferController baseURL] path] stringByAppendingPathComponent:backupName];
		else
#endif
		archivePath = MAKE_TMP_PATH();
		
		//Compute total size of all items that will go in the archive and add some margin
		size = 0;
		for(item in [results objectForKey:kDirectoryScannerResultKey_ModifiedItems_Data])
		size += [item totalSize];
		for(item in [results objectForKey:kDirectoryScannerResultKey_AddedItems])
		size += [item totalSize];
		size /= 1024;
		size += size * 10 / 100; //Add 10% margin
		if([[scanner userInfoForKey:kBackupScannerUserInfoKey_Atomic] boolValue]) //Add another 25% margin in case of atomic backups
		size += size / 4;
		
		//Make sure we have enough disk space for the snapshot
		if([[scanner userInfoForKey:kBackupScannerUserInfoKey_DiskImage] boolValue] && ![[scanner userInfoForKey:kBackupScannerUserInfoKey_Compressed] boolValue])
		size = MAX(5 * 1024, size); //Sparse disk images must be 5Mb minimum
		else {
			error = nil;
			if([[[manager attributesOfFileSystemForPath:_scratchDir error:&error] objectForKey:NSFileSystemFreeSize] unsignedLongLongValue] / 100 * (100 - kDiskSpaceMargin) < size) {
				REPORT_GENERIC_ERROR(kBackupControllerErrorCode_CheckingLocalDiskSpace, error, YES, _GetVolumeName(_scratchDir), nil);
				goto Exit;
			}
		}
		
		//Make sure we have enough disk space for the archive
		error = nil;
		if([[[manager attributesOfFileSystemForPath:[archivePath stringByDeletingLastPathComponent] error:&error] objectForKey:NSFileSystemFreeSize] unsignedLongLongValue] / 100 * (100 - kDiskSpaceMargin) < size) {
			REPORT_GENERIC_ERROR(kBackupControllerErrorCode_CheckingLocalDiskSpace, error, YES, _GetVolumeName(archivePath), nil);
			goto Exit;
		}
		
		//Do we need to create uncompressed disk images i.e. sparse disk images?
		if([[scanner userInfoForKey:kBackupScannerUserInfoKey_DiskImage] boolValue] && ![[scanner userInfoForKey:kBackupScannerUserInfoKey_Compressed] boolValue]) {
			archivePath = [archivePath stringByAppendingPathExtension:@"sparseimage"];
			
			//Create the sparse disk image, mount it and use it directly as the snapshot directory
			UPDATE_STATUS(kBackupControllerStatus_CreatingDiskImage, 0, 0);
			completed = [[DiskImageController sharedDiskImageController] makeSparseDiskImageAtPath:archivePath withName:backupName size:size password:password];
			UPDATE_STATUS(kBackupControllerStatus_Idle, 0, 0);
			if(completed) {
				snapshotPath = [@"/tmp" stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
				if(![[DiskImageController sharedDiskImageController] mountDiskImage:archivePath atPath:snapshotPath usingShadowFile:nil password:password private:YES verify:NO]) {
					REPORT_GENERIC_ERROR(kBackupControllerErrorCode_MountingDiskImage, nil, YES, archivePath, snapshotPath);
					if(![manager removeItemAtPath:archivePath error:&error])
					REPORT_GENERIC_ERROR(kBackupControllerErrorCode_DeletingItem, error, NO, archivePath, nil);
					goto Exit;
				}
			}
			else {
				REPORT_GENERIC_ERROR(kBackupControllerErrorCode_CreatingDiskImage, nil, YES, archivePath, nil);
				goto Exit;
			}
			
			//Check the abort flag
			if([_delegate backupControllerShouldAbort:self]) {
				[[DiskImageController sharedDiskImageController] unmountDiskImageAtPath:snapshotPath force:YES];
				[manager removeItemAtPath:archivePath error:NULL];
				goto Exit;
			}
		}
		else {
			//Add the proper extension to the archive path
			if([[scanner userInfoForKey:kBackupScannerUserInfoKey_DiskImage] boolValue])
			archivePath = [archivePath stringByAppendingPathExtension:@"dmg"];
			else if([[scanner userInfoForKey:kBackupScannerUserInfoKey_Compressed] boolValue])
			archivePath = [archivePath stringByAppendingPathExtension:@"zip"];
			else
			archivePath = [archivePath stringByAppendingPathExtension:@"cpio"];
			
			CHECK_IMMEDIATE_ABORT();
			
			//Create the snapshot directory
			snapshotPath = MAKE_TMP_PATH();
			if(![manager createDirectoryAtPath:snapshotPath withIntermediateDirectories:YES attributes:nil error:&error]) {
				REPORT_GENERIC_ERROR(kBackupControllerErrorCode_CreatingDirectory, error, YES, snapshotPath, nil);
				goto Exit;
			}
		}
		
		//Copy all modified or added items
		completed = YES;
		while(1) {
			if(allResults) {
				array = [allResults objectForKey:kDirectoryScannerResultKey_ModifiedItems_Data];
				for(item in [results objectForKey:kDirectoryScannerResultKey_ModifiedItems_Data])
				[(NSMutableArray*)array addObject:[item path]];
				array = [allResults objectForKey:kDirectoryScannerResultKey_AddedItems];
				for(item in [results objectForKey:kDirectoryScannerResultKey_AddedItems])
				[(NSMutableArray*)array addObject:[item path]];
				array = [allResults objectForKey:kDirectoryScannerResultKey_RemovedItems];
				for(item in [results objectForKey:kDirectoryScannerResultKey_RemovedItems])
				[(NSMutableArray*)array addObject:[item path]];
			}
			
			//Create a local auto-release pool
			[results retain];
			[localPool release];
			localPool = [NSAutoreleasePool new];
			[results autorelease];
			
			//In atomic mode, delete removed or modified items
			if([[scanner userInfoForKey:kBackupScannerUserInfoKey_Atomic] boolValue]) {
				for(item in [results objectForKey:kDirectoryScannerResultKey_RemovedItems]) {
					string = [snapshotPath stringByAppendingPathComponent:[item path]];
					if([manager fileExistsAtPath:string] && ![manager removeItemAtPath:string error:&error])
					REPORT_GENERIC_ERROR(kBackupControllerErrorCode_DeletingItem, error, NO, string, nil);
				}
				for(item in [results objectForKey:kDirectoryScannerResultKey_ModifiedItems_Data]) {
					string = [snapshotPath stringByAppendingPathComponent:[item path]];
					if([manager fileExistsAtPath:string] && ![manager removeItemAtPath:string error:&error])
					REPORT_GENERIC_ERROR(kBackupControllerErrorCode_DeletingItem, error, NO, string, nil);
				}
			}
			
			//Concatenate modified and added items into a single list
			array = [results objectForKey:kDirectoryScannerResultKey_ModifiedItems_Data];
			if([results objectForKey:kDirectoryScannerResultKey_AddedItems]) {
				array = [NSMutableArray arrayWithArray:array];
				[(NSMutableArray*)array addObjectsFromArray:[results objectForKey:kDirectoryScannerResultKey_AddedItems]];
			}
			
			//Make sure the list is not empty
			if([array count]) {
				[snapshotFiles addObjectsFromArray:array];
				
				//Create subdirectories or copy files into the snapshot directory
				index = 0;
				count = [array count];
				UPDATE_STATUS(kBackupControllerStatus_CopyingFiles, index, count);
				for(item in array) {
					if([_delegate backupControllerShouldAbort:self]) {
						completed = NO;
						break;
					}
					
					++index;
					UPDATE_STATUS(kBackupControllerStatus_CopyingFiles, index, count);
					
					if(![item isDirectory]) {
						string = [[snapshotPath stringByAppendingPathComponent:[item path]] stringByDeletingLastPathComponent];
						if(![manager fileExistsAtPath:string] && ![manager createDirectoryAtPath:string withIntermediateDirectories:YES attributes:nil error:&error]) {
							[snapshotFiles removeObject:item];
							[scanner removeDirectoryItemAtSubpath:[item path]];
							success = NO;
							REPORT_GENERIC_ERROR(kBackupControllerErrorCode_CreatingDirectory, error, NO, string, nil);
							continue;
						}
						
						if(![manager copyFileUnlockedAtPath:[[scanner rootDirectory] stringByAppendingPathComponent:[item path]] toPath:[snapshotPath stringByAppendingPathComponent:[item path]] error:&error]) {
							[snapshotFiles removeObject:item];
							[scanner removeDirectoryItemAtSubpath:[item path]];
							success = NO;
							REPORT_GENERIC_ERROR(kBackupControllerErrorCode_CopyingItem, error, NO, [[scanner rootDirectory] stringByAppendingPathComponent:[item path]], [snapshotPath stringByAppendingPathComponent:[item path]]);
						}
					}
				}
				UPDATE_STATUS(kBackupControllerStatus_Idle, 0, 0);
			}
			
			//In atomic mode, keep scanning until there are no more changes being reported
			if(completed && [[scanner userInfoForKey:kBackupScannerUserInfoKey_Atomic] boolValue]) {
				results = [scanner scanAndCompareRootDirectory:kDirectoryScannerOption_OnlyReportTopLevelRemovedItems];
				if(results) {
					if([results objectForKey:kDirectoryScannerResultKey_RemovedItems] || [results objectForKey:kDirectoryScannerResultKey_ModifiedItems_Data] || [results objectForKey:kDirectoryScannerResultKey_AddedItems])
					continue;
				}
				else
				completed = NO;
			}
			
			break;
		}
		[localPool release];
		localPool = nil;
		
		//Do we have a sparse disk image acting as the snapshot directory?
		if([[scanner userInfoForKey:kBackupScannerUserInfoKey_DiskImage] boolValue] && ![[scanner userInfoForKey:kBackupScannerUserInfoKey_Compressed] boolValue]) {
			//Unmount it
			if(![[DiskImageController sharedDiskImageController] unmountDiskImageAtPath:snapshotPath force:NO]) {
				if(![[DiskImageController sharedDiskImageController] unmountDiskImageAtPath:snapshotPath force:YES]) {
					success = NO;
					REPORT_GENERIC_ERROR(kBackupControllerErrorCode_UnmountingDiskImage, nil, NO, snapshotPath, nil);
				}
			}
			
			//Upload sparse disk image to destination
			if([snapshotFiles count]) {
#if __FAST_FILE_SCHEME__
				if([_transferController isMemberOfClass:[LocalTransferController class]]) {
					[uploadedFiles addObject:archivePath];
					if(completed == YES) {
						if([_delegate backupControllerShouldAbort:self])
						completed = NO;
						else
						[self _makeFileReadOnly:archivePath];
					}
				}
				else
#endif
				{
					if((completed == YES) && ![_delegate backupControllerShouldAbort:self]) {
						[uploadedFiles addObject:[archivePath lastPathComponent]];
						do {
							UPDATE_STATUS(kBackupControllerStatus_UploadingFile, 0, 0);
							completed = [_transferController uploadFileFromPath:archivePath toPath:[archivePath lastPathComponent]];
							UPDATE_STATUS(kBackupControllerStatus_Idle, 0, 0);
						} while(!completed && ![_delegate backupControllerShouldAbort:self] && [_delegate backupController:self shouldRetryFileTransferWithURL:[_transferController absoluteURLForRemotePath:[archivePath lastPathComponent]]]);
						if((completed == NO) && ![_delegate backupControllerShouldAbort:self])
						REPORT_GENERIC_ERROR(kBackupControllerErrorCode_UploadingFile, nil, YES, archivePath, [archivePath lastPathComponent]);
					}
					else
					completed = NO;
				}
			}
			
			//Delete sparse disk image
#if __FAST_FILE_SCHEME__
			if(![snapshotFiles count] || ![_transferController isMemberOfClass:[LocalTransferController class]])
#endif
			{
				if(![manager removeItemAtPath:archivePath error:&error]) {
					success = NO;
					REPORT_GENERIC_ERROR(kBackupControllerErrorCode_DeletingItem, error, NO, archivePath, nil);
				}
			}
			
			if(completed == NO)
			goto Exit;
		}
		else {
			if((completed == YES) && ![_delegate backupControllerShouldAbort:self]) {
				//Make sure we have some items
				if([snapshotFiles count]) {
					//Precompute the number of segmented archives
					if(segmentSize > 0) {
						[snapshotFiles sortUsingFunction:_ItemInfoSortFunction context:NULL];
						index = 0;
						while(1) {
							segments += 1;
							size = 0;
							while(1) {
								item = [snapshotFiles objectAtIndex:index++];
								if([item isDirectory]) {
									if(index == [snapshotFiles count])
									break;
									else
									continue;
								}
								
								size += [item totalSize];
								if(size / 1024 >= segmentSize * 1024)
								break;
								if((index == [snapshotFiles count]) || ((size + [(DirectoryItem*)[snapshotFiles objectAtIndex:index] totalSize]) / 1024 >= segmentSize * 1024))
								break;
							}
							if(index == [snapshotFiles count])
							break;
						}
					}
					
					//Create snapshots and archives
					count = 0;
					index = 0;
					while(1) {
						//Create a local autorelease pool
						[localPool release];
						localPool = [NSAutoreleasePool new];
						
						//Check if we need to create segmented archives
						if(segmentSize > 0) {
							count += 1;
							UPDATE_STATUS(kBackupControllerStatus_Segment_Begin, count, segments);
							
							//Create a temporary snapshot directory
							backupPath = MAKE_TMP_PATH();
							completed = [manager createDirectoryAtPath:backupPath withIntermediateDirectories:NO attributes:nil error:&error];
							if(completed == NO) {
								REPORT_GENERIC_ERROR(kBackupControllerErrorCode_CreatingDirectory, error, YES, backupPath, nil);
								break;
							}
							
							//Move items from snapshot directory to temporary one until we exceed the maximum segment size
							size = 0;
							while(1) {
								item = [snapshotFiles objectAtIndex:index++];
								if([item isDirectory]) {
									if(index == [snapshotFiles count])
									break;
									else
									continue;
								}
								if([_delegate backupControllerShouldAbort:self]) {
									completed = NO;
									break;
								}
								
								//Store the part number in the item
								[scanner setUserInfo:[NSNumber numberWithUnsignedInteger:count] forDirectoryItemAtSubpath:[item path]];
								
								//Create intermediate directories if necessary
								string = [[item path] stringByDeletingLastPathComponent];
								if([string length]) {
									string = [backupPath stringByAppendingPathComponent:string]; 
									if(![manager fileExistsAtPath:string]) {
										completed = [manager createDirectoryAtPath:string withIntermediateDirectories:YES attributes:nil error:&error];
										if(completed == NO) {
											REPORT_GENERIC_ERROR(kBackupControllerErrorCode_CreatingDirectory, error, YES, string, nil);
											break;
										}
									}
								}
								
								//Move the item
								completed = [manager moveItemAtPath:[snapshotPath stringByAppendingPathComponent:[item path]] toPath:[backupPath stringByAppendingPathComponent:[item path]] error:&error];
								if(completed == NO) {
									REPORT_GENERIC_ERROR(kBackupControllerErrorCode_MovingItem, error, YES, [snapshotPath stringByAppendingPathComponent:[item path]], [backupPath stringByAppendingPathComponent:[item path]]);
									break;
								}
								
								//Update the total size and make sure we are not above the limit
								size += [item totalSize];
								if(size / 1024 >= segmentSize * 1024)
								break;
								if((index == [snapshotFiles count]) || ((size + [(DirectoryItem*)[snapshotFiles objectAtIndex:index] totalSize]) / 1024 >= segmentSize * 1024))
								break;
							}
							
							path = [[[archivePath stringByDeletingPathExtension] stringByAppendingFormat:kSegmentFormat, count] stringByAppendingPathExtension:[archivePath pathExtension]];
						}
						else {
							//Use the entire snapshot directory
							backupPath = snapshotPath;
							path = archivePath;
							completed = YES;
						}
						
						//Create the archive
						if((completed == YES) && ![_delegate backupControllerShouldAbort:self]) {
							if([[scanner userInfoForKey:kBackupScannerUserInfoKey_DiskImage] boolValue]) {
								UPDATE_STATUS(kBackupControllerStatus_CreatingDiskImage, 0, 0);
								completed = [[DiskImageController sharedDiskImageController] makeCompressedDiskImageAtPath:path withName:(count > 0 ? [backupName stringByAppendingFormat:kSegmentFormat, count] : backupName) contentsOfDirectory:backupPath password:password];
								UPDATE_STATUS(kBackupControllerStatus_Idle, 0, 0);
								if(completed == NO) {
									REPORT_GENERIC_ERROR(kBackupControllerErrorCode_CreatingDiskImage, nil, YES, backupPath, path);
									path = nil;
								}
							}
							else {
								arguments = [NSMutableArray arrayWithObjects:@"-c", @"--noacl", /*@"--noqtn", @"--noextattr",*/ nil];
								if([[scanner userInfoForKey:kBackupScannerUserInfoKey_Compressed] boolValue])
								[arguments addObject:@"-k"];
								[arguments addObject:backupPath];
								[arguments addObject:path];
								UPDATE_STATUS(kBackupControllerStatus_CreatingArchive, 0, 0);
								completed = ([Task runWithToolPath:kDittoToolPath arguments:arguments inputString:nil timeOut:0.0] ? YES : NO);
								UPDATE_STATUS(kBackupControllerStatus_Idle, 0, 0);
								if(completed == NO) {
									REPORT_GENERIC_ERROR(kBackupControllerErrorCode_CreatingArchive, nil, YES, backupPath, path);
									path = nil;
								}
							}
						}
						else {
							completed = NO;
							path = nil;
						}
						
						//Upload the archive
#if __FAST_FILE_SCHEME__
						if([_transferController isMemberOfClass:[LocalTransferController class]]) {
							if(completed == YES)
							[uploadedFiles addObject:path];
							if([_delegate backupControllerShouldAbort:self])
							completed = NO;
						}
						else
#endif
						{
							if((completed == YES) && ![_delegate backupControllerShouldAbort:self]) {
								if(count > 0)
								string = [[backupName stringByAppendingFormat:kSegmentFormat, count] stringByAppendingPathExtension:[path pathExtension]];
								else
								string = [backupName stringByAppendingPathExtension:[path pathExtension]];
								[uploadedFiles addObject:string];
								do {
									UPDATE_STATUS(kBackupControllerStatus_UploadingFile, 0, 0);
									completed = [_transferController uploadFileFromPath:path toPath:string];
									UPDATE_STATUS(kBackupControllerStatus_Idle, 0, 0);
								} while(!completed && ![_delegate backupControllerShouldAbort:self] && [_delegate backupController:self shouldRetryFileTransferWithURL:[_transferController absoluteURLForRemotePath:string]]);
								if((completed == NO) && ![_delegate backupControllerShouldAbort:self])
								REPORT_GENERIC_ERROR(kBackupControllerErrorCode_UploadingFile, nil, YES, path, string);
							}
							else
							completed = NO;
						}
						
						//Delete the archive
#if __FAST_FILE_SCHEME__
						if(![_transferController isMemberOfClass:[LocalTransferController class]])
#endif
						{
							if(path && ![manager removeItemAtPath:path error:&error]) {
								success = NO;
								REPORT_GENERIC_ERROR(kBackupControllerErrorCode_DeletingItem, error, NO, path, nil);
							}
						}
						
						//In case of segmented archives, delete the temporary snapshot directory and also check if we are done
						if(count > 0) {
							if(![manager removeItemAtPath:backupPath error:&error]) {
								success = NO;
								REPORT_GENERIC_ERROR(kBackupControllerErrorCode_DeletingItem, error, NO, backupPath, nil);
							}
							
							UPDATE_STATUS(kBackupControllerStatus_Segment_End, count, segments);
							
							if(index == [snapshotFiles count])
							break;
						}
						else
						break;
						
						if(completed == NO)
						break;
					}
					[localPool release];
					localPool = nil;
				}
				else
				completed = YES;
			}
			else
			completed = NO;
			
			//Delete snapshot directory
			if(![manager removeItemAtPath:snapshotPath error:&error]) {
				success = NO;
				REPORT_GENERIC_ERROR(kBackupControllerErrorCode_DeletingItem, error, NO, snapshotPath, nil);
			}
			
			if(completed == NO)
			goto Exit;
		}
		
		//Remember results
		if(allResults) {
			[[allResults objectForKey:kDirectoryScannerResultKey_ModifiedItems_Data] sortUsingFunction:_PathSortFunction context:NULL];
			[[allResults objectForKey:kDirectoryScannerResultKey_AddedItems] sortUsingFunction:_PathSortFunction context:NULL];
			[[allResults objectForKey:kDirectoryScannerResultKey_RemovedItems] sortUsingFunction:_PathSortFunction context:NULL];
			[scanner setUserInfo:allResults forKey:kBackupScannerUserInfoKey_Differences];
		}
		
		//Remember end date
		[scanner setUserInfo:[NSDate date] forKey:kBackupScannerUserInfoKey_EndDate];
		
		//Create BOM file from scanner and upload it
#if __FAST_FILE_SCHEME__
		if([_transferController isMemberOfClass:[LocalTransferController class]]) {
			path = [[[_transferController baseURL] path] stringByAppendingPathComponent:[backupName stringByAppendingPathExtension:kBOMFileExtension]];
			completed = [scanner writeToFile:path];
			if(completed == NO) {
				REPORT_GENERIC_ERROR(kBackupControllerErrorCode_WritingFile, nil, NO, path, nil);
				goto Exit;
			}
		}
		else
#endif
		{
			path = MAKE_TMP_PATH();
			completed = [scanner writeToFile:path];
			if(completed) {
				[uploadedFiles addObject:[backupName stringByAppendingPathExtension:kBOMFileExtension]];
				do {
					UPDATE_STATUS(kBackupControllerStatus_UploadingFile, 0, 0);
					completed = [_transferController uploadFileFromPath:path toPath:[backupName stringByAppendingPathExtension:kBOMFileExtension]];
					UPDATE_STATUS(kBackupControllerStatus_Idle, 0, 0);
				} while(!completed && ![_delegate backupControllerShouldAbort:self] && [_delegate backupController:self shouldRetryFileTransferWithURL:[_transferController absoluteURLForRemotePath:[backupName stringByAppendingPathExtension:kBOMFileExtension]]]);
				if((completed == NO) && ![_delegate backupControllerShouldAbort:self])
				REPORT_GENERIC_ERROR(kBackupControllerErrorCode_UploadingFile, nil, YES, path, [backupName stringByAppendingPathExtension:kBOMFileExtension]);
				
				if(![manager removeItemAtPath:path error:&error]) {
					success = NO;
					REPORT_GENERIC_ERROR(kBackupControllerErrorCode_DeletingItem, error, NO, path, nil);
				}
				
				if(completed == NO)
				goto Exit;
			}
			else
			REPORT_GENERIC_ERROR(kBackupControllerErrorCode_WritingFile, nil, YES, path, nil);
		}
	}
	
	//We're done!
	result = [NSNumber numberWithBool:success];
	goto Done;
	
Exit:
	//Delete all files uploaded so far
#if __FAST_FILE_SCHEME__
	if([_transferController isMemberOfClass:[LocalTransferController class]]) {
		for(path in uploadedFiles) {
			if(![manager removeItemAtPath:path error:&error])
			NSLog(@"%s: Failed deleting \"%@\":\n%@", __FUNCTION__, path, error);
		}
	}
	else
#endif
	for(path in uploadedFiles) {
		if(![_transferController deleteFileAtPath:path])
		NSLog(@"%s: Failed deleting \"%@\"", __FUNCTION__, [[_transferController absoluteURLForRemotePath:path] absoluteString]);
	}
	
Done:
	//Run post-backup executable if any
	if((path = [parameters objectForKey:@"postExecutable"])) {
		UPDATE_STATUS(kBackupControllerStatus_RunningExecutable, 0, 0);
		completed = _RunExecutable(path, sourcePath, destinationString, [result description], nil);
		UPDATE_STATUS(kBackupControllerStatus_Idle, 0, 0);
		if(completed == NO)
		REPORT_GENERIC_ERROR(kBackupControllerErrorCode_RunningExecutable, nil, NO, path, nil);
	}

	//Reset active transfer controller
	_transferController = nil;

	return result;
}

- (id) update:(NSDictionary*)parameters
{
	return [self backup:[NSDictionary dictionaryWithObjectsAndKeys:[parameters objectForKey:@"backup"], @"destination", [parameters objectForKey:@"dryRun"], @"dryRun", nil]];
}

- (id) list:(NSDictionary*)parameters
{
	NSMutableArray*				list = nil;
	NSDictionary*				results;
	NSString*					path;
	NSInteger					index;
	
	//Create a transfer controller to this URL
	UPDATE_STATUS(kBackupControllerStatus_AccessingDestination, 0, 0);
	_transferController = [FileTransferController fileTransferControllerWithURL:_URLFromDestination([parameters objectForKey:@"backup"])];
	UPDATE_STATUS(kBackupControllerStatus_Idle, 0, 0);
	if(_transferController == nil)
	return nil;
	[_transferController setDelegate:self];
	
	CHECK_IMMEDIATE_ABORT();
	
	//Get the list of all files
#if __FAST_FILE_SCHEME__
	if([_transferController isMemberOfClass:[LocalTransferController class]]) {
		results = [_transferController contentsOfDirectoryAtPath:nil];
		if(results == nil)
		goto Exit;
	}
	else
#endif
	{
		UPDATE_STATUS(kBackupControllerStatus_CheckingDestination, 0, 0);
		results = [_transferController contentsOfDirectoryAtPath:nil];
		UPDATE_STATUS(kBackupControllerStatus_Idle, 0, 0);
		if(results == nil) {
			if(![_delegate backupControllerShouldAbort:self])
			REPORT_GENERIC_ERROR(kBackupControllerErrorCode_CheckingDestination, nil, YES, [[_transferController absoluteURLForRemotePath:nil] absoluteString], nil);
			goto Exit;
		}
	}
	
	//Only keep BOM files
	list = [NSMutableArray array];
	for(path in [[results allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
		if(![path hasSuffix:kBOMFileExtension])
		continue;
		
		index = [[path substringFromIndex:[kBackupPrefix length]] integerValue] - 1;
		if(index < [list count]) {
			REPORT_GENERIC_ERROR(kBackupControllerErrorCode_CheckingDestination, nil, YES, [[_transferController absoluteURLForRemotePath:nil] absoluteString], nil);
			list = nil;
			return NO;
		}
		while([list count] < index)
		[list addObject:[NSNull null]];
		[list insertObject:[[results objectForKey:path] objectForKey:NSFileModificationDate] atIndex:index];
	}
	
Exit:
	_transferController = nil;
	
	return list;
}

- (id) info:(NSDictionary*)parameters
{
	DirectoryScanner*			scanner = nil;
	
	//Create a transfer controller to this URL
	UPDATE_STATUS(kBackupControllerStatus_AccessingDestination, 0, 0);
	_transferController = [FileTransferController fileTransferControllerWithURL:_URLFromDestination([parameters objectForKey:@"backup"])];
	UPDATE_STATUS(kBackupControllerStatus_Idle, 0, 0);
	if(_transferController == nil)
	return nil;
	[_transferController setDelegate:self];
	
	CHECK_IMMEDIATE_ABORT();
	
	//Retrieve the directory scanner
	scanner = [self _scannerForRevision:[[parameters objectForKey:@"revision"] integerValue] fileTransferController:_transferController];
	if(scanner == (DirectoryScanner*)kCFNull)
	scanner = nil;
	
Exit:
	_transferController = nil;
	
	return scanner;
}

- (id) restore:(NSDictionary*)parameters
{
	NSString*					targetPath = [[parameters objectForKey:@"target"] stringByStandardizingPath];
	NSString*					password = [parameters objectForKey:@"password"];
	NSAutoreleasePool*			localPool = nil;
	DirectoryScanner*			scanner = nil;
	BOOL						success = YES,
								completed;
	NSFileManager*				manager;
	NSString*					archivePath;
	DirectoryItem*				item;
	DirectoryItem*				info;
	NSError*					error;
	NSString*					snapshotPath;
	NSString*					path;
	NSMutableArray*				arguments;
	NSMutableArray*				array;
	NSMutableDictionary*		items;
	id							key;
	NSString*					sourcePath;
	NSUInteger					index,
								count,
								segments,
								segment;
	NSUInteger					params[2];
	
	//Create our custom file manager
	manager = [[NSFileManager new] autorelease];
	[manager setDelegate:self];
	
	//Create a transfer controller to this URL
	UPDATE_STATUS(kBackupControllerStatus_AccessingDestination, 0, 0);
	_transferController = [FileTransferController fileTransferControllerWithURL:_URLFromDestination([parameters objectForKey:@"backup"])];
	UPDATE_STATUS(kBackupControllerStatus_Idle, 0, 0);
	if(_transferController == nil)
	return nil;
	[_transferController setDelegate:self];
	
	CHECK_IMMEDIATE_ABORT();
	
	//Retrieve the directory scanner
	scanner = [self _scannerForRevision:[[parameters objectForKey:@"revision"] integerValue] fileTransferController:_transferController];
	if((scanner == nil) || (scanner == (DirectoryScanner*)kCFNull))
	goto Exit;
	item = [scanner directoryItemAtSubpath:[parameters objectForKey:@"item"]];
	if(item == nil) {
		REPORT_GENERIC_ERROR(kBackupControllerErrorCode_RetrievingBOMEntry, nil, YES, [parameters objectForKey:@"item"], nil);
		goto Exit;
	}
	
	CHECK_IMMEDIATE_ABORT();
	
	//Erase previous item if any and prepare for restoration
	if(targetPath)
	targetPath = [targetPath stringByAppendingPathComponent:[[item path] lastPathComponent]];
	else
	targetPath = [[scanner rootDirectory] stringByAppendingPathComponent:[item path]];
	if([manager fileExistsAtPath:targetPath] && ![manager removeItemAtPath:targetPath error:&error]) {
		REPORT_GENERIC_ERROR(kBackupControllerErrorCode_DeletingItem, error, YES, targetPath, nil);
		goto Exit;
	}
	path = [targetPath stringByDeletingLastPathComponent];
	if(![manager fileExistsAtPath:path] && ![manager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&error]) {
		REPORT_GENERIC_ERROR(kBackupControllerErrorCode_CreatingDirectory, error, YES, path, nil);
		goto Exit;
	}
	if([item isDirectory]) {
		if(![manager createDirectoryAtPath:targetPath withIntermediateDirectories:NO attributes:nil error:&error]) {
			REPORT_GENERIC_ERROR(kBackupControllerErrorCode_CreatingDirectory, error, YES, targetPath, nil);
			goto Exit;
		}
		sourcePath = [item path];
	}
	else {
		targetPath = [targetPath stringByDeletingLastPathComponent];
		sourcePath = [[item path] stringByDeletingLastPathComponent];
	}
	
	//Get list of all items to restore
	if([item isDirectory])
	array = (NSMutableArray*)[scanner contentsOfDirectoryAtSubpath:[item path] recursive:YES useAbsolutePaths:NO];
	else
	array = (NSMutableArray*)[NSArray arrayWithObject:item]; //WARNING: "item" has an absolute path, not relative to "sourcePath"
	
	//Group items by archive revision / part and isolate directories
	items = [NSMutableDictionary dictionary];
	for(info in array) {
		if([info isDirectory])
		key = [NSNull null];
		else {
			params[0] = [info revision];
			params[1] = [[info userInfo] unsignedIntegerValue];
			key = [[NSData alloc] initWithBytes:params length:sizeof(params)];
		}
		
		array = [items objectForKey:key];
		if(array == nil) {
			array = [NSMutableArray new];
			[items setObject:array forKey:key];
			[array release];
		}
		[array addObject:info];
		
		[key release];
	}
	
	CHECK_IMMEDIATE_ABORT();
	
	//Recreate all directories
	completed = YES;
	for(info in [items objectForKey:[NSNull null]]) {
		path = [targetPath stringByAppendingPathComponent:[info path]];
		if(![manager createDirectoryAtPath:path withIntermediateDirectories:NO attributes:nil error:&error]) {
			REPORT_GENERIC_ERROR(kBackupControllerErrorCode_CreatingDirectory, error, YES, path, nil);
			completed = NO;
		}
	}
	
	//Restore files
	if(completed == YES) {
		segments = [items count];
		if([items objectForKey:[NSNull null]])
		segments -= 1;
		segment = 0;
		for(key in items) {
			//Make sure we have a group of files, not directories
			if(key == [NSNull null])
			continue;
			array = [items objectForKey:key];
			
			//Update segment status if necessary
			if(segments > 1) {
				segment += 1;
				UPDATE_STATUS(kBackupControllerStatus_Segment_Begin, segment, segments);
			}
			
			//Create a local autorelease pool
			[localPool release];
			localPool = [NSAutoreleasePool new];
			
			//Build the archive name
			[key getBytes:params length:sizeof(params)];
			path = [NSString stringWithFormat:kBackupFormat, params[0]];
			if(params[1] > 0)
			path = [path stringByAppendingFormat:kSegmentFormat, params[1]];
			if([[scanner userInfoForKey:kBackupScannerUserInfoKey_DiskImage] boolValue]) {
				if([[scanner userInfoForKey:kBackupScannerUserInfoKey_Compressed] boolValue])
				path = [path stringByAppendingPathExtension:@"dmg"];
				else
				path = [path stringByAppendingPathExtension:@"sparseimage"];
			}
			else {
				if([[scanner userInfoForKey:kBackupScannerUserInfoKey_Compressed] boolValue])
				path = [path stringByAppendingPathExtension:@"zip"];
				else
				path = [path stringByAppendingPathExtension:@"cpio"];
			}
			
			//Check the abort flag
			if([_delegate backupControllerShouldAbort:self]) {
				completed = NO;
				break;
			}
			
			//Download the archive
#if __FAST_FILE_SCHEME__
			if([_transferController isMemberOfClass:[LocalTransferController class]])
			archivePath = [[[_transferController baseURL] path] stringByAppendingPathComponent:path];
			else
#endif
			{
				archivePath = MAKE_TMP_PATH();
				do {
					UPDATE_STATUS(kBackupControllerStatus_DownloadingFile, 0, 0);
					completed = [_transferController downloadFileFromPath:path toPath:archivePath];
					UPDATE_STATUS(kBackupControllerStatus_Idle, 0, 0);
				} while(!completed && ![_delegate backupControllerShouldAbort:self] && [_delegate backupController:self shouldRetryFileTransferWithURL:[_transferController absoluteURLForRemotePath:path]]);
				if(completed == NO) {
					if(![_delegate backupControllerShouldAbort:self])
					REPORT_GENERIC_ERROR(kBackupControllerErrorCode_DownloadingFile, nil, YES, path, archivePath);
					break;
				}
			}
			
			//Extract the archive and copy the files from it
			if(![_delegate backupControllerShouldAbort:self]) {
				if([[scanner userInfoForKey:kBackupScannerUserInfoKey_DiskImage] boolValue]) {
					snapshotPath = [@"/tmp" stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
					UPDATE_STATUS(kBackupControllerStatus_MountingDiskImage, 0, 0);
					completed = ([[DiskImageController sharedDiskImageController] mountDiskImage:archivePath atPath:snapshotPath usingShadowFile:nil password:password private:YES verify:YES] ? YES : NO);
					UPDATE_STATUS(kBackupControllerStatus_Idle, 0, 0);
					if(completed) {
						path = [snapshotPath stringByAppendingPathComponent:sourcePath];
						count = [array count];
						index = 0;
						UPDATE_STATUS(kBackupControllerStatus_CopyingFiles, index, count);
						for(info in array) {
							++index;
							UPDATE_STATUS(kBackupControllerStatus_CopyingFiles, index, count);
							
							if(![manager copyItemAtPath:[path stringByAppendingPathComponent:([item isDirectory] ? [info path] : [[info path] lastPathComponent])] toPath:[targetPath stringByAppendingPathComponent:([item isDirectory] ? [info path] : [[info path] lastPathComponent])] error:&error]) {
								success = NO;
								REPORT_GENERIC_ERROR(kBackupControllerErrorCode_CopyingItem, error, NO, [path stringByAppendingPathComponent:[info path]], [targetPath stringByAppendingPathComponent:[info path]]);
							}
						}
						UPDATE_STATUS(kBackupControllerStatus_Idle, 0, 0);
						
						if(![[DiskImageController sharedDiskImageController] unmountDiskImageAtPath:snapshotPath force:NO]) {
							if(![[DiskImageController sharedDiskImageController] unmountDiskImageAtPath:snapshotPath force:YES]) {
								success = NO;
								REPORT_GENERIC_ERROR(kBackupControllerErrorCode_UnmountingDiskImage, nil, NO, snapshotPath, nil);
							}
						}
					}
					else
					REPORT_GENERIC_ERROR(kBackupControllerErrorCode_MountingDiskImage, nil, YES, archivePath, snapshotPath);
				}
				else {
					snapshotPath = MAKE_TMP_PATH();
					arguments = [NSMutableArray arrayWithObject:@"-x"];
					if([[scanner userInfoForKey:kBackupScannerUserInfoKey_Compressed] boolValue])
					[arguments addObject:@"-k"];
					[arguments addObject:archivePath];
					[arguments addObject:snapshotPath];
					UPDATE_STATUS(kBackupControllerStatus_ExtractingArchive, 0, 0);
					completed = ([Task runWithToolPath:kDittoToolPath arguments:arguments inputString:nil timeOut:0.0] ? YES : NO);
					UPDATE_STATUS(kBackupControllerStatus_Idle, 0, 0);
					if(completed) {
						path = [snapshotPath stringByAppendingPathComponent:sourcePath];
						count = [array count];
						index = 0;
						UPDATE_STATUS(kBackupControllerStatus_CopyingFiles, index, count);
						for(info in array) {
							++index;
							UPDATE_STATUS(kBackupControllerStatus_CopyingFiles, index, count);
							
							if(![manager moveItemAtPath:[path stringByAppendingPathComponent:([item isDirectory] ? [info path] : [[info path] lastPathComponent])] toPath:[targetPath stringByAppendingPathComponent:([item isDirectory] ? [info path] : [[info path] lastPathComponent])] error:&error]) {
								success = NO;
								REPORT_GENERIC_ERROR(kBackupControllerErrorCode_CopyingItem, error, NO, [path stringByAppendingPathComponent:[info path]], [targetPath stringByAppendingPathComponent:[info path]]);
							}
						}
						UPDATE_STATUS(kBackupControllerStatus_Idle, 0, 0);
						
						if(![manager removeItemAtPath:snapshotPath error:&error]) {
							success = NO;
							REPORT_GENERIC_ERROR(kBackupControllerErrorCode_DeletingItem, error, NO, snapshotPath, nil);
						}
					}
					else
					REPORT_GENERIC_ERROR(kBackupControllerErrorCode_MountingDiskImage, nil, YES, archivePath, snapshotPath);
				}
			}
			else
			completed = NO;
			
			//Delete the downloaded archive
#if __FAST_FILE_SCHEME__
			if(![_transferController isMemberOfClass:[LocalTransferController class]])
#endif
			{
				if(![manager removeItemAtPath:archivePath error:&error]) {
					success = NO;
					REPORT_GENERIC_ERROR(kBackupControllerErrorCode_DeletingItem, error, NO, archivePath, nil);
				}
			}
			
			//Update segment status if necessary
			if(segments > 1)
			UPDATE_STATUS(kBackupControllerStatus_Segment_End, segment, segments);
			
			if(completed == NO)
			break;
		}
		[localPool release];
		localPool = nil;
	}
	
	//In case of error, delete the restored item
	if(completed == NO) {
		if([item isDirectory])
		path = targetPath;
		else
		path = [targetPath stringByAppendingPathComponent:[[item path] lastPathComponent]];
		if(![manager removeItemAtPath:path error:&error])
		REPORT_GENERIC_ERROR(kBackupControllerErrorCode_DeletingItem, error, NO, path, nil);
		goto Exit;
	}
	
	//Reset active transfer controller
	_transferController = nil;
	
	return [NSNumber numberWithBool:success];
	
Exit:
	_transferController = nil;
	return nil;
}

- (id) delete:(NSDictionary*)parameters
{
	id							result = nil;
	BOOL						completed;
	NSDictionary*				results;
	NSString*					path;
	
	//Create a transfer controller to this URL
	UPDATE_STATUS(kBackupControllerStatus_AccessingDestination, 0, 0);
	_transferController = [FileTransferController fileTransferControllerWithURL:_URLFromDestination([parameters objectForKey:@"backup"])];
	UPDATE_STATUS(kBackupControllerStatus_Idle, 0, 0);
	if(_transferController == nil)
	return nil;
	[_transferController setDelegate:self];
	
	CHECK_IMMEDIATE_ABORT();
	
	//Get the list of all files
#if __FAST_FILE_SCHEME__
	if([_transferController isMemberOfClass:[LocalTransferController class]]) {
		results = [_transferController contentsOfDirectoryAtPath:nil];
		if(results == nil)
		goto Exit;
	}
	else
#endif
	{
		UPDATE_STATUS(kBackupControllerStatus_CheckingDestination, 0, 0);
		results = [_transferController contentsOfDirectoryAtPath:nil];
		UPDATE_STATUS(kBackupControllerStatus_Idle, 0, 0);
		if(results == nil) {
			if(![_delegate backupControllerShouldAbort:self])
			REPORT_GENERIC_ERROR(kBackupControllerErrorCode_CheckingDestination, nil, YES, [[_transferController absoluteURLForRemotePath:nil] absoluteString], nil);
			goto Exit;
		}
	}
	
	//Delete all archive & BOM files
	result = [NSNumber numberWithBool:YES];
	for(path in [results allKeys]) {
		if(![path hasPrefix:kBackupPrefix])
		continue;
		
#if __FAST_FILE_SCHEME__
		if([_transferController isMemberOfClass:[LocalTransferController class]])
		completed = [_transferController deleteFileAtPath:path];
		else
#endif
		{
			UPDATE_STATUS(kBackupControllerStatus_DeletingFile, 0, 0);
			completed = [_transferController deleteFileAtPath:path];
			UPDATE_STATUS(kBackupControllerStatus_Idle, 0, 0);
		}
		if(completed == NO) {
			REPORT_GENERIC_ERROR(kBackupControllerErrorCode_DeletingFile, nil, NO, [[_transferController absoluteURLForRemotePath:path] absoluteString], nil);
			result = [NSNumber numberWithBool:NO];
		}
	}
	
Exit:
	_transferController = nil;
	
	return result;
}

@end
