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
#import <SystemConfiguration/SystemConfiguration.h>

#ifdef __APPLICATION__
#import "AppController.h"
#import "Keychain.h"
#else
#import "Version.h"
#endif
#import "BackupController.h"
#import "DirectoryScanner.h"
#import "Help.h"

#define kReadBufferSize			1024
#ifdef __APPLICATION__
#define kLockFileName			@"/tmp/MathusalemLock-%@"
#endif

#ifdef __APPLICATION__
#define LOCALIZED_STRING(__STRING__) [[NSBundle mainBundle] localizedStringForKey:(__STRING__) value:(__STRING__) table:nil]
#endif

@interface Delegate : NSObject <BackupControllerDelegate>
{
@private
	BOOL						_progress,
								_interactive;
	BackupControllerStatus		_lastStatus;
	float						_lastProgress;
}
@property(getter=isDisplayingProgress) BOOL displayProgress;
@property(getter=isInteractive) BOOL interactive;
@end

static pthread_mutex_t			_mutex = PTHREAD_MUTEX_INITIALIZER;
static BOOL						_shouldAbortTransfer = NO,
								_shouldAbortCompletely = NO;

static NSString* _PromptUserInput(NSString* prompt)
{
	static char*				readBuffer = NULL;
	char*						newline;
	
	//Allocate buffer
	if(readBuffer == NULL)
	readBuffer = malloc(kReadBufferSize);
	
	//Prompt text through stdin
	printf("%s", [prompt UTF8String]);
	fflush(stdout);
	if(fgets(readBuffer, kReadBufferSize, stdin) == NULL)
	return nil;
	newline = strchr(readBuffer, '\n');
	if(newline != NULL)
	*newline = '\0';
	
	return [NSString stringWithUTF8String:readBuffer];
}

/* Called from an interrupt */
static void _SignalHandler(int signal)
{
#ifdef __APPLICATION__
	NSAutoreleasePool*			pool;
#endif
	
#ifdef __APPLICATION__
	if(NSApp) {
		pool = [NSAutoreleasePool new];
		[(AppController*)[NSApp delegate] handleSignal:signal];
		[pool release];
	}
	else
#endif
	switch(signal) {
		
		//Abort the current command on SIGQUIT or SIGTERM
		case SIGQUIT:
		case SIGTERM:
		if(pthread_mutex_trylock(&_mutex) == 0) {
			CFRunLoopStop(CFRunLoopGetMain());
			pthread_mutex_unlock(&_mutex);
		}
		else {
			_shouldAbortTransfer = YES;
			_shouldAbortCompletely = YES;
			printf("<ABORTING COMMAND...>\n");
		}
		break;
		
		//Only abort the active file transfer on SIGINT
		case SIGINT:
		_shouldAbortTransfer = YES;
		printf("<ABORTING FILE TRANSFER...>\n");
		break;
		
	}
}

static id _ConvertObjectToPropertyList(id object)
{
	id							newObject,
								value,
								newValue;
	
	if([object isKindOfClass:[NSArray class]]) {
		newObject = [NSMutableArray array];
		for(value in object) {
			newValue = _ConvertObjectToPropertyList(value);
			if(newValue)
			[newObject addObject:newValue];
		}
	}
	else if([object isKindOfClass:[NSDictionary class]]) {
		newObject = [NSMutableDictionary dictionary];
		for(value in object) {
			newValue = _ConvertObjectToPropertyList([object objectForKey:value]);
			if(newValue)
			[newObject setObject:newValue forKey:value];
		}
	}
	else if([object isKindOfClass:[DirectoryScanner class]])
	newObject = _ConvertObjectToPropertyList([object subpathsOfRootDirectory]);
	else if([object isKindOfClass:[DirectoryItem class]])
	newObject = [object path]; //FIXME: Is this the best conversion?
	else if(object == [NSNull null])
	newObject = nil;
	else
	newObject = object;
	
	return newObject;
}

