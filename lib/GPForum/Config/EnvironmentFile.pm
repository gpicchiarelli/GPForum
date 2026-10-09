# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Config::EnvironmentFile;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Config;
use GPForum::Config::Report;

our $VERSION = '0.001';

# The settings page's sections, as an operator reads their names.
const my %SECTION_TITLE => (
    application      => 'Application',
    security         => 'Security',
    database         => 'Database',
    search           => 'Search',
    processes        => 'Processes',
    operating_system => 'Operating system',
    cache            => 'Cache',
    realtime         => 'Live updates',
    jobs             => 'Background jobs',
    mail             => 'Mail',
    antivirus        => 'Antivirus',
);

const my $RULE => q{#} . ( q{ -} x 38 );

const my $HEADER => <<'TEXT';
# GPForum's environment file.
#
# Copy it to /etc/gpforum/gpforum.env (on FreeBSD,
# /usr/local/etc/gpforum/gpforum.env), owned by root with group gpforum and
# mode 0640: it holds secrets. The service reads it when it starts, so restart
# after a change: systemctl restart gpforum gpforum-outbox.
#
# Fill in the first block. Everything under "Advanced" is commented out and
# keeps GPForum's default; uncomment a line only to change it. GPForum names
# every setting it cannot use, with an example, when it starts.
#
# Write a value as it is when it holds only letters, digits and _ . / : @ , +
# % = -. Put any other value -- one with a space, $, a quote, a backslash, #
# or ; in it, as a password may have -- in double quotes, with a backslash
# before each " \ $ and `. systemd, the FreeBSD rc script's shell and gpforum
# then all read the same value:
#   GPFORUM_DATABASE_PASSWORD="my \$ecret \"pass\" word"
# reads my $ecret "pass" word. Left bare, systemd would read the whole line
# and a shell would stop at the first space and expand the $.
#
# This file is generated from the settings table in lib/GPForum/Config.pm,
# and t/463 keeps the two in step. To regenerate it:
#   script/gpforum-carton exec perl -Ilib -MGPForum::Config::EnvironmentFile \
#     -e 'print GPForum::Config::EnvironmentFile->render' \
#     > deploy/gpforum.env.example
TEXT

# The template: the settings every installation decides, uncommented, then
# the rest by section, commented out at their defaults. Retired settings are
# left out.
sub render ( $class, $settings = GPForum::Config->settings ) {
    my @current   = grep { !$_->{retired} } @{$settings};
    my @decisions = grep { $_->{operator} } @current;
    my @advanced  = grep { !$_->{operator} } @current;

    return join "\n", $HEADER,
      _banner('Decide these'),
      ( map { _decision($_) } @decisions ),
      _banner('Advanced: the defaults suit most installations'),
      _sections( \@advanced );
}

sub _banner ($title) {
    return join "\n", $RULE, "# $title", $RULE, q{};
}

# A decision: its summary, how to make it when it is a secret, and the line
# with the example production would use -- empty for a secret.
sub _decision ($setting) {
    my @lines = ("# $setting->{summary}");
    if ( defined $setting->{generate} ) {
        push @lines, "# Generate one with: $setting->{generate}";
    }
    my $value =
        defined $setting->{generate} ? q{}
      : defined $setting->{example}  ? $setting->{example}
      :                                _default($setting);
    push @lines, GPForum::Config::Report->assignment( $setting->{env}, $value ),
      q{};

    return join "\n", @lines;
}

sub _sections ($settings) {
    my ( @order, %in );
    for my $setting ( @{$settings} ) {
        my $section = $setting->{section};
        if ( !$in{$section} ) {
            push @order, $section;
        }
        push @{ $in{$section} }, $setting;
    }

    return map {
        join "\n", "# $SECTION_TITLE{$_}", q{},
          map { _advanced($_) }
          @{ $in{$_} }
    } @order;
}

sub _advanced ($setting) {
    return join "\n", "# $setting->{summary}",
      q{#}
      . GPForum::Config::Report->assignment( $setting->{env},
        _default($setting) ),
      q{};
}

# The default as an environment file writes it: on or off for a boolean,
# nothing for a list.
sub _default ($setting) {
    my $type = $setting->{type};
    return q{} if $type eq 'list' || $type eq 'words';
    return $setting->{default} ? 'on' : 'off' if $type eq 'boolean';

    return $setting->{default} // q{};
}

1;

__END__

=head1 NAME

GPForum::Config::EnvironmentFile - The environment file template, from the
settings table.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    print GPForum::Config::EnvironmentFile->render;

=head1 DESCRIPTION

Renders C<deploy/gpforum.env.example> from L<GPForum::Config>'s settings
table: a header saying where the file goes and who may read it, the
settings every installation decides -- each with its one-line summary and a
production example, a secret with the command that generates it -- and an
"Advanced" block with every other setting, by section, commented out at its
default. Retired settings are left out. C<t/463> holds the shipped file to
what this renders.

=head1 SUBROUTINES/METHODS

=head2 render

Class method. Takes an optional settings table (L<GPForum::Config/settings>
by default) and returns the template's text.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None: it reads the settings table, not the environment.

=head1 DEPENDENCIES

L<Const::Fast>, L<Mojo::Base>, L<GPForum::Config>, and
L<GPForum::Config::Report> for each assignment.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The file is written for systemd's C<EnvironmentFile=> and for a shell that
sources it, as the FreeBSD rc script does; a value with spaces or a C<;> is
double-quoted so both read it whole (L<GPForum::Config::Report/assignment>,
which the report of a wrong setting writes its examples with too).

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
