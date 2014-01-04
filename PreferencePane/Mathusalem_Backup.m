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

#import "Mathusalem_Backup.h"
#import "Mathusalem_PreferencePane.h"
#import "BackupController.h"
#import "DirectoryScanner.h"
#import "FileTransferController.h"
#import "NSURL+Parameters.h"
#import "Keychain.h"

#define kLabelPrefix			@"net.pol-online.mathusalem-"
#define kErrorDomain			@"Mathusalem_PreferencePane"

#define CACHED_BOM_FILENAME(__REVISION__) [NSString stringWithFormat:@"Cached-Revision-%05i.data", __REVISION__]

@interface Mathusalem_Entry : NSObject
{
	DirectoryScanner*	_scanner;
	NSString*			_subpath;
	NSUInteger			_revision,
						_maxRevision;
	BOOL				_leaf;
	NSMutableArray*		_children;
}
+ (Mathusalem_Entry*) loadingEntry;
+ (Mathusalem_Entry*) unavailableEntry;
- (id) initWithDirectoryScanner:(DirectoryScanner*)scanner subpath:(NSString*)subpath revision:(NSUInteger)revision isLeaf:(BOOL)leaf;
@property(readonly) DirectoryScanner* scanner;
@property(readonly, getter=isLeaf) BOOL leaf;
@property(readonly) NSArray* children;
@property(readonly) NSUInteger maxRevision;
@end

@interface Mathusalem_Backup (BackupOperationDelegate) <BackupOperationDelegate>
@end

@interface NSMutableString (Mathusalem_PreferencePane)
- (NSString*) string;
@end

@interface NSMutableArray (Mathusalem_PreferencePane)
- (void) addMutableObjectsFromArray:(NSArray*)otherArray;
@end

static NSString*				_weekDays[] = {@"sunday", @"monday", @"tuesday", @"wednesday", @"thursday", @"friday", @"saturday"};
static NSCalendarDate*			_baseDate = nil;

@implementation Mathusalem_Entry

@synthesize scanner=_scanner, leaf=_leaf, children=_children, maxRevision=_maxRevision;

+ (Mathusalem_Entry*) loadingEntry
{
	static Mathusalem_Entry*	entry = nil;
	
	if(entry == nil)
	entry = [[Mathusalem_Entry alloc] initWithDirectoryScanner:nil subpath:nil revision:0 isLeaf:YES];
	
	return entry;
}

+ (Mathusalem_Entry*) unavailableEntry
{
	static Mathusalem_Entry*	entry = nil;
	
	if(entry == nil)
	entry = [[Mathusalem_Entry alloc] initWithDirectoryScanner:nil subpath:@"" revision:0 isLeaf:YES];
	
	return entry;
}

- (id) initWithDirectoryScanner:(DirectoryScanner*)scanner subpath:(NSString*)subpath revision:(NSUInteger)revision isLeaf:(BOOL)leaf
{
	Mathusalem_Entry*		entry;
	DirectoryItem*			item;
	
	if((self = [super init])) {
		_scanner = [scanner retain];
		_subpath = [subpath copy];
		_revision = revision;
		_maxRevision = revision;
		_leaf = leaf;
		
		if(_leaf == NO) {
			_children = [NSMutableArray new];
			for(item in [_scanner contentsOfDirectoryAtSubpath:_subpath recursive:NO useAbsolutePaths:NO]) {
				entry = [[Mathusalem_Entry alloc] initWithDirectoryScanner:_scanner subpath:(_subpath ? [_subpath stringByAppendingPathComponent:[item path]] : [item path]) revision:[item revision] isLeaf:![item isDirectory]];
				if([entry maxRevision] > _maxRevision)
				_maxRevision = [entry maxRevision];
				[_children addObject:entry];
				[entry release];
			}
		}
	}
	
	return self;
}

- (void) dealloc
{
	[_children release];
	[_scanner release];
	[_subpath release];
	
	[super dealloc];
}

- (id) value
{
	static NSDictionary*	redAttributes = nil;
	static NSDictionary*	orangeAttributes = nil;
	static NSDictionary*	grayAttributes = nil;
	
	if(grayAttributes == nil)
	grayAttributes = [[NSDictionary dictionaryWithObject:[NSColor darkGrayColor] forKey:NSForegroundColorAttributeName] retain];
	if(orangeAttributes == nil)
	orangeAttributes = [[NSDictionary dictionaryWithObject:[NSColor orangeColor] forKey:NSForegroundColorAttributeName] retain];
	if(redAttributes == nil)
	redAttributes = [[NSDictionary dictionaryWithObject:[NSColor redColor] forKey:NSForegroundColorAttributeName] retain];
	
	if(_scanner) {
		if(_subpath) {
			if(![[_scanner userInfoForKey:kBackupScannerUserInfoKey_FullBackup] boolValue] && ([_scanner revision] > 1)) {
				if(_revision == [_scanner revision])
				return [[[NSAttributedString alloc] initWithString:[_subpath lastPathComponent] attributes:redAttributes] autorelease];
				else if((_leaf == NO) && (_maxRevision == [_scanner revision]))
				return [[[NSAttributedString alloc] initWithString:[_subpath lastPathComponent] attributes:orangeAttributes] autorelease];
				else
				return [[[NSAttributedString alloc] initWithString:[_subpath lastPathComponent] attributes:grayAttributes] autorelease];
			}
			else
			return [_subpath lastPathComponent];
		}
		else
		return [NSString stringWithFormat:@"[%i] %@", [_scanner revision], [[_scanner userInfoForKey:@"startDate"] descriptionWithCalendarFormat:@"%Y-%m-%d %H:%M" timeZone:nil locale:nil]];
	}
	
	return [[[NSAttributedString alloc] initWithString:(_subpath ? LOCALIZED_STRING(@"UNAVAILABLE_ENTRY") : LOCALIZED_STRING(@"LOADING_ENTRY")) attributes:[NSDictionary dictionaryWithObject:[NSColor grayColor] forKey:NSForegroundColorAttributeName]] autorelease];
}

@end

@implementation Mathusalem_Backup

@synthesize preferencePane, uniqueID, edited, originalName, name, source, type, host, path, user, password, format, segment, password1, password2, atomic, fullBackup, excludeHidden, inForeground, skipConfirmation, lowPriority, preExecutable, postExecutable, scratch, excludedNames, excludedPaths, hourInterval, monthDate, weekDate, mode, day, weekDays;