static void _TimerCallBack(CFRunLoopTimerRef timer, void* info)
{
	NSAutoreleasePool*			pool = [NSAutoreleasePool new];
	SEL							selector = [[(NSArray*)info objectAtIndex:0] pointerValue];
	NSDictionary*				parameters = [(NSArray*)info objectAtIndex:1];
	BOOL*						successPtr = [[(NSArray*)info objectAtIndex:2] pointerValue];
	BOOL						plistMode = [[parameters objectForKey:@"plist"] boolValue];
	CFTimeInterval				time = 0.0;
	id							result;
	
	//Lock the execution mutex
	pthread_mutex_lock(&_mutex);
	
	//Run the command
	if(plistMode == NO) {
		result = NSStringFromSelector(selector);
		printf("[%s] Running command '%s'...\n", [[[NSDate date] description] UTF8String], [[result substringToIndex:([result length] - 1)] UTF8String]);
		time = CFAbsoluteTimeGetCurrent();
	}
	result = [[BackupController sharedBackupController] performSelector:selector withObject:parameters];
	if(result && [(Delegate*)[[BackupController sharedBackupController] delegate] isDisplayingProgress])
	fprintf(stderr, "\r");
	if(plistMode == NO) {
		time = CFAbsoluteTimeGetCurrent() - time;
		printf("[%s] Done in %i:%02imn!\n", [[[NSDate date] description] UTF8String], (int)floor(time / 60.0), (int)round(fmod(time, 60.0)));
	}
	
	//Report the result or abort on fatal error
	if(result) {
		if(plistMode) {
			result = _ConvertObjectToPropertyList(result);
			result = [[[NSString alloc] initWithData:[NSPropertyListSerialization dataFromPropertyList:result format:NSPropertyListXMLFormat_v1_0 errorDescription:NULL] encoding:NSUTF8StringEncoding] autorelease];
		}
		printf("%s\n", [[result description] UTF8String]);
		
		if(timer)
		CFRunLoopTimerSetNextFireDate(timer, CFAbsoluteTimeGetCurrent() + CFRunLoopTimerGetInterval(timer));
	}
	else {
		if(plistMode == NO)
		printf("<NO RESULT>\n");
		*successPtr = NO;
		
		if(timer)
		CFRunLoopStop(CFRunLoopGetMain());
	}
	
	//Unlock the execution mutex
	pthread_mutex_unlock(&_mutex);
	
	[pool release];
}

