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

#import <sys/sysctl.h>
#import <grp.h>

#import "Mathusalem_PreferencePane.h"
#import "Mathusalem_Backup.h"
#import "DirectoryScanner.h"
#import "FileTransferController.h"
#import "NSURL+Parameters.h"
#import "Task.h"

#define kMathusalemPrefix			@"[Mathusalem] "
#define kServerTimeOut				20.0 //seconds

@interface Mathusalem_Bucket : NSObject
{
	Mathusalem_PreferencePane*	_preferencePane;
	NSURL*						_url;
	NSString*					_name;
	NSArray*					_children;
}
- (id) initWithPreferencePane:(Mathusalem_PreferencePane*)pane url:(NSURL*)url name:(NSString*)name;
@property(readonly) NSURL* url;
@property(readonly, getter=isLeaf) BOOL leaf;
@property(copy) NSArray* children;
@property(readonly) id value;
@end

@interface NSString (Mathusalem_PreferencePane)
@property(readonly, getter=isLeaf) BOOL leaf;
@property(readonly) id value;
@end

@interface Mathusalem_PreferencePane () <FileTransferControllerDelegate>
- (NSString*) _launchdPlistPathForName:(NSString*)name;
- (void) _saveBackup:(Mathusalem_Backup*)backup;
- (void) _performRegistration;
@end

@interface Mathusalem_PreferencePane (Internal)
- (void) _didFindUpdate:(NSDictionary*)info;
- (NSArray*) _updateKeysForBucket:(Mathusalem_Bucket*)bucket;
- (NSString*) _serverURLQueryString;
@end

static inline BOOL _IsUserAdmin()
{
	struct group*				info = getgrnam("admin");
	gid_t						groups[NGROUPS_MAX];
	int							count,
								i;
	
	if(info) {
		count = getgroups(NGROUPS_MAX, groups);
		for(i = 0; i < count; ++i) {
			if(groups[i] == info->gr_gid)
			return YES;
		}
	}
	
	return NO;
}

static void _launchctl(NSString* command, ...)
{
	NSMutableArray*					arguments = [NSMutableArray arrayWithObject:command];
	va_list							list;
	
	//Parse arguments
	va_start(list, command);
	while(command) {
		if((command = va_arg(list, id)))
		[arguments addObject:command];
	}
	va_end(list);
	
	//Run launchctl task
	[Task runWithToolPath:@"/bin/launchctl" arguments:arguments inputString:nil timeOut:0.0];
}

@implementation NSString (Mathusalem_PreferencePane)

- (BOOL) isLeaf
{
	return YES;
}

- (id) value
{
	return [[self copy] autorelease];
}

@end

@implementation Mathusalem_Bucket

@synthesize children=_children, url=_url;

- (id) initWithPreferencePane:(Mathusalem_PreferencePane*)pane url:(NSURL*)url name:(NSString*)name
{
	if((self = [super init])) {
		_preferencePane = pane;
		_url = [url retain];
		_name = [name copy];
		_children = nil;
	}
	
	return self;
}

- (void) dealloc
{
	[_children release];
	[_name release];
	[_url release];
	
	[super dealloc];
}

- (BOOL) isLeaf
{
	return NO;
}

- (NSArray*) children
{
	if(_children == nil)
	_children = [[_preferencePane _updateKeysForBucket:self] retain];
	
	return _children;
}

- (id) value
{
	return _name;
}

@end

@implementation Mathusalem_PreferencePane

@synthesize currentTask=_currentTask, buckets=_buckets;

+ (NSOperationQueue*) sharedOperationQueue;
{
	static NSOperationQueue*		operationQueue = nil;
	
	if(operationQueue == nil)
	operationQueue = [NSOperationQueue new];
	
	return operationQueue;
}

- (NSArray*) allBackups
{
	return [backupArrayController content];
}

- (NSString*) _launchdPlistPathForName:(NSString*)name
{
	NSString*						path;
	
	//Build path to ~/Library/LaunchAgents and optionaly append a plist name
	path = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) objectAtIndex:0];
	path = [path stringByAppendingPathComponent:@"LaunchAgents"];
	if(name)
	path = [path stringByAppendingPathComponent:[NSString stringWithFormat:@"%@%@.plist", kMathusalemPrefix, name]];
	
	return path;
}

- (void) mainViewDidLoad
{
	NSDictionary*					info;
	
	[super mainViewDidLoad];
	
	//Retrieve version info directly from bundle Info.plist and InfoPlist.strings to ensure we always have the correct one even when System Preferences loads us after replacing the bundle
	info = [NSPropertyListSerialization propertyListFromData:[NSData dataWithContentsOfFile:[[[self bundle] bundlePath] stringByAppendingPathComponent:@"Contents/Info.plist"]] mutabilityOption:NSPropertyListImmutable format:NULL errorDescription:NULL];
	_version = [[info objectForKey:@"CFBundleShortVersionString"] copy];
	info = [NSPropertyListSerialization propertyListFromData:[NSData dataWithContentsOfFile:[[self bundle] pathForResource:@"InfoPlist" ofType:@"strings"]] mutabilityOption:NSPropertyListImmutable format:NULL errorDescription:NULL];
	
	//Watch for NSTask termination - needed if the user starts some backups manually
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_taskDidTerminate:) name:NSTaskDidTerminateNotification object:nil];
	
	//Setup user interface
	[[historyBrowser cellPrototype] setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[[historyBrowser cellPrototype] setLineBreakMode:NSLineBreakByTruncatingMiddle];
	[[bucketBrowser cellPrototype] setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
	[[bucketBrowser cellPrototype] setLineBreakMode:NSLineBreakByTruncatingMiddle];
	if([info objectForKey:@"CFBundleGetInfoString"])
	[versionField setStringValue:[info objectForKey:@"CFBundleGetInfoString"]];
	[backupArrayController setSortDescriptors:[NSArray arrayWithObject:[[[NSSortDescriptor alloc] initWithKey:@"name" ascending:YES selector:@selector(caseInsensitiveCompare:)] autorelease]]];
	[namesArrayController setSortDescriptors:[NSArray arrayWithObject:[[[NSSortDescriptor alloc] initWithKey:@"string" ascending:YES selector:@selector(caseInsensitiveCompare:)] autorelease]]];
	[pathsArrayController setSortDescriptors:[NSArray arrayWithObject:[[[NSSortDescriptor alloc] initWithKey:@"string" ascending:YES selector:@selector(caseInsensitiveCompare:)] autorelease]]];
	_bucketSortDescriptors = [[NSArray arrayWithObject:[[[NSSortDescriptor alloc] initWithKey:@"value" ascending:YES] autorelease]] retain];
}

- (void) willSelect
{
	NSFileManager*			manager = [NSFileManager defaultManager];
	NSString*				path = [self _launchdPlistPathForName:nil];
	NSError*				error;
	Mathusalem_Backup*		backup;
	NSString*				string;
	
	[super willSelect];
	
	//Create ~/Library/LaunchAgents if it does not exist already
	if(![manager fileExistsAtPath:path]) {
		if(![manager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&error])
		[[NSAlert alertWithError:error] runModal];
	}
	
	//Scan ~/Library/LaunchAgents for Mathusalem plists and load them
	[backupArrayController setContent:[NSMutableArray array]];
	for(string in [manager contentsOfDirectoryAtPath:path error:NULL]) {
		if([string hasPrefix:kMathusalemPrefix]) {
			backup = [[Mathusalem_Backup alloc] initWithLaunchdPlist:[path stringByAppendingPathComponent:string]];
			if(backup) {
				[backup setPreferencePane:self];
				[backup setName:[[string stringByDeletingPathExtension] substringFromIndex:[kMathusalemPrefix length]]];
				[backup setOriginalName:[backup name]];
				[backup setEdited:NO];
				[backupArrayController addObject:backup];
				[backup release];
			}
		}
	}
	if([[backupArrayController content] count])
	[backupArrayController setSelectionIndex:0];
	
	//Setup user interface
	[tabView selectTabViewItemAtIndex:0];
}

- (void) _performRegistration
{
	id					registration = [[NSUserDefaults standardUserDefaults] objectForKey:kUserDefaultKey_Registration];
	
	//Show registration window if user hasn't registered and it's past the registration date
	if(registration == nil) {
		[[NSUserDefaults standardUserDefaults] setObject:[NSDate dateWithTimeIntervalSinceNow:kRegistrationDelay] forKey:kUserDefaultKey_Registration];
		LOG(@"Registration required after %@", [[NSUserDefaults standardUserDefaults] objectForKey:kUserDefaultKey_Registration]);
	}
	else if([registration isKindOfClass:[NSDate class]]) {
		if([(NSDate*)registration timeIntervalSinceNow] < 0.0)
		[NSApp beginSheet:registrationWindow modalForWindow:[[self mainView] window] modalDelegate:nil didEndSelector:NULL contextInfo:NULL];
	}
}

- (void) didSelect
{
	[super didSelect];
	
	//Check for updates if necessary
	if(_updateCheckResult == nil) {
		_updateCheckResult = [NSNull null];
		if(![[[self bundle] bundlePath] hasPrefix:@"/Library/"] || _IsUserAdmin())
		[[Mathusalem_PreferencePane sharedOperationQueue] addOperation:[[[NSInvocationOperation alloc] initWithTarget:self selector:@selector(_checkForUpdateOperation:) object:[[self bundle] objectForInfoDictionaryKey:@"UpdateURL"]] autorelease]];
		else
		LOG(@"Disabling new version checking since installed for all users and current user is not admin");
	}
	else if([_updateCheckResult isKindOfClass:[NSDictionary dictionary]]) {
		[self _didFindUpdate:_updateCheckResult];
		_updateCheckResult = [NSNull null];
	}
	else
	[self _performRegistration];
}

- (void) _saveBackup:(Mathusalem_Backup*)backup
{
	NSFileManager*			manager = [NSFileManager defaultManager];
	NSString*				path;
	NSError*				error;
	
	//Delete the previous launchd plist if necessary
	if([backup originalName]) {
		path = [self _launchdPlistPathForName:[backup originalName]];
		_launchctl(@"unload", @"-S", @"Aqua", path, nil);
		if(![manager removeItemAtPath:path error:&error])
		[[NSAlert alertWithError:error] runModal];
	}
	
	//Create a new launchd plist
	path = [self _launchdPlistPathForName:[backup name]];
	if([backup writeToLaunchdPlist:path]) {
		[backup setOriginalName:[backup name]];
		[backup setEdited:NO];
		
		if([backup isValid])
		_launchctl(@"load", @"-S", @"Aqua", path, nil);
	}
}

- (void) _unselectAlertDidEnd:(NSAlert*)alert returnCode:(NSInteger)returnCode contextInfo:(void*)contextInfo
{
	Mathusalem_Backup*		backup;
	
	//Remove sheet immediately
	[[alert window] orderOut:nil];
	
	//Save all edited backups if the user wants it
	if(returnCode == NSAlertOtherReturn)
	[self replyToShouldUnselect:NSUnselectCancel];
	else {
		if(returnCode == NSAlertDefaultReturn) {
			for(backup in [backupArrayController content]) {
				if([backup isEdited])
				[self _saveBackup:backup];
			}
		}
		[self replyToShouldUnselect:NSUnselectNow];
	}
}

- (NSPreferencePaneUnselectReply) shouldUnselect
{
	Mathusalem_Backup*		backup;
	NSAlert*				alert;
	
	//Check if there are any edited backups
	for(backup in [backupArrayController content]) {
		if([backup isEdited]) {
			alert = [NSAlert alertWithMessageText:LOCALIZED_STRING(@"UNSELECT_TITLE") defaultButton:LOCALIZED_STRING(@"UNSELECT_DEFAULT_BUTTON") alternateButton:LOCALIZED_STRING(@"UNSELECT_ALTERNATE_BUTTON") otherButton:LOCALIZED_STRING(@"UNSELECT_OTHER_BUTTON") informativeTextWithFormat:LOCALIZED_STRING(@"UNSELECT_MESSAGE")];
			[alert beginSheetModalForWindow:[[self mainView] window] modalDelegate:self didEndSelector:@selector(_unselectAlertDidEnd:returnCode:contextInfo:) contextInfo:NULL];
			return NSUnselectLater;
		}
	}
	
	return NSUnselectNow;
}

- (void) willUnselect
{
	[super willUnselect];
	
	[[Mathusalem_PreferencePane sharedOperationQueue] cancelAllOperations];
	[[Mathusalem_PreferencePane sharedOperationQueue] waitUntilAllOperationsAreFinished];
}

- (void) didUnselect
{
	//Reset history tree controller
	[historyTreeController unbind:@"content"];
	[historyTreeController setContent:nil];
	
	//Remove all loaded backups
	[backupArrayController setContent:nil];
	
	[super didUnselect];
}

- (void) tabView:(NSTabView*)tabView willSelectTabViewItem:(NSTabViewItem*)tabViewItem
{
	//Setup history tree controller
	if([[tabViewItem identifier] isEqualToString:@"history"]) {
		[historyTreeController bind:@"content" toObject:backupArrayController withKeyPath:@"selection.history" options:[NSDictionary dictionaryWithObject:[NSNumber numberWithBool:YES] forKey:NSRaisesForNotApplicableKeysBindingOption]];
		[historyTreeController rearrangeObjects];
		
		[progressSpinner startAnimation:nil]; //NOTE: For some reason, we need to always force animation to start
	}
}

- (void) tabView:(NSTabView*)tabView didSelectTabViewItem:(NSTabViewItem*)tabViewItem
{
	//Reset history tree controller
	if(![[tabViewItem identifier] isEqualToString:@"history"])
	[historyTreeController unbind:@"content"];
}

- (BOOL) isBackupNameUnique:(NSString*)name
{
	Mathusalem_Backup*		backup;
	
	//Check name against all existing backup names
	for(backup in [backupArrayController content]) {
		if([name caseInsensitiveCompare:[backup name]] == NSOrderedSame)
		return NO;
	}
	
	return YES;
}

@end

@implementation Mathusalem_PreferencePane (Actions)

- (IBAction) addBackup:(id)sender
{
	NSUInteger				index = 0;
	NSString*				name;
	Mathusalem_Backup*		backup;
	
	//Make a unique name
	do {
		name = [NSString stringWithFormat:LOCALIZED_STRING(@"BACKUP_NAME"), ++index];
	} while(![self isBackupNameUnique:name]);
	
	//Check if the user wants to duplicate an existing backup
	if(([[NSApp currentEvent] modifierFlags] & NSAlternateKeyMask) && ([backupArrayController selectionIndex] != NSNotFound))
	backup = [[backupArrayController arrangedObjects] objectAtIndex:[backupArrayController selectionIndex]];
	else
	backup = nil;
	
	//Create backup
	if(backup)
	backup = [[Mathusalem_Backup alloc] initWithBackup:backup];
	else
	backup = [Mathusalem_Backup new];
	[backup setPreferencePane:self];
	[backup setName:name];
	[backup setEdited:YES];
	[backupArrayController addObject:backup];
	[backup release];
	
	//Make sure new backup is visible in list
	[backupTableView scrollRowToVisible:[backupArrayController selectionIndex]];
}

- (void) _removeAlertDidEnd:(NSAlert*)alert returnCode:(NSInteger)returnCode contextInfo:(void*)contextInfo
{
	Mathusalem_Backup*		backup = [[backupArrayController arrangedObjects] objectAtIndex:[backupArrayController selectionIndex]];
	NSFileManager*			manager = [NSFileManager defaultManager];
	NSString*				path;
	NSError*				error;
	
	//Delete the backup if the user confirmed the action
	if(returnCode != NSAlertDefaultReturn) {
		if(returnCode == NSAlertAlternateReturn) {
			if(![backup deleteAllDestinationFiles])
			[[NSAlert alertWithMessageText:LOCALIZED_STRING(@"DELETE_FAILED_TITLE") defaultButton:LOCALIZED_STRING(@"DELETE_FAILED_DEFAULT_BUTTON") alternateButton:nil otherButton:nil informativeTextWithFormat:@""] runModal];
		}
		
		[backup resetCache];
		
		path = [self _launchdPlistPathForName:[backup name]];
		if([manager fileExistsAtPath:path]) {
			_launchctl(@"unload", @"-S", @"Aqua", path, nil);
			if(![manager removeItemAtPath:path error:&error])
			[[NSAlert alertWithError:error] runModal];
		}
		[backupArrayController removeObject:backup];
	}
}

- (IBAction) removeBackup:(id)sender
{
	NSAlert*				alert;
	
	//Prompt the user for confirmation
	alert = [NSAlert alertWithMessageText:LOCALIZED_STRING(@"BACKUP_REMOVE_TITLE") defaultButton:LOCALIZED_STRING(@"BACKUP_REMOVE_DEFAULT_BUTTON") alternateButton:LOCALIZED_STRING(@"BACKUP_REMOVE_ALTERNATE_BUTTON") otherButton:LOCALIZED_STRING(@"BACKUP_REMOVE_OTHER_BUTTON") informativeTextWithFormat:LOCALIZED_STRING(@"BACKUP_REMOVE_MESSAGE")];
	[alert beginSheetModalForWindow:[[self mainView] window] modalDelegate:self didEndSelector:@selector(_removeAlertDidEnd:returnCode:contextInfo:) contextInfo:NULL];
}

- (IBAction) saveBackup:(id)sender
{
	Mathusalem_Backup*		backup = [[backupArrayController arrangedObjects] objectAtIndex:[backupArrayController selectionIndex]];
	
	if([[NSApp currentEvent] modifierFlags] & NSAlternateKeyMask) {
		if(![backup loadSettingsFromDestination])
		NSBeep();
	}
	else
	[self _saveBackup:backup];
}

- (void) _taskDidTerminate:(NSNotification*)notification
{
	//Check if the terminated task is our current Backup task
	if([notification object] == _currentTask) {
		[self willChangeValueForKey:@"currentTask"];
		[_currentTask release];
		_currentTask = nil;
		[self didChangeValueForKey:@"currentTask"];
	}
}

- (IBAction) runBackup:(id)sender
{
	Mathusalem_Backup*		backup = [[backupArrayController arrangedObjects] objectAtIndex:[backupArrayController selectionIndex]];
	NSArray*				arguments = [backup executionArgumentsIncludingPassword:YES];
	NSTask*					task;
	
	//Fix launch arguments
	[(NSMutableArray*)arguments addObject:@"-password"];
	[(NSMutableArray*)arguments addObject:([backup password1] && [backup password2] ? [backup password1] : @"")];
	[(NSMutableArray*)arguments removeObject:@"--prompt"];
	if(![arguments containsObject:@"--foreground"])
	[(NSMutableArray*)arguments addObject:@"--foreground"];
	if([[NSApp currentEvent] modifierFlags] & NSAlternateKeyMask)
	[(NSMutableArray*)arguments addObject:@"--dryRun"];
	
	//Launch Mathusalem task
	task = [NSTask new];
	[task setLaunchPath:[Mathusalem_Backup executablePath]];
	[task setArguments:arguments];
	@try {
#ifdef __DEBUG__
		LOG(@"Launching Mathusalem application with arguments:\n%@", arguments);
#else
		LOG(@"Launching Mathusalem application...");
#endif
		[task launch];
	}
	@catch(NSException* localException) {
		LOG(@"<FAILED> %@", localException);
		[task release];
		return;
	}
	
	//Reset backup history
	[backup resetHistory];
	
	//Remember the task so that we can know when it has terminated
	[self willChangeValueForKey:@"currentTask"];
	_currentTask = task;
	[self didChangeValueForKey:@"currentTask"];
}

- (void) _sourcePanelDidEnd:(NSSavePanel*)sheet returnCode:(NSInteger)returnCode contextInfo:(void*)contextInfo
{
	Mathusalem_Backup*		backup = [[backupArrayController arrangedObjects] objectAtIndex:[backupArrayController selectionIndex]];
	NSString*				path = [[sheet filename] stringByAbbreviatingWithTildeInPath];
	NSError*				error;
	
	//Set source path
	if(returnCode == NSFileHandlingPanelOKButton) {
		if(![[backup source] isEqualToString:path]) {
			if([backup validateValue:&path forKey:@"source" error:&error])
			[backup setSource:path];
			else
			[[NSAlert alertWithError:error] runModal];
		}
	}
}

- (IBAction) chooseSource:(id)sender
{
	Mathusalem_Backup*		backup = [[backupArrayController arrangedObjects] objectAtIndex:[backupArrayController selectionIndex]];
	NSOpenPanel*			openPanel = [NSOpenPanel openPanel];
	
	//Ask user to select source
	[openPanel setCanChooseFiles:NO];
	[openPanel setCanChooseDirectories:YES];
	[openPanel beginSheetForDirectory:[backup source] file:nil modalForWindow:[[self mainView] window] modalDelegate:self didEndSelector:@selector(_sourcePanelDidEnd:returnCode:contextInfo:) contextInfo:NULL];
}

- (void) _destinationPanelDidEnd:(NSSavePanel*)sheet returnCode:(NSInteger)returnCode contextInfo:(void*)contextInfo
{
	Mathusalem_Backup*		backup = [[backupArrayController arrangedObjects] objectAtIndex:[backupArrayController selectionIndex]];
	NSString*				path = [sheet filename];
	
	//Set destination path
	if(returnCode == NSFileHandlingPanelOKButton) {
		if(![[backup path] isEqualToString:path])
		[backup setPath:path];
	}
}

- (IBAction) chooseDestination:(id)sender
{
	Mathusalem_Backup*		backup = [[backupArrayController arrangedObjects] objectAtIndex:[backupArrayController selectionIndex]];
	NSOpenPanel*			openPanel = [NSOpenPanel openPanel];
	
	//Ask user to select destination
	[openPanel setCanChooseFiles:NO];
	[openPanel setCanChooseDirectories:YES];
	[openPanel setCanCreateDirectories:YES];
	[openPanel beginSheetForDirectory:[backup path] file:nil modalForWindow:[[self mainView] window] modalDelegate:self didEndSelector:@selector(_destinationPanelDidEnd:returnCode:contextInfo:) contextInfo:NULL];
}

- (void) _executablePanelDidEnd:(NSSavePanel*)sheet returnCode:(NSInteger)returnCode contextInfo:(void*)contextInfo
{
	Mathusalem_Backup*		backup = [[backupArrayController arrangedObjects] objectAtIndex:[backupArrayController selectionIndex]];
	NSString*				path = [sheet filename];
	NSError*				error;
	
	//Dismiss open panel
	[NSApp endSheet:sheet];
	[sheet orderOut:nil];
	
	//Set executable path
	if(returnCode == NSFileHandlingPanelOKButton) {
		if(contextInfo) {
			if(![[backup postExecutable] isEqualToString:path]) {
				if([backup validateValue:&path forKey:@"postExecutable" error:&error])
				[backup setPostExecutable:path];
				else
				[[NSAlert alertWithError:error] runModal];
			}
		}
		else {
			if(![[backup preExecutable] isEqualToString:path]) {
				if([backup validateValue:&path forKey:@"preExecutable" error:&error])
				[backup setPreExecutable:path];
				else
				[[NSAlert alertWithError:error] runModal];
			}
		}
	}
}

- (IBAction) chooseExecutable:(id)sender
{
	Mathusalem_Backup*		backup = [[backupArrayController arrangedObjects] objectAtIndex:[backupArrayController selectionIndex]];
	NSOpenPanel*			openPanel = [NSOpenPanel openPanel];
	NSString*				executable = ([(NSButton*)sender tag] ? [backup postExecutable] : [backup preExecutable]);
	
	//Ask user to select executable
	[openPanel setCanChooseFiles:YES];
	[openPanel setCanChooseDirectories:NO];
	[openPanel beginSheetForDirectory:[executable stringByDeletingLastPathComponent] file:[executable lastPathComponent] modalForWindow:[[self mainView] window] modalDelegate:self didEndSelector:@selector(_executablePanelDidEnd:returnCode:contextInfo:) contextInfo:([(NSButton*)sender tag] ? (void*)kCFNull : NULL)];
}

- (void) _scratchPanelDidEnd:(NSSavePanel*)sheet returnCode:(NSInteger)returnCode contextInfo:(void*)contextInfo
{
	Mathusalem_Backup*		backup = [[backupArrayController arrangedObjects] objectAtIndex:[backupArrayController selectionIndex]];
	NSString*				path = [sheet filename];
	
	//Set scratch path
	if(returnCode == NSFileHandlingPanelOKButton) {
		if(![[backup scratch] isEqualToString:path])
		[backup setScratch:path];
	}
}

- (IBAction) chooseScratch:(id)sender
{
	Mathusalem_Backup*		backup = [[backupArrayController arrangedObjects] objectAtIndex:[backupArrayController selectionIndex]];
	NSOpenPanel*			openPanel = [NSOpenPanel openPanel];
	
	//Ask user to select scratch
	[openPanel setCanChooseFiles:NO];
	[openPanel setCanChooseDirectories:YES];
	[openPanel setCanCreateDirectories:YES];
	[openPanel beginSheetForDirectory:[backup scratch] file:nil modalForWindow:[[self mainView] window] modalDelegate:self didEndSelector:@selector(_scratchPanelDidEnd:returnCode:contextInfo:) contextInfo:NULL];
}

- (IBAction) doneEditingBuckets:(id)sender
{
	Mathusalem_Backup*		backup = [[backupArrayController arrangedObjects] objectAtIndex:[backupArrayController selectionIndex]];
	
	//Dismiss bucket editor window
	[NSApp endSheet:bucketWindow];
	[bucketWindow orderOut:nil];
	
	//Reset state
	[bucketProgress stopAnimation:nil];
	[self setBuckets:nil];
	[backup resetHistory];
}

+ (void) fileTransferControllerDidFail:(FileTransferController*)controller withError:(NSError*)error
{
	LOG(@"%@", error);
}

- (void) _didUpdateKeys:(NSArray*)arguments
{
	Mathusalem_Bucket*		bucket = [arguments objectAtIndex:0];
	NSDictionary*			contents = ([arguments count] > 1 ? [arguments objectAtIndex:1] : nil);
	
	//Decrease updating count
	[self willChangeValueForKey:@"updatingBuckets"];
	_updatingBuckets -= 1;
	[self didChangeValueForKey:@"updatingBuckets"];
	
	//Update select bucket children
	if([_buckets containsObject:bucket])
	[bucket setChildren:(contents ? [[contents allKeys] sortedArrayUsingDescriptors:_bucketSortDescriptors] : [NSArray arrayWithObject:LOCALIZED_STRING(@"UNAVAILABLE_ENTRY")])];
}

- (void) _updateKeysOperation:(Mathusalem_Bucket*)bucket
{
	NSURL*					url = [NSURL URLWithScheme:@"http" user:[[bucket url] user] password:[[bucket url] passwordByReplacingPercentEscapes] host:[NSString stringWithFormat:@"%@.%@", [bucket value], [[bucket url] host]] port:0 path:nil];
	FileTransferController*	controller = [[AmazonS3TransferController alloc] initWithBaseURL:url];
	
	//Load all bucket keys and pass result to main thread
	[controller setDelegate:(id<FileTransferControllerDelegate>)[self class]];
	[self performSelectorOnMainThread:@selector(_didUpdateKeys:) withObject:[NSArray arrayWithObjects:bucket, [controller contentsOfDirectoryAtPath:nil], nil] waitUntilDone:NO];
	[controller setDelegate:nil];
	
	[controller release];
}

- (NSArray*) _updateKeysForBucket:(Mathusalem_Bucket*)bucket
{
	//Increase updating count
	[self willChangeValueForKey:@"updatingBuckets"];
	_updatingBuckets += 1;
	[self didChangeValueForKey:@"updatingBuckets"];
	
	//Load selected bucket children in background
	[[Mathusalem_PreferencePane sharedOperationQueue] addOperation:[[[NSInvocationOperation alloc] initWithTarget:self selector:@selector(_updateKeysOperation:) object:bucket] autorelease]];	
	
	return [NSArray arrayWithObject:LOCALIZED_STRING(@"LOADING_ENTRY")];
}

- (void) _didUpdateBuckets:(NSArray*)arguments
{
	NSURL*					url = [arguments objectAtIndex:0];
	NSDictionary*			contents = ([arguments count] > 1 ? [arguments objectAtIndex:1] : nil);
	NSMutableArray*			buckets;
	NSString*				key;
	
	//Decrease updating count
	[self willChangeValueForKey:@"updatingBuckets"];
	_updatingBuckets -= 1;
	[self didChangeValueForKey:@"updatingBuckets"];
	
	//Update bucket list
	if([bucketWindow isVisible]) {
		buckets = [NSMutableArray new];
		for(key in contents)
		[buckets addObject:[[[Mathusalem_Bucket alloc] initWithPreferencePane:self url:url name:key] autorelease]];
		[buckets sortUsingDescriptors:_bucketSortDescriptors];
		[self setBuckets:buckets];
		[buckets release];
	}
}

- (void) _updateBucketsOperation:(NSURL*)url
{
	AmazonS3TransferController*	controller = [[AmazonS3TransferController alloc] initWithBaseURL:url];
	
	//Load all buckets and pass result to main thread
	[controller setDelegate:(id<FileTransferControllerDelegate>)[self class]];
	[self performSelectorOnMainThread:@selector(_didUpdateBuckets:) withObject:[NSArray arrayWithObjects:url, [controller contentsOfDirectoryAtPath:nil], nil] waitUntilDone:NO];
	[controller setDelegate:nil];
	
	[controller release];
}

- (void) _refreshBuckets
{
	Mathusalem_Backup*		backup = [[backupArrayController arrangedObjects] objectAtIndex:[backupArrayController selectionIndex]];
	NSURL*					url = [NSURL URLWithScheme:@"http" user:[backup user] password:[backup password] host:kFileTransferHost_AmazonS3 port:0 path:nil];
	
	//Decrease updating count
	[self willChangeValueForKey:@"updatingBuckets"];
	_updatingBuckets += 1;
	[self didChangeValueForKey:@"updatingBuckets"];
	
	//Load all buckets in background
	[[Mathusalem_PreferencePane sharedOperationQueue] addOperation:[[[NSInvocationOperation alloc] initWithTarget:self selector:@selector(_updateBucketsOperation:) object:url] autorelease]];
}

- (IBAction) doneAddingBucket:(id)sender
{
	//Dismiss bucket name window
	[NSApp stopModalWithCode:[(NSControl*)sender tag]];
	[bucketPanel orderOut:nil];
}

- (IBAction) addBucket:(id)sender
{
	Mathusalem_Backup*			backup = [[backupArrayController arrangedObjects] objectAtIndex:[backupArrayController selectionIndex]];
	AmazonS3TransferController*	controller;
	
	//Prompt user for bucket name, then create bucket & reload bucket list
	if([NSApp runModalForWindow:bucketPanel] && [[bucketTextField stringValue] length]) {
		controller = [[AmazonS3TransferController alloc] initWithAccessKeyID:[backup user] secretAccessKey:[backup password] bucket:[bucketTextField stringValue]];
		[controller setDelegate:(id<FileTransferControllerDelegate>)[self class]];
		[controller createDirectoryAtPath:nil];
		[controller setDelegate:nil];
		[controller release];
		
		[self _refreshBuckets];
	}
}

- (IBAction) removeBucket:(id)sender
{
	Mathusalem_Backup*			backup = [[backupArrayController arrangedObjects] objectAtIndex:[backupArrayController selectionIndex]];
	NSString*					name = [[bucketTreeController selection] valueForKey:@"value"];
	AmazonS3TransferController*	controller;
	NSAlert*					alert;
	NSDictionary*				contents;
	NSString*					key;
	
	//Prompt user for confirmation
	alert = [NSAlert alertWithMessageText:[NSString stringWithFormat:LOCALIZED_STRING(@"BUCKET_REMOVE_TITLE"), name] defaultButton:LOCALIZED_STRING(@"BUCKET_REMOVE_DEFAULT_BUTTON") alternateButton:nil otherButton:LOCALIZED_STRING(@"BUCKET_REMOVE_OTHER_BUTTON") informativeTextWithFormat:LOCALIZED_STRING(@"BUCKET_REMOVE_MESSAGE")];
	[alert setAlertStyle:NSCriticalAlertStyle];
	
	//Delete bucket and all its keys & reload bucket list
	if([alert runModal] == NSAlertOtherReturn) {
		controller = [[AmazonS3TransferController alloc] initWithAccessKeyID:[backup user] secretAccessKey:[backup password] bucket:[bucketTextField stringValue]];
		[controller setDelegate:(id<FileTransferControllerDelegate>)[self class]];
		contents = [controller contentsOfDirectoryAtPath:nil];
		for(key in contents)
		[controller deleteFileAtPath:key];
		[controller deleteDirectoryAtPath:nil];
		[controller setDelegate:nil];
		[controller release];
		
		[self _refreshBuckets];
	}
}

- (BOOL) isUpdatingBuckets
{
	return (_updatingBuckets > 0);
}

- (IBAction) editBuckets:(id)sender
{
	//Show bucket editor window
	[NSApp beginSheet:bucketWindow modalForWindow:[[self mainView] window] modalDelegate:nil didEndSelector:NULL contextInfo:NULL];
	[bucketProgress startAnimation:nil];
	[self _refreshBuckets];
}

- (void) _confirmAlertDidEnd:(NSSavePanel*)sheet returnCode:(NSInteger)returnCode contextInfo:(void*)contextInfo
{
	NSMutableArray*			arguments = [NSMutableArray arrayWithObject:@"restore"];
	NSTask*					task;
	
	//Autorelease parameters immediately so they don't leak
	[(id)contextInfo autorelease];
	
	//Make sure the user confirmed restoration
	if(returnCode != NSFileHandlingPanelOKButton)
	return;
	
	//Setup arguments
	[arguments addObject:@"-backup"];
	[arguments addObject:[(id)contextInfo objectForKey:@"backup"]];
	if([(id)contextInfo objectForKey:@"item"]) {
		[arguments addObject:@"-item"];
		[arguments addObject:[(id)contextInfo objectForKey:@"item"]];
	}
	if([(id)contextInfo objectForKey:@"revision"]) {
		[arguments addObject:@"-revision"];
		[arguments addObject:[[(id)contextInfo objectForKey:@"revision"] stringValue]];
	}
	if([(id)contextInfo objectForKey:@"target"]) {
		[arguments addObject:@"-target"];
		[arguments addObject:[(id)contextInfo objectForKey:@"target"]];
	}
	if([(id)contextInfo objectForKey:@"password"]) {
		[arguments addObject:@"-password"];
		[arguments addObject:[(id)contextInfo objectForKey:@"password"]];
	}
	[arguments addObject:@"--foreground"];
	
	//Launch Mathusalem task
	task = [NSTask new];
	[task setLaunchPath:[Mathusalem_Backup executablePath]];
	[task setArguments:arguments];
	@try {
#ifdef __DEBUG__
		LOG(@"Launching Mathusalem application with arguments:\n%@", arguments);
#else
		LOG(@"Launching Mathusalem application...");
#endif
		[task launch];
	}
	@catch(NSException* localException) {
		LOG(@"<FAILED> %@", localException);
		[task release];
		return;
	}
	
	//Remember the task so that we can know when it has terminated
	[self willChangeValueForKey:@"currentTask"];
	_currentTask = task;
	[self didChangeValueForKey:@"currentTask"];
}

- (void) _restorePanelDidEnd:(NSSavePanel*)sheet returnCode:(NSInteger)returnCode contextInfo:(void*)contextInfo
{
	NSAlert*			alert;
	NSString*			path;
	
	//Dismiss open panel immediately
	[sheet orderOut:nil];
	
	//Autorelease parameters immediately so they don't leak
	[(id)contextInfo autorelease];
	
	//Make sure the user confirmed restoration
	if(returnCode != NSFileHandlingPanelOKButton)
	return;
	
	//Add target to parameters
	[(id)contextInfo setObject:[sheet filename] forKey:@"target"];
	
	//If target already exist, ask user to confirm overwrite
	path = [[sheet filename] stringByAppendingPathComponent:[[(id)contextInfo objectForKey:@"item"] lastPathComponent]];
	if([[NSFileManager defaultManager] fileExistsAtPath:path]) {
		alert = [NSAlert alertWithMessageText:[NSString stringWithFormat:LOCALIZED_STRING(@"CONFIRM_TITLE"), [path stringByAbbreviatingWithTildeInPath]] defaultButton:LOCALIZED_STRING(@"CONFIRM_DEFAULT_BUTTON") alternateButton:nil otherButton:LOCALIZED_STRING(@"CONFIRM_OTHER_BUTTON") informativeTextWithFormat:LOCALIZED_STRING(@"CONFIRM_MESSAGE")];
		[alert setAlertStyle:NSCriticalAlertStyle];
		[alert beginSheetModalForWindow:[[self mainView] window] modalDelegate:self didEndSelector:@selector(_confirmAlertDidEnd:returnCode:contextInfo:) contextInfo:[(id)contextInfo retain]];
	}
	else
	[self _confirmAlertDidEnd:nil returnCode:NSFileHandlingPanelOKButton contextInfo:[(id)contextInfo retain]];
}

- (IBAction) restoreItem:(id)sender
{
	Mathusalem_Backup*		backup = [[backupArrayController arrangedObjects] objectAtIndex:[backupArrayController selectionIndex]];
	DirectoryScanner*		scanner = [[historyTreeController selection] valueForKey:@"scanner"];
	NSString*				path = [historyBrowser path];
	NSOpenPanel*			openPanel = [NSOpenPanel openPanel];
	NSMutableDictionary*	parameters;
	NSRange					range;
	
	//Build parameters
	range = [path rangeOfString:@"/" options:0 range:NSMakeRange(1, [path length] - 1)];
	path = (range.location != NSNotFound ? [path substringFromIndex:(range.location + 1)] : nil);
	parameters = [NSMutableDictionary dictionary];
	[parameters setObject:[[backup destinationURLIncludingPassword:YES] absoluteString] forKey:@"backup"];
	[parameters setObject:[NSNumber numberWithInteger:[scanner revision]] forKey:@"revision"];
	if(path)
	[parameters setObject:path forKey:@"item"];
	if([backup password1] && [backup password2])
	[parameters setObject:[backup password1] forKey:@"password"];
	
	//Ask user to select target
	[openPanel setCanChooseFiles:NO];
	[openPanel setCanChooseDirectories:YES];
	[openPanel setCanCreateDirectories:YES];
	[openPanel beginSheetForDirectory:[[scanner rootDirectory] stringByAppendingPathComponent:[path stringByDeletingLastPathComponent]] file:nil modalForWindow:[[self mainView] window] modalDelegate:self didEndSelector:@selector(_restorePanelDidEnd:returnCode:contextInfo:) contextInfo:[parameters retain]];
}

- (IBAction) openHelp:(id)sender
{
	[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:LOCALIZED_STRING(@"HELP_URL")]];
}