+ (void) initialize
{
	if(_baseDate == nil)
	_baseDate = [[NSCalendarDate alloc] initWithYear:2000 month:1 day:1 hour:0 minute:0 second:0 timeZone:nil];
}

+ (NSSet*) keyPathsForValuesAffectingValid
{
	return [NSSet setWithObjects:@"source", @"type", @"host", @"path", nil];
}

+ (NSSet*) keyPathsForValuesAffectingHistory
{
	return [NSSet setWithObjects:@"type", @"host", @"path", @"user", @"password", nil];
}

+ (NSString*) executablePath
{
	return [[[NSBundle bundleForClass:[Mathusalem_Backup class]] pathForResource:@"Mathusalem" ofType:@"app"] stringByAppendingPathComponent:@"Contents/MacOS/Mathusalem"];
}

+ (NSURL*) _makeDestinationURLWithType:(NSInteger)aType user:(NSString*)aUser password:(NSString*)aPassword host:(NSString*)aHost path:(NSString*)aPath
{
	NSString*				scheme = nil;
	
	if(!aHost || ((aType == kType_LocalDisk) && !aPath))
	return nil;
	
	switch(aType) {
		
		case kType_LocalDisk:
		scheme = @"file";
		break;
		
		case kType_AFP:
		scheme = @"afp";
		break;
		
		case kType_SMB:
		scheme = @"smb";
		break;
		
		case kType_FTP:
		scheme = @"ftp";
		break;
		
		case kType_SFTP:
		scheme = @"ssh";
		break;
		
		case kType_WebDAV:
		case kType_iDisk:
		case kType_AmazonS3:
		scheme = @"http";
		break;
		
		case kType_SecureWebDAV:
		case kType_SecureAmazonS3:
		scheme = @"https";
		break;
		
	}
	
	return [NSURL URLWithScheme:scheme user:aUser password:aPassword host:((aType == kType_AmazonS3) || (aType == kType_SecureAmazonS3) ? [NSString stringWithFormat:@"%@.%@", aPath, kFileTransferHost_AmazonS3] : aHost) port:0 path:((aType != kType_AmazonS3) && (aType != kType_SecureAmazonS3) ? aPath : nil)]; //NOTE: "host" may already include the port
}

- (void) observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary*)change context:(void*)context
{
	if(context != [Mathusalem_Backup class]) {
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
		return;
	}
	
	[self willChangeValueForKey:@"edited"];
	edited = YES;
	[self didChangeValueForKey:@"edited"];
}

- (id) init
{
	return [self initWithUniqueID:[(id)CFUUIDCreateString(kCFAllocatorDefault, (CFUUIDRef)[(id)CFUUIDCreate(kCFAllocatorDefault) autorelease]) autorelease]];
}

- (id) initWithUniqueID:(NSString*)anID
{
	if((self = [super init])) {
		uniqueID = [anID copy];
		type = kType_LocalDisk;
		host = @"localhost";
		format = kFormat_CompressedDiskImage;
		segment = 0;
		mode = kMode_Manually;
		hourInterval = 24;
		monthDate = [[NSDate dateWithTimeIntervalSinceReferenceDate:[_baseDate timeIntervalSinceReferenceDate]] retain];
		weekDate = [[NSDate dateWithTimeIntervalSinceReferenceDate:[_baseDate timeIntervalSinceReferenceDate]] retain];
		day = 0;
		weekDays = [NSMutableDictionary new];
		excludedNames = [NSMutableArray new];
		excludedPaths = [NSMutableArray new];
		excludeHidden = YES;
		lowPriority = YES;
		
		[self addObserver:self forKeyPath:@"excludedNames" options:0 context:[Mathusalem_Backup class]];
		[self addObserver:self forKeyPath:@"excludedPaths" options:0 context:[Mathusalem_Backup class]];
	}
	
	return self;
}

- (id) initWithBackup:(Mathusalem_Backup*)backup
{
	if(backup == nil) {
		[self release];
		return nil;
	}
	
	if((self = [self init])) {
		[self setSource:[backup source]];
		
		[self setType:[backup type]];
		[self setHost:[backup host]];
		[self setPath:[backup path]];
		[self setUser:[backup user]];
		[self setPassword:[backup password]];
		[self setFormat:[backup format]];
		[self setSegment:[backup segment]];
		[self setPassword1:[backup password1]];
		[self setPassword2:[backup password2]];
		
		[self setMode:[backup mode]];
		[self setHourInterval:[backup hourInterval]];
		[self setDay:[backup day]];
		[self setMonthDate:[backup monthDate]];
		[self setWeekDate:[backup weekDate]];
		[[self weekDays] addEntriesFromDictionary:[backup weekDays]];
		
		[self setAtomic:[backup atomic]];
		[self setInForeground:[backup isInForeground]];
		[self setSkipConfirmation:[backup skipConfirmation]];
		[self setLowPriority:[backup lowPriority]];
		[self setFullBackup:[backup fullBackup]];
		[self setExcludeHidden:[backup excludeHidden]];
		[[self excludedNames] addMutableObjectsFromArray:[backup excludedNames]];
		[[self excludedPaths] addMutableObjectsFromArray:[backup excludedPaths]];
		[self setPreExecutable:[backup preExecutable]];
		[self setPostExecutable:[backup postExecutable]];
		[self setScratch:[backup scratch]];
	}
	
	return self;
}

- (void) dealloc
{
	[_historyURL release];
	[_history release];
	
	[_cacheDirectory release];
	
	[self removeObserver:self forKeyPath:@"excludedNames"];
	[self removeObserver:self forKeyPath:@"excludedPaths"];
	
	[uniqueID release];
	[originalName release];
	[name release];
	[source release];
	[host release];
	[path release];
	[user release];
	[password release];
	[preExecutable release];
	[postExecutable release];
	[scratch release];
	[excludedNames release];
	[excludedPaths release];
	[monthDate release];
	[weekDate release];
	[weekDays release];
	[password1 release];
	[password2 release];
	
	[super dealloc];
}

- (void) setValue:(id)value forKeyPath:(NSString*)keyPath
{
	[super setValue:value forKeyPath:keyPath];
	
	if([keyPath hasPrefix:@"weekDays"]) {
		[self willChangeValueForKey:@"edited"];
		edited = YES;
		[self didChangeValueForKey:@"edited"];
	}
}

