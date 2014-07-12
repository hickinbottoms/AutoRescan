# Linux directory monitoring for AutoRescan plugin for Squeezebox Server.
# Copyright © Stuart Hickinbottom 2007-2014

# This file is part of AutoRescan
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

use strict;
use warnings;

package Plugins::AutoRescan::Monitor_Linux;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use File::Basename qw (dirname);
use Linux::Inotify2;

# Our notification object (we actually create it when the plugin is
# initialising).
my $inotify;

# A logger we will use to write plugin-specific messages.
my $log = Slim::Utils::Log->addLogCategory(
	{
		'category'     => 'plugin.autorescan',
		'defaultLevel' => 'INFO',
		'description'  => 'PLUGIN_AUTORESCAN'
	}
);

# Access to preferences for this plugin.
my $myPrefs = preferences('plugin.autorescan');

# Initialise this monitor, as an object.
sub new {
	my $invocant = shift;
	my $class    = ref($invocant) || $invocant;
	my $self     = {
		poll_each  => 0,
		can_script => 1,
	};
	bless( $self, $class );

	$log->debug("Initialising inotify directory monitoring");

	# Create the inotify interface object and start watching.
	$inotify = new Linux::Inotify2;
	if ( !$inotify ) {
		$log->debug(
"Unable to initialise inotify interface - is it compiled into the kernel?"
		);

		return undef;
	}

	# We don't operate in blocking mode - we're going to poll for changes
	# to make sure Squeezebox Server keeps running.
	$inotify->blocking(0);

	return $self;
}

sub delete {
	my $class = shift;

	$log->debug("Shutting down inotify directory monitoring");

	# Discard our inotify interface.
	my $inotify = undef;
}

# Add a watch for a specified directory.
sub addWatch {
	my $class = shift;
	my $dir   = shift;

	return if !$inotify;

	$log->debug("Adding inotify watch for: $dir");

	return $inotify->watch(
		$dir,
		IN_MODIFY | IN_ATTRIB | IN_MOVE | IN_CREATE | IN_DELETE |
		  IN_DELETE_SELF,
		\&watchCallback
	);
}

# Nothing to do in this plugin.
sub addDone {
	my $class = shift;
}

# Pump inotify events since we're running in non-blocking mode.
sub poll {
	my $class = shift;

	$inotify->poll;
}

# Called when any modification event is detected by inotify.
sub watchCallback() {
	my $e = shift;

	my $filename       = $e->fullname;
	my $is_directory   = $e->IN_ISDIR;
	my $was_created    = $e->IN_CREATE;
	my $was_modified   = $e->IN_MODIFY;
	my $was_deleted    = $e->IN_DELETE;
	my $was_moved_to   = $e->IN_MOVED_TO;
	my $was_moved_from = $e->IN_MOVED_FROM;
	my $was_attred     = $e->IN_ATTRIB;
	my $dir_name       = dirname($filename);
	$log->debug(
"Received inotify event for: $filename (is_directory=$is_directory, was_created=$was_created, was_modified=$was_modified, was_deleted=$was_deleted, was_moved_from=$was_moved_from, was_moved_to=$was_moved_to, was_attred=$was_attred"
	);

	if ( $was_created && $is_directory ) {
		$log->info("New directory created: $filename");

		Plugins::AutoRescan::Plugin::noteTouch($filename);

	} elsif ( $was_created && not $is_directory ) {
		$log->info(
			"Directory detected as modified by file creation: $dir_name");

		Plugins::AutoRescan::Plugin::noteTouch($dir_name);

	} elsif ( $was_modified && not $is_directory ) {
		$log->info(
			"Directory detected as modified by file modification: $dir_name");

		Plugins::AutoRescan::Plugin::noteTouch($dir_name);
	} elsif ( $was_deleted && not $is_directory ) {
		$log->info(
			"Directory detected as modified by file deletion: $dir_name");

		Plugins::AutoRescan::Plugin::noteTouch($dir_name);
	} elsif ( $was_moved_to && $is_directory ) {
		$log->info("Directory detected as moved in: $filename");

		Plugins::AutoRescan::Plugin::noteTouch($filename);
	} elsif ( $was_moved_to && not $is_directory ) {
		$log->info("Directory detected as modified by move in: $dir_name");

		Plugins::AutoRescan::Plugin::noteTouch($dir_name);
	} elsif ( $was_moved_from && $is_directory && -d $filename ) {
		$log->info("Directory detected as modified out: $filename");

		Plugins::AutoRescan::Plugin::noteTouch($filename);
	} elsif ( $was_moved_from && not $is_directory ) {
		$log->info("Directory detected as modified by move out: $dir_name");

		Plugins::AutoRescan::Plugin::noteTouch($dir_name);
	} elsif ( $was_attred && $is_directory ) {
		$log->info("Directory detected as modified by attribute change: $filename");

		Plugins::AutoRescan::Plugin::noteTouch($filename);
	} elsif ( $was_attred && not $is_directory ) {
		$log->info("Directory detected as modified by file attribute change: $dir_name");

		Plugins::AutoRescan::Plugin::noteTouch($dir_name);
	}
}

# Execute the named script (if it exists).
sub executeScript {
	my $class  = shift;
	my $script = shift;

	if ($script) {
		$log->info("Executing rescan script: $script");

		system $script;
	}
}

1;

__END__
