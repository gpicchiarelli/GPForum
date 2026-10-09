# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Bootstrap::Config;

use Const::Fast;
use English    qw(-no_match_vars);
use Mojo::Util qw(encode);
use v5.40;

use GPForum::Config;
use GPForum::Config::Report;
use GPForum::Service::I18N::CliCatalog;
use GPForum::X::Config;

our $VERSION = '0.001';

# sysexits.h's EX_CONFIG, "configuration error": what a supervisor or a
# script can tell apart from a crash (255, which Perl gives any uncaught
# exception) and from a failed run (1).
const my $EX_CONFIG => 78;

# The configuration the application starts with. When it is wrong, every
# problem is reported at once, in the operator's language, and the start
# ends with EX_CONFIG: an exception nothing catches makes Perl exit with $!,
# so it is set just before the throw. A test or a caller that catches it gets
# the X::Config as before.
sub load ( $class, $environment = undef, %options ) {
    my $config;
    try {
        $config = GPForum::Config->from_environment($environment);
    }
    catch ($error) {
        _stop($error);
    };

    my $tls = $class->tls_problem( $config, $options{can_tls} );
    if ($tls) {
        _refuse( [$tls] );
    }

    return $config;
}

# A service that sends by smtp with TLS on, on a Perl that cannot load the
# TLS module, would start and then fail every message, sign-up confirmations
# and password resets included: it is stopped at the start instead, with the
# fix. The configuration says when (GPForum::Config::smtp_tls_problem), so
# doctor, mail-check and the front door say it as this start-up does.
sub tls_problem ( $class, $config, $can_tls = undef ) {
    return $config->smtp_tls_problem($can_tls);
}

sub _stop ($error) {
    my $invalid = GPForum::X::Config->caught($error);
    if ( !$invalid || !@{ $invalid->problems } ) {
        die $error;    ## no critic (ErrorHandling::RequireCarping) -- rethrows the caught error as it was raised
    }

    _refuse( $invalid->problems );

    return;
}

sub _refuse ($problems) {

    # Perl writes an uncaught exception's message to STDERR as it is,
    # with no encoding layer: the report is encoded here, at the edge it
    # is meant for, or an Italian "è" reaches the terminal as one stray
    # byte.
    my $catalog = GPForum::Service::I18N::CliCatalog->new;
    my $report  = encode( 'UTF-8', $catalog->config_report($problems) );
    local $OS_ERROR = $EX_CONFIG;
    GPForum::X::Config->throw(
        message  => $report,
        problems => $problems,
    );
}

# Once the log is set up: one warning for each retired setting the
# environment still sets, so an old environment file starts and says what to
# remove, and one for each old name, with the line that replaces it.
sub register ( $class, %input ) {
    my $catalog = GPForum::Service::I18N::CliCatalog->new;
    my $log     = $input{application}->log;
    for my $variable ( @{ $input{config}->retired_settings } ) {
        $log->warn(
            $catalog->text( 'config.retired', { variable => $variable } ) );
    }
    for my $renamed ( @{ $input{config}->renamed_settings } ) {
        $log->warn( $class->renamed_warning( $renamed, $catalog ) );
    }

    return;
}

# The sentence for one old name or old value: the variable, what it is now
# called and the line to write instead, such as GPFORUM_SMTP_TLS=starttls or
# GPFORUM_ENV=production.
sub renamed_warning ( $class, $renamed, $catalog = undef ) {
    $catalog //= GPForum::Service::I18N::CliCatalog->new;

    return $catalog->text( @{ GPForum::Config::Report->renamed($renamed) } );
}

1;

__END__

=head1 NAME

GPForum::Bootstrap::Config - The configuration the application starts with.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $config = GPForum::Bootstrap::Config->load;
    ...
    GPForum::Bootstrap::Config->register(
        application => $app,
        config      => $config,
    );

=head1 DESCRIPTION

Reads L<GPForum::Config> from the environment for the application's start.
A configuration with problems stops the start with every problem listed in
the operator's language (L<GPForum::Service::I18N::CliCatalog>) and exit
status 78, EX_CONFIG. Once the log is configured, L</register> warns of each
retired setting the environment still sets, and of each setting it still
names by an old name.

=head1 SUBROUTINES/METHODS

=head2 load

Class method. Takes an optional environment hash reference (C<%ENV> by
default) and, after it, C<can_tls> to say whether this Perl can speak TLS
(by default it is asked, as L</tls_problem> says), and returns the
configuration. Throws L<GPForum::X::Config> whose
message is the report in the operator's language, encoded as UTF-8 for the
terminal, with C<$!> set to 78 so an uncaught throw exits with that status:
for every problem L<GPForum::Config> finds, and, once it finds none, for the
one L</tls_problem> finds on this host. Any other error is rethrown as it
is.

=head2 tls_problem

Class method. Takes a configuration and, optionally, whether TLS can be
used (by default: whether L<Net::SMTP> can, which it can only with
IO::Socket::SSL), and
returns the problem L</load> stops the start with when mail leaves by
C<smtp> with C<GPFORUM_SMTP_TLS> on and the module does not load, or undef:
L<GPForum::Config/smtp_tls_problem>'s answer, which doctor, mail-check and
the front door ask too.

=head2 register

Class method. Takes C<application> and C<config> and logs one warning for
each variable in the configuration's C<retired_settings>, and one, from
L</renamed_warning>, for each of its C<renamed_settings>.

=head2 renamed_warning

Class method. Takes one of the configuration's C<renamed_settings> (a hash
reference with C<variable>, C<replacement> and C<value>, and C<old> for an
old value) and an optional catalog, and returns the sentence that names the
old variable or value, what it is now called and the line to write in its
place, in the operator's language (L<GPForum::Config::Report/renamed>).

=head1 DIAGNOSTICS

The report L<GPForum::Config::Report> renders, in English or Italian.

=head1 CONFIGURATION AND ENVIRONMENT

Reads the C<GPFORUM_*> variables through L<GPForum::Config>, and C<LC_ALL>,
C<LC_MESSAGES> and C<LANG> for the language.

=head1 DEPENDENCIES

L<Const::Fast>, L<Mojo::Util>, L<GPForum::Config>, L<GPForum::Config::Report>,
L<GPForum::Service::I18N::CliCatalog>, L<GPForum::X::Config>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The commands that read the configuration themselves (C<bin/gpforum-*>) print
the same report in the operator's language through
L<GPForum::Command::Usage/failure>, and exit 1 as any failed command does;
C<bin/gpforum> and its subcommands go through here and exit 78. Under
Hypnotoad, Mojolicious prefixes the report with C<Can't load application>
and exits 255.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