- (void) didChangeValueForKey:(NSString*)key
{
	[super didChangeValueForKey:key];
	
	if(![key isEqualToString:@"edited"] && ![key isEqualToString:@"history"] && ![key isEqualToString:@"updating"]) {
		[self willChangeValueForKey:@"edited"];
		edited = YES;
		[self didChangeValueForKey:@"edited"];
	}
}

- (void) setType:(NSInteger)aType
{
	if(aType != type) {
		[self willChangeValueForKey:@"type"];
		type = aType;
		[self didChangeValueForKey:@"type"];
		
		switch(type) {
			
			case kType_LocalDisk:
			[self setHost:@"localhost"];
			break;
			
			case kType_iDisk:
			[self setHost:kFileTransferHost_iDisk];
			break;
			
			case kType_AmazonS3:
			case kType_SecureAmazonS3:
			[self setHost:kFileTransferHost_AmazonS3];
			break;
			
			default:
			[self setHost:nil];
			break;
			
		}
		
		[self setPath:((type == kType_AmazonS3) || (type == kType_SecureAmazonS3) ? LOCALIZED_STRING(@"DEFAULT_BUCKET") : nil)];
		[self setUser:nil];
		[self setPassword:nil];
	}
}

- (void) setFormat:(NSInteger)aFormat
{
	if(aFormat != format) {
		[self willChangeValueForKey:@"format"];
		format = aFormat;
		[self didChangeValueForKey:@"format"];
		
		if(format == kFormat_SparseDiskImage)
		[self setSegment:0];
		
		[self setPassword1:nil];
		[self setPassword2:nil];
	}
}

- (BOOL) validateName:(id*)ioValue error:(NSError**)outError
{
	if(![(NSString*)*ioValue length] || ![preferencePane isBackupNameUnique:*ioValue]) {
		*outError = [NSError errorWithDomain:kErrorDomain code:1 userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:LOCALIZED_STRING(@"VALIDATE_NAME"), *ioValue] forKey:NSLocalizedDescriptionKey]];
		return NO;
	}

	return YES;
}

- (BOOL) validateSource:(id*)ioValue error:(NSError**)outError
{
	BOOL					isDirectory;
	
	if(*ioValue) {
		*ioValue = [*ioValue stringByStandardizingPath];
		if(![*ioValue isAbsolutePath] || ![[NSFileManager defaultManager] fileExistsAtPath:*ioValue isDirectory:&isDirectory] || !isDirectory) {
			*outError = [NSError errorWithDomain:kErrorDomain code:1 userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:LOCALIZED_STRING(@"VALIDATE_DIRECTORY"), *ioValue] forKey:NSLocalizedDescriptionKey]];
			return NO;
		}
		
		if([*ioValue isEqualToString:@"/"] || [[*ioValue stringByDeletingLastPathComponent] isEqualToString:@"/Volumes"] || [[*ioValue stringByDeletingLastPathComponent] isEqualToString:@"/Users"]) {
			*outError = [NSError errorWithDomain:kErrorDomain code:1 userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:LOCALIZED_STRING(@"VALIDATE_SOURCE"), *ioValue] forKey:NSLocalizedDescriptionKey]];
			return NO;
		}
		
		if((type == kType_LocalDisk) && path && ([*ioValue hasPrefix:path] || [path hasPrefix:*ioValue])) {
			*outError = [NSError errorWithDomain:kErrorDomain code:1 userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:LOCALIZED_STRING(@"VALIDATE_DIRECTORY"), *ioValue] forKey:NSLocalizedDescriptionKey]];
			return NO;
		}
		
		*ioValue = [*ioValue stringByAbbreviatingWithTildeInPath];
	}
	
	return YES;
}

- (NSError*) _validateDestination:(NSURL*)url
{
	NSString*				urlString = [url absoluteString];
	Mathusalem_Backup*		backup;
	
	if(urlString == nil)
	return nil;
	
	for(backup in [preferencePane allBackups]) {
		if(backup == self)
		continue;
		if([urlString caseInsensitiveCompare:[[backup destinationURLIncludingPassword:NO] absoluteString]] == NSOrderedSame)
		return [NSError errorWithDomain:kErrorDomain code:1 userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:LOCALIZED_STRING(@"VALIDATE_DESTINATION"), urlString] forKey:NSLocalizedDescriptionKey]];
	}
	
	return nil;
}

- (BOOL) validateHost:(id*)ioValue error:(NSError**)outError
{
	NSRange					range;
	
	if(*ioValue) {
		range = [*ioValue rangeOfString:@"://"];
		if(range.location != NSNotFound)
		*ioValue = [*ioValue substringFromIndex:(range.location + 3)];
		
		if([*ioValue rangeOfString:@"/"].location != NSNotFound) {
			*outError = [NSError errorWithDomain:kErrorDomain code:1 userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:LOCALIZED_STRING(@"VALIDATE_HOST"), *ioValue] forKey:NSLocalizedDescriptionKey]];
			return NO;
		}
		
		*outError = [self _validateDestination:[Mathusalem_Backup _makeDestinationURLWithType:type user:user password:nil host:*ioValue path:path]];
		if(*outError)
		return NO;
	}
	
	return YES;
}

- (BOOL) validatePath:(id*)ioValue error:(NSError**)outError
{
	static NSCharacterSet*	set = nil;
	BOOL					isDirectory;
	
	if((type == kType_AmazonS3) || (type == kType_SecureAmazonS3)) {
		if(set == nil)
		set = [[[NSCharacterSet characterSetWithCharactersInString:@".abcdefghijklmnopqrstuvwxyz_ABCDEFGHIJKLMNOPQRSTUVWXYZ-0123456789"] invertedSet] retain];
		
		//Restrictions are here: http://docs.amazonwebservices.com/AmazonS3/2006-03-01/BucketRestrictions.html
		if(![(NSString*)*ioValue length] || ([*ioValue rangeOfCharacterFromSet:set].location != NSNotFound) || ([(NSString*)*ioValue length] < 3) || ([(NSString*)*ioValue length] > 255)) {
			*outError = [NSError errorWithDomain:kErrorDomain code:1 userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:LOCALIZED_STRING(@"VALIDATE_BUCKET"), *ioValue] forKey:NSLocalizedDescriptionKey]];
			return NO;
		}
	}
	else if(*ioValue) {
		if(![*ioValue isAbsolutePath]) {
			*outError = [NSError errorWithDomain:kErrorDomain code:1 userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:LOCALIZED_STRING(@"VALIDATE_PATH"), *ioValue] forKey:NSLocalizedDescriptionKey]];
			return NO;
		}
		
		if(type == kType_LocalDisk) {
			*ioValue = [*ioValue stringByStandardizingPath];
			if(![[NSFileManager defaultManager] fileExistsAtPath:*ioValue isDirectory:&isDirectory] || !isDirectory) {
				*outError = [NSError errorWithDomain:kErrorDomain code:1 userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:LOCALIZED_STRING(@"VALIDATE_DIRECTORY"), *ioValue] forKey:NSLocalizedDescriptionKey]];
				return NO;
			}
			if(source && ([*ioValue hasPrefix:[source stringByExpandingTildeInPath]] || [[source stringByExpandingTildeInPath] hasPrefix:*ioValue])) {
				*outError = [NSError errorWithDomain:kErrorDomain code:1 userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:LOCALIZED_STRING(@"VALIDATE_DIRECTORY"), *ioValue] forKey:NSLocalizedDescriptionKey]];
				return NO;
			}
		}
	}
	
	if(*ioValue) {
		*outError = [self _validateDestination:[Mathusalem_Backup _makeDestinationURLWithType:type user:user password:nil host:host path:*ioValue]];
		if(*outError)
		return NO;
	}
		
	return YES;
}

- (BOOL) validateUser:(id*)ioValue error:(NSError**)outError
{
	if(*ioValue) {
		*outError = [self _validateDestination:[Mathusalem_Backup _makeDestinationURLWithType:type user:*ioValue password:nil host:host path:path]];
		if(*outError)
		return NO;
	}
	
	return YES;
}

- (BOOL) validateSegment:(id*)ioValue error:(NSError**)outError
{
	*ioValue = [NSNumber numberWithInteger:MAX([*ioValue integerValue], 0)];
	
	return YES;
}

- (BOOL) validatePassword1:(id*)ioValue error:(NSError**)outError
{
	if(*ioValue && password2 && ![*ioValue isEqualToString:password2]) {
		*outError = [NSError errorWithDomain:kErrorDomain code:1 userInfo:[NSDictionary dictionaryWithObject:LOCALIZED_STRING(@"VALIDATE_PASSWORD") forKey:NSLocalizedDescriptionKey]];
		return NO;
	}
	
	return YES;
}

- (BOOL) validatePassword2:(id*)ioValue error:(NSError**)outError
{
	if(*ioValue && password1 && ![*ioValue isEqualToString:password1]) {
		*outError = [NSError errorWithDomain:kErrorDomain code:1 userInfo:[NSDictionary dictionaryWithObject:LOCALIZED_STRING(@"VALIDATE_PASSWORD") forKey:NSLocalizedDescriptionKey]];
		return NO;
	}
	
	return YES;
}

- (BOOL) _validateExecutable:(id*)ioValue error:(NSError**)outError
{
	BOOL					isDirectory;
	NSString*				extension;
	
	if(*ioValue) {
		*ioValue = [*ioValue stringByStandardizingPath];
		extension = [[*ioValue pathExtension] lowercaseString];
		if(![*ioValue isAbsolutePath] || ![[NSFileManager defaultManager] fileExistsAtPath:*ioValue isDirectory:&isDirectory] || (isDirectory && ![extension isEqualToString:@"app"]) || (!isDirectory && ![[NSFileManager defaultManager] isExecutableFileAtPath:*ioValue] && ![extension isEqualToString:@"scpt"] && ![extension isEqualToString:@"applescript"])) {
			*outError = [NSError errorWithDomain:kErrorDomain code:1 userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:LOCALIZED_STRING(@"VALIDATE_EXECUTABLE"), *ioValue] forKey:NSLocalizedDescriptionKey]];
			return NO;
		}
	}
	
	return YES;
}

- (BOOL) validatePreExecutable:(id*)ioValue error:(NSError**)outError
{
	return [self _validateExecutable:ioValue error:outError];
}

- (BOOL) validatePostExecutable:(id*)ioValue error:(NSError**)outError
{
	return [self _validateExecutable:ioValue error:outError];
}

- (BOOL) validateScratch:(id*)ioValue error:(NSError**)outError
{
	BOOL					isDirectory;
	
	if(*ioValue) {
		*ioValue = [*ioValue stringByStandardizingPath];
		if(![*ioValue isAbsolutePath] || ![[NSFileManager defaultManager] fileExistsAtPath:*ioValue isDirectory:&isDirectory] || !isDirectory) {
			*outError = [NSError errorWithDomain:kErrorDomain code:1 userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:LOCALIZED_STRING(@"VALIDATE_DIRECTORY"), *ioValue] forKey:NSLocalizedDescriptionKey]];
			return NO;
		}
	}
	
	return YES;
}

- (BOOL) validateHourInterval:(id*)ioValue error:(NSError**)outError
{
	*ioValue = [NSNumber numberWithInteger:MAX([*ioValue integerValue], 1)];
	
	return YES;
}

- (BOOL) isValid
{
	if(source == nil)
	return NO;
	
	if(!host || ((type == kType_LocalDisk) && !path))
	return NO;
	
	return YES;
}

- (NSURL*) destinationURLIncludingPassword:(BOOL)includePassword
{
	return [Mathusalem_Backup _makeDestinationURLWithType:type user:user password:(includePassword ? password : nil) host:host path:path];
}

