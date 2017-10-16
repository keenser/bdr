#!/usr/bin/env perl
#
# This test, added for RT#59119, verfies that apply_delay works.
#
use strict;
use warnings;
use lib 't/';
use Cwd;
use Config;
use PostgresNode;
use TestLib;
use IPC::Run qw(timeout);;
use Test::More;
use utils::nodemanagement qw(
		:DEFAULT
		generate_bdr_logical_join_query
		copy_transform_postgresqlconf
		start_bdr_init_copy
		);

my $timedout = 0;

# Create an upstream node and bring up bdr
my $nodes = make_bdr_group(2,'node_');
my ($node_0,$node_1) = @$nodes;

$node_0->safe_psql($bdr_test_dbname, q[
SELECT bdr.bdr_replicate_ddl_command($DDL$
CREATE TABLE public.city(
  city_sid INT PRIMARY KEY,
  name VARCHAR,
  UNIQUE(name)
);
$DDL$);
]);
wait_for_apply($node_0, $node_1);

foreach my $node ($node_0, $node_1)
{
    $node->safe_psql($bdr_test_dbname,
        q[ALTER SYSTEM SET bdr.default_apply_delay = 500;]);
    $node->safe_psql($bdr_test_dbname,
        q[ALTER SYSTEM SET bdr.log_conflicts_to_table = on;]);
    $node->safe_psql($bdr_test_dbname,
        q[ALTER SYSTEM SET bdr.synchronous_commit = on;]);
    $node->safe_psql($bdr_test_dbname,
        q[ALTER SYSTEM SET bdr.conflict_logging_include_tuples = on;]);
    $node->safe_psql($bdr_test_dbname,
        q[SELECT pg_reload_conf();]);
}

# Repeat a conflicting action multiple times.
#
# apply_delay isn't a sleep after each apply, its the minimum age before
# an xact may be applied on the peer(s).
my ($nerrors_0, $nerrors_1) = (0,0);
foreach my $i (0..2)
{
    $nerrors_0 += (0 != $node_0->psql($bdr_test_dbname, q[INSERT INTO city(city_sid, name) VALUES (2, 'Tom Price');]));
    $nerrors_1 += (0 != $node_1->psql($bdr_test_dbname, q[INSERT INTO city(city_sid, name) VALUES (3, 'Tom Price');]));
    $node_1->safe_psql($bdr_test_dbname, q[SELECT * FROM bdr.wait_slot_confirm_lsn(NULL, NULL)]);
    $node_1->safe_psql($bdr_test_dbname, q[DELETE FROM city;]);
    # See RT#59119
    $node_1->safe_psql($bdr_test_dbname, q[SELECT * FROM bdr.wait_slot_confirm_lsn(NULL, NULL)]);
}

my $nconflicts_0 = $node_0->safe_psql($bdr_test_dbname, q[SELECT count(*) FROM bdr.bdr_conflict_history]);
my $nconflicts_1 = $node_1->safe_psql($bdr_test_dbname, q[SELECT count(*) FROM bdr.bdr_conflict_history]);

cmp_ok($nconflicts_0 + $nconflicts_1, "==", 3, "detected required conflicts");

done_testing();
