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

enum {
	kType_LocalDisk = 0,
	kType_iDisk,
	kType_AmazonS3,
	kType_SecureAmazonS3,
	kType_AFP,
	kType_SMB,
	kType_FTP,
	kType_SFTP,
	kType_WebDAV,
	kType_SecureWebDAV
};

enum {
	kFormat_CompressedDiskImage = 0,
	kFormat_SparseDiskImage,
	kFormat_ZIPArchive,
	kFormat_CPIOArchive
};

enum {
	kMode_Manually = 0,
	kMode_Login,
	kMode_Mounted,
	kMode_Interval,
	kMode_Month,
	kMode_Week
};

@class Mathusalem_PreferencePane;

@interface Mathusalem_Backup : NSObject
{
	Mathusalem_PreferencePane*	preferencePane;
	NSString*					uniqueID;
	BOOL						edited;
	NSString*					originalName;
	
	NSString*					name;
								
	NSString*					source;
	NSString*					host;
	NSString*					path;
	NSString*					user;
	NSString*					password;
	NSString*					password1;
	NSString*					password2;
	NSInteger					type,
								format,
								segment,
								mode,
								hourInterval,
								day;
	BOOL						atomic,
								fullBackup,
								excludeHidden,
								inForeground,
								skipConfirmation,
								lowPriority;
	NSString*					preExecutable;
	NSString*					postExecutable;
	NSString*					scratch;
	NSMutableArray*				excludedNames;
	NSMutableArray*				excludedPaths;
	NSDate*						monthDate;
	NSDate*						weekDate;
	NSMutableDictionary*		weekDays;
	
	NSString*					_cacheDirectory;
	
	NSMutableArray*				_history;
	NSURL*						_historyURL;
	NSUInteger					_historyToken,
								_historyOperations;
}
+ (NSString*) executablePath;

- (id) initWithUniqueID:(NSString*)anID;
- (id) initWithBackup:(Mathusalem_Backup*)backup;
- (id) initWithLaunchdPlist:(NSString*)filePath;
- (BOOL) writeToLaunchdPlist:(NSString*)filePath;

- (BOOL) loadSettingsFromDestination;
- (BOOL) deleteAllDestinationFiles;
- (void) resetCache;

- (NSURL*) destinationURLIncludingPassword:(BOOL)includePassword;
- (NSArray*) executionArgumentsIncludingPassword:(BOOL)includePassword;

- (void) resetHistory;

@property(assign) Mathusalem_PreferencePane* preferencePane;
@property(readonly) NSString* uniqueID;
@property(getter=isEdited) BOOL edited;
@property(copy) NSString* originalName;

@property(copy) NSString* name;

@property(copy) NSString* source;
@property NSInteger type;
@property(copy) NSString* host;
@property(copy) NSString* path;
@property(copy) NSString* user;
@property(copy) NSString* password;
@property NSInteger format;
@property NSInteger segment;
@property(copy) NSString* password1;
@property(copy) NSString* password2;

@property NSInteger mode;
@property NSInteger hourInterval;
@property NSInteger day;
@property(copy) NSDate*	monthDate;
@property(copy) NSDate*	weekDate;
@property(readonly) NSMutableDictionary* weekDays;

@property BOOL atomic;
@property(getter=isInForeground) BOOL inForeground;
@property BOOL skipConfirmation;
@property BOOL fullBackup;
@property BOOL excludeHidden;
@property BOOL lowPriority;
@property(readonly) NSMutableArray* excludedNames;
@property(readonly) NSMutableArray* excludedPaths;
@property(copy) NSString* preExecutable;
@property(copy) NSString* postExecutable;
@property(copy) NSString* scratch;

@property(readonly, getter=isValid) BOOL valid;
@property(readonly) NSArray* history;
@property(readonly, getter=isUpdating) BOOL updating;
@end