- (NSArray*) executionArgumentsIncludingPassword:(BOOL)includePassword
{
	NSMutableArray*			arguments = [NSMutableArray arrayWithObject:@"backup"];
	NSString*				string = [[self destinationURLIncludingPassword:includePassword] absoluteString];
	
	if(source) {
		[arguments addObject:@"-source"];
		[arguments addObject:source];
	}
	if(string) {
		[arguments addObject:@"-destination"];
		[arguments addObject:string];
	}
	switch(format) {
		
		case kFormat_SparseDiskImage:
		[arguments addObject:@"--diskImage"];
		break;
		
		case kFormat_CompressedDiskImage:
		[arguments addObject:@"--diskImage"];
		[arguments addObject:@"--compressed"];
		break;
		
		case kFormat_ZIPArchive:
		[arguments addObject:@"--compressed"];
		break;
		
		case kFormat_CPIOArchive:
		break;
		
	}
	if(segment > 0) {
		[arguments addObject:@"-segment"];
		[arguments addObject:[NSString stringWithFormat:@"%i", segment]];
	}
	if(atomic)
	[arguments addObject:@"--atomic"];
	if(fullBackup)
	[arguments addObject:@"--fullBackup"];
	if(excludeHidden)
	[arguments addObject:@"--excludeHidden"];
	for(string in excludedNames) {
		if([string length]) {
			[arguments addObject:@"-excludeName"];
			[arguments addObject:[NSString stringWithString:string]];
		}
	}
	for(string in excludedPaths) {
		if([string length]) {
			[arguments addObject:@"-excludePath"];
			[arguments addObject:[NSString stringWithString:string]];
		}
	}
	if(preExecutable) {
		[arguments addObject:@"-preExecutable"];
		[arguments addObject:preExecutable];
	}
	if(postExecutable) {
		[arguments addObject:@"-postExecutable"];
		[arguments addObject:postExecutable];
	}
	if(scratch) {
		[arguments addObject:@"-scratch"];
		[arguments addObject:scratch];
	}
	if(!skipConfirmation)
	[arguments addObject:@"--prompt"];
	if(inForeground)
	[arguments addObject:@"--foreground"];
	if(mode == kMode_Mounted)
	[arguments addObject:@"--checkReachability"];
	[arguments addObject:@"-uniqueID"];
	[arguments addObject:uniqueID];
	[arguments addObject:@"-name"];
	[arguments addObject:name];
	
	return arguments;
}

- (void) resetHistory
{
	[_historyURL release];
	_historyURL = nil;
}

- (NSArray*) history
{
	NSURL*						url = [self destinationURLIncludingPassword:YES];
	NSMutableDictionary*		parameters;
	
	if(![url isEqual:_historyURL]) {
		if(_historyURL)
		[self resetCache];
		
		[_history release];
		_history = nil;
		[_historyURL release];
		_historyURL = [url retain];
	}
	
	if(_history == nil) {
		_history = [NSMutableArray new];
		if(_historyURL) {
			_historyToken += 1;
			[self willChangeValueForKey:@"updating"];
			_historyOperations = 0;
			[self didChangeValueForKey:@"updating"];
			
			parameters = [NSMutableDictionary dictionaryWithObject:[NSNumber numberWithUnsignedInteger:_historyToken] forKey:@"~token"];
			[parameters setObject:_historyURL forKey:@"backup"];
			[[Mathusalem_PreferencePane sharedOperationQueue] addOperation:[BackupController backupOperationWithCommand:@"list" parameters:parameters delegate:self]];
			
			[self willChangeValueForKey:@"updating"];
			_historyOperations = 1;
			[self didChangeValueForKey:@"updating"];
		}
	}
	
	return _history;
}

- (BOOL) isUpdating
{
	return (_historyOperations > 0 ? YES : NO);
}

- (id) initWithLaunchdPlist:(NSString*)filePath
{
	NSDictionary*			plist;
	NSArray*				arguments;
	NSRange					range;
	NSString*				error;
	NSURL*					url;
	id						collection;
	
	plist = [NSPropertyListSerialization propertyListFromData:[NSData dataWithContentsOfFile:filePath] mutabilityOption:NSPropertyListImmutable format:NULL errorDescription:&error];
	if(plist == nil) {
		[[NSAlert alertWithMessageText:error defaultButton:nil alternateButton:nil otherButton:nil informativeTextWithFormat:@""] runModal];
		[self release];
		return nil;
	}
	arguments = [plist objectForKey:@"ProgramArguments"];
	
	if((self = [self initWithUniqueID:[[plist objectForKey:@"Label"] substringFromIndex:[kLabelPrefix length]]])) {
		if([arguments containsObject:@"-source"])
		[self setSource:[arguments objectAtIndex:([arguments indexOfObject:@"-source"] + 1)]];
		
		if([arguments containsObject:@"-destination"]) {
			url = [NSURL URLWithString:[arguments objectAtIndex:([arguments indexOfObject:@"-destination"] + 1)]];
			url = [[Keychain sharedKeychain] URLWithPasswordForURL:url];
			if([[url scheme] isEqualToString:@"file"])
			[self setType:kType_LocalDisk];
			else if([[url scheme] isEqualToString:@"afp"])
			[self setType:kType_AFP];
			else if([[url scheme] isEqualToString:@"smb"])
			[self setType:kType_SMB];
			else if([[url scheme] isEqualToString:@"ftp"])
			[self setType:kType_FTP];
			else if([[url scheme] isEqualToString:@"ssh"])
			[self setType:kType_SFTP];
			else if([[url scheme] isEqualToString:@"https"]) {
				range = [[url host] rangeOfString:kFileTransferHost_AmazonS3];
				if(range.location != NSNotFound) {
					[self setType:kType_SecureAmazonS3];
					[self setHost:kFileTransferHost_AmazonS3];
					[self setPath:[[url host] substringToIndex:(range.location - 1)]];
				}
				else
				[self setType:kType_SecureWebDAV];
			}
			else {
				range = [[url host] rangeOfString:kFileTransferHost_AmazonS3];
				if(range.location != NSNotFound) {
					[self setType:kType_AmazonS3];
					[self setHost:kFileTransferHost_AmazonS3];
					[self setPath:[[url host] substringToIndex:(range.location - 1)]];
				}
				else {
					if([[url host] isEqualToString:kFileTransferHost_iDisk])
					[self setType:kType_iDisk];
					else
					[self setType:kType_WebDAV];
				}
			}
			if((type != kType_AmazonS3) && (type != kType_SecureAmazonS3)) {
				[self setHost:([url port] ? [NSString stringWithFormat:@"%@:%@", [url host], [url port]] : [url host])];
				[self setPath:([[url path] length] ? [url path] : nil)];
			}
			[self setUser:[url user]];
			[self setPassword:[url passwordByReplacingPercentEscapes]];
		}
		
		if([arguments containsObject:@"--diskImage"]) {
			if([arguments containsObject:@"--compressed"])
			[self setFormat:kFormat_CompressedDiskImage];
			else
			[self setFormat:kFormat_SparseDiskImage];
		}
		else if([arguments containsObject:@"--compressed"])
		[self setFormat:kFormat_ZIPArchive];
		else
		[self setFormat:kFormat_CPIOArchive];
		if([arguments containsObject:@"-segment"])
		[self setSegment:[[arguments objectAtIndex:([arguments indexOfObject:@"-segment"] + 1)] integerValue]];
		[self setPassword1:[[Keychain sharedKeychain] genericPasswordForService:kBackupPasswordKeychainService account:uniqueID]];
		[self setPassword2:[self password1]];
		
		atomic = [arguments containsObject:@"--atomic"];
		fullBackup = [arguments containsObject:@"--fullBackup"];
		excludeHidden = [arguments containsObject:@"--excludeHidden"];
		range = NSMakeRange(0, [arguments count]);
		while(1) {
			range.location = [arguments indexOfObject:@"-excludeName" inRange:range];
			if(range.location == NSNotFound)
			break;
			[excludedNames addObject:[NSMutableString stringWithString:[arguments objectAtIndex:(range.location + 1)]]];
			range.location += 2;
			range.length = [arguments count] - range.location;
		}
		range = NSMakeRange(0, [arguments count]);
		while(1) {
			range.location = [arguments indexOfObject:@"-excludePath" inRange:range];
			if(range.location == NSNotFound)
			break;
			[excludedPaths addObject:[NSMutableString stringWithString:[arguments objectAtIndex:(range.location + 1)]]];
			range.location += 2;
			range.length = [arguments count] - range.location;
		}
		inForeground = [arguments containsObject:@"--foreground"];
		skipConfirmation = ![arguments containsObject:@"--prompt"];
		if([arguments containsObject:@"-preExecutable"])
		[self setPreExecutable:[arguments objectAtIndex:([arguments indexOfObject:@"-preExecutable"] + 1)]];
		if([arguments containsObject:@"-postExecutable"])
		[self setPostExecutable:[arguments objectAtIndex:([arguments indexOfObject:@"-postExecutable"] + 1)]];
		if([arguments containsObject:@"-scratch"])
		[self setScratch:[arguments objectAtIndex:([arguments indexOfObject:@"-scratch"] + 1)]];
		lowPriority = [[plist objectForKey:@"LowPriorityIO"] boolValue];
		
		mode = kMode_Manually;
		if([[plist objectForKey:@"RunAtLoad"] boolValue])
		mode = kMode_Login;
		else if([[plist objectForKey:@"StartOnMount"] boolValue])
		mode = kMode_Mounted;
		else if([plist objectForKey:@"StartInterval"]) {
			mode = kMode_Interval;
			hourInterval = [[plist objectForKey:@"StartInterval"] integerValue] / 3600;
		}
		else {
			collection = [plist objectForKey:@"StartCalendarInterval"];
			if([collection isKindOfClass:[NSDictionary class]]) {
				mode = kMode_Month;
				day = [[collection objectForKey:@"Day"] integerValue] - 1;
				[monthDate release];
				monthDate = [[NSDate dateWithTimeIntervalSinceReferenceDate:[[_baseDate dateByAddingYears:0 months:0 days:0 hours:[[collection objectForKey:@"Hour"] integerValue] minutes:[[collection objectForKey:@"Minute"] integerValue] seconds:0] timeIntervalSinceReferenceDate]] retain];
			}
			else if([collection isKindOfClass:[NSArray class]]) {
				mode = kMode_Week;
				for(collection in collection) {
					[weekDays setObject:[NSNumber numberWithBool:YES] forKey:_weekDays[[[collection objectForKey:@"Weekday"] integerValue]]];
					[weekDate release];
					weekDate = [[NSDate dateWithTimeIntervalSinceReferenceDate:[[_baseDate dateByAddingYears:0 months:0 days:0 hours:[[collection objectForKey:@"Hour"] integerValue] minutes:[[collection objectForKey:@"Minute"] integerValue] seconds:0] timeIntervalSinceReferenceDate]] retain];
				}
			}
		}
	}
	
	return self;
}

