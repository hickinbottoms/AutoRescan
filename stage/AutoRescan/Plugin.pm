# AutoRescan Plugin for Squeezebox Server
# Copyright © Stuart Hickinbottom 2007-2014

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
use constant AUTORESCAN_DELAY_DEFAULT  => 5;
use constant AUTORESCAN_SCRIPT_DEFAULT => '';

# Polling control.
use constant AUTORESCAN_POLL => 1;

# Export the version to the server (as a subversion keyword).
use vars qw($VERSION);
$VERSION = 'v1.4.1 (trunk-7.x)';

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

# Access to preferences for this plugin and for server-wide settings.
my $myPrefs     = preferences('plugin.autorescan');
my $serverPrefs = preferences('server');

# Flag to protect against multiple initialisation or shutdown
my $initialised = 0;

# Below are functions that are part of the standard Squeezebox Server plugin
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

	# Create the monitor interface, depending on our current platorm.
	my $os = Slim::Utils::OSDetect::OS();
	if ( $os eq 'unix' ) {
		$log->debug('Linux monitoring method selected');
		eval 'use Plugins::AutoRescan::Monitor_Linux';
		$monitor = Plugins::AutoRescan::Monitor_Linux->new($class);
	} elsif ( $os eq 'win' ) {
		$log->debug('Windows monitoring method selected');
		eval 'use Plugins::AutoRescan::Monitor_Windows';
		$monitor = Plugins::AutoRescan::Monitor_Windows->new($class);
	} else {
		$log->warn(
"Unsupported operating system type '$os' - will not monitor for changes"
		);
	}

	my $can_script = 0;
	$can_script = $monitor->{can_script} if ($monitor);

	# Initialise settings.
	Plugins::AutoRescan::Settings->new( $class, $can_script );

	# Remember we're now initialised. This prevents multiple-initialisation,
	# which may otherwise cause trouble with duplicate hooks or modes.
	$initialised = 1;

	# Make sure the preferences are set to something sensible before we call
	# on them later.
	checkDefaults();

	# If initialisation worked then add monitors.
	addWatch() if ($monitor);

	$log->debug("Initialisation complete");
}

# Called when the plugin is being disabled or Squeezebox Server shut down.
sub shutdownPlugin() {

	my $class = shift;

	return if !$initialised;    # don't need to do it twice

	$log->debug("Shutting down");

	# If we've still got a pending callback timer then cancel it so we're
	# not called back after shutdown.
	killCallbackTimer();

	# Shutdown the monitor.
	$log->debug("Removing change monitor");
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

	if ( !defined( $myPrefs->get('script') ) ) {
		$myPrefs->set( 'script', AUTORESCAN_SCRIPT_DEFAULT );
	}

	# If the revision isn't yet in the preferences we set it to something
	# that's guaranteed to be different so that we can detect the plugin
	# is used for the first time.
	if ( !defined( $myPrefs->get('revision') ) ) {
		$myPrefs->set( 'revision', '-undefined-' );
	}
}

# Add a watch to the music folder.
sub addWatch() {

	# Filter media directories for those with audio - LMS7.7+ only.
	my $audioDirs = Slim::Utils::Misc::getMediaDirs('audio');

	for my $audioDir (@$audioDirs) {

		if ( defined $audioDir && -d $audioDir ) {
			$log->debug("Adding monitor to music directory: $audioDir");

		 # Add the watch callback. This will also watch all subordinate folders.
			addNotifierRecursive($audioDir);

			# Tell the monitor.
			$monitor->addDone if $monitor;

			# Add a poller callback timer. We need this to pump events.
			Slim::Utils::Timers::setTimer( undef,
				Time::HiRes::time() + AUTORESCAN_POLL, \&poller );

		} else {
			$log->info(
				"Music folder is not defined - skipping add of change monitor");
		}

	}

}

# Recursively add notifiers for all folders under a given root.
sub addNotifierRecursive($) {
	my $dir = shift;

	if ( -d $dir ) {
		find(
			{
				wanted => sub {
					addNotifier($File::Find::name) if -d $File::Find::name;
				},
				follow   => 1,
				no_chdir => 1
			},
			$dir
		);
	}
}

# Add an monitor for a given directory.
sub addNotifier($) {
	my $dir = shift;

	# We prune the search from directories that start with a '.'
	# (don't you also keep your music files in git-annex..?)
	if (basename($dir) =~ m/^\./) {
		$File::Find::prune = 1;
		$log->debug("Not monitoring hidden directory tree: $dir");
		return;
	}

	# Only add a monitor if we're not already monitoring this directory (and
	# it is indeed a directory).
	if (not exists $monitors{$dir}) {

		# Remember the monitor object created - we do this so we can check if
		# it's already being monitored later on.
		$monitors{$dir} = $monitor->addWatch($dir);
	}
}

# Called periodically so we can detect and dispatch any events.
sub poller() {

	# Pump that poller - let the monitors decide how to do that. We support
	# pumping for each monitored directory, or only once in total, depending
	# on what the monitor type wants to do.
	if ( $monitor && $monitor->{poll_each} ) {

		# Loop through the monitored directories and poll each.
		for my $dir ( keys %monitors ) {
			$monitor->poll( $dir, $monitors{$dir} );
		}
	} else {

		# Pump the poller once.
		$monitor->poll if $monitor;
	}

	# Schedule another poll.
	Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + AUTORESCAN_POLL,
		\&poller );
}

# Note a directory as having been touched - we schedule a callback to see if
# it's convenient to perform a rescan.
sub noteTouch {
	my $dir = shift;

	# Schedule a callback to trigger a rescan in a short time.
	setCallbackTimer();

	# Make sure we are monitoring any new subdirectories under here.
	addNotifierRecursive($dir);
}

# Remove any existing delayed callback timer. This is tolerant if there's
# currently no timer set.
sub killCallbackTimer {
	$log->debug("Cancelling any pending change callback");
	Slim::Utils::Timers::killOneTimer( undef, \&delayedChangeCallback );
}

# Add a new callback timer to call us back in a short while.
sub setCallbackTimer {

	# Remove any existing timer.
	killCallbackTimer();

	# Schedule a callback.
	$log->debug("Scheduling a delayed callback");
	Slim::Utils::Timers::setTimer( undef,
		Time::HiRes::time() + $myPrefs->get('delay'),
		\&delayedChangeCallback );
}

# Called following a short delay following the most recently detected change.
# This is what ultimately triggers the database rescan.
sub delayedChangeCallback {
	$log->debug("Delayed callback invoked");

	# Check if there's a scan currently in progress.
	if ( Slim::Music::Import->stillScanning() ) {

	 # If so then schedule another delayed callback - we'll try again in a short
	 # while.
		$log->debug("Putting off rescan due to current scan being in progress");
		setCallbackTimer();
	} else {

		# If not then we'll trigger the rescan now.
		$log->info("Triggering database rescan following directory changes");
		Slim::Control::Request::executeRequest( undef, ['rescan'] );

		# If the monitor supports a rescan script then call it.
		if ( $monitor->{can_script} ) {
			$monitor->executeScript( $myPrefs->get('script') );
		}
	}
}

1;

__END__

# Local Variables:
# tab-width:4
# indent-tabs-mode:t
# End:
