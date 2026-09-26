# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::AttachmentFilesystemDrill;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Digest::SHA qw(sha256_hex);
use English     qw(-no_match_vars);
use File::Copy  qw(copy);
use File::Find  qw(find);
use File::Path  qw(make_path remove_tree);
use File::Spec;
use File::Temp    qw(tempdir);
use JSON::MaybeXS qw(encode_json);
use Mojo::Base -base, -signatures;
use Mojo::File qw(path);

use GPForum::Service::Attachment::FilesystemStorage;
use GPForum::Service::Operations::EvidenceMeta qw(evidence_finalize);

our $VERSION = '0.001';

const my $EXIT_FAILURE   => 1;
const my $DEFAULT_ROOT   => 'var/attachments';
const my $SAMPLE_KEY_A   => 'drill/aa/bb/sample-one.bin';
const my $SAMPLE_KEY_B   => 'drill/cc/nested/sample-two.txt';
const my $SAMPLE_BYTES_A => "\x00\x01GPForum-attachment-drill-a\xff";
const my $SAMPLE_BYTES_B => "attachment drill sample b\nline2\n";
const my $RESIDUAL_BETA  => 'This drill does not claim private-beta readiness.';
const my $RESIDUAL_LIVE =>
'Live production attachment trees and object-storage backends remain outside this rehearsal; the drill populates a throwaway var/attachments layout only.';

has root_name => $DEFAULT_ROOT;

sub run ( $self, $options ) {
    my $evidence = _base_evidence($options);
    my $ok       = eval {
        $self->_execute( $evidence, $options );
        return 1;
    };
    if ( !$ok ) {
        $evidence->{status} = 'fail';
        $evidence->{error}  = _trim_error($EVAL_ERROR);
    }
    $evidence->{status} ||= 'pass';
    $self->_cleanup($evidence);

    return evidence_finalize($evidence);
}

sub format_evidence ( $self, $evidence, $format ) {
    return encode_json($evidence) . "\n" if $format eq 'json';

    return _human_evidence($evidence);
}

