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

# The file gpforum setup writes: what this installation decided, and nothing
# it did not. Every other setting keeps its default, named in the reference.
const my $HEADER => <<'TEXT';
# GPForum's settings: what this installation decided. The service reads this
# file when it starts, and so does gpforum; gpforum doctor checks it. Every
# other setting keeps its default: deploy/gpforum.env.example lists them all.
# Put a value with a space, $, ", \, # or ; in double quotes, with a backslash
# before each " \ $ and `: GPFORUM_DATABASE_PASSWORD="my \$ecret".
TEXT

# deploy/gpforum.env.example: every setting, for the operator who needs one
# more than setup wrote.
const my $REFERENCE_HEADER => <<'TEXT';
# Every setting GPForum reads, for its environment file.
#
# gpforum setup writes /etc/gpforum/gpforum.env (on FreeBSD,
# /usr/local/etc/gpforum/gpforum.env) with the settings under "Decide these",
# owned by root with group gpforum and mode 0640: it holds secrets. Copy a
# line from "Advanced" into it only to change that default, then restart the
# services that read it: systemctl restart gpforum gpforum-outbox. GPForum
# names every setting it cannot use, with an example, when it starts, and
# gpforum doctor checks the file.
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
#     -e 'print GPForum::Config::EnvironmentFile->render_reference' \
#     > deploy/gpforum.env.example
TEXT

# The file setup writes: each decision with its one-line summary, and the
# settings that are decisions only with another's value -- the SMTP server,
# when mail leaves by smtp -- commented out under it. Retired settings are
# left out.
sub render ( $class, $settings = GPForum::Config->settings ) {
    my @lines = ($HEADER);
    my %shown;
    for my $setting ( grep { !$_->{retired} } @{$settings} ) {
        if ( $setting->{operator} ) {
            push @lines, _decision( $setting, generate => 0 );
            next;
        }
        next if !$setting->{operator_when};

        my ( $on, $value ) = @{ $setting->{operator_when} };
        if ( !$shown{"$on=$value"}++ ) {
            my ($other) = grep { $_->{name} eq $on } @{$settings};
            push @lines, "# With $other->{env}=$value:";
        }
        push @lines,
          q{#}
          . GPForum::Config::Report->assignment( $setting->{env},
            $setting->{example} // _default($setting) );
        if ( $setting == _last_with( $settings, $on, $value ) ) {
            push @lines, q{};
        }
    }

    return join "\n", @lines;
}

# The reference, deploy/gpforum.env.example: the settings every installation
# decides, uncommented, then the rest by section, commented out at their
# defaults. Retired settings are left out.
sub render_reference ( $class, $settings = GPForum::Config->settings ) {
    my @current   = grep { !$_->{retired} } @{$settings};
    my @decisions = grep { $_->{operator} } @current;
    my @advanced  = grep { !$_->{operator} } @current;

    return join "\n", $REFERENCE_HEADER,
      _banner('Decide these'),
      ( map { _decision( $_, generate => 1 ) } @decisions ),
      _banner('Advanced: the defaults suit most installations'),
      _sections( \@advanced );
}

sub _last_with ( $settings, $on, $value ) {
    my @with = grep {
             $_->{operator_when}
          && $_->{operator_when}[0] eq $on
          && $_->{operator_when}[1] eq $value
    } @{$settings};

    return $with[-1];
}

sub _banner ($title) {
    return join "\n", $RULE, "# $title", $RULE, q{};
}

# A decision: its summary, in the reference how to make it when it is a
# secret, and the line with the example production would use -- empty for a
# secret, which setup generates.
sub _decision ( $setting, %options ) {
    my @lines = ("# $setting->{summary}");
    if ( $options{generate} && defined $setting->{generate} ) {
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

    print GPForum::Config::EnvironmentFile->render;              # setup's
    print GPForum::Config::EnvironmentFile->render_reference;    # the example

=head1 DESCRIPTION

Renders the environment file from L<GPForum::Config>'s settings table, in two
forms.

L</render> is the file C<gpforum setup> writes: a few lines on what it is and
where the rest are, then each setting an installation decides with its
one-line summary -- the environment, the address, the database, mail, the
antivirus and the two secrets setup generates -- and, commented out under
the mail, the settings that are decisions only when mail leaves by smtp.
Nothing else: every other setting keeps its default.

L</render_reference> is C<deploy/gpforum.env.example>: a header saying where
the file goes and who may read it, the same decisions -- a secret with the
command that generates it -- and an "Advanced" block with every other
setting, by section, commented out at its default. C<t/463> holds the
shipped file to what it renders. Retired settings are in neither.

=head1 SUBROUTINES/METHODS

=head2 render

Class method. Takes an optional settings table (L<GPForum::Config/settings>
by default) and returns the text of the file setup writes.

=head2 render_reference

Class method. Takes the same optional table and returns the text of
C<deploy/gpforum.env.example>.

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
