# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::SendmailFound;

use Mojo::Base 'GPForum::Service::Operations::MailCheck', -signatures;
use v5.40;

our $VERSION = '0.001';

# A mail-check dry run that found a sendmail program, without looking for
# one.
sub run ( $self, $options ) {
    return {
        status => 'pass',
        config =>
          { mail_transport => 'sendmail', mail_from => 'forum@forum.walk.org' },
        probe => {
            status => 'pass',
            action => 'sendmail_path',
            path   => '/usr/sbin/sendmail',
        },
    };
}

1;
