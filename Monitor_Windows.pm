# Windows directory monitoring for AutoRescan plugin for Squeezebox Server.
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

package Plugins::AutoRescan::Monitor_Windows;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Win32::ChangeNotify;
use Win32::IPC;

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
		poll_each  => 1,
		can_script => 0,
	};
	bless( $self, $class );

	$log->debug("Initialising ChangeNotify directory monitoring");

	return $self;
}

sub delete {
	my $class = shift;

	$log->debug("Shutting down ChangeNotify directory monitoring");
}

# Add a watch for a specified directory.
sub addWatch {
	my $class = shift;
	my $dir   = shift;

	$log->debug("Adding ChangeNotify watch for: $dir");

	return Win32::ChangeNotify->new( $dir, 0,
		FILE_NOTIFY_CHANGE_DIR_NAME | FILE_NOTIFY_CHANGE_FILE_NAME |
		  FILE_NOTIFY_CHANGE_SIZE | FILE_NOTIFY_CHANGE_LAST_WRITE );
}

# Nothing to do in this plugin.
sub addDone {
	my $class = shift;
}

# Pump ChangeNotify events.
sub poll {
	my $class = shift;
	my $dir   = shift;
	my $cn    = shift;

	# See if the monitor IPC object signals a change. We do that in
	# non-blocking mode.
	my $result = $cn->wait(0);
	if ( $result == 1 ) {

		# A change was reported so deal with it and reset the monitor so
		# it will continue to report changes.
		$log->info("Directory detected as modified: $dir");
		$cn->reset;
		Plugins::AutoRescan::Plugin::noteTouch($dir);
	}

}

# Nothing to do for this plugin (scripts not yet supported).
sub executeScript {
	my $class  = shift;
	my $script = shift;
}

1;

__END__
