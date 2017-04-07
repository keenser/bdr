#!/usr/bin/env perl
#
# This test is intended to verify that if a node is cleanly parted
# from the group while holding the global DDL lock, the lock will
# become available for another peer to take.
#
use strict;
use warnings;
use lib 't/';
use Cwd;
use Config;
use PostgresNode;
use TestLib;
use Test::More tests => 18;
use utils::nodemanagement;

# Create an upstream node and bring up bdr
my $nodes = make_bdr_group(3,'node_');
my $node_0 = $nodes->[0];
my $node_1 = $nodes->[1];
my $node_2 = $nodes->[2];

# Acquire the global ddl lock in a background psql session so that 
# we keep holding it until we commit/abort.
my ($psql_stdin, $psql_stdout, $psql_stderr) = ('','', '');
note "Acquiring global ddl lock on node_1";
my $psql = IPC::Run::start(
    ['psql', '-qAX', '-d', $node_1->connstr($bdr_test_dbname), '-f', '-'],
    '<', \$psql_stdin, '>', \$psql_stdout, '2>', \$psql_stderr);

$psql_stdin .= "BEGIN;\n";
$psql_stdin .= "SELECT 'acquired' FROM bdr.acquire_global_lock('ddl');\n";
$psql->pump until $psql_stdout =~ 'acquired';

is( $node_0->safe_psql( $bdr_test_dbname, "SELECT state FROM bdr.bdr_global_locks"), 'acquired', "ddl lock acquired");

# Part node B. The part should fail if B currently holds the global DDL lock.
# (or we should release it?).
TODO: {
    local $TODO = 'ddl lock check on part not implemented yet';
    is($node_0->psql( $bdr_test_dbname, "SELECT bdr.bdr_part_by_node_names(ARRAY['node_1'])" ),
        3, 'part_by_node_names call should fail');
    is( $node_0->safe_psql( $bdr_test_dbname, "SELECT node_status FROM bdr.bdr_nodes WHERE node_name = 'node_1' "), 'r',
        "Part should fail");
};

# If the node that holds the DDL lock goes down permanently while holding the
# DDL lock, parting the node with bdr.bdr_part_by_node_names() will release the
# lock on other nodes.
#
# Bug #15
TODO: {
    local $TODO = 'ddl lock release on part not implemented yet';
    is( $node_0->safe_psql( $bdr_test_dbname, "SELECT state FROM bdr.bdr_global_locks"), '', "ddl lock released after part");
};

# TODO:
#
# Have a node try to acquire the DDL lock while another node is down, so it can
# never successfully acquire it. Run the acquire command in the background; if
# we ran in the foreground with a timer the lock attempt would get released
# when the backend died and the xact aborted.
#
# Then hard-kill the node that's trying to acquire the lock. Verify that the
# other nodes consider it still held. Part the acquiring node from the others
# and verify that the lock was force-released.
