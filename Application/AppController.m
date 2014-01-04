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

#import <pthread.h>

#import "AppController.h"

#define LOCALIZED_STRING(__STRING__) [[NSBundle mainBundle] localizedStringForKey:(__STRING__) value:(__STRING__) table:nil]

@interface AppController ()
- (void) _abort;
- (void) _abortAlertDidEnd:(NSAlert*)alert returnCode:(NSInteger)returnCode contextInfo:(void*)contextInfo;
- (void) _didFinishBackup:(id)argument;
- (void) _promptAlertDidEnd:(NSAlert*)alert returnCode:(NSInteger)returnCode contextInfo:(void*)contextInfo;
- (void) _didUpdateStatus:(NSArray*)arguments;
- (void) _showError:(NSError*)error;
- (void) _fileTransferDidFail:(NSURL*)url;
@end

static pthread_mutex_t				_controllerMutex = PTHREAD_MUTEX_INITIALIZER;

@implementation AppController

- (void) _abort
{
	//Signal the BackupController thread in case it's waiting for an answer
	[_transferCondition lock];
	_transferRetry = NO;
	[_transferCondition signal];
	[_transferCondition unlock];
	
	//Make the BackupController abort at the next opportunity
	_shouldAbortTransfer = YES;
	_shouldAbortCompletely = YES;
}

/* Called from an interrupt */
- (void) handleSignal:(int)signal
{
	[self performSelectorOnMainThread:@selector(_abort) withObject:nil waitUntilDone:NO];
}

- (void) _abortAlertDidEnd:(NSAlert*)alert returnCode:(NSInteger)returnCode contextInfo:(void*)contextInfo
{
	//If in the meantime the BackupController has finished, just terminate immediately
	if(_backupResult) {
		[NSApp terminate:nil];
		return;
	}
	
	//Abort if the user confirmed
	if(returnCode == NSAlertDefaultReturn) {
		[self _abort];
		[abortButton setEnabled:NO];
	}
}

- (IBAction) abort:(id)sender
{
	NSString*				title = [NSString stringWithFormat:@"ABORT_%@_TITLE", [_command uppercaseString]];
	NSString*				message = [NSString stringWithFormat:@"ABORT_%@_MESSAGE", [_command uppercaseString]];
	NSAlert*				alert;
	
	//Show a confirmation sheet
	alert = [NSAlert alertWithMessageText:LOCALIZED_STRING(title) defaultButton:LOCALIZED_STRING(@"ABORT_DEFAULT_BUTTON") alternateButton:nil otherButton:LOCALIZED_STRING(@"ABORT_OTHER_BUTTON") informativeTextWithFormat:LOCALIZED_STRING(message)];
	[alert beginSheetModalForWindow:panel modalDelegate:self didEndSelector:@selector(_abortAlertDidEnd:returnCode:contextInfo:) contextInfo:NULL];
}

- (IBAction) stop:(id)sender
{
	//Tell the BackupController to abort the current file transfer
	_shouldAbortTransfer = YES;
	[stopButton setEnabled:NO];
}

- (IBAction) restart:(id)sender
{
	//Signal the BackupController thread with the answer
	[_transferCondition lock];
	_transferRetry = YES;
	[_transferCondition signal];
	[_transferCondition unlock];
	
	//Update user interface
	[restartButton setHidden:YES];
	[stopButton setHidden:NO];
}

- (void) _didFinishBackup:(id)argument
{
	//Dismiss the abort confirmation sheet if present
	[[panel attachedSheet] orderOut:nil];
	
	//Only terminate immediately if there are no error alerts visible
	if(_alertCount == 0)
	[NSApp terminate:nil];
}

- (void) _promptAlertDidEnd:(NSAlert*)alert returnCode:(NSInteger)returnCode contextInfo:(void*)contextInfo
{
	//Terminate immediately if the user does not want to run the backup
	if(returnCode != NSAlertDefaultReturn) {
		[[alert window] orderOut:nil];
		_backupResult = [NSNull null];
		[NSApp terminate:nil];
		return;
	}
	
	//Restore normal window level if necessary
	if(![[(NSDictionary*)contextInfo objectForKey:@"foreground"] boolValue])
	[panel setLevel:NSNormalWindowLevel];
	
	//Start BackupController operation
	_transferCondition = [NSCondition new];
	[[NSOperationQueue new] addOperation:[BackupController backupOperationWithCommand:_command parameters:[(NSDictionary*)contextInfo autorelease] delegate:self]];
}

