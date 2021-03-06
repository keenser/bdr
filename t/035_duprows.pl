#!/usr/bin/env perl
#
# This test was written to exercise a duplicate-rows replication issue that
# turned out to relate to confusion about whether the confirmed_flush_lsn and
# START_REPLICATION lsn were inclusive or exclusive.
#
# It is retained here to prevent regressions on this issue and because it
# provides some coverage of replication crash and recovery.
#
# See:
#     d96d8bb5 Use end-of-commit LSN in progress tracking
#
use strict;
use warnings;
use lib "t/";
use Cwd;
use Config;
use PostgresNode;
use TestLib;
use utils::nodemanagement;
use Test::More tests => 14;

my $query = q[
select coalesce(node_name, bdr.bdr_get_local_node_name()) AS origin_node_name, x
from t
cross join lateral bdr.get_transaction_replorigin(xmin) ro(originid)
left join pg_replication_origin on (roident = originid)
cross join lateral bdr.bdr_parse_replident_name(roname)
left join bdr.bdr_nodes on (remote_sysid, remote_timeline, remote_dboid) = (node_sysid, node_timeline, node_dboid)
order by x;
];

my $node_a = get_new_node('node_a');
initandstart_bdr_group($node_a);

my $node_b = get_new_node('node_b');
initandstart_logicaljoin_node($node_b, $node_a);

my @nodes = ($node_a, $node_b);

# Everything working?
$node_a->safe_psql('bdr_test', q[SELECT bdr.bdr_replicate_ddl_command($DDL$CREATE TABLE public.t(x text)$DDL$)]);
# Make sure everything caught up by forcing another lock
$node_a->safe_psql('bdr_test', q[SELECT bdr.acquire_global_lock('write_lock')]);

for my $node (@nodes) {
  $node->safe_psql('bdr_test', q[INSERT INTO t(x) VALUES (bdr.bdr_get_local_node_name())]);
}
$node_a->safe_psql('bdr_test', q[SELECT bdr.acquire_global_lock('write_lock')]);

my $expected = q[node_a|node_a
node_b|node_b];

is($node_a->safe_psql('bdr_test', $query), $expected, 'results node A before restart B');
is($node_b->safe_psql('bdr_test', $query), $expected, 'results node B before restart B');

#
# We've stored the end of the commit record of the last replayed xact into the
# replication identifier now. If the other node crashes, it'll lose any standby
# status updates and keepalive responses we might've sent to advance our
# confirmed_flush_lsn past that point. So when we START_REPLICATION again it'll
# use our supplied LSN from the local replication origin as passed to
# START_REPLICATION instead of the further-ahead LSN stored on the upstream
# slot.
#
# Prior to BDR 2.0 and d96d8bb5, we used to store the commit start lsn on
# our replication origin. So we'd ask to replay the last commit again
# in this situation and get a duplicate commit.
#
$node_b->stop('immediate');
$node_b->start;

is($node_a->safe_psql('bdr_test', $query), $expected, 'results node A after restart B');
is($node_b->safe_psql('bdr_test', $query), $expected, 'results node B after restart B');

$node_a->stop;
is($node_b->safe_psql('bdr_test', $query), $expected, 'results node B during restart A');
$node_a->start;
# to make sure a is ready for queries again:
sleep(1);

note "taking final DDL lock";
$node_a->safe_psql('bdr_test', q[SELECT bdr.acquire_global_lock('write_lock')]);
note "done, checking final state";

$expected = q[node_a|node_a
node_b|node_b];

is($node_a->safe_psql('bdr_test', $query), $expected, 'final results node A');
is($node_b->safe_psql('bdr_test', $query), $expected, 'final results node B');

$node_a->stop;
$node_b->stop;