int main(int argc, const char* argv[])
{
    NSAutoreleasePool*			pool = [NSAutoreleasePool new];
	struct sigaction			interruptAction = {{_SignalHandler}, SIGINT, 0},
								quitAction = {{_SignalHandler}, SIGQUIT, 0},
								terminateAction = {{_SignalHandler}, SIGTERM, 0};
	NSMutableDictionary*		parameters = [NSMutableDictionary dictionary];
	NSArray*					arrayOptions = [NSArray arrayWithObjects:@"excludePath", @"excludeName", nil];
	CFRunLoopTimerContext		context = {0, NULL, NULL, NULL, NULL};
	NSString*					command = nil;
	BOOL						success = YES,
								reachable = NO;
	int							i;
	NSString*					key;
	NSString*					value;
	NSMutableArray*				array;
	CFRunLoopTimerRef			timer;
	CFTimeInterval				interval;
	SEL							selector;
	Delegate*					delegate;
	SCNetworkReachabilityRef	reachability;
	SCNetworkConnectionFlags	flags;
	NSURL*						url;
	NSRange						range;
#ifdef __APPLICATION__
	int							selfPID = [[NSProcessInfo processInfo] processIdentifier],
								otherPID = 0;
	ProcessSerialNumber			psn;
	NSError*					error;
#endif
	
	//Setup signal handling
	sigaction(SIGINT, &interruptAction, NULL);
	sigaction(SIGQUIT, &quitAction, NULL);
	sigaction(SIGTERM, &terminateAction, NULL);
	
	//Retrieve the command
	command = (argc > 1 ? [NSString stringWithUTF8String:argv[1]] : nil);
	
	//Retrieve the parameters
	for(i = 2; i < argc; ++i) {
		if((argv[i][0] != '-') || (strlen(argv[i]) < 3))
		continue;
		
		if(argv[i][1] == '-') {
			key = [NSString stringWithUTF8String:&argv[i][2]];
			[parameters setValue:[NSNumber numberWithBool:YES] forKey:key];
		}
		else if(i + 1 < argc) {
			key = [NSString stringWithUTF8String:&argv[i][1]];
			value = [NSString stringWithUTF8String:argv[i + 1]];
#ifdef __DEBUG__
			if([value rangeOfString:@"://"].location == NSNotFound) { //Work around Xcode stripping double-slashes when launching with Instruments (radr://6099452)
				if([value hasPrefix:@"http:/"])
				value = [@"http://" stringByAppendingString:[value substringFromIndex:6]];
				else if([value hasPrefix:@"ftp:/"])
				value = [@"ftp://" stringByAppendingString:[value substringFromIndex:5]];
				else if([value hasPrefix:@"file:/"])
				value = [@"file://" stringByAppendingString:[value substringFromIndex:6]];
			}
#endif
			if([arrayOptions containsObject:key]) {
				array = [parameters objectForKey:key];
				if(array == nil) {
					array = [NSMutableArray new];
					[parameters setObject:array forKey:key];
					[array release];
				}
				[array addObject:value];
			}
			else
			[parameters setObject:value forKey:key];
			i += 1;
		}
	}
	
#ifdef __APPLICATION__
	if((value = [parameters objectForKey:@"uniqueID"])) {
		//Make sure we don't already have an instance running with the same unique ID
		[[NSData dataWithContentsOfFile:[NSString stringWithFormat:kLockFileName, value]] getBytes:&otherPID length:sizeof(int)];
		if(otherPID > 0) {
			if(GetProcessForPID(otherPID, &psn) == noErr) {
				printf("<An instance with the same unique ID is already running>\n");
				goto Exit;
			}
		}
		if(![[NSData dataWithBytes:&selfPID length:sizeof(int)] writeToFile:[NSString stringWithFormat:kLockFileName, value] options:NSAtomicWrite error:&error])
		printf("%s\n", [[error description] UTF8String]);
		
		//Retrieve password from Keychain
		if([parameters objectForKey:@"password"] == nil) {
			value = [[Keychain sharedKeychain] genericPasswordForService:kBackupPasswordKeychainService account:value];
			if(value)
			[parameters setObject:value forKey:@"password"];
		}
		else if(![[parameters objectForKey:@"password"] length])
		[parameters removeObjectForKey:@"password"];
	}
#endif

	//Check local and remote reachability if necessary
	if([[parameters objectForKey:@"checkReachability"] boolValue]) {
		value = [[parameters objectForKey:@"source"] stringByStandardizingPath];
		if(value) {
			reachable = [[NSFileManager defaultManager] fileExistsAtPath:value];
			if(reachable == NO)
			goto Exit;
		}
		
		value = [parameters objectForKey:@"destination"];
		if(value == nil)
		value = [parameters objectForKey:@"backup"];
		if(value) {
			range = [value rangeOfString:@"://"];
			if(range.location != NSNotFound)
			url = [NSURL URLWithString:value];
			else
			url = [NSURL fileURLWithPath:[value stringByStandardizingPath]];
		}
		else
		url = nil;
		
		if(url) {
			if([[url scheme] isEqualToString:@"file"])
			reachable = [[NSFileManager defaultManager] fileExistsAtPath:[url path]];
			else {
				reachability = SCNetworkReachabilityCreateWithName(kCFAllocatorDefault, [[url host] UTF8String]);
				if(reachability) {
					if(SCNetworkReachabilityGetFlags(reachability, &flags) && (flags & kSCNetworkFlagsReachable) && !(flags & kSCNetworkFlagsConnectionRequired))
					reachable = YES;
					CFRelease(reachability);
				}
			}
		}
		if(reachable == NO)
		goto Exit;
	}
	
#ifdef __APPLICATION__
	//Run in application mode if required
	if(![[parameters objectForKey:@"noGUI"] boolValue]) {
		[parameters setValue:command forKey:@""];
		[[NSUserDefaults standardUserDefaults] setVolatileDomain:parameters forName:@"parameters"];
		
		return NSApplicationMain(argc, argv);
	}
#else
	//Print version
	if(![[parameters objectForKey:@"plist"] boolValue])
	printf("<%s version %s (%i)>\n", getprogname(), _version, _svnRevision);
#endif
	
	//Run the command if valid
	if((command == nil) || [command isEqualToString:@"help"])
	printf(_help, getprogname());
	else {
		selector = NSSelectorFromString([NSString stringWithFormat:@"%@:", command]);
		if([[BackupController sharedBackupController] respondsToSelector:selector]) {
			delegate = [Delegate new];
			if([[parameters objectForKey:@"interactive"] boolValue])
			[delegate setInteractive:YES];
			if([[parameters objectForKey:@"progress"] boolValue])
			[delegate setDisplayProgress:YES];
			[[BackupController sharedBackupController] setDelegate:delegate];
			
			if([parameters objectForKey:@"scratch"])
			[[BackupController sharedBackupController] setScratchDirectory:[parameters objectForKey:@"scratch"]];
			
			interval = [[parameters objectForKey:@"interval"] doubleValue];
			array = [NSMutableArray arrayWithObjects:[NSValue valueWithPointer:selector], parameters, [NSValue valueWithPointer:&success], nil];
			if(interval > 0.0) {
				context.info = array;
				timer = CFRunLoopTimerCreate(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent(), interval, 0, 0, _TimerCallBack, &context);
				CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopCommonModes);
				
				CFRunLoopRun();
				
				CFRunLoopRemoveTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopCommonModes);
				CFRelease(timer);
			}
			else
			_TimerCallBack(NULL, array);
			
			[[BackupController sharedBackupController] setDelegate:nil];
			[delegate release];
		}
		else
		printf("<Unsupported command \"%s\">\n", [command UTF8String]);
	}
	