- (void) applicationDidFinishLaunching:(NSNotification*)notification
{
	NSDictionary*			parameters = [[NSUserDefaults standardUserDefaults] volatileDomainForName:@"parameters"];
	NSString*				command = [parameters objectForKey:@""];
	NSAlert*				alert;
	NSString*				remote;
	NSString*				local;
	NSURL*					url;
	
	//Make sure we have a valid command
	if(!command || (![command isEqualToString:@"backup"] && ![command isEqualToString:@"restore"])) {
		alert = [NSAlert alertWithMessageText:LOCALIZED_STRING(@"INVALID_TITLE") defaultButton:LOCALIZED_STRING(@"INVALID_DEFAULT_BUTTON") alternateButton:nil otherButton:nil informativeTextWithFormat:LOCALIZED_STRING(@"INVALID_MESSAGE")];
		[alert setAlertStyle:NSCriticalAlertStyle];
		[alert runModal];
		_backupResult = [NSNull null];
		[NSApp terminate:nil];
		return;
	}
	_command = [command copy];
	
	//Setup user interface
	remote = [parameters objectForKey:([_command isEqualToString:@"backup"] ? @"destination" : @"backup")];
	if([remote rangeOfString:@"://"].location == NSNotFound)
	remote = [[remote stringByStandardizingPath] stringByAbbreviatingWithTildeInPath];
	else {
		url = [NSURL URLWithString:remote];
		remote = [NSString stringWithFormat:@"%@://%@%@", [url scheme], [url host], [url path]];
	}
	local = [[[parameters objectForKey:([_command isEqualToString:@"backup"] ? @"source" : @"target")] stringByStandardizingPath] stringByAbbreviatingWithTildeInPath];
	if([_command isEqualToString:@"backup"]) {
		[sourceTextField setStringValue:local];
		[destinationTextField setStringValue:remote];
	}
	else {
		if([parameters objectForKey:@"item"])
		remote = [remote stringByAppendingFormat:@"/%@", [parameters objectForKey:@"item"]];
		[sourceTextField setStringValue:remote];
		[destinationTextField setStringValue:local];
	}
	_lastStatus = -1;
	[self _didUpdateStatus:[NSArray arrayWithObjects:[NSNumber numberWithInteger:kBackupControllerStatus_Idle], [NSNumber numberWithUnsignedInteger:0], [NSNumber numberWithUnsignedInteger:0], nil]];
	if([parameters objectForKey:@"name"])
	[panel setTitle:[NSString stringWithFormat:@"%@ - %@", [panel title], [parameters objectForKey:@"name"]]];
	[panel setLevel:([[parameters objectForKey:@"foreground"] boolValue] ? NSFloatingWindowLevel : NSNormalWindowLevel)];
	[panel makeKeyAndOrderFront:nil];
	if([[parameters objectForKey:@"foreground"] boolValue])
	[NSApp activateIgnoringOtherApps:YES];
	
	//If necessary, prompt the user before starting
	if([_command isEqualToString:@"backup"] && [[parameters objectForKey:@"prompt"] boolValue]) {
		if(![[parameters objectForKey:@"foreground"] boolValue]) {
			[panel setLevel:NSFloatingWindowLevel];
			[NSApp activateIgnoringOtherApps:YES];
		}
		
		alert = [NSAlert alertWithMessageText:LOCALIZED_STRING(@"PROMPT_TITLE") defaultButton:LOCALIZED_STRING(@"PROMPT_DEFAULT_BUTTON") alternateButton:nil otherButton:LOCALIZED_STRING(@"PROMPT_OTHER_BUTTON") informativeTextWithFormat:LOCALIZED_STRING(@"PROMPT_MESSAGE")];
		[alert beginSheetModalForWindow:panel modalDelegate:self didEndSelector:@selector(_promptAlertDidEnd:returnCode:contextInfo:) contextInfo:[parameters retain]];
	}
	else
	[self _promptAlertDidEnd:nil returnCode:NSAlertDefaultReturn contextInfo:[parameters retain]];
}

