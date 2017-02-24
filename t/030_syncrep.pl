use strict;
use warnings;
use Cwd;
use Config;
use PostgresNode;
use TestLib;
use Test::More tests => 11;
require "t/utils/common.pl";

#
# This test creates a 4-node group with two mutual sync-rep pairs.
# 
#    A <===> B
#    ^       ^
#    |       |
#    v       v
#    B <===> C
#

my $tempdir = TestLib::tempdir;

my $node_a = get_new_node('node_a');
create_bdr_group($node_a);

my $node_b = get_new_node('node_b');
startandjoin_node($node_b, $node_a);

# application_name should be the same as the node name
is($node_a->safe_psql('postgres', q[SELECT application_name FROM pg_stat_activity WHERE application_name <> 'psql' AND application_name NOT LIKE '%init' ORDER BY application_name]),
q[bdr supervisor
node_a:perdb
node_b:apply
node_b:send],
'2-node application_name check');

# Create the other nodes
my $node_c = get_new_node('node_c');
startandjoin_node($node_c, $node_a);

my $node_d = get_new_node('node_d');
startandjoin_node($node_d, $node_c);

# other apply workers should be visible now
is($node_a->safe_psql('postgres', q[SELECT application_name FROM pg_stat_activity WHERE application_name <> 'psql' AND application_name NOT LIKE '%init' ORDER BY application_name]),
q[bdr supervisor
node_a:perdb
node_b:apply
node_b:send
node_c:apply
node_c:send
node_d:apply
node_d:send],
'4-node application_name check');

# Everything working?
$node_a->safe_psql('bdr_test', q[SELECT bdr.bdr_replicate_ddl_command($DDL$CREATE TABLE public.t(x text)$DDL$)]);
# Make sure everything caught up by forcing another lock
$node_a->safe_psql('bdr_test', q[SELECT bdr.acquire_global_lock('write')]);

my @nodes = ($node_a, $node_b, $node_c, $node_d);
for my $node (@nodes) {
  $node->safe_psql('bdr_test', q[INSERT INTO t(x) VALUES (bdr.bdr_get_local_node_name())]);
}
$node_a->safe_psql('bdr_test', q[SELECT bdr.acquire_global_lock('write')]);

# With a node down we should still be able to do work
$node_b->stop;
$node_a->safe_psql('bdr_test', q[INSERT INTO t(x) VALUES ('node_a - async')]);
$node_b->start;

diag "reconfiguring into synchronous pairs A<=>B, C<=>D";
$node_a->safe_psql('bdr_test', q[ALTER SYSTEM SET synchronous_standby_names = '"node_b:send"']);
$node_b->safe_psql('bdr_test', q[ALTER SYSTEM SET synchronous_standby_names = '"node_a:send"']);

$node_c->safe_psql('bdr_test', q[ALTER SYSTEM SET synchronous_standby_names = '"node_d:send"']);
$node_d->safe_psql('bdr_test', q[ALTER SYSTEM SET synchronous_standby_names = '"node_c:send"']);

for my $node (@nodes) {
  $node->restart;
}

# Everything should work while the system is all-up
$node_a->safe_psql('bdr_test', q[INSERT INTO t(x) VALUES ('node_a - sync B-up')]);

# but with node B down, node A should refuse to confirm commit
diag "stopping B";
$node_b->stop;
my $timed_out;
diag "inserting on A when B is down; expect psql timeout in 10s";
$node_a->psql('bdr_test', q[INSERT INTO t(x) VALUES ('node_a - sync B-down')], timeout => 10, timed_out => \$timed_out);
ok($timed_out, 'txn on A times out if B is down');

is($node_a->safe_psql('bdr_test', q[SELECT 1 FROM t WHERE x = 'node_a - sync B-down']), '', 'committed xact not visible on A yet');

is($node_c->safe_psql('bdr_test', q[SELECT 1 FROM t WHERE x = 'node_a - sync B-down']), '1', 'committed xact visible on C');

# but commiting on C should become immediately visible on both A and D when B is down
# TODO: wait for sync-up better
$node_c->safe_psql('bdr_test', q[INSERT INTO t(x) VALUES ('node_c - sync B-down')]);
sleep(2);
is($node_c->safe_psql('bdr_test', q[SELECT 1 FROM t WHERE x = 'node_c - sync B-down']), '1', 'C xact visible on C');
is($node_a->safe_psql('bdr_test', q[SELECT 1 FROM t WHERE x = 'node_c - sync B-down']), '1', 'C xact visible on A');
is($node_d->safe_psql('bdr_test', q[SELECT 1 FROM t WHERE x = 'node_c - sync B-down']), '1', 'C xact visible on D');

diag "starting B";
$node_b->start;

# Because Pg commits a txn in sync rep before checking sync, once B comes back up
# and catches up, we should see the txn from when it was down.
#
# FIXME: use slot catchup

sleep(2);
is($node_b->safe_psql('bdr_test', q[SELECT 1 FROM t WHERE x = 'node_a - sync B-down']), '1', 'B received xact from A');

is($node_a->safe_psql('bdr_test', q[SELECT 1 FROM t WHERE x = 'node_a - sync B-down']), '', 'committed xact visible on A after B confirms');
