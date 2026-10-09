# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::Support::EnvironmentFileEdit;

use Carp qw(croak);
use Const::Fast;
use English    qw(-no_match_vars);
use File::Temp ();
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::File qw(path);

use GPForum::Command::Support::ServiceEnvironment;
use GPForum::Config::Report;

our $VERSION = '0.001';

# How the commands that write the environment file -- gpforum secret rotate,
# gpforum setup -- change it: a line at a time, each other line kept as the
# operator left it, and the whole file replaced in one rename, so the service
# never reads half of it.

const my $MODE_BITS => oct '7777';

# Where stat puts the mode, the owner and the group.
const my $STAT_MODE => 2;
const my $STAT_UID  => 4;
const my $STAT_GID  => 5;

# The last assignment of each name, as the service reads the file.
sub values_of ( $class, $lines ) {
    my %found;
    for my $line ( @{$lines} ) {
        my $assignment =
          GPForum::Command::Support::ServiceEnvironment->parse_line($line);
        next if !ref $assignment;
        $found{ $assignment->[0] } = $assignment->[1];
    }

    return \%found;
}

# Sets a name's value where the file assigns it, else on a new line after
# the line that assigns the name given, else after its commented-out line
# in the template, else at the end.
sub assign ( $class, $lines, $name, $value, $after = undef ) {
    my $line = GPForum::Config::Report->assignment( $name, $value ) . "\n";
    my @at   = grep { $class->assigns( $lines->[$_], $name ) } 0 .. $#{$lines};
    if (@at) {
        $lines->[ $at[-1] ] = $line;
        for my $index ( reverse @at[ 0 .. $#at - 1 ] ) {
            splice @{$lines}, $index, 1;
        }
        return;
    }

    my ($anchor) =
      grep {
        defined $after
          ? $class->assigns( $lines->[$_], $after )
          : $lines->[$_] =~ /\A [#] \s* \Q$name\E =/msx
      } 0 .. $#{$lines};
    if ( defined $anchor ) {
        splice @{$lines}, $anchor + 1, 0, $line;
        return;
    }
    if ( @{$lines} && $lines->[-1] !~ /\n\z/msx ) {
        $lines->[-1] .= "\n";
    }
    push @{$lines}, $line;

    return;
}

# Drops every line that assigns a name.
sub remove ( $class, $lines, $name ) {
    @{$lines} = grep { !$class->assigns( $_, $name ) } @{$lines};

    return;
}

sub assigns ( $class, $line, $name ) {
    my $assignment =
      GPForum::Command::Support::ServiceEnvironment->parse_line($line);

    return ref $assignment && $assignment->[0] eq $name ? 1 : 0;
}

# Writes the text beside the file and renames it over it, with the owner,
# group and mode the file had -- it holds secrets, readable by the service's
# group and nobody else -- or, for a file not there yet, the ones given.
# Croaks with the system's reason (Permission denied, say) when it cannot.
sub replace ( $class, $file, $text, %ownership ) {
    my @stat = stat $file;
    my $mode = $ownership{mode} // $stat[$STAT_MODE]
      // croak "replace $file: no mode for a new file";
    my $uid = $ownership{uid} // $stat[$STAT_UID] // $EFFECTIVE_USER_ID;
    my $gid = $ownership{gid} // $stat[$STAT_GID]
      // ( split q{ }, $EFFECTIVE_GROUP_ID )[0];

    my $temporary = _temporary_beside($file);
    print {$temporary} $text or croak "write: $OS_ERROR";
    close $temporary         or croak "close: $OS_ERROR";
    chmod $mode & $MODE_BITS, $temporary->filename
      or croak "chmod: $OS_ERROR";
    if (   $uid != $EFFECTIVE_USER_ID
        || $gid != ( split q{ }, $EFFECTIVE_GROUP_ID )[0] )
    {
        chown $uid, $gid, $temporary->filename
          or croak "chown: $OS_ERROR";
    }
    rename $temporary->filename, $file or croak "rename: $OS_ERROR";
    $temporary->unlink_on_destroy(0);

    return;
}

# A file in the same directory, for the rename. File::Temp's own error
# names the template it tried, XXXXXXXXXX and all; the system's reason --
# Permission denied, in a directory root owns -- is the one an operator reads.
sub _temporary_beside ($file) {
    my $temporary;
    try {
        $temporary = File::Temp->new(
            DIR    => path($file)->dirname->to_string,
            UNLINK => 1,
        );
    }
    catch ($error) {
        croak( $OS_ERROR ? "$OS_ERROR" : $error );
    };

    return $temporary;
}

1;

__END__

=head1 NAME

GPForum::Command::Support::EnvironmentFileEdit - Changes the environment file a
line at a time, and replaces it in one rename.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $edit  = 'GPForum::Command::Support::EnvironmentFileEdit';
    my @lines = split /^/msx, path($file)->slurp;
    $edit->assign( \@lines, GPFORUM_PUBLIC_BASE_URL => 'https://forum.example.org' );
    $edit->replace( $file, join q{}, @lines );

=head1 DESCRIPTION

What C<gpforum secret rotate> and C<gpforum setup> share to change the
environment file the service reads: they read its lines as the service does
(L<GPForum::Command::Support::ServiceEnvironment/parse_line>), set or drop an
assignment and leave every other line -- the operator's comments included --
as it was, then write the file beside itself and rename it over the old one,
keeping its owner, group and mode.

=head1 SUBROUTINES/METHODS

=head2 values_of

Class method. Takes the file's lines and returns a hash reference of each
name's last assignment, as the service reads it.

=head2 assign

Class method. Takes the lines, a name, a value and, optionally, the name
whose line the new one follows. Sets the value where the file assigns the
name (dropping any earlier assignment of it), else after that name's line,
else after the template's commented-out line for it, else at the end.

=head2 remove

Class method. Drops every line of the lines that assigns a name.

=head2 assigns

Class method. Whether a line assigns a name.

=head2 replace

Class method. Takes the file, its new text and, for a file not there yet,
its C<mode>, C<uid> and C<gid>; an existing file keeps its own unless they
are given. Croaks with the system's reason when it cannot write.

=head1 DIAGNOSTICS

C<replace> croaks with what the system said: the directory not writable, the
owner not one this process may give.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<File::Temp>, L<GPForum::Command::Support::ServiceEnvironment>,
L<GPForum::Config::Report> (to write an assignment as the file holds it).

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Changing the owner needs root.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
