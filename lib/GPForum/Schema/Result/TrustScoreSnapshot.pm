# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Schema::Result::TrustScoreSnapshot;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Core', -signatures;

our $VERSION = '0.001';

__PACKAGE__->table('trust_score_snapshots');

__PACKAGE__->add_columns(
    user_id => { data_type => 'uuid',    is_nullable => 0 },
    score   => { data_type => 'integer', is_nullable => 0, default_value => 0 },
    trust_level =>
      { data_type => 'integer', is_nullable => 0, default_value => 0 },
    calculated_at =>
      { data_type => 'timestamp with time zone', is_nullable => 0 },
    version => { data_type => 'bigint', is_nullable => 0, default_value => 1 },
);

__PACKAGE__->set_primary_key('user_id');
__PACKAGE__->belongs_to( user => 'GPForum::Schema::Result::User', 'user_id' );

1;