sub exit_status ( $self, $evidence ) {
    return 0 if ( $evidence->{status} // q{} ) eq 'pass';

    return $EXIT_FAILURE;
}

sub _execute ( $self, $evidence, $options ) {
    my $workspace = tempdir( 'gpforum-attach-drill-XXXXXX', TMPDIR => 1 );
    $evidence->{_workspace}      = $workspace;
    $evidence->{_keep_workspace} = $options->{keep_workspace} ? 1 : 0;

    my $source_root = path( $workspace, $DEFAULT_ROOT )->to_string;
    my $backup_root = path( $workspace, 'backup', $DEFAULT_ROOT )->to_string;
    make_path($source_root);

    my $storage =
      GPForum::Service::Attachment::FilesystemStorage->new(
        root => $source_root );
    $storage->write_object( $SAMPLE_KEY_A, $SAMPLE_BYTES_A );
    $storage->write_object( $SAMPLE_KEY_B, $SAMPLE_BYTES_B );

    my $before = _inventory($source_root);
    _assert_inventory_size( $before, 2 );
    _copy_tree( $source_root, $backup_root );
    my $backup = _inventory($backup_root);
    _assert_inventories_match( $before, $backup, 'backup' );

    remove_tree( $source_root, { keep_root => 1 } );
    _assert_empty($source_root);

    _copy_tree( $backup_root, $source_root );
    my $after = _inventory($source_root);
    _assert_inventories_match( $before, $after, 'restore' );

    my $restored =
      GPForum::Service::Attachment::FilesystemStorage->new(
        root => $source_root );
    croak 'restored object A content mismatch'
      if $restored->read_object($SAMPLE_KEY_A) ne $SAMPLE_BYTES_A;
    croak 'restored object B content mismatch'
      if $restored->read_object($SAMPLE_KEY_B) ne $SAMPLE_BYTES_B;

    $evidence->{attachments} = {
        covered              => \1,
        mode                 => 'populated_var_attachments',
        storage_backend      => 'filesystem',
        storage_root         => $DEFAULT_ROOT,
        workspace_layout     => $DEFAULT_ROOT,
        files                => scalar keys %{$after},
        sha256_match         => \1,
        sample_object_keys   => [ $SAMPLE_KEY_A, $SAMPLE_KEY_B ],
        backup_path          => $backup_root,
        restore_path         => $source_root,
        wiped_before_restore => \1,
    };

    return;
}

sub _cleanup ( $self, $evidence ) {
    my $workspace = delete $evidence->{_workspace};
    my $keep      = delete $evidence->{_keep_workspace};
    return if !_has_text($workspace);
    return if $keep;
    remove_tree($workspace);

    return;
}

sub _inventory ($root) {
    my %files;
    find(
        {
            wanted => sub {
                return if !-f $File::Find::name;
                my $relative = File::Spec->abs2rel( $File::Find::name, $root );
                $relative =~ s{\\}{/}gmsx;
                open my $handle, '<:raw', $File::Find::name
                  or croak "failed to read $File::Find::name: $ERRNO";
                local $INPUT_RECORD_SEPARATOR = undef;
                my $content = <$handle>;
                close $handle
                  or croak "failed to close $File::Find::name: $ERRNO";
                $files{$relative} = sha256_hex($content);
            },
            no_chdir => 1,
        },
        $root
    );

    return \%files;
}

sub _copy_tree ( $from, $to ) {
    make_path($to);
    find(
        {
            wanted => sub {
                my $src = $File::Find::name;
                my $rel = File::Spec->abs2rel( $src, $from );
                return if $rel eq q{.};
                my $dest = path( $to, $rel )->to_string;
                if ( -d $src ) {
                    make_path($dest);
                    return;
                }
                return if !-f $src;
                make_path( path($dest)->dirname->to_string );
                copy( $src, $dest )
                  or croak "failed to copy $src to $dest: $ERRNO";
            },
            no_chdir => 1,
        },
        $from
    );

    return;
}

sub _assert_inventory_size ( $inventory, $expected ) {
    my $count = scalar keys %{$inventory};
    croak "expected $expected attachment files, found $count"
      if $count != $expected;

    return;
}

sub _assert_inventories_match ( $left, $right, $label ) {
    my @left_keys  = sort keys %{$left};
    my @right_keys = sort keys %{$right};
    croak "$label file list mismatch"
      if join( "\n", @left_keys ) ne join( "\n", @right_keys );
    for my $key (@left_keys) {
        croak "$label digest mismatch for $key"
          if $left->{$key} ne $right->{$key};
    }

    return;
}

sub _assert_empty ($root) {
    my $inventory = _inventory($root);
    croak 'source tree was not emptied before restore'
      if keys %{$inventory};

    return;
}

sub _base_evidence ($options) {
    return {
        check          => 'attachment_filesystem',
        status         => undef,
        drill          => 'attachment_filesystem',
        residual_gaps  => [ $RESIDUAL_LIVE, $RESIDUAL_BETA ],
        keep_workspace => $options->{keep_workspace} ? \1 : \0,
    };
}

sub _human_evidence ($evidence) {
    my $attachments = $evidence->{attachments} // {};
    my @lines       = ( 'staging-drill-attachments status='
          . ( $evidence->{status} // 'fail' ) );
    push @lines,
        'attachments covered='
      . ( $attachments->{covered} ? 'true' : 'false' )
      . ' files='
      . ( $attachments->{files} // 0 )
      . ' layout='
      . ( $attachments->{workspace_layout} // $DEFAULT_ROOT );
    if ( _has_text( $evidence->{error} ) ) {
        push @lines, 'error=' . $evidence->{error};
    }

    return join( "\n", @lines ) . "\n";
}

sub _trim_error ($error) {
    $error = "$error";
    $error =~ s/\s+\z//msx;

    return $error;
}

sub _has_text ($value) {
    return defined $value && length $value;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::AttachmentFilesystemDrill - Populated var/attachments backup/restore.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $evidence =
      GPForum::Service::Operations::AttachmentFilesystemDrill->new->run({});

=head1 DESCRIPTION

Creates a throwaway workspace with a populated C<var/attachments> tree via
L<GPForum::Service::Attachment::FilesystemStorage>, copies it to a backup
tree, wipes the source, restores into the same C<var/attachments> path, and
verifies SHA-256 digests and object bytes. Does not mutate a live operator
attachment root and does not claim private-beta readiness.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
