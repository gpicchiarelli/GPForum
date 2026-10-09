# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::Dependencies;

use Const::Fast;
use English          qw(-no_match_vars);
use List::Util       qw(any);
use Module::Metadata ();
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::File qw(path);

our $VERSION = '0.001';

# The files that list what the forum needs at run time: cpanfile's top level
# and its postgres feature. The test and develop phases are not the forum's.
const my @CPANFILES => qw(cpanfile cpanfile.postgres);

# A requirement as cpanfile writes it: requires 'Name', 'version';
const my $REQUIREMENT =>
  qr/\A \s* requires \s+ '([^']+)' (?: \s* , \s* '([^']*)' )? \s* ;/msx;

# The opening and the end of a phase's block (on test => sub { ... };).
const my $PHASE_OPENS => qr/\A \s* on \s+ \S+ \s* => \s* sub \s* [{]/msx;
const my $BLOCK_ENDS  => qr/\A \s* [}] \s* ; /msx;

# Compiled modules, loaded to prove they were built for this Perl: one built
# for another dies on load with a handshake or API version mismatch. A
# release upgrade of the system Perl (brew upgrade perl, a distribution
# upgrade) leaves local/ with modules of the Perl before.
const my @COMPILED => qw(DBD::Pg Cpanel::JSON::XS Crypt::Argon2
  Email::Address::XS);

# How many modules a sentence names before it says "and N more".
const my $NAMED => 5;

# What a check found wrong, by the list it is in, as gpforum doctor says it.
const my %PROBLEM => (
    missing  => 'doctor.deps_missing',
    outdated => 'doctor.deps_outdated',
    broken   => 'doctor.deps_broken',
);

# A module Perl could not find, as its error names the file: "Can't locate
# Foo/Bar.pm in @INC".
const my $NOT_FOUND =>
  qr{\A Can't [ ] locate [ ] (\S+?) [.]pm [ ] in [ ] \@INC}msx;

# The checkout whose cpanfiles are read; the module's own by default.
has root => sub {
    return path(__FILE__)
      ->realpath->dirname->dirname->dirname->dirname->dirname->to_string;
};

# The directories a module is looked for in; @INC by default.
has inc => sub { return [@INC] };

# Loads a module by name and returns its error, or undef; a test gives its
# own.
has loader => sub {
    return sub ($module) {
        my $file = ( $module =~ s{::}{/}grmsx ) . '.pm';
        try {
            require $file;
        }
        catch ($error) {
            return "$error";
        };
        return undef;
    };
};

# Whether every module the release needs is installed, at the version it
# needs, and the compiled ones were built for this Perl. Returns { status,
# perl, count, missing, outdated, broken }: each list holds { module,
# wanted, found } or { module, error }.
sub check ($self) {
    my ( @missing, @outdated, @broken );
    my $requirements = $self->requirements;
    for my $requirement ( @{$requirements} ) {
        my ( $module, $wanted ) = @{$requirement}{qw(module wanted)};
        next if $module eq 'perl';

        my $found =
          Module::Metadata->new_from_module( $module, inc => $self->inc );
        if ( !$found ) {
            push @missing, { module => $module, wanted => $wanted };
            next;
        }
        if ( _older( $found->version, $wanted ) ) {
            push @outdated,
              {
                module => $module,
                wanted => $wanted,
                found  => _shown( $found->version ),
              };
        }
    }
    my %absent = map { $_->{module} => 1 } @missing;
    for my $module ( grep { !$absent{$_} } @COMPILED ) {
        my $error = $self->loader->($module);
        next if !defined $error;
        push @broken, { module => $module, error => _first_line($error) };
    }

    return {
        status   => ( @missing || @outdated || @broken ) ? 'fail' : 'ok',
        perl     => _perl_version(),
        count    => scalar( grep { $_->{module} ne 'perl' } @{$requirements} ),
        missing  => \@missing,
        outdated => \@outdated,
        broken   => \@broken,
    };
}

# A check's result as an operator reads it, added to a
# GPForum::Service::Operations::Findings: one line when every module is
# there, else one per list with the command that installs them.
sub findings ( $self, $result, $findings, $install ) {
    if ( $result->{status} eq 'ok' ) {
        $findings->add(
            name    => 'dependencies',
            status  => 'ok',
            message => [
                'doctor.deps_ok',
                { count => $result->{count}, version => $result->{perl} }
            ],
        );
        return $findings;
    }

    for my $list ( sort keys %PROBLEM ) {
        my $modules = $result->{$list} // [];
        next if !@{$modules};
        $findings->add(
            name    => 'dependencies',
            status  => 'fail',
            message => [
                $PROBLEM{$list},
                {
                    modules => $self->named($modules),
                    version => $result->{perl},
                }
            ],
            fixes => [$install],
        );
    }

    return $findings;
}

# The command that installs what the release needs: on a server, as root and
# without the maintainer's tools; in a development checkout, with them.
sub install_command ( $self, $deployed ) {
    return 'make install-deps-postgres' if !$deployed;

    return 'sudo make -C ' . $self->root . ' install-deps-production';
}

# The check, with the module an error says Perl could not find among the
# missing ones: a command that could not load reports what it lacked, the
# modules a release needs indirectly included, which no cpanfile names.
sub check_after ( $self, $error ) {
    my $result = $self->check;
    my ($file) = "$error" =~ $NOT_FOUND;
    return $result if !defined $file;

    my $module = $file =~ s{/}{::}grmsx;
    return $result if any { $_->{module} eq $module } @{ $result->{missing} };

    return {
        %{$result},
        status  => 'fail',
        missing => [ @{ $result->{missing} }, { module => $module } ],
    };
}

# What the release needs at run time, in the order the cpanfiles list it:
# { module, wanted }, wanted '0' where no version is named.
sub requirements ($self) {
    my @requirements;
    for my $name (@CPANFILES) {
        my $file = path( $self->root, $name );
        next if !-e $file;

        my $depth = 0;
        for my $line ( split /\n/msx, $file->slurp ) {
            if ( $line =~ $PHASE_OPENS ) {
                $depth++;
                next;
            }
            if ( $depth && $line =~ $BLOCK_ENDS ) {
                $depth--;
                next;
            }
            next if $depth;

            my ( $module, $wanted ) = $line =~ $REQUIREMENT;
            next if !defined $module;
            push @requirements, { module => $module, wanted => $wanted // '0' };
        }
    }

    return \@requirements;
}

# A list of modules as a sentence names them: the first few, then how many
# more.
sub named ( $class, $modules ) {
    my @names = map { $_->{module} } @{$modules};
    return join q{, }, @names if @names <= $NAMED;

    return
      join( q{, }, @names[ 0 .. $NAMED - 1 ] ) . q{, +} . ( @names - $NAMED );
}

sub _older ( $found, $wanted ) {
    return 0 if !defined $wanted || $wanted eq '0';
    return 1 if !defined $found;

    my $older;
    try {
        $older = version->parse("$found") < version->parse($wanted) ? 1 : 0;
    }
    catch ($error) {
        $older = 0;
    };

    return $older;
}

sub _shown ($version) {
    return defined $version ? "$version" : q{?};
}

sub _perl_version {
    return sprintf '%vd', $PERL_VERSION;
}

sub _first_line ($text) {
    my ($line) = split /\n/msx, $text;
    $line //= q{};
    $line =~ s/\s+ at \s+ \S+ \s+ line \s+ \d+ [.]? \z//msx;

    return $line;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::Dependencies - Whether this Perl has every
module the release needs.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $report = GPForum::Service::Operations::Dependencies->new->check;
    # { status => 'fail', perl => '5.44.0', count => 24,
    #   missing => [ { module => 'Crypt::Argon2', wanted => '0.032' } ],
    #   outdated => [], broken => [] }

=head1 DESCRIPTION

Reads what the release needs at run time from F<cpanfile> (its top level,
not the test and develop phases) and F<cpanfile.postgres>, and looks for
each module on C<@INC> -- C<local/> under the front door -- without loading
it, comparing its version with the one asked for. The compiled modules the
forum cannot work without are loaded, so one built for an earlier Perl,
which a system Perl upgrade leaves behind in C<local/>, is found here rather
than at the service's next start. C<gpforum doctor> reports the result.

=head1 SUBROUTINES/METHODS

=head2 root

The checkout whose cpanfiles are read.

=head2 inc

The directories modules are looked for in.

=head2 loader

A code reference that loads a module by name and returns its error or undef.

=head2 check

Returns C<status> (C<ok> or C<fail>), C<perl> (this interpreter's version),
C<count> (the modules required) and the lists C<missing>, C<outdated> and
C<broken>.

=head2 findings

Takes a result of L</check>, a L<GPForum::Service::Operations::Findings> and
the install command, and adds the lines C<gpforum doctor> writes for it.

=head2 install_command

Takes whether the host is a server (staging or production) and returns the
command that installs the release's modules there.

=head2 check_after

Takes the error a command could not load with and returns L</check>, with
the module the error says Perl could not find among the missing ones.

=head2 requirements

The run-time requirements as C<< { module, wanted } >> pairs.

=head2 named

Class method. A list of modules as a sentence names them: at most five, then
how many more.

=head1 DIAGNOSTICS

None: a module that does not load is reported, not raised.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Module::Metadata>, L<Mojo::File>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The cpanfiles are read line by line, as GPForum writes them: one
C<requires> to a line, phases opened with C<on PHASE =E<gt> sub {> and
closed with C<};>. Carton's snapshot is not read, so a module newer than the
one pinned there passes.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