- (IBAction) openWebSite:(id)sender
{
	[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:[sender title]]];
}

- (NSString*) _serverURLQueryString
{
	NSMutableString*		query = [NSMutableString stringWithFormat:@"?version=%@", _version];
	size_t					length = 256;
	char*					buffer[length];
	NSString*				error;
	int						status;
	NSDictionary*			systemVersion;
	
	//Retrieve computer model
	status = sysctlbyname("hw.model", buffer, &length, NULL, 0);
	if(status == 0)
	[query appendFormat:@"&model=%s", buffer];
	else
	LOG(@"%s: sysctlbyname() failed with error %i", __FUNCTION__, status);
	
	//Retrieve OS version
	systemVersion = [NSPropertyListSerialization propertyListFromData:[NSData dataWithContentsOfFile:@"/System/Library/CoreServices/SystemVersion.plist"] mutabilityOption:NSPropertyListImmutable format:NULL errorDescription:&error];
	if([systemVersion objectForKey:@"ProductVersion"])
	[query appendFormat:@"&os=%@", [systemVersion objectForKey:@"ProductVersion"]];
	else
	LOG(@"%s: Unable to parse SystemVersion.plist (%@)", __FUNCTION__, error);
	
#ifdef __DEBUG__
	//Add debug hint
	[query appendString:@"&debug=1"];
#endif
	
	return [query stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
}

- (IBAction) doneRegistration:(id)sender
{
	NSString*				url = [[self bundle] objectForInfoDictionaryKey:@"RegistrationURL"];
	NSURLRequest*			request;
	NSURLResponse*			response;
	id						error;
	NSData*					data;
	NSNumber*				info;
	
	//Send registration information
	if([(NSButton*)sender tag]) {
		if(![[registrationCityTextField stringValue] length] || ![[registrationCountryTextField stringValue] length]) {
			NSBeep();
			return;
		}
		
		url = [url stringByAppendingString:[self _serverURLQueryString]];
		url = [url stringByAppendingFormat:@"&country=%@", [[registrationCountryTextField stringValue] stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
		if([[registrationStateTextField stringValue] length])
		url = [url stringByAppendingFormat:@"&state=%@", [[registrationStateTextField stringValue] stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
		url = [url stringByAppendingFormat:@"&city=%@", [[registrationCityTextField stringValue] stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
		if([[registrationCommentTextField stringValue] length])
		url = [url stringByAppendingFormat:@"&comment=%@", [[registrationCommentTextField stringValue] stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
		
		request = [NSURLRequest requestWithURL:[NSURL URLWithString:url] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:kServerTimeOut];
		data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
		if(data && ([(NSHTTPURLResponse*)response statusCode] == 200)) {
			info = [NSPropertyListSerialization propertyListFromData:data mutabilityOption:NSPropertyListMutableContainers format:NULL errorDescription:&error];
			if(info) {
				if([info boolValue]) {
					[[NSUserDefaults standardUserDefaults] setObject:_version forKey:kUserDefaultKey_Registration];
					LOG(@"Successfully sent registration information");
				}
				else {
					LOG(@"%s: Server side registration failed", __FUNCTION__);
					return;
				}
			}
			else
			LOG(@"%s: Unable to parse property list (%@)", __FUNCTION__, error);
		}
		else {
			LOG(@"%s: Failed sending registration info to \"%@\" (%@)", __FUNCTION__, url, error);
			return;
		}
	}
	else
	[[NSUserDefaults standardUserDefaults] removeObjectForKey:kUserDefaultKey_Registration];
	
	//Dismiss registration window
	[NSApp endSheet:registrationWindow];
	[registrationWindow orderOut:nil];
}

@end

@implementation Mathusalem_PreferencePane (AutoUpdating)

- (void) fileTransferControllerDidStart:(FileTransferController*)controller
{
	[downloadProgress setIndeterminate:NO];
}

- (void) fileTransferControllerDidUpdateProgress:(FileTransferController*)controller;
{
	[downloadProgress setDoubleValue:[controller transferProgress]];
}

- (void) fileTransferControllerDidFail:(FileTransferController*)controller withError:(NSError*)error
{
	LOG(@"%@", error);
	
	[downloadProgress setIndeterminate:YES];
}

- (void) fileTransferControllerDidSucceed:(FileTransferController*)controller
{
	[downloadProgress setIndeterminate:YES];
}

- (void) _didFinishDownload:(id)argument
{
	NSAlert*					alert;
	
	//Clean up user interface
	[downloadProgress stopAnimation:nil];
	[NSApp endSheet:downloadWindow];
	[downloadWindow orderOut:nil];
	
	//Inform user of the result
	if(argument) {
		alert = [NSAlert alertWithMessageText:LOCALIZED_STRING(@"UPDATE_SUCCESS_TITLE") defaultButton:LOCALIZED_STRING(@"UPDATE_SUCCESS_DEFAULT_BUTTON") alternateButton:nil otherButton:nil informativeTextWithFormat:LOCALIZED_STRING(@"UPDATE_SUCCESS_MESSAGE")];
		[alert setAlertStyle:NSInformationalAlertStyle];
		[alert beginSheetModalForWindow:[[self mainView] window] modalDelegate:nil didEndSelector:NULL contextInfo:NULL];
	}
	else
	[[NSAlert alertWithMessageText:LOCALIZED_STRING(@"UPDATE_FAILED_TITLE") defaultButton:LOCALIZED_STRING(@"UPDATE_FAILED_DEFAULT_BUTTON") alternateButton:nil otherButton:nil informativeTextWithFormat:LOCALIZED_STRING(@"UPDATE_FAILED_MESSAGE")] runModal];
}

- (void) _downloadUpdate:(NSURL*)url
{
	BOOL						success = NO;
	FileTransferController*		controller;
	NSString*					path;
	NSArray*					array;
	
	//Download the update file and extract it
	controller = [[HTTPTransferController alloc] initWithBaseURL:url];
	[controller setDelegate:self];
	path = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
	if([controller downloadFileFromPath:nil toPath:path]) {
		array = NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory, NSUserDomainMask, YES);
		if(![array count])
		array = NSSearchPathForDirectoriesInDomains(NSDesktopDirectory, NSUserDomainMask, YES);
		if(![array count])
		array = [NSArray arrayWithObject:NSHomeDirectory()];
		
		if([Task runWithToolPath:@"/usr/bin/ditto" arguments:[NSArray arrayWithObjects:@"-x", @"-k", path, [array objectAtIndex:0], nil] inputString:nil timeOut:0.0]) {
			[[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:[array objectAtIndex:0] isDirectory:YES]];
			success = YES;
		}
	}
	[[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
	[controller release];
	
	//Signal main thread download is done
	[self performSelectorOnMainThread:@selector(_didFinishDownload:) withObject:(success ? [NSNull null] : nil) waitUntilDone:NO];
}

- (void) _updateAlertDidEnd:(NSAlert*)alert returnCode:(NSInteger)returnCode contextInfo:(void*)contextInfo
{
	//Release update info
	[(id)contextInfo autorelease];
	
	//Remove sheet immediately
	[[alert window] orderOut:nil];
	
	//Download new version
	if(returnCode == NSAlertDefaultReturn) {
		[NSApp beginSheet:downloadWindow modalForWindow:[[self mainView] window] modalDelegate:nil didEndSelector:NULL contextInfo:NULL];
		[downloadProgress startAnimation:nil];
		
		[[Mathusalem_PreferencePane sharedOperationQueue] addOperation:[[[NSInvocationOperation alloc] initWithTarget:self selector:@selector(_downloadUpdate:) object:[NSURL URLWithString:[(NSDictionary*)contextInfo objectForKey:@"downloadURL"]]] autorelease]];
	}
}

- (void) _didFindUpdate:(NSDictionary*)info
{
	NSAlert*				alert;
	
	//Check if we can display a sheet now
	if(![self isSelected] || ([[[self mainView] window] attachedSheet] != nil)) {
		_updateCheckResult = [info retain];
		return;
	}
	
	//Prompt user to download new version
	alert = [NSAlert alertWithMessageText:[NSString stringWithFormat:LOCALIZED_STRING(@"UPDATE_TITLE"), [info objectForKey:@"version"]] defaultButton:LOCALIZED_STRING(@"UPDATE_DEFAULT_BUTTON") alternateButton:nil otherButton:LOCALIZED_STRING(@"UPDATE_OTHER_BUTTON") informativeTextWithFormat:LOCALIZED_STRING(@"UPDATE_MESSAGE"), _version];
	[alert setAlertStyle:NSInformationalAlertStyle];
	if([info objectForKey:@"releaseNotes"])
	[[webView mainFrame] loadData:[info objectForKey:@"releaseNotes"] MIMEType:@"text/html" textEncodingName:@"UTF-8" baseURL:nil];
	[alert setAccessoryView:[[webView superview] superview]];
	[alert beginSheetModalForWindow:[[self mainView] window] modalDelegate:self didEndSelector:@selector(_updateAlertDidEnd:returnCode:contextInfo:) contextInfo:[info retain]];
}

static inline BOOL _IsVersionNewer(NSString* webVersion, NSString* currentVersion)
{
	NSCharacterSet*			set = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789."] invertedSet];
	NSUInteger				webCount = [[webVersion componentsSeparatedByString:@"."] count],
							currentCount = [[currentVersion componentsSeparatedByString:@"."] count],
							i;
	
	//Make sure both versions have the same number of components
	if(webCount > currentCount) {
		for(i = 0; i < webCount - currentCount; ++i)
		currentVersion = [currentVersion stringByAppendingString:@".0"];
	}
	else if(currentCount > webCount) {
		for(i = 0; i < currentCount - webCount; ++i)
		webVersion = [webVersion stringByAppendingString:@".0"];
	}
	
	//Convert 1.0 style to 1.0z so that it's considered "greater" than 1.0b for instance
	if([webVersion rangeOfCharacterFromSet:set].location == NSNotFound)
	webVersion = [webVersion stringByAppendingString:@"z"];
	if([currentVersion rangeOfCharacterFromSet:set].location == NSNotFound)
	currentVersion = [currentVersion stringByAppendingString:@"z"];
	
	return ([webVersion compare:currentVersion options:(NSCaseInsensitiveSearch | NSNumericSearch)] == NSOrderedDescending);
}

- (void) _checkForUpdateOperation:(NSString*)url
{
	NSMutableDictionary*	info;
	id						error;
	NSURLRequest*			request;
	NSURLResponse*			response;
	NSData*					data;
	
	//Download latest version info, compare with current version and download release notes if necessary
	LOG(@"Checking for new version...");
	url = [url stringByAppendingString:[self _serverURLQueryString]];
	request = [NSURLRequest requestWithURL:[NSURL URLWithString:url] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:kServerTimeOut];
	data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
	if(data && ([(NSHTTPURLResponse*)response statusCode] == 200)) {
		info = [NSPropertyListSerialization propertyListFromData:data mutabilityOption:NSPropertyListMutableContainers format:NULL errorDescription:&error];
		if(info) {
			if(_IsVersionNewer([info objectForKey:@"version"], _version)) {
				url = [[NSBundle preferredLocalizationsFromArray:[[info objectForKey:@"releaseNotes"] allKeys]] objectAtIndex:0];
				data = [NSURLConnection sendSynchronousRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:[[info objectForKey:@"releaseNotes"] objectForKey:url]]] returningResponse:&response error:&error];
				if(data && ([(NSHTTPURLResponse*)response statusCode] == 200))
				[info setObject:data forKey:@"releaseNotes"];
				else
				[info removeObjectForKey:@"releaseNotes"];
				
				LOG(@"A new version %@ is available", [info objectForKey:@"version"]);
				[self performSelectorOnMainThread:@selector(_didFindUpdate:) withObject:info waitUntilDone:NO];
				return;
			}
			else
			LOG(@"Current version %@ is up-to-date", _version);
		}
		else
		LOG(@"%s: Unable to parse property list (%@)", __FUNCTION__, error);
	}
	else
	LOG(@"%s: Failed retrieving update info from \"%@\" (%@)", __FUNCTION__, url, error);
	
	[self performSelectorOnMainThread:@selector(_performRegistration) withObject:nil waitUntilDone:NO];
}

@end
