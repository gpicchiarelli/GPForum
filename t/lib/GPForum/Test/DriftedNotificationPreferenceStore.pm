# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::DriftedNotificationPreferenceStore;

use strict;
use warnings;

use Mojo::Base 'GPForum::Service::Notification::PreferenceStore';

our $VERSION = '0.001';

# The real preference store, whose channel list the settings form reads,
# with one misspelt channel added: a form and a store that drifted apart.
# The form then posts a channel the store does not know.
sub channel_names {
    my ($self) = @_;

    return [ @{ $self->SUPER::channel_names }, 'emial' ];
}

1;