- (BOOL) writeToLaunchdPlist:(NSString*)filePath
{
	NSMutableDictionary*	configuration = [NSMutableDictionary dictionary];
	NSMutableDictionary*	dictionary;
	NSString*				key;
	NSUInteger				i;
	NSMutableArray*			array;
	NSError*				error;
	NSCalendarDate*			date;
	
	[[Keychain sharedKeychain] addPasswordForURL:[self destinationURLIncludingPassword:YES]];
	if(password1 && password2)
	[[Keychain sharedKeychain] addGenericPassword:password1 forService:kBackupPasswordKeychainService account:uniqueID];
	else
	[[Keychain sharedKeychain] removeGenericPasswordForService:kBackupPasswordKeychainService account:uniqueID];
	
	if(![self isValid])
	[configuration setObject:[NSNumber numberWithBool:YES] forKey:@"Disabled"];
	
	[configuration setObject:[NSString stringWithFormat:@"%@%@", kLabelPrefix, uniqueID] forKey:@"Label"];
	if(lowPriority) {
		[configuration setObject:[NSNumber numberWithBool:YES] forKey:@"LowPriorityIO"];
		[configuration setObject:[NSNumber numberWithInteger:10] forKey:@"Nice"];
	}
	
	array = [NSMutableArray new];
	[array addObject:[Mathusalem_Backup executablePath]];
	[array addObjectsFromArray:[self executionArgumentsIncludingPassword:NO]];
	[configuration setObject:array forKey:@"ProgramArguments"];
	[array release];
	
	switch(mode) {
		
		case kMode_Manually:
		break;
		
		case kMode_Login:
		[configuration setObject:[NSNumber numberWithBool:YES] forKey:@"RunAtLoad"];
		break;
		
		case kMode_Mounted:
		[configuration setObject:[NSNumber numberWithBool:YES] forKey:@"StartOnMount"];
		break;
		
		case kMode_Interval:
		[configuration setObject:[NSNumber numberWithInteger:(hourInterval * 3600)] forKey:@"StartInterval"];
		break;
		
		case kMode_Month:
		date = [NSCalendarDate dateWithTimeIntervalSinceReferenceDate:[monthDate timeIntervalSinceReferenceDate]];
		dictionary = [NSMutableDictionary new];
		[dictionary setObject:[NSNumber numberWithInteger:(day + 1)] forKey:@"Day"];
		[dictionary setObject:[NSNumber numberWithInteger:[date hourOfDay]] forKey:@"Hour"];
		[dictionary setObject:[NSNumber numberWithInteger:[date minuteOfHour]] forKey:@"Minute"];
		[configuration setObject:dictionary forKey:@"StartCalendarInterval"];
		[dictionary release];
		break;
		
		case kMode_Week:
		date = [NSCalendarDate dateWithTimeIntervalSinceReferenceDate:[weekDate timeIntervalSinceReferenceDate]];
		array = [NSMutableArray new];
		for(key in weekDays) {
			if(![[weekDays objectForKey:key] boolValue])
			continue;
			for(i = 0; i < 7; ++i) {
				if([key isEqualToString:_weekDays[i]]) {
					dictionary = [NSMutableDictionary new];
					[dictionary setObject:[NSNumber numberWithInteger:i] forKey:@"Weekday"];
					[dictionary setObject:[NSNumber numberWithInteger:[date hourOfDay]] forKey:@"Hour"];
					[dictionary setObject:[NSNumber numberWithInteger:[date minuteOfHour]] forKey:@"Minute"];
					[array addObject:dictionary];
					[dictionary release];
					break;
				}
			}
		}
		if([array count])
		[configuration setObject:array forKey:@"StartCalendarInterval"];
		[array release];
		break;
		
	}
	
	if(![[NSPropertyListSerialization dataFromPropertyList:configuration format:NSPropertyListXMLFormat_v1_0 errorDescription:NULL] writeToFile:filePath options:NSAtomicWrite error:&error]) {
		[[NSAlert alertWithError:error] runModal];
		return NO;
	}
	
	//NOTE: Make sure we have '-rw-r--r--' or launchd will fail loading the plist
	if(![[NSFileManager defaultManager] setAttributes:[NSDictionary dictionaryWithObject:[NSNumber numberWithUnsignedLong:0644] forKey:NSFilePosixPermissions] ofItemAtPath:filePath error:&error])
	LOG(@"Failed setting permissions for launchd plist \"%@\"", filePath);
	
	return YES;
}

