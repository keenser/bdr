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
use Test::More tests => 28;
use utils::nodemanagement qw(
		:DEFAULT
		generate_bdr_logical_join_query
		copy_transform_postgresqlconf
		start_bdr_init_copy
		);

# Create an upstream node and bring up bdr
my $nodes = make_bdr_group(3,'node_');
my $node_0 = $nodes->[0];
my $offline_index = 1;
my $offline_node = $nodes->[$offline_index];
my $node_2 = $nodes->[2];

# Make sure DDL locking works
my $timedout = 0;
my $ret = $node_0->psql($bdr_test_dbname,
	q[SELECT bdr.acquire_global_lock('ddl');],
	timed_out => \$timedout, timeout => 10);
is($ret, 0, 'DDL lock succeeded with node up');
is($timedout, 0, 'DDL lock acquisition did not time out with node up');

# Bring a node down
$offline_node->stop;
 
# and make sure DDL locking now times out, the node acquires ddl
# lock on other peers and keeps waiting for offline node.
$timedout = 0;
#X$ret = $node_0->psql($bdr_test_dbname,
#X          q[SELECT bdr.acquire_global_lock('ddl');],
#X            timed_out =>\$timedout, timeout => 10);
#Xis($timedout, 1, 'DDL lock acquisition attempt timed out with node down');
#X

my $lock = start_acquire_ddl_lock($node_0, 'ddl');
# Not much way around waiting here, since we're trying to show we'll
# time out...
sleep(2);
is($node_2->safe_psql($bdr_test_dbname, q[SELECT state FROM bdr.bdr_global_locks]), 'acquired',
    'local DDL lock acquired on node 2');
# No good way to show if requesting node has replies
# from all peers. Best we can do is see if bdr.bdr_acquire_global_lock(...)
# stmt has finished. FIXME need ddl lock status functions
is($node_0->safe_psql($bdr_test_dbname, "SELECT state FROM pg_stat_activity WHERE pid = " . $lock->{backend_pid} . ";"),
    'active', 'still trying to acquire lock on node_0');

cancel_ddl_lock($lock);
ok(!wait_acquire_ddl_lock($lock, undef, 1), 'did not acquire lock');

# After the psql session terminates, we'll send a message to peer nodes
# to release the DDL lock acquisition attempt. This will take a while, so
# poll here.
$node_2->poll_query_until($bdr_test_dbname, "SELECT NOT EXISTS (SELECT 1 FROM bdr.bdr_global_locks WHERE state = 'acquired')");
wait_for_apply($node_0, $node_2);
wait_for_apply($node_2, $node_0);

# If DDL locking attempt fails, so should logical join, without creating any
# slots or nodes entries.
my $new_node_name = 'new_logical_join_node';
my $new_node = get_new_node($new_node_name);
initandstart_node($new_node);
my $join_query = generate_bdr_logical_join_query($new_node, $node_0);
# The join query will always complete immediately, we need to look at the
# progress of join completion to determine whether it gets anywhere.
$new_node->safe_psql($bdr_test_dbname, $join_query);

# We should never become ready
$new_node->psql($bdr_test_dbname, "SELECT bdr.bdr_node_join_wait_for_ready()",
	timed_out => \$timedout, timeout => 10);
is($timedout, 1, 'Logical node join timed out while node down');

TODO: {
    local $TODO = 'join should not proceed until it can acquire ddl lock on remote node';
    is($new_node->safe_psql($bdr_test_dbname, "SELECT node_status FROM bdr.bdr_nodes WHERE node_name = '$new_node_name'"), 'i',
        "bdr.bdr_nodes still in status 'i'");

    splice @{$nodes}, $offline_index, 1;
    # check no slot or nodes entry created on any peer for new node yet

    todo_skip 'skipped because Test::More does not recognise TODO in sub', 2;
    check_joinfail_status($new_node,@{$nodes});
};

# If we bring the offline node back online, join should be able to proceed
$offline_node->start;
is($new_node->psql($bdr_test_dbname, "SELECT bdr.bdr_node_join_wait_for_ready()"), 0,
    'join succeeded once offline node came back');


# Similarly a physical join should fail when a node in group is down
$offline_node->stop;
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

