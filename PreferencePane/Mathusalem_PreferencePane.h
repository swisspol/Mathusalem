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

#import <PreferencePanes/PreferencePanes.h>
#import <WebKit/WebKit.h>

#define kRegistrationDelay				(7 * 24 * 3600.0) //seconds

#define kUserDefaultKey_Registration	@"mathusalem.registration"

#define LOCALIZED_STRING(__STRING__) [[NSBundle bundleForClass:[Mathusalem_PreferencePane class]] localizedStringForKey:(__STRING__) value:(__STRING__) table:nil]
#define LOG(...) NSLog(@"%@", [@"Mathusalem: " stringByAppendingFormat:__VA_ARGS__])

@class Mathusalem_Backup;

@interface Mathusalem_PreferencePane : NSPreferencePane 
{
	IBOutlet NSTabView*				tabView;
	IBOutlet NSArrayController*		backupArrayController;
	IBOutlet NSArrayController*		namesArrayController;
	IBOutlet NSArrayController*		pathsArrayController;
	IBOutlet NSTreeController*		historyTreeController;
	IBOutlet NSTableView*			backupTableView;
	IBOutlet NSBrowser*				historyBrowser;
	IBOutlet NSTextField*			versionField;
	IBOutlet NSProgressIndicator*	progressSpinner;
	IBOutlet WebView*				webView;
	IBOutlet NSWindow*				downloadWindow;
	IBOutlet NSProgressIndicator*	downloadProgress;
	IBOutlet NSWindow*				bucketWindow;
	IBOutlet NSTreeController*		bucketTreeController;
	IBOutlet NSBrowser*				bucketBrowser;
	IBOutlet NSProgressIndicator*	bucketProgress;
	IBOutlet NSPanel*				bucketPanel;
	IBOutlet NSTextField*			bucketTextField;
	IBOutlet NSWindow*				registrationWindow;
	IBOutlet NSTextField*			registrationCityTextField;
	IBOutlet NSTextField*			registrationStateTextField;
	IBOutlet NSTextField*			registrationCountryTextField;
	IBOutlet NSTextField*			registrationCommentTextField;
	
	NSString*						_version;
	NSArray*						_buckets;
	NSArray*						_bucketSortDescriptors;
	NSUInteger						_updatingBuckets;
	id								_updateCheckResult;
	NSTask*							_currentTask;
}
+ (NSOperationQueue*) sharedOperationQueue;

@property(readonly) NSArray* allBackups;
@property(readonly) NSTask* currentTask;
@property(copy) NSArray* buckets;
@property(readonly, getter=isUpdatingBuckets) BOOL updatingBuckets;

- (BOOL) isBackupNameUnique:(NSString*)name;
@end

@interface Mathusalem_PreferencePane (Actions)
- (IBAction) addBackup:(id)sender;
- (IBAction) removeBackup:(id)sender;
- (IBAction) saveBackup:(id)sender;
- (IBAction) runBackup:(id)sender;
- (IBAction) chooseSource:(id)sender;
- (IBAction) chooseDestination:(id)sender;
- (IBAction) chooseExecutable:(id)sender;
- (IBAction) chooseScratch:(id)sender;
- (IBAction) doneEditingBuckets:(id)sender;
- (IBAction) doneAddingBucket:(id)sender;
- (IBAction) addBucket:(id)sender;
- (IBAction) removeBucket:(id)sender;
- (IBAction) editBuckets:(id)sender;
- (IBAction) restoreItem:(id)sender;
- (IBAction) openHelp:(id)sender;
- (IBAction) openWebSite:(id)sender;
- (IBAction) doneRegistration:(id)sender;
@end
