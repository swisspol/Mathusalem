#!/bin/sh

#####
#
# This script takes an optional argument indicating the path to the base Developer directory
#
#####

# Setup variables
DATE=`date "+%Y-%m-%d-%H-%M-%S"`
SCRATCH_DIR="/tmp/$DATE"
PROJECT="Mathusalem"
XCODEBUILD="$1/usr/bin/xcodebuild"

# Create scratch directory
mkdir "$SCRATCH_DIR"
cd "$SCRATCH_DIR"

# Check out TOT & retrieve version / revision
echo "Checking out HEAD..."
svn checkout "https://mathusalem.googlecode.com/svn/trunk/" "$PROJECT" > /dev/null
if [[ $? -ne 0 ]]
then
	rm -rf "$SCRATCH_DIR"
	exit 1;
fi
REVISION=`svn info "$PROJECT" | grep "Revision:" | awk '{ print $2 }'`
VERSION=`svn propget version "$PROJECT/$PROJECT.xcodeproj/project.pbxproj"`
echo "<Using version $VERSION ($REVISION)>"

# Export source from server
echo "Exporting source..."
SOURCE="$PROJECT Source $VERSION ($REVISION)"
svn export -r $REVISION "https://mathusalem.googlecode.com/svn/trunk/" "$SOURCE" > /dev/null
if [[ $? -ne 0 ]]
then
	rm -rf "$SCRATCH_DIR"
	exit 1;
fi

# Tag revision on server side
echo "Tagging revision on server..."
svn copy -r $REVISION -m "Tagging version $VERSION for revision $REVISION" "https://mathusalem.googlecode.com/svn/trunk/" "https://mathusalem.googlecode.com/svn/tags/Version-$VERSION-$REVISION" > /dev/null
if [[ $? -ne 0 ]]
then
	rm -rf "$SCRATCH_DIR"
	exit 1;
fi

# Fix svn:externals revision for PolKit on the tagged revision
echo "Fixing external revisions on tagged revision..."
TAG="$PROJECT Tag $VERSION ($REVISION)"
svn checkout "https://mathusalem.googlecode.com/svn/tags/Version-$VERSION-$REVISION" "$TAG" > /dev/null
if [[ $? -ne 0 ]]
then
	rm -rf "$SCRATCH_DIR"
	exit 1;
fi
EXTERNAL_REVISION=`svn info "$PROJECT/PolKit" | grep "Revision:" | awk '{ print $2 }'`
svn propset "svn:externals" "PolKit -r $EXTERNAL_REVISION http://polkit.googlecode.com/svn/trunk/" "$TAG" > /dev/null
if [[ $? -ne 0 ]]
then
	rm -rf "$SCRATCH_DIR"
	exit 1;
fi
svn commit -m "Fixed svn:externals" "$TAG" > /dev/null
if [[ $? -ne 0 ]]
then
	rm -rf "$SCRATCH_DIR"
	exit 1;
fi

# Build project
echo "Building project..."
ROOT="$PROJECT $VERSION"
cd "$PROJECT"
$XCODEBUILD install DSTROOT="$SCRATCH_DIR/$ROOT" -nodistribute > /dev/null
cd ..
if [[ $? -ne 0 ]]
then
	rm -rf "$SCRATCH_DIR"
	exit 1;
fi

# Create & upload build archive
ARCHIVE="$PROJECT-$VERSION.zip"
ditto -c -k --keepParent "$ROOT" "$ARCHIVE"
$PROJECT/Support/googlecode_upload.py -s "$PROJECT $VERSION (PRE-RELEASE - DOWNLOAD AT YOUR OWN RISK - DO NOT REDISTRIBUTE)" -l "Type-Archive, OpSys-OSX" -p "mathusalem" -u "info@pol-online.net" "$ARCHIVE"
if [[ $? -ne 0 ]]
then
        mv -f "$ARCHIVE" ~/Desktop/
fi

# Create & upload source archive
ARCHIVE="$PROJECT-Source-$VERSION.zip"
ditto -c -k --keepParent "$SOURCE" "$ARCHIVE"
$PROJECT/Support/googlecode_upload.py -s "Source for $PROJECT $VERSION" -l "Type-Source, OpSys-OSX" -p "mathusalem" -u "info@pol-online.net" "$ARCHIVE"
if [[ $? -ne 0 ]]
then
        mv -f "$ARCHIVE" ~/Desktop/
fi

# Delete scratch directory
rm -rf "$SCRATCH_DIR"
