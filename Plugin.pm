# AutoRescan Plugin for SqueezeCentre
# Copyright © Stuart Hickinbottom 2007-2008

# This file is part of AutoRescan.
#
# AutoRescan is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# AutoRescan is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with AutoRescan; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA

# $Id$

# This is a plugin to provide automatic rescanning of music files as they are
# changed within the filesystem. It depends on the 'inotify' kernel function
# within Linux and, therefore, currently only works when used on a Linux system
# where that kernel feature has been enabled. See the INSTALL file for further
# instructions on the kernel configuration.
#
# For further details see:
# http://www.hickinbottom.com

use strict;
use warnings;

package Plugins::AutoRescan::Plugin;

use base qw(Slim::Plugin::Base);

use utf8;
use Plugins::AutoRescan::Settings;
use Plugins::AutoRescan::Monitor_Linux;
use Slim::Utils::Strings qw (string);
use Slim::Utils::Timers;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Time::HiRes;
use Scalar::Util qw(blessed);
use File::Find;
use File::Basename;
use Slim::Utils::OSDetect;

# Name of this plugin - used for various global things to prevent clashes with
# other plugins.
use constant PLUGIN_NAME => 'PLUGIN_AUTORESCAN';

# Preference ranges and defaults.
use constant AUTORESCAN_DELAY_DEFAULT => 5;

# Polling control.
use constant AUTORESCAN_POLL => 1;

# Export the version to the server (as a subversion keyword).
use vars qw($VERSION);
$VERSION = 'v@@VERSION@@ (trunk-7.x)';

# A logger we will use to write plugin-specific messages.
my $log = Slim::Utils::Log->addLogCategory(
	{
		'category'     => 'plugin.autorescan',
		'defaultLevel' => 'INFO',
		'description'  => 'PLUGIN_AUTORESCAN'
	}
);

# Monitor object that contains the platform-specific functionality for
# monitoring directories for changes.
my $monitor;

# Hash so we can track directory monitors.
my %monitors;

# Hash of directories detected as touched.
my %touchedDirs;

# Access to preferences for this plugin and for server-wide settings.
my $myPrefs     = preferences('plugin.autorescan');
my $serverPrefs = preferences('server');

# Flag to protect against multiple initialisation or shutdown
my $initialised = 0;

# Below are functions that are part of the standard SqueezeCentre plugin
# interface.

# Return the name of this plugin; this goes on the server setting plugin
# page, for example.
sub getDisplayName {
	return PLUGIN_NAME;
}

# Set up this plugin when it's inserted or the server started.
sub initPlugin() {

	my $class = shift;

	return if $initialised;    # don't need to do it twice

	$log->info("Initialising $VERSION");

	$class->SUPER::initPlugin(@_);

	# Initialise settings.
	Plugins::AutoRescan::Settings->new($class);

	# Remember we're now initialised. This prevents multiple-initialisation,
	# which may otherwise cause trouble with duplicate hooks or modes.
	$initialised = 1;

	# Make sure the preferences are set to something sensible before we call
	# on them later.
	checkDefaults();

	# Create the monitor interface, depending on our current platorm.
	my $os = Slim::Utils::OSDetect::OS();
	if ($os eq 'unix') {
		$log->debug('Linux monitoring method selected');
		$monitor = Plugins::AutoRescan::Monitor_Linux->new($class);
	} elsif ($os eq 'windows') {
		$log->debug('Windows monitoring method selected');
		#@@TODO@@
	} else {
		$log->warn("Unsupported operating system type '$os' - will not monitor for changes");
	}

	# If initialisation worked then add monitors.
	addWatch() if ($monitor);

	$log->debug("Initialisation complete");
}

# Called when the plugin is being disabled or SqueezeCenter shut down.
sub shutdownPlugin() {

	my $class = shift;

	return if !$initialised;    # don't need to do it twice

	$log->debug("Shutting down");

	# Shutdown the monitor.
	$monitor->delete if $monitor;

	# We're no longer initialised.
	$initialised = 0;
}

# Below are functions that are specific to this plugin.

