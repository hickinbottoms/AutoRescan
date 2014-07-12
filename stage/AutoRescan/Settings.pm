# Web settings page handler for AutoRescan plugin for Squeezebox Server.
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

package Plugins::AutoRescan::Settings;

use base qw(Slim::Web::Settings);
use Slim::Utils::Log;
use Slim::Utils::Prefs;

# A logger we will use to write plugin-specific messages.
my $log = Slim::Utils::Log->addLogCategory(
	{
		'category'     => 'plugin.autorescan',
		'defaultLevel' => 'INFO',
		'description'  => 'PLUGIN_AUTORESCAN'
	}
);

my $can_script = 0;

# Access to preferences for this plugin.
my $myPrefs = preferences('plugin.autorescan');

sub new {
	my $class = shift;
	shift;
	$can_script = shift;

	$log->debug("Initialising settings (can_script=$can_script)");

	$class->SUPER::new;
}

sub name {
	return 'PLUGIN_AUTORESCAN';
}

sub page {
	return 'plugins/AutoRescan/settings/basic.html';
}

# Set up validation rules.
$myPrefs->setValidate( { 'validator' => 'intlimit', 'low' => 1, 'high' => 30 },
	'delay' );

sub handler {
	my ( $class, $client, $params ) = @_;

	# A list of all our plugin preferences (with the common prefix removed).
	my @prefs = qw(
	  delay
	  script
	);

	if ( $params->{'saveSettings'} ) {
		$log->debug('Saving plugin preferences');

		# Now change the preferences from the ones posted through our
		# settings page.
		for my $pref (@prefs) {
			$myPrefs->set( $pref, $params->{$pref} );
		}
	}

	for my $pref (@prefs) {
		$params->{'prefs'}->{$pref} = $myPrefs->get($pref);
	}

	# Pass in whether scripting is allowed.
	$params->{'prefs'}->{can_script} = $can_script;

	return $class->SUPER::handler( $client, $params );
}

1;

__END__
