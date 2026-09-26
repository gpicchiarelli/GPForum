package GPForum::Command::OsPreflight;

use strict;
use warnings;

use Carp    qw(croak);
use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;

use GPForum::Command::Usage;
use GPForum::Config;
use GPForum::OS::Preflight;
use GPForum::Runtime;

our $VERSION = '0.001';

has config  => undef;
has runtime => undef;

# A usage croak becomes the documented usage exit instead of an uncaught
# exception: same text, on stderr, status 2, without croak's " at FILE line N".
# Anything else is rethrown, so a real failure is not relabelled as misuse.
sub run ( $self, @arguments ) {
    my $status = eval { return $self->_run(@arguments); };
    return $status if defined $status;

    my $error = GPForum::Command::Usage->trimmed($EVAL_ERROR);
    if ( !GPForum::Command::Usage->is_usage($error) ) {
        die "$error\n";
    }

    return GPForum::Command::Usage->error( undef, $error );
}

sub _run ( $self, @arguments ) {
    my $options = _options(@arguments);
    if ( $options->{help} ) {
        print _usage() or croak 'failed to write usage';
        return 0;
    }

    my $preflight = $self->_preflight;
    my $report    = $preflight->report;
    my $output =
      $options->{json} ? $preflight->as_json : $preflight->human_text;

    print $output or croak 'failed to write OS preflight report';

    return _exit_status( $report, $options );
}

sub _preflight ($self) {
    my $config  = $self->_config;
    my $runtime = $self->runtime || GPForum::Runtime->from_config($config);

    return GPForum::OS::Preflight->from_runtime(
        $runtime,
        min_recommended_workers   => $config->os_min_recommended_workers,
        max_open_file_descriptors => $config->os_max_open_file_descriptors,
    );
}

sub _config ($self) {
    if ( $self->config ) {
        return $self->config;
    }

    return GPForum::Config->from_environment;
}

sub _options (@arguments) {
    my $options = {
        help   => 0,
        json   => 0,
        strict => 0,
    };

    for my $argument (@arguments) {
        _apply_option( $options, $argument );
    }

    return $options;
}

sub _apply_option ( $options, $argument ) {
    if ( $argument eq '--help' ) {
        $options->{help} = 1;
        return;
    }
    if ( $argument eq '--json' ) {
        $options->{json} = 1;
        return;
    }
    if ( $argument eq '--human' ) {
        $options->{json} = 0;
        return;
    }
    if ( $argument eq '--strict' ) {
        $options->{strict} = 1;
        return;
    }

    croak _usage();
}

sub _exit_status ( $report, $options ) {
    return 1 if $report->{status} eq 'fail';
    return 0 if !$options->{strict};

    return $report->{status} eq 'ok' ? 0 : 1;
}

# Public so the Mojolicious command adapter in GPForum::CLI can show the same
# text `--help` prints, instead of a second copy that drifts.
sub usage_text ($class) {
    return _usage();
}

sub _usage {
    return
        'Usage: '
      . GPForum::Command::Usage->program
      . " [--human|--json] [--strict] [--help]\n";
}

1;