# Called during initialisation, this makes sure that the plugin preferences
# stored are sensible. This has the effect of adding them the first time this
# plugin is activated and removing the need to check they're defined in each
# case of reading them.
sub checkDefaults {
	if ( !defined( $myPrefs->get('delay') ) ) {
		$myPrefs->set( 'delay', AUTORESCAN_DELAY_DEFAULT );
	}

	# If the revision isn't yet in the preferences we set it to something
	# that's guaranteed to be different so that we can detect the plugin
	# is used for the first time.
	if ( !defined( $myPrefs->get('revision') ) ) {
		$myPrefs->set( 'revision', '-undefined-' );
	}
}

# Add an inotify watch to the music folder.
sub addWatch() {
	my $audioDir = $serverPrefs->get('audiodir');

	if (defined $audioDir && -d $audioDir) {
		$log->debug("Adding inotify monitor to music directory: $audioDir");

		# Add the watch callback. This will also watch all subordinate folders.
		addNotifierRecursive($audioDir);

		# Tell the monitor.
		$monitor->addDone if $monitor;

		# Add a poller callback timer. We need this to pump events.
		Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + AUTORESCAN_POLL, \&poller);

	} else {
		$log->info("Music folder is not defined - skipping add of change monitor");
	}

}

# Recursively add notifiers for all folders under a given root.
sub addNotifierRecursive($) {
	my $dir = shift;

	if (-d $dir) {
		find({ wanted => sub {
				addNotifier($File::Find::name) if -d $File::Find::name;
			}, follow => 1, no_chdir => 1 }, $dir);
	}
}

# Add an monitor for a given directory.
sub addNotifier($) {
	my $dir = shift;

	# Only add a monitor if we're not already monitoring this directory (and
	# it is indeed a directory).
	if (not exists $monitors{$dir} && -d $dir) {
		# Remember the monitor object created - we do this so we can check if
		# it's already being monitored later on.
		$monitors{$dir} = $monitor->addWatch($dir);
	} else {
		$log->debug("Not adding monitor, one is already present for: $dir");
	}
}

# Called periodically so we can detect and dispatch any events.
sub poller() {

	# Pump that poller - let the monitors decide how to do that.
	$monitor->poll if $monitor;

	# Flag of whether any rescanning was performed.
	my $scan_done = 0;

	# We don't perform any rescanning if a scan is currently underway - we
	# defer it until it's finished.
	if (not Slim::Music::Import->stillScanning()) {

		# If there are any touched directories that are older than our delay
		# time then rescan them and remove them from our hash of tracked
		# directories.
		my $triggerTime = Time::HiRes::time() - $myPrefs->get('delay');
		for my $dir (keys %touchedDirs) {
			if ($touchedDirs{$dir} < $triggerTime) {
				$log->info("Triggering RESCAN of folder: $dir");
				$scan_done = 1;

				# Rescan the changed directory.
				my $dirURL = Slim::Utils::Misc::fileURLFromPath($dir);
				my $dirObject = Slim::Schema->rs('Track')->objectForUrl({
						'url'      => $dirURL,
						'create'   => 1,
						'readTags' => 1,
						'commit'   => 1,
					});

				# This bodge is necessary to fool the scan function into
				# looking into this directory even though its modification time
				# may not have changed from that in the database. This can
				# happen if individual files are touched (eg though editing
				# their tags), which won't normally have the effect of touching
				# the directory.
				$dirObject->set_column('timestamp', $dirObject+1);

				# Now ask for the directory to be rescanned.
				Slim::Utils::Misc::findAndScanDirectoryTree( { obj => $dirObject } );
				
				delete $touchedDirs{$dir};
			}
		}
	}

	# If a rescan was performed then do a database cleanup. This is necessary
	# to remove items from the database that no longer exist - eg the old file
	# if the file has been renamed or moved.
	# Note that this might be slow since it has to traverse every file in the
	# database - that shouldn't be too much of an annoyance, though, since
	# the user is assumed to have just moved music around and it won't happen
	# too often.
	if ($scan_done) {
		$log->info("One or more scans have been performed. Now performing cleanup");
		Slim::Schema->cleanupStaleTrackEntries;
	}

	# Schedule another poll.
	Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + AUTORESCAN_POLL, \&poller);
}

# Note a directory as having been touched.
sub noteTouch {
	my $dir = shift;

	# Note the time the directory was touched. If we already had it monitored
	# then we just touch the time that was already there. That way we won't
	# repeatedly rescan directories as they are being populated etc.
	$touchedDirs{$dir} = Time::HiRes::time();
}

1;

__END__

# Local Variables:
# tab-width:4
# indent-tabs-mode:t
# End:
