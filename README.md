Overview
========

Mathusalem is a simple backup system for Mac OS X Leopard, which can be used either as a System Preferences pane or directly as a command line tool.

This source code is copyrighted Pierre-Olivier Latour and available under the terms of the GPLv3 license.

Installation
============

Installing Mathusalem
---------------------

1. Download the latest version of Mathusalem from the Downloads page
2. Go to your Downloads directory:
 1. Open the Mathusalem subdirectory
 2. Double-click on Mathusalem.prefpane to install it
 3. Once in System Preferences, confirm installation
6. Now that it has been installed, you can drag to the Trash the Mathusalem directory from inside your Downloads directory

Updating Mathusalem
-------------------

Mathusalem has an built-in auto-update mechanism that checks if a new version is available whenever you go its preference pane. If there is a new version, you will be notified and from then, just follow the onscreen instructions.

Uninstalling Mathusalem
-----------------------

1. Open System Preferences and go to the Mahusalem pane
2. Delete all backup entries
3. Quit System Preferences
4. Drag Mathusalem.prefpane from ~/Library/PreferencePanes or /Library/PreferencePanes to the Trash

Command Line Tool
=================

When you download the latest version of Mathusalem from the Downloads page, you get a folder with both the Mathusalem preference pane and the command line tool.

The command line tool version is strictly GUI-less and must be used from the Terminal, shell scripts or equivalent. You run it like this:

```
./Mathusalem command [options...]
```

To learn about the list of supported commands and their options, read the tool help or run the tool with the "help" command:

```
./Mathusalem help
```

If you want both the ability to run Mathusalem from the command line and have a GUI, you need to use the Mathusalem application, located in "Mathusalem.prefPane/Contents/Resources":

```
./Mathusalem.app/Contents/MacOS/Mathusalem
```

However, it only supports the "backup" and "restore" commands.

Limitations
===========

**IMPORTANT:** In response to some users comments, please be aware that Mathusalem is not designed to "clone" an entire file system or a subportion of it, but instead to optimally handle everyday simple backups.

The following information is only provided for completeness and only matters for very advanced users: the majority of users are not affected by any of this.

* Mathusalem only cares about modifications of the actual file content, not of its attributes like access permissions
* To determine is a file content has changed, it only looks at its modification date, not the inside of the file
* It does not follow symlinks, which are copied instead
* Mathusalem does not guarantee to preserve owner, permissions or Finder locked state on files or directories
* It does not preserve extended attributes on directories, but preserves them on files
* The initial backup requires as much extra space on the boot volume as the total size of the data being backed up
* It is not capable of splitting individual files when creating segmented backups
* You cannot "prune" old incremental backups
