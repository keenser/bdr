#!/usr/bin/env perl
#
# This test tries to ensure that joining a node while another is offline will
# hang until the offline node comes back.
#
use strict;
use warnings;
use lib 't/';
use Cwd;
use Config;
use PostgresNode;
use TestLib;
use IPC::Run qw(timeout);;
use Test::More tests => 24;
use utils::nodemanagement qw(
		:DEFAULT
		generate_bdr_logical_join_query
		copy_transform_postgresqlconf
		start_bdr_init_copy
		);

# Create an upstream node and bring up bdr
my $nodes = make_bdr_group(3,'node_');
my $node_0 = $nodes->[0];

# Make sure DDL locking works
my $timedout = 0;
my $ret = $node_0->psql($bdr_test_dbname,
	q[SELECT bdr.acquire_global_lock('ddl');],
	timed_out => \$timedout, timeout => 10);
is($ret, 0, 'DDL lock succeeded with node up');
is($timedout, 0, 'DDL lock acquisition did not time out with node up');

# Bring a node down
my $offline_index = 1;
my $offline_node = $nodes->[$offline_index];
$offline_node->stop;
 
# and make sure DDL locking now times out, the node acquires ddl
# lock on other peers and keeps waiting for offline node.
$node_0->psql($bdr_test_dbname,
          q[SELECT bdr.acquire_global_lock('ddl');],
            timed_out =>\$timedout,timeout => 10);
is($timedout, 1, 'DDL lock acquisition attempt timed out with node down');
# Release the DDL lock by restarting node
my $node_2=$nodes->[2];
$offline_node->start;
while(1) {
    sleep(0.5);
    if($node_2->safe_psql($bdr_test_dbname,"SELECT locktype from bdr.bdr_global_locks;") ne 'ddl_lock') {
        last; 
    }
}
# If DDL lock fails, so should logical join, without creating any slots
# or nodes entries.
$offline_node->stop;
my $new_node_name = 'new_logical_join_node';
my $new_node = get_new_node($new_node_name);
initandstart_node($new_node);
my $join_query = generate_bdr_logical_join_query($new_node, $node_0);
$new_node->psql($bdr_test_dbname, $join_query,
	timed_out => \$timedout, timeout => 10);

TODO: {
    # https://github.com/2ndQuadrant/bdr-private/issues/20
	local $TODO = "logical join doesn't seem to time out when it should (#20)";
	is($timedout, 1, 'Logical node join timed out while node down');
	# check no bdr.bdr_nodes entry exists for new node
        is($new_node->safe_psql($bdr_test_dbname, "SELECT node_status FROM bdr.bdr_nodes WHERE node_name = '$new_node_name'"), '', "bdr_nodes entry  on local node" );
	splice @{$nodes}, $offline_index, 1;
	# check no slot created on any peer for new node
	check_joinfail_status($new_node,@{$nodes});
}

# Similarly a physical join should fail when a node in group is down
my $new_physical_join_node = get_new_node('new_physical_join_node');
my $new_conf_file = copy_transform_postgresqlconf( $new_physical_join_node, $node_0 );
my $timeout = IPC::Run::timeout(my $to=10, exception=>"Timed out");
my $handle = start_bdr_init_copy($new_physical_join_node, $node_0, $new_conf_file,[$timeout]);
eval {
    $handle->finish;
};
like($@, qr/Timed out/, "Physical node joined timed out while node down");
# check no slot created on any peer for new node
check_joinfail_status($new_physical_join_node,@{$nodes});

