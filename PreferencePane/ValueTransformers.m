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

#import "ValueTransformers.h"
#import "Mathusalem_Backup.h"

@implementation Mathusalem_UserPasswordEnabledTransformer

+ (Class) transformedValueClass
{
	return [NSNumber class];
}

- (id) transformedValue:(id)value
{
	return [NSNumber numberWithBool:([value integerValue] != kType_LocalDisk)];
}

@end

@implementation Mathusalem_HostEnabledTransformer

+ (Class) transformedValueClass
{
	return [NSNumber class];
}

- (id) transformedValue:(id)value
{
	return [NSNumber numberWithBool:(([value integerValue] != kType_LocalDisk) && ([value integerValue] != kType_iDisk) && ([value integerValue] != kType_AmazonS3) && ([value integerValue] != kType_SecureAmazonS3))];
}

@end

@implementation Mathusalem_PathEnabledTransformer

+ (Class) transformedValueClass
{
	return [NSNumber class];
}

- (id) transformedValue:(id)value
{
	return [NSNumber numberWithBool:(([value integerValue] == kType_AmazonS3) || ([value integerValue] == kType_SecureAmazonS3))];
}

@end

@implementation Mathusalem_InvertedPathEnabledTransformer

+ (Class) transformedValueClass
{
	return [NSNumber class];
}

- (id) transformedValue:(id)value
{
	return [NSNumber numberWithBool:(([value integerValue] != kType_AmazonS3) && ([value integerValue] != kType_SecureAmazonS3))];
}

@end

@implementation Mathusalem_FormatEnabledTransformer

+ (Class) transformedValueClass
{
	return [NSNumber class];
}

- (id) transformedValue:(id)value
{
	return [NSNumber numberWithBool:([value integerValue] != kFormat_SparseDiskImage)];
}

@end

@implementation Mathusalem_PasswordEnabledTransformer

+ (Class) transformedValueClass
{
	return [NSNumber class];
}

- (id) transformedValue:(id)value
{
	return [NSNumber numberWithBool:(([value integerValue] != kFormat_SparseDiskImage) && ([value integerValue] != kFormat_CompressedDiskImage))];
}

@end

@implementation Mathusalem_IntervalEnabledTransformer

+ (Class) transformedValueClass
{
	return [NSNumber class];
}

- (id) transformedValue:(id)value
{
	return [NSNumber numberWithBool:([value integerValue] == kMode_Interval)];
}

@end

@implementation Mathusalem_MonthEnabledTransformer

+ (Class) transformedValueClass
{
	return [NSNumber class];
}

- (id) transformedValue:(id)value
{
	return [NSNumber numberWithBool:([value integerValue] == kMode_Month)];
}

@end

@implementation Mathusalem_WeekEnabledTransformer

+ (Class) transformedValueClass
{
	return [NSNumber class];
}

- (id) transformedValue:(id)value
{
	return [NSNumber numberWithBool:([value integerValue] == kMode_Week)];
}

@end

@implementation Mathusalem_ImageTransformer

+ (void) initialize
{
	[super initialize];
	
	if(self == [Mathusalem_ImageTransformer class]) {
		[(NSImage*)[[NSImage alloc] initWithContentsOfFile:[[NSBundle bundleForClass:[Mathusalem_Backup class]] pathForResource:@"Green" ofType:@"tiff"]] setName:@"Mathusalem-Green"];
		[(NSImage*)[[NSImage alloc] initWithContentsOfFile:[[NSBundle bundleForClass:[Mathusalem_Backup class]] pathForResource:@"Red" ofType:@"tiff"]] setName:@"Mathusalem-Red"];
	}
}

+ (Class) transformedValueClass
{
	return [NSImage class];
}

- (id) transformedValue:(id)value
{
	return ([value boolValue] ? [NSImage imageNamed:@"Mathusalem-Red"] : [NSImage imageNamed:@"Mathusalem-Green"]);
}

@end

@implementation Mathusalem_HistoryEnabledTransformer

+ (Class) transformedValueClass
{
	return [NSNumber class];
}

- (id) transformedValue:(id)value
{
	return [NSNumber numberWithBool:([value length] > 0)];
}

@end

@implementation Mathusalem_BucketEnabledTransformer

+ (Class) transformedValueClass
{
	return [NSNumber class];
}

- (id) transformedValue:(id)value
{
	return [NSNumber numberWithBool:([value length] == 1)];
}

@end
