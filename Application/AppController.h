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

#import <AppKit/AppKit.h>

#import "BackupController.h"

@interface AppController : NSObject <BackupOperationDelegate>
{
	IBOutlet NSPanel*				panel;
	IBOutlet NSTextField*			sourceTextField;
	IBOutlet NSTextField*			destinationTextField;
	IBOutlet NSProgressIndicator*	progressIndicator;
	IBOutlet NSTextField*			statusTextField;
	IBOutlet NSButton*				abortButton;
	IBOutlet NSButton*				stopButton;
	IBOutlet NSButton*				restartButton;
	
	BackupController*				_controller;
	NSString*						_command;
	BOOL							_shouldAbortTransfer,
									_shouldAbortCompletely;
	BackupControllerStatus			_lastStatus;
	NSUInteger						_lastMax;
	double							_lastProgress;
	id								_backupResult;
	NSCondition*					_transferCondition;
	BOOL							_transferRetry;
	NSUInteger						_alertCount;
}
- (IBAction) abort:(id)sender;
- (IBAction) stop:(id)sender;
- (IBAction) restart:(id)sender;

- (void) handleSignal:(int)signal;
@end