- (BOOL) windowShouldClose:(id)sender
{
	[self abort:nil];
	
	return NO;
}

- (NSApplicationTerminateReply) applicationShouldTerminate:(NSApplication*)sender
{
	//Prompt the user if the BackupController is not finished
	if(_backupResult == nil) {
		[self abort:nil];
		return NSTerminateCancel;
	}
	
	return NSTerminateNow;
}

/* Called from BackupController thread */
- (void) backupController:(BackupController*)controller didStartCommand:(NSString*)command parameters:(NSDictionary*)parameters
{
	//Remember backup controller
	pthread_mutex_lock(&_controllerMutex);
	_controller = [controller retain];
	pthread_mutex_unlock(&_controllerMutex);
	
	//Setup custom scratch directory to use if necessary
	if([parameters objectForKey:@"scratch"])
	[controller setScratchDirectory:[parameters objectForKey:@"scratch"]];
	
	NSLog(@"BackupController command '%@' started...", command);
}

/* Called from BackupController thread */
- (void) backupController:(BackupController*)controller didFinishCommand:(NSString*)command parameters:(NSDictionary*)parameters result:(id)result
{
	NSLog(@"BackupController completed with result: %@", result);
	
	//Clear backup controller
	pthread_mutex_lock(&_controllerMutex);
	[_controller release];
	_controller = nil;
	pthread_mutex_unlock(&_controllerMutex);
	
	//Signal main thread BackupController has finished
	_backupResult = (result ? [result retain] : [NSNull null]);
	[self performSelectorOnMainThread:@selector(_didFinishBackup:) withObject:nil waitUntilDone:NO];
}

/* Called from BackupController thread */
- (BOOL) backupControllerShouldAbort:(BackupController*)controller
{
	return _shouldAbortCompletely;
}

- (void) _didUpdateStatus:(NSArray*)arguments
{
	static NSString*		prefix = nil;
	BackupControllerStatus	status = [[arguments objectAtIndex:0] integerValue];
	NSUInteger				value = [[arguments objectAtIndex:1] unsignedIntegerValue],
							max = [[arguments objectAtIndex:2] unsignedIntegerValue];
	NSString*				string;
	NSString*				info;
	double					progress;
	
	//Update the status text field and the file transfer stop / restart buttons
	if((status != _lastStatus) || (max != _lastMax)) {
		switch(status) {
			
			case kBackupControllerStatus_Segment_Begin:
			case kBackupControllerStatus_Segment_End:
			[prefix release];
			prefix = (status == kBackupControllerStatus_Segment_Begin ? [[NSString alloc] initWithFormat:LOCALIZED_STRING(@"SEGMENT-FORMAT"), value, max] : nil);
			status = kBackupControllerStatus_Idle;
			value = 0;
			max = 0;
			info = nil;
			break;
			
			case kBackupControllerStatus_CopyingFiles:
			info = [NSString stringWithFormat:@"%i", max];
			break;
			
			case kBackupControllerStatus_DownloadingFile:
			case kBackupControllerStatus_UploadingFile:
			if(max > 0) {
				if(max >= 1024 * 1024)
				info = [NSString stringWithFormat:LOCALIZED_STRING(@"STATUS-MB-FORMAT"), (double)max / (double)(1024.0 * 1024.0)];
				else
				info = [NSString stringWithFormat:LOCALIZED_STRING(@"STATUS-KB-FORMAT"), MAX(max / 1024, 1)];
			}
			else
			info = @"";
			break;
			
			default:
			info = nil;
			break;
			
		}
		string = [NSString stringWithFormat:@"STATUS-%i", status];
		string = [NSString stringWithFormat:LOCALIZED_STRING(string), info];
		if(prefix)
		string = [prefix stringByAppendingString:string];
		[statusTextField setStringValue:string];
		
		if((status == kBackupControllerStatus_DownloadingFile) || (status == kBackupControllerStatus_UploadingFile))
		[stopButton setEnabled:YES];
		else if((_lastStatus == kBackupControllerStatus_DownloadingFile) || (_lastStatus == kBackupControllerStatus_UploadingFile))
		[stopButton setEnabled:NO];
		
		_lastStatus = status;
		_lastMax = max;
		_lastProgress = -1.0;
	}
	
	//Update the progress indicator
	if(max > 0) {
		if([progressIndicator isIndeterminate])
		[progressIndicator setIndeterminate:NO];
		
		//Reduce user interface updates to 1% increments
		progress = round((double)value / (double)max * 100.0);
		if(progress > _lastProgress) {
			[progressIndicator setDoubleValue:progress];
			_lastProgress = progress;
		}
	}
	else {
		if(![progressIndicator isIndeterminate])
		[progressIndicator setIndeterminate:YES];
		[progressIndicator startAnimation:nil]; //NOTE: For some reason, we need to always force animation to start
	}
}

