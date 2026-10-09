# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Config::Report;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

# What an operator reads when the settings are wrong, in English, keyed as
# the command-line catalogs (locale/cli/*.po) key them. The English is here,
# beside the code that raises it, as gettext keeps a msgid in the source:
# GPForum::Config sits below the service layer that reads the catalogs, so it
# cannot ask them, and t/462 holds locale/cli/en.po to these words. Whoever
# can read the catalogs -- the start-up in Bootstrap::Config -- hands render a
# translator, and the operator reads the same report in their own language.
const my %ENGLISH => (
    'config.header' => q{GPForum's settings need attention:},
    'config.footer' => q{Set these in the service's environment file}
      . q{ (deploy/gpforum.env.example describes every setting),}
      . q{ then try again.},
    'config.example'      => 'Example: {assignment}',
    'config.generate'     => 'Generate one with: {command}',
    'config.did_you_mean' => 'Did you mean {suggestion}?',
    'config.required'     => '{variable} is required.',
    'config.required_in'  => '{variable} is required in {environment}.',
    'config.not_integer'  =>
      q{{variable} must be a whole number, not '{value}'.},
    'config.not_integer_or_auto' =>
      q{{variable} must be a whole number or auto, not '{value}'.},
    'config.not_boolean' => q{{variable} must be on or off, not '{value}'.},
    'config.at_least'  => '{variable} must be at least {minimum}, not {value}.',
    'config.at_most'   => '{variable} must be at most {maximum}, not {value}.',
    'config.not_above' =>
      '{variable} must not exceed {limit_variable} ({limit}), not {value}.',
    'config.one_of'   => q{{variable} must be one of {choices}, not '{value}'.},
    'config.timezone' =>
q{{variable} must be an IANA time zone such as Europe/Rome, not '{value}'.},
    'config.trusted_proxies' => '{variable} must name at least one address'
      . ' while {proxy_variable} is on.',
    'config.minion_url' => '{variable} is required while {minion_variable}'
      . ' is on.',
    'config.glifistore_url' => '{variable} must be tcp://host:port,'
      . q{ unix://path or host:port, not '{value}'.},
    'config.antivirus_command' => '{variable} is required when'
      . ' {antivirus_variable} is command.',
    'config.url' => '{variable} must be a full address, with http:// or'
      . q{ https:// and a host, not '{value}'.},
    'config.https' =>
      q{{variable} must use https:// in {environment}, not '{value}'.},
    'config.mail_from_local' => q{{variable} is '{value}': mail servers}
      . ' refuse a sender at localhost, so {environment} needs an address'
      . q{ at the forum's own domain.},
    'config.log_transport' => '{variable}=log only writes mail to the log;'
      . ' {environment} must deliver it, with sendmail or smtp.',
    'config.test_transport' => '{variable}=test keeps mail in memory and'
      . ' sends none; {environment} must deliver it, with sendmail or smtp.',
    'config.placeholder_url' => q{{variable} is '{value}', an example}
      . ' address that leads nowhere; {environment} needs the one members'
      . ' reach this forum at.',
    'config.placeholder_mail_from' => q{{variable} is '{value}', an example}
      . ' address mail servers will not deliver from; {environment} needs'
      . q{ one at the forum's own domain.},
    'config.smtp_host' => '{variable} is required when {transport_variable}'
      . ' is smtp.',
    'config.smtp_tls_module' => '{variable}={value} encrypts mail through the'
      . ' Perl module {module}, which this Perl cannot load: install it, or'
      . ' set {variable}=off for a relay that takes mail in the clear.',
    'config.listen' => '{variable} must list addresses such as'
      . q{ http://127.0.0.1:8080, not '{value}'.},
    'config.short_secret' => '{variable} is {length} characters long;'
      . ' {environment} needs at least {minimum}.',
    'config.development_secret' =>
      '{variable} must not include the development default.',
    'config.retired' => '{variable} no longer has any effect;'
      . ' remove it from the environment file.',
    'config.renamed' => '{variable} is now called {replacement};'
      . ' write {assignment} in the environment file in its place.',
);

# A problem's own lines are indented under the header, and what helps fix it
# -- an example, a suggestion, how to make a secret -- under the problem.
const my $PROBLEM_INDENT => q{ } x 2;
const my $HINT_INDENT    => q{ } x 4;

# A setting that is not a secret can still carry one: a DSN's password= (or
# libpq's sslpassword=), or the user:password@ of a URL such as
# GPFORUM_MINION_PG_URL. libpq lets a DSN quote a value that holds spaces or
# semicolons, so a quoted one is replaced whole, not up to its first space,
# and one left unterminated up to the end. A password with an @ that was
# never percent-encoded runs to the last @ before the host, not the first.
const my $REDACTED     => '[redacted]';
const my $QUOTED_VALUE => qr/'(?:[^'\\]|\\.)*(?:'|\z)/msx;
const my $INLINE_PASSWORD => qr{\b(\w*(?:password|passwd|pwd) \s* = \s*)
  (?:$QUOTED_VALUE|[^;&\s]+)}msxi;
const my $URL_PASSWORD => qr{(:// [^/:@\s]* :)[^/\s]+ (@)}msx;

sub english ($class) {
    return {%ENGLISH};
}

# The whole report: a header, each problem with what helps fix it, and the
# footer, one line each and the last one ending in a newline, so the shell's
# prompt starts on a line of its own.
sub render ( $class, $problems, $translate = undef ) {
    my @blocks = map { $class->_block( $_, $translate ) } @{$problems};

    return join "\n\n",
      $class->text( 'config.header', {}, $translate ),
      @blocks,
      $class->text( 'config.footer', {}, $translate ) . "\n";
}

# One problem in a sentence, such as "GPFORUM_ENV must be one of ...".
sub sentence ( $class, $problem, $translate = undef ) {
    return $class->text( $problem->{key}, _parameters($problem), $translate );
}

sub text ( $class, $key, $parameters, $translate = undef ) {

    # The table is read-only, and reading it with a key it does not hold
    # dies: a key nobody knows is asked about first.
    my $template = $translate ? $translate->($key) : undef;
    $template //= exists $ENGLISH{$key} ? $ENGLISH{$key} : $key;
    $template =~ s{ [{] (\w+) [}] }
                  { exists $parameters->{$1} ? $parameters->{$1} : "{$1}" }gemsx;

    return $template;
}

# A variable's assignment as an environment file holds it, read whole both by
# systemd's EnvironmentFile= and by a shell that sources the file (the
# FreeBSD rc script, `set -a; . file`), where a bare ; or space would end it:
# a plain word stays bare, anything else is double-quoted, which both strip.
sub assignment ( $class, $variable, $value ) {
    return "$variable=$value"
      if $value =~ m{\A [[:alnum:]_./:@,+%=-]* \z}msx;

    ( my $escaped = $value ) =~ s/(["\\\$`])/\\$1/gmsx;
    return qq{$variable="$escaped"};
}

sub _block ( $class, $problem, $translate ) {
    my @lines = ( $PROBLEM_INDENT . $class->sentence( $problem, $translate ) );
    if ( defined $problem->{suggestion} ) {
        push @lines,
          $HINT_INDENT
          . $class->text( 'config.did_you_mean',
            { suggestion => $problem->{suggestion} }, $translate );
    }
    if ( defined $problem->{generate} ) {
        push @lines,
          $HINT_INDENT
          . $class->text( 'config.generate',
            { command => $problem->{generate} }, $translate );
    }
    elsif ( defined $problem->{example} && length $problem->{example} ) {
        push @lines,
          $HINT_INDENT
          . $class->text(
            'config.example',
            {
                assignment => $class->assignment(
                    $problem->{variable}, $problem->{example}
                )
            },
            $translate
          );
    }

    return join "\n", @lines;
}

# Text with each password a value carries in it replaced by [redacted].
sub without_passwords ( $class, $text ) {
    return $text if !defined $text;

    $text =~ s/$INLINE_PASSWORD/$1$REDACTED/gmsx;
    $text =~ s/$URL_PASSWORD/$1$REDACTED$2/gmsx;

    return $text;
}

# The value a sentence quotes, without a password in it: a refused
# GPFORUM_MINION_PG_URL of postgresql://gpforum:PASSWORD@db/minion was
# quoted whole by every gpforum verb, and by the service's start in its log.
sub _parameters ($problem) {
    return {
        %{ $problem->{parameters} // {} },
        variable => $problem->{variable},
        value    => __PACKAGE__->without_passwords( $problem->{value} // q{} ),
    };
}

1;

__END__

=head1 NAME

GPForum::Config::Report - What an operator reads when the settings are wrong.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $text = GPForum::Config::Report->render( $error->problems );

    # In the operator's language, from the command-line catalogs:
    my $catalog = GPForum::Service::I18N::CliCatalog->new;
    print GPForum::Config::Report->render( $error->problems,
        $catalog->translator );

=head1 DESCRIPTION

Turns the problems L<GPForum::Config> finds into the report an operator
reads: a header, every problem in a sentence that names its variable, under
each one an example, a suggestion or how to generate a secret, and a footer
that says where to set them. The English words live here, keyed as the
command-line catalogs in C<locale/cli/> key them; a translator turns a key
into the operator's language.

=head1 SUBROUTINES/METHODS

=head2 english

Class method. The English text of every key, as a new hash reference.

=head2 render

Class method. Takes an array reference of problems and an optional
translator, and returns the whole report, ending in a newline. A problem is
a hash reference with C<key>, C<variable>, C<value>, optional C<parameters>
(a hash reference for the sentence's other placeholders) and optional
C<suggestion>, C<generate> or C<example>.

=head2 sentence

Class method. One problem's sentence, without its hints.

=head2 assignment

Class method. Takes a variable and a value and returns C<VARIABLE=value> as
an environment file holds it: the value bare when it is a plain word,
double-quoted otherwise (a space, a C<;>), so systemd's C<EnvironmentFile=>
and a shell sourcing the file both read it whole.

=head2 without_passwords

Class method. Takes a text and returns it with each password a setting's
value can carry -- a DSN's C<password=> (quoted or not, C<sslpassword=>
too) and a URL's C<user:password@> -- replaced by C<[redacted]>. Every
sentence quotes a value through it, and
L<GPForum::Service::Admin::Settings/redact> redacts with it.

=head2 text

Class method. Takes a key, a hash reference of placeholder values and an
optional translator, and returns the text with each C<{name}> filled in. A
key the translator does not know is read in English; a key nobody knows is
returned as it is.

=head1 DIAGNOSTICS

None: a placeholder without a value is left in the text as C<{name}>.

=head1 CONFIGURATION AND ENVIRONMENT

None. A translator is a code reference that takes a key and returns its
template, or undef.

=head1 DEPENDENCIES

L<Const::Fast>, L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