Exit:
	[pool release];
	return (success ? 0 : 1);
}

@implementation Delegate

@synthesize displayProgress=_progress, interactive=_interactive;

- (BOOL) backupControllerShouldAbort:(BackupController*)controller
{
	return _shouldAbortCompletely;
}

- (void) backupController:(BackupController*)controller didUpdateStatus:(BackupControllerStatus)status currentValue:(NSUInteger)value maxValue:(NSUInteger)max
{
	float						progress;
	NSString*					string;
	
	//Report progress if necessary
	if(_progress) {
		if(status != _lastStatus) {
			_lastProgress = -1.0;
			_lastStatus = status;
		}
		
		//Retrieve text for status
		string = [NSString stringWithFormat:@"STATUS-%i", status];
#ifdef __APPLICATION__
		string = [NSString stringWithFormat:LOCALIZED_STRING(string), @""];
#endif
		
		//Throttle down updates to 1% increments
		if(max > 0) {
			progress = roundf((float)value / (float)max * 100.0);
			if(progress > _lastProgress) {
				fprintf(stderr, "\r%s (%.0f%%)", [string UTF8String], progress);
				_lastProgress = progress;
			}
		}
		else
		fprintf(stderr, "\r%s", [string UTF8String]);
	}
}

- (void) backupController:(BackupController*)controller errorDidOccur:(NSError*)error
{
	//Report the error
	if(_progress)
	fprintf(stderr, "\r");
	printf("%s\n%s\n", [[error localizedDescription] UTF8String], [[[error userInfo] description] UTF8String]);
}

- (BOOL) backupControllerShouldAbortCurrentFileTransfer:(BackupController*)controller
{
	return _shouldAbortTransfer;
}

- (BOOL) backupController:(BackupController*)controller shouldRetryFileTransferWithURL:(NSURL*)url
{
	NSString*					result;
	
	//Prompt the user for continuation
	if(_interactive) {
		if(_progress)
		fprintf(stderr, "\r");
		result = _PromptUserInput([NSString stringWithFormat:@"FILE TRANSFER FAILED: %@\nDo you want to try again [y/n]? ", [url absoluteString]]);
	}
	else
	result = nil;
	
	return (result && ([result caseInsensitiveCompare:@"Y"] == NSOrderedSame));
}

@end
