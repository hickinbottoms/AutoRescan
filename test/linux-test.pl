#!/usr/bin/perl
#
use strict;
use warnings;

use File::Basename qw (dirname);
use Linux::Inotify2;

print "initialising\n";
my $in = new Linux::Inotify2 || die "couldn't create Linux::Inotify2 object";
$in->blocking(0);

print "adding watch\n";
$in->watch(
	"/tmp",
	IN_MODIFY | IN_ATTRIB | IN_MOVE | IN_CREATE | IN_DELETE |
		IN_DELETE_SELF,
	\&watchCallback) || die "can't add watch";

print "polling\n";
while(1) {
	$in->poll;
	sleep 1;
}


sub watchCallback() {
	my $e = shift;

	my $filename       = $e->fullname;
	my $is_directory   = $e->IN_ISDIR;
	my $was_created    = $e->IN_CREATE;
	my $was_modified   = $e->IN_MODIFY;
	my $was_deleted    = $e->IN_DELETE;
	my $was_moved_to   = $e->IN_MOVED_TO;
	my $was_moved_from = $e->IN_MOVED_FROM;
	my $dir_name       = dirname($filename);

	print "Received inotify event for: $filename (is_directory=$is_directory, was_created=$was_created, was_modified=$was_modified, was_deleted=$was_deleted, was_moved_from=$was_moved_from, was_moved_to=$was_moved_to)\n";
}