/* Called from BackupController thread */
- (void) backupController:(BackupController*)controller didUpdateStatus:(BackupControllerStatus)status currentValue:(NSUInteger)value maxValue:(NSUInteger)max
{
	[self performSelectorOnMainThread:@selector(_didUpdateStatus:) withObject:[NSArray arrayWithObjects:[NSNumber numberWithInteger:status], [NSNumber numberWithUnsignedInteger:value], [NSNumber numberWithUnsignedInteger:max], nil] waitUntilDone:NO];
}

- (void) _showError:(NSError*)error
{
	NSArray*				paths = [[error userInfo] objectForKey:kBackupControllerPathsKey];
	NSAlert*				alert;
	NSString*				path;
	NSMutableString*		string;
	
	//Build error alert
	string = [NSString stringWithFormat:@"ERROR-%i", [error code]];
	alert = [NSAlert alertWithMessageText:LOCALIZED_STRING(string) defaultButton:LOCALIZED_STRING(@"ERROR_DEFAULT_BUTTON") alternateButton:nil otherButton:nil informativeTextWithFormat:@"%@", [[error userInfo] objectForKey:NSUnderlyingErrorKey]];
	[alert setAlertStyle:NSCriticalAlertStyle];
	if([paths count]) {
		string = [NSMutableString new];
		for(path in paths) {
			if([string length])
			[string appendString:@"\n"];
			[string appendString:path];
		}
		[alert setInformativeText:string];
		[string release];
	}
	[[alert window] setLevel:[panel level]];
	
	//Show error alert on screen
	_alertCount += 1;
	[alert runModal];
	_alertCount -= 1;
	
	//Terminate immediately if the BackupController is finished and there are no visible error alerts
	if(_backupResult && (_alertCount == 0))
	[NSApp terminate:nil];
}

/* Called from BackupController thread */
- (void) backupController:(BackupController*)controller errorDidOccur:(NSError*)error
{
	NSLog(@"%@\n%@", [error localizedDescription], [[error userInfo] description]);
	
	if([[[error userInfo] objectForKey:kBackupControllerFatalErrorKey] boolValue])
	[self performSelectorOnMainThread:@selector(_showError:) withObject:error waitUntilDone:NO];
}

- (void) _fileTransferDidFail:(NSURL*)url
{
	//Update the user interface
	_shouldAbortTransfer = NO;
	[stopButton setHidden:YES];
	[restartButton setHidden:NO];
	[statusTextField setStringValue:LOCALIZED_STRING(@"STATUS-TRANSFER-PAUSED")];
	[progressIndicator stopAnimation:nil];
}

/* Called from BackupController thread */
- (BOOL) backupControllerShouldAbortCurrentFileTransfer:(BackupController*)controller
{
	return _shouldAbortTransfer;
}

/* Called from BackupController thread */
- (BOOL) backupController:(BackupController*)controller shouldRetryFileTransferWithURL:(NSURL*)url
{
	BOOL					result;
	
	//Wait for an answer from main thread
	[_transferCondition lock];
	[self performSelectorOnMainThread:@selector(_fileTransferDidFail:) withObject:url waitUntilDone:NO];
	[_transferCondition wait];
	result = _transferRetry;
	[_transferCondition unlock];
	
	return result;
}

@end
