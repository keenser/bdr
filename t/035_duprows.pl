use strict;
use warnings;
use Cwd;
use Config;
use PostgresNode;
use TestLib;
use Test::More tests => 8;
require "t/utils/common.pl";

my $query = q[
select coalesce(node_name, bdr.bdr_get_local_node_name()) AS origin_node_name, x
from t
cross join lateral bdr.get_transaction_replorigin(xmin) ro(originid)
left join pg_replication_origin on (roident = originid)
cross join lateral bdr.bdr_parse_replident_name(roname)
left join bdr.bdr_nodes on (remote_sysid, remote_timeline, remote_dboid) = (node_sysid, node_timeline, node_dboid)
order by x;
];

my $tempdir = TestLib::tempdir;

my $node_a = get_new_node('node_a');
create_bdr_group($node_a);

my $node_b = get_new_node('node_b');
startandjoin_node($node_b, $node_a);

my @nodes = ($node_a, $node_b);

# Everything working?
$node_a->safe_psql('bdr_test', q[SELECT bdr.bdr_replicate_ddl_command($DDL$CREATE TABLE public.t(x text)$DDL$)]);
# Make sure everything caught up by forcing another lock
$node_a->safe_psql('bdr_test', q[SELECT bdr.acquire_global_lock('write')]);

for my $node (@nodes) {
  $node->safe_psql('bdr_test', q[INSERT INTO t(x) VALUES (bdr.bdr_get_local_node_name())]);
}
$node_a->safe_psql('bdr_test', q[SELECT bdr.acquire_global_lock('write')]);

my $expected = q[node_a|node_a
node_b|node_b];

is($node_a->safe_psql('bdr_test', $query), $expected, 'results node A before restart B');
is($node_b->safe_psql('bdr_test', $query), $expected, 'results node B before restart B');

$node_b->stop('immediate');
$node_b->start;

is($node_a->safe_psql('bdr_test', $query), $expected, 'results node A after restart B');
is($node_b->safe_psql('bdr_test', $query), $expected, 'results node B after restart B');

$node_a->stop;
is($node_b->safe_psql('bdr_test', $query), $expected, 'results node B during restart A');
$node_a->start;
# to make sure a is ready for queries again:
sleep(1);

diag "taking final DDL lock";
$node_a->safe_psql('bdr_test', q[SELECT bdr.acquire_global_lock('write')]);
diag "done, checking final state";

$expected = q[node_a|node_a
node_b|node_b];

is($node_a->safe_psql('bdr_test', $query), $expected, 'final results node A');
is($node_b->safe_psql('bdr_test', $query), $expected, 'final results node B');

$node_a->stop;
$node_b->stop;