- (BOOL) loadSettingsFromDestination
{
	NSURL*						url = [self destinationURLIncludingPassword:YES];
	DirectoryScanner*			scanner;
	
	if(url == nil)
	return NO;
	
	[[BackupController sharedBackupController] setDelegate:self];
	scanner = [[BackupController sharedBackupController] info:[NSDictionary dictionaryWithObject:url forKey:@"backup"]];
	[[BackupController sharedBackupController] setDelegate:nil];
	if(scanner == nil)
	return NO;
	
	[self setSource:[scanner rootDirectory]];
	if([[scanner userInfoForKey:kBackupScannerUserInfoKey_DiskImage] boolValue]) {
		if([[scanner userInfoForKey:kBackupScannerUserInfoKey_Compressed] boolValue])
		[self setFormat:kFormat_CompressedDiskImage];
		else
		[self setFormat:kFormat_SparseDiskImage];
	}
	else {
		if([[scanner userInfoForKey:kBackupScannerUserInfoKey_Compressed] boolValue])
		[self setFormat:kFormat_ZIPArchive];
		else
		[self setFormat:kFormat_CPIOArchive];
	}
	[self setSegment:[[scanner userInfoForKey:kBackupScannerUserInfoKey_Segment] integerValue]];
	[self setPassword1:nil];
	[self setPassword2:nil];
	[self setAtomic:[[scanner userInfoForKey:kBackupScannerUserInfoKey_Atomic] boolValue]];
	[self setFullBackup:[[scanner userInfoForKey:kBackupScannerUserInfoKey_FullBackup] boolValue]];
	[self setExcludeHidden:[scanner excludeHiddenItems]];
	
	[self willChangeValueForKey:@"excludedNames"];
	[[self excludedNames] removeAllObjects];
	[[self excludedNames] addMutableObjectsFromArray:[scanner userInfoForKey:@"excludedNames"]];
	[self didChangeValueForKey:@"excludedNames"];
	
	[self willChangeValueForKey:@"excludedPaths"];
	[[self excludedPaths] removeAllObjects];
	[[self excludedPaths] addMutableObjectsFromArray:[scanner userInfoForKey:@"excludedPaths"]];
	[self didChangeValueForKey:@"excludedPaths"];
	
	return YES;
}

- (BOOL) deleteAllDestinationFiles
{
	NSURL*						url = [self destinationURLIncludingPassword:YES];
	BOOL						success = NO;
	
	if(url == nil)
	return YES;
	
	[[BackupController sharedBackupController] setDelegate:self];
	success = [[[BackupController sharedBackupController] delete:[NSDictionary dictionaryWithObject:url forKey:@"backup"]] boolValue];
	[[BackupController sharedBackupController] setDelegate:nil];
	
	return success;
}

- (NSString*) _cacheDirectory
{
	NSArray*					array;
	
	if(_cacheDirectory == nil) {
		array = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
		if([array count]) {
			_cacheDirectory = [[array objectAtIndex:0] stringByAppendingPathComponent:[NSString stringWithFormat:@"[Mathusalem] %@", uniqueID]];
			if(![[NSFileManager defaultManager] fileExistsAtPath:_cacheDirectory] && ![[NSFileManager defaultManager] createDirectoryAtPath:_cacheDirectory withIntermediateDirectories:NO attributes:nil error:NULL]) {
				LOG(@"Failed creating backup cache \"%@\"", _cacheDirectory);
				_cacheDirectory = nil;
			}
			else
			[_cacheDirectory retain];
		}
	}
	
	return _cacheDirectory;
}

- (void) resetCache
{
	NSError*					error;
	
	if(_cacheDirectory) {
		if(![[NSFileManager defaultManager] removeItemAtPath:_cacheDirectory error:&error])
		LOG(@"Failed deleting backup cache \"%@\": %@", _cacheDirectory, error);
		
		[_cacheDirectory release];
		_cacheDirectory = nil;
	}
}

@end

/*
These methods are called from the BackupController thread
*/
@implementation Mathusalem_Backup (BackupOperationDelegate)

- (void) backupController:(BackupController*)controller didStartCommand:(NSString*)command parameters:(NSDictionary*)parameters
{
	NSURL*						url = [parameters objectForKey:@"backup"];
	
	if([command isEqualToString:@"list"])
	NSLog(@"Started fetching backup list from \"%@://%@%@\"...", [url scheme], [url host], [url path]);
	else if([command isEqualToString:@"info"])
	NSLog(@"Started fetching backup info for revision %@ from \"%@://%@%@\"...", [parameters objectForKey:@"revision"], [url scheme], [url host], [url path]);
}

- (void) _didReceiveHistoryInfo:(NSArray*)arguments
{
	DirectoryScanner*			scanner = ([arguments count] > 1 ? [arguments objectAtIndex:1] : nil);
	BOOL						shouldCache = ([arguments count] > 2 ? [[arguments objectAtIndex:2] boolValue] : NO);
	Mathusalem_Entry*			entry;
	NSString*					file;
	NSAutoreleasePool*			localPool;
	
	if([[arguments objectAtIndex:0] unsignedIntegerValue] != _historyToken)
	return;
	
	[self willChangeValueForKey:@"updating"];
	_historyOperations -= 1;
	[self didChangeValueForKey:@"updating"];
	
	[self willChangeValueForKey:@"history"];
	entry = (scanner ? [[Mathusalem_Entry alloc] initWithDirectoryScanner:scanner subpath:nil revision:0 isLeaf:NO] : [[Mathusalem_Entry unavailableEntry] retain]);
	[_history autorelease];
	_history = [[NSMutableArray alloc] initWithArray:_history]; //NOTE: Bindings can't observe the actual content of an array, so we need to replace it completely
	[_history replaceObjectAtIndex:([scanner revision] - 1) withObject:entry];
	[entry release];
	[self didChangeValueForKey:@"history"];
	
	if(scanner && shouldCache && (file = [self _cacheDirectory])) {
		localPool = [NSAutoreleasePool new];
		file = [file stringByAppendingPathComponent:CACHED_BOM_FILENAME([scanner revision])];
		if(![NSKeyedArchiver archiveRootObject:scanner toFile:file])
		LOG(@"Failed archiving DirectoryScanner to \"%@\"", file);
		[localPool release];
	}
}

- (void) _loadCachedHistoryInfo:(NSDictionary*)parameters
{
	NSString*					file = [parameters objectForKey:@"file"];
	DirectoryScanner*			scanner;
	
	scanner = [NSKeyedUnarchiver unarchiveObjectWithFile:file];
	if(scanner == nil)
	LOG(@"Failed unarchiving DirectoryScanner from \"%@\"", file);
	
	[self performSelectorOnMainThread:@selector(_didReceiveHistoryInfo:) withObject:[NSArray arrayWithObjects:[parameters objectForKey:@"~token"], scanner, nil] waitUntilDone:NO];
}

- (void) _didReceiveHistoryList:(NSArray*)arguments
{
	NSArray*					list = ([arguments count] > 1 ? [arguments objectAtIndex:1] : nil);
	NSFileManager*				manager = [NSFileManager defaultManager];
	NSOperation*				lastOperation = nil;
	NSOperation*				operation;
	NSUInteger					i;
	NSMutableDictionary*		parameters;
	NSString*					file;
	
	if([[arguments objectAtIndex:0] unsignedIntegerValue] != _historyToken)
	return;
	
	[self willChangeValueForKey:@"updating"];
	_historyOperations -= 1;
	[self didChangeValueForKey:@"updating"];

	if(list) {
		[self willChangeValueForKey:@"history"];
		[_history autorelease];
		_history = [NSMutableArray new]; //NOTE: Bindings can't observe the actual content of an array, so we need to replace it completely
		for(i = 0; i < [list count]; ++i) {
			if([list objectAtIndex:i] == (NSDate*)[NSNull null]) {
				[_history addObject:[Mathusalem_Entry unavailableEntry]];
				continue;
			}
			
			[_history addObject:[Mathusalem_Entry loadingEntry]];
			
			parameters = [NSMutableDictionary dictionaryWithObject:[NSNumber numberWithUnsignedInteger:_historyToken] forKey:@"~token"];
			file = [[self _cacheDirectory] stringByAppendingPathComponent:CACHED_BOM_FILENAME(i + 1)];
			if(file && [manager fileExistsAtPath:file]) {
				[parameters setObject:file forKey:@"file"];
				operation = [[[NSInvocationOperation alloc] initWithTarget:self selector:@selector(_loadCachedHistoryInfo:) object:parameters] autorelease];
			}
			else {
				[parameters setObject:_historyURL forKey:@"backup"];
				[parameters setObject:[NSNumber numberWithInteger:(i + 1)] forKey:@"revision"];
				operation = [BackupController backupOperationWithCommand:@"info" parameters:parameters delegate:self];
				if(lastOperation)
				[operation addDependency:lastOperation];
				lastOperation = operation;
			}
			[[Mathusalem_PreferencePane sharedOperationQueue] addOperation:operation];
			
			[self willChangeValueForKey:@"updating"];
			_historyOperations += 1;
			[self didChangeValueForKey:@"updating"];
		}
		[self didChangeValueForKey:@"history"];
	}
	else {
		[_historyURL release];
		_historyURL = nil;
	}
}

- (void) backupController:(BackupController*)controller didFinishCommand:(NSString*)command parameters:(NSDictionary*)parameters result:(id)result
{
	NSURL*						url = [parameters objectForKey:@"backup"];
	
	if([command isEqualToString:@"list"]) {
		NSLog(@"Done fetching backup list from \"%@://%@%@\"!", [url scheme], [url host], [url path]);
		[self performSelectorOnMainThread:@selector(_didReceiveHistoryList:) withObject:[NSArray arrayWithObjects:[parameters objectForKey:@"~token"], result, nil] waitUntilDone:NO];
	}
	else if([command isEqualToString:@"info"]) {
		NSLog(@"Done fetching backup info for revision %@ from \"%@://%@%@\"!", [parameters objectForKey:@"revision"], [url scheme], [url host], [url path]);
		[self performSelectorOnMainThread:@selector(_didReceiveHistoryInfo:) withObject:[NSArray arrayWithObjects:[parameters objectForKey:@"~token"], result, [NSNumber numberWithBool:YES], nil] waitUntilDone:NO];
	}
}

- (BOOL) backupControllerShouldAbort:(BackupController*)controller
{
	return NO;
}

- (void) backupController:(BackupController*)controller didUpdateStatus:(BackupControllerStatus)status currentValue:(NSUInteger)value maxValue:(NSUInteger)max
{
	;
}

- (void) backupController:(BackupController*)controller errorDidOccur:(NSError*)error
{
	NSLog(@"%@", error);
}

- (BOOL) backupControllerShouldAbortCurrentFileTransfer:(BackupController*)controller
{
	return NO;
}

- (BOOL) backupController:(BackupController*)controller shouldRetryFileTransferWithURL:(NSURL*)url
{
	return NO;
}

@end

@implementation NSMutableString (Mathusalem_PreferencePane)

- (NSString*) string
{
	return [[self copy] autorelease];
}

@end

@implementation NSMutableArray (Mathusalem_PreferencePane)

- (void) addMutableObjectsFromArray:(NSArray*)otherArray
{
	id						object;
	
	for(object in otherArray)
	[self addObject:[[object mutableCopy] autorelease]];
}

@end
