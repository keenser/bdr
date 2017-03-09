use strict;
use warnings;
use Cwd;
use Config;
use PostgresNode;
use TestLib;
use threads;
use Test::More;

my $tempdir = TestLib::tempdir;

my $dbname = 'bdr_test';

# Init and start first node
# Create BDR group
sub create_bdr_group {
	my $node = shift;
	my $node_name = $node->name();
	initandstart_node($node, $dbname);
	$node->safe_psql($dbname, qq{
			SELECT bdr.bdr_group_create(
					local_node_name := '$node_name',
					node_external_dsn := '@{[ $node->connstr($dbname) ]}'
					);
			});
	$node->safe_psql($dbname, 'SELECT bdr.bdr_node_join_wait_for_ready()');
	is($node->safe_psql($dbname, 'SELECT bdr.bdr_is_active_in_db()'), 't', 'BDR is active on node-a after group create');
}



# Init and start node with BDR
sub initandstart_node {
	my $node = shift;
	my $dbname = shift;

	$node->init(hba_permit_replication => 1, allows_streaming => 1);
	edit_conf($node,'postgresql.conf');
	$node->start;
	bringup_bdr($node,$dbname);

}

# Edit Postgresql.conf with required 
# parameters for BDR.
sub edit_conf {
	my $node = shift;
	my $conf_file = shift;

	# Setting bdr.trace_replay=on here can be a big help, so added for
	# discoverability.
	$node->append_conf($conf_file, q{
			wal_level = logical
			track_commit_timestamp = on
			shared_preload_libraries = 'bdr'
			max_connections = 100
			max_wal_senders = 20
			max_replication_slots = 20
# Make sure there are enough background worker slots for BDR to run
			max_worker_processes = 20
			log_min_messages = debug1
			#bdr.trace_replay = off
			log_line_prefix = '%m %p %d [%a] %c:%l (%v:%t) '
			});

}

# Bring up BDR
sub bringup_bdr {
	my $node = shift;

	$node->safe_psql('postgres', qq{CREATE DATABASE $dbname;});
	$node->safe_psql($dbname, q{CREATE EXTENSION btree_gist;});
	$node->safe_psql($dbname, q{CREATE EXTENSION bdr;});

}
# Start a node, bring up bdr on a new node and join to 
# upstream node using bdr_group_join .Check status.
sub startandjoin_node {
	my $join_node = shift;
	my $upstream_node = shift;
	my $join_node_name = $join_node->name();
	my $upstream_node_name = $upstream_node->name();
	my $check_status = shift;
	initandstart_node($join_node);
	bdr_join($join_node,$upstream_node);
	if (defined $check_status && $check_status) {
		check_join_status($join_node,$upstream_node,$join_node_name,$upstream_node_name);
	}

}

# BDR group join
sub bdr_join {

	my $local_node = shift;
	my $join_node = shift;
	my $node_name = $local_node->name();
	$local_node->safe_psql($dbname, qq{
			SELECT bdr.bdr_group_join(
					local_node_name := '$node_name',
					node_external_dsn := '@{[ $local_node->connstr($dbname) ]}',
					join_using_dsn := '@{[ $join_node->connstr($dbname) ]}'
					);
			});
	$local_node->safe_psql($dbname, 'SELECT bdr.bdr_node_join_wait_for_ready()');
	
}

# Remove a node from cluster using 'bdr_part_by_node_names' and check status.
sub part_node {
	my $part_node = shift;
	my $upstream_node = shift;
	my $part_node_name = $part_node->name();
	my $upstream_node_name = $upstream_node->name();
	my $check_status = @_;  

	$upstream_node->psql($dbname, "SELECT bdr.bdr_part_by_node_names(ARRAY['$part_node_name'])");
	sleep(2);
	if ( defined $check_status && $check_status) {
		check_part_status($part_node,$upstream_node,$part_node_name,$upstream_node_name,$check_status);
	}
}
# Check node status is 'k' on self and upstream node
sub check_part_status {
	my $part_node = shift;
	my $upstream_node = shift;
	my $part_node_name = $part_node->name();
	my $upstream_node_name = $upstream_node->name();
	is($upstream_node->safe_psql($dbname, "SELECT node_status FROM bdr.bdr_nodes WHERE node_name = '$part_node_name'"), 'k',qq($part_node_name status on upstream node after part));
	is($part_node->safe_psql($dbname, "SELECT node_status FROM bdr.bdr_nodes WHERE node_name = '$part_node_name'"), 'k', qq($part_node_name status on local node after part));
# After a part if the entry is not removed from bdr.bdr_nodes, next node join hangs on wait.
	$upstream_node->safe_psql($dbname, "DELETE FROM bdr.bdr_nodes WHERE node_name = '$part_node_name' and node_status = 'k'");
	# stop this node 
	sleep(5); 
        $part_node->stop();
}

# 1. Check BDR is_active status is 't'
# 2. Check node status is ready  'r' on self
# and upstream node.
sub check_join_status {
	my $join_node = shift;
	my $upstream_node = shift;
	my $join_node_name = $join_node->name();
	my $upstream_node_name = $upstream_node->name();
	is($join_node->safe_psql($dbname, 'SELECT bdr.bdr_is_active_in_db()'), 't', qq(BDR is_active status on $join_node_name after join));
	is($join_node->safe_psql($dbname, "SELECT node_status FROM bdr.bdr_nodes WHERE node_name = '$join_node_name'"), 'r', qq($join_node_name status on local node) );
	is($upstream_node->safe_psql($dbname, "SELECT node_status FROM bdr.bdr_nodes WHERE node_name = '$join_node_name'"), 'r', qq($join_node_name status on upstream node));
}
# Acquire global ddl lock on node1 and try to part it.
# Part should fail if lock is not released.
# Currently failing as the node gets parted with status 'k'
# TODO: modify test to expected part failure
sub get_ddl_lock {
	my $node1 = shift;
	my $node2 = shift;
	threads->create(\&acquire_global_lock,$node1);
	sleep(5);
	isnt($node2->safe_psql($dbname,"SELECT locktype FROM bdr.bdr_global_locks"),'',"Got the lock");
	part_node($node1,$node2,1);
	is($node2->safe_psql($dbname,"SELECT locktype FROM bdr.bdr_global_locks"),'',"lock released");
}
sub acquire_global_lock {
	my $node = shift;
	$node->safe_psql($dbname,"BEGIN; SELECT bdr.acquire_global_lock('ddl');SELECT pg_sleep(3000);");
}

# Create a single integer column table
sub create_table {
	my $node = shift;
	my $table_name = shift;
	$node->safe_psql($dbname, qq{
			SELECT bdr.bdr_replicate_ddl_command(\$DDL\$
					CREATE TABLE public.$table_name(
						id integer primary key
						);
					\$DDL\$);
			});
}
# Create a bigint column table
# with default sequence
sub create_table_sequence {
	my $node = shift;
	my $table_name = shift;
	$node->safe_psql($dbname, qq{SELECT bdr.bdr_replicate_ddl_command(\$DDL\$ CREATE SEQUENCE public.test_seq; \$DDL\$)});
	sleep(5);
	$node->safe_psql($dbname, qq{
			SELECT bdr.bdr_replicate_ddl_command(\$DDL\$ 
					CREATE TABLE public.$table_name (
						id bigint NOT NULL DEFAULT bdr.global_seq_nextval('public.test_seq'),
						node_name text); 
					\$DDL\$);
			});
	sleep(5);
}
# Insert into table_sequence
sub insert_into_table_sequence {
	my $node = shift;
	my $table_name = shift;
	my $no_of_inserts = shift;
	my $node_name = $node->name();
	if (  not defined $no_of_inserts) {
		$no_of_inserts = 1;
	}
	for (my $i = 1; $i <= $no_of_inserts; $i++) {
		$node->safe_psql($dbname, " INSERT INTO public.$table_name(node_name) VALUES('$node_name')");
	}
	sleep(5);
	
}
# Check table entries withglobal sequence
sub check_sequence_table {
        my $node = shift;
        my $expected = shift;
        my $message = shift;
        is($node->safe_psql($dbname,"SELECT node_name FROM public.test_table_sequence"),$expected,$message);

}
# Compare sequence table records on nodes 
# with that on upstream node
sub compare_sequence_table_with_upstream {
        my $message = shift;
	my $upstream_node = shift;
        my @nodes = @_;
        my $upstream_record = $upstream_node->safe_psql($dbname,"SELECT * FROM public.test_table_sequence");
        foreach my $node (@nodes) {
                my $node_record = $node->safe_psql($dbname,"SELECT * FROM public.test_table_sequence");
                is($upstream_record,$node_record,$message .$node->name."" );
        }
}
# Put a node under write load with 500 inserts
sub write_load {
	my $node = shift;
	my $table_name = "write_load_join";
	create_table($node,$table_name);
	for( $a = 1; $a < 1000; $a = $a + 1 ){
		$node->safe_psql($dbname, "INSERT INTO $table_name VALUES($a)");
	}
}
# Check if concurrent multinode join works
sub concurrent_joins {
	my $type = shift;
	my $upstream_node = shift;
        my @nodes_array = @_;
	
	if ($type eq 'logical') {
		concurrent_joins_logical($upstream_node,@nodes_array);
	}
	elsif ($type eq 'physical') {
		concurrent_joins_physical($upstream_node,@nodes_array);
	}
		
}

sub concurrent_joins_logical {
        my $upstream_node = shift;
        my @nodes_array = @_;
        my $nodes_cnt = @nodes_array;
        foreach my $node (@nodes_array)
        {
                initandstart_node($node);
        }
        foreach my $node (@nodes_array)
        {
                threads->create(\&bdr_join ,$node,$upstream_node);
        }
        my @threads = threads->list();
        foreach my $thread(@threads) {
                $thread->join();
        }
        foreach my $node (@nodes_array)
        {
                check_join_status($node,$upstream_node);
        }

}
sub concurrent_joins_physical {
        my $upstream_node = shift;
        my @nodes_array = @_;
        my $nodes_cnt = @nodes_array;
        foreach my $node (@nodes_array)
        {
                threads->create(\&join_notest ,$node,$upstream_node);
        }
        my @threads = threads->list();
        foreach my $thread(@threads) {
                $thread->join();
        }
        sleep(10);
        foreach my $node (@nodes_array)
        {
                check_join_status($node,$upstream_node);
        }

}
# Here bdr_init_copy is given a system call since we do not want 
# to test command_ok or fail in 'thread'
sub join_notest {

        my $join_node = shift;
        my $upstream_node = shift;
        my $join_node_name = $join_node->name();
        my $upstream_node_name = $upstream_node->name();
        my $check_status = shift;
        edit_postgresqlconf($join_node,$upstream_node);
        system('bdr_init_copy', '-v', '-D', $join_node->data_dir, "-n", $join_node_name, '-d', $upstream_node->connstr($dbname), '--local-dbname', $dbname, '--local-port', $join_node->port,'--postgresql-conf', "$tempdir/postgresql.conf.$join_node_name");
        sleep(10);
}

sub concurrent_part {
        my $upstream_node = shift;
        my @nodes_array = @_;
        foreach my $node (@nodes_array)
        {
                threads->create(\&part_node ,$node,$upstream_node);
        }
        my @threads = threads->list();
        foreach my $thread(@threads) {
                $thread->join();
        }
        foreach my $node (@nodes_array)
        {
                check_part_status($node,$upstream_node);
                remove_nodes($node);
        }

}
# Check if multi-node join works concurrently.
# # with a mix of logical and physical joins.
sub concurrent_joins_logical_physical {
        my $upstream_node = shift;
        my $node_physical_join = shift;
        my @nodes_array = @_;
        foreach my $node (@nodes_array)
        {
                initandstart_node($node);
        }
        foreach my $node (@nodes_array)
        {
                threads->create(\&bdr_join ,$node,$upstream_node);
        }
        threads->create(\&join_notest,$node_physical_join,$upstream_node);
        my @threads = threads->list();
        foreach my $thread(@threads) {
                $thread->join();
        }
        foreach my $node (@nodes_array)
        {
                check_join_status($node,$upstream_node);
        }
        check_join_status($node_physical_join,$upstream_node);
}

sub edit_postgresqlconf {
        my $join_node = shift;
        my $upstream_node = shift;
        my $join_node_name = $join_node->name();

        open(my $upstream_conf, "<", $upstream_node->data_dir . '/postgresql.conf')
                or die ("can't open node_a conf file for reading: $!");

        open(my $joinnode_conf, ">", "$tempdir/postgresql.conf.$join_node_name")
                or die ("can't open node_b conf file for writing: $!");

        while (<$upstream_conf>)
        {
                if ($_ =~ "^port")
                {
                        print $joinnode_conf "port = " . $join_node->port . "\n";
                }
                else
                {
                        print $joinnode_conf $_;
                }
        }
        close($upstream_conf) or die ("failed to close old postgresql.conf: $!");
        close($joinnode_conf) or die ("failed to close new postgresql.conf: $!");

}
# Initialize a node and do a physical join
# to upstream node.
sub initializeandjoin_node {
        my $join_node = shift;
        my $upstream_node = shift;
        my $join_node_name = $join_node->name();
        my $upstream_node_name = $upstream_node->name();
        my $check_status = shift;

        edit_postgresqlconf($join_node,$upstream_node);
        command_ok(
                        [ 'bdr_init_copy', '-v', '-D', $join_node->data_dir, "-n", $join_node_name, '-d', $upstream_node->connstr($dbname), '--local-dbname', $dbname, '--local-port', $join_node->port,'--postgresql-conf', "$tempdir/postgresql.conf.$join_node_name"],
                        'bdr_init_copy succeeds');
        sleep(10);
        if (defined $check_status && $check_status) {
                check_join_status($join_node,$upstream_node,$join_node_name,$upstream_node_name);
        }

}
# Check if part and join works concurrently
sub concurrent_join_part {
	my $type = shift;
        my $upstream_node = shift;
	if ($type eq 'logical') {
		concurrent_join_part_logical($upstream_node);
	}
	elsif($type eq 'physical') {
		concurrent_join_part_physical($upstream_node);
	}

}
sub concurrent_join_part_logical {
        my $upstream_node = shift;
# Join a node that can be used to  part
	my $node_k = get_new_node('node_k');
        startandjoin_node($node_k,$upstream_node,1);
# Initialise a node that can be used to join
	my  $node_l = get_new_node('node_l');
        initandstart_node($node_l);
        my @join_nodes = $node_l;
        my @part_nodes = $node_k;
        foreach my $join_node (@join_nodes)
        {
                threads->create(\&bdr_join ,$join_node,$upstream_node);
        }
        foreach my $part_node (@part_nodes)
        {
                threads->create(\&part_node ,$part_node,$upstream_node);
        }
        my @threads = threads->list();
        foreach my $thread(@threads) {
                $thread->join();
        }
        foreach my $node (@join_nodes)
        {
                check_join_status($node,$upstream_node);
        }
        foreach my $node (@part_nodes)
        {
                check_part_status($node,$upstream_node);
        }
}
sub concurrent_join_part_physical {
        my $upstream_node = shift;
# Join a node that can be used to  part
	my $node_k = get_new_node('node_k');
        initializeandjoin_node($node_k,$upstream_node,1);
# Initialise a node that can be used to join
	my  $node_l = get_new_node('node_l');
        my @join_nodes = $node_l;
        my @part_nodes = $node_k;
        foreach my $join_node (@join_nodes)
        {
                threads->create(\&join_notest ,$join_node,$upstream_node);
        }
        foreach my $part_node (@part_nodes)
        {
                threads->create(\&part_node ,$part_node,$upstream_node);
        }
        my @threads = threads->list();
        foreach my $thread(@threads) {
                $thread->join();
        }
        foreach my $node (@join_nodes)
        {
                check_join_status($node,$upstream_node);
        }
        foreach my $node (@part_nodes)
        {
                check_part_status($node,$upstream_node);
                remove_nodes($node);
        }
}


# Try to join a new node to upstream node
# # while upstream is under write load
sub join_under_write_load {
	my $type = shift;
	my $upstream_node = shift;
# Start a node to join under write load
	my $node_m = get_new_node('node_m');
# Initiate heavy Inserts on upstream and simultaneously 
# try to join new node to the cluster
	my $write_thread = threads->create(\&write_load,$upstream_node);
	my $join_thread;
	if ($type eq 'logical') {
		initandstart_node($node_m);
		$join_thread  = threads->create(\&bdr_join ,$node_m,$upstream_node);
        }
        elsif($type eq 'physical') {
		$join_thread  = threads->create(\&join_notest ,$node_m,$upstream_node);
        }
	$join_thread->join();
	sleep(10);
	check_join_status($node_m,$upstream_node);
}

# Try to join while inserts happeneing on 
# sequence table
sub join_under_sequence_write_load {
	my $type = shift;
	my $upstream_node = shift;
# Start a node to join under write load
	my $node_m = get_new_node('node_m');
# Initiate heavy Inserts on upstream and simultaneously  join new 
# to the cluster
	my $write_thread = threads->create(\&insert_into_table_sequence,$upstream_node,"test_table_sequence",500);
	my $join_thread;
	if ($type eq 'logical') {
		initandstart_node($node_m);
		$join_thread  = threads->create(\&bdr_join ,$node_m,$upstream_node);
        }
        elsif($type eq 'physical') {
		$join_thread  = threads->create(\&join_notest ,$node_m,$upstream_node);
        }
	$join_thread->join();
	sleep(10);
	check_join_status($node_m,$upstream_node);
	$write_thread->join();
	compare_sequence_table_with_upstream("New node join while inserts into sequence table: ",$upstream_node,$node_m);
}

# Make concurrent inserts into sequence table
# from two nodes. Also check that global sequence
# ids generated are unique.
sub concurrent_insert {
        my $upstream_node =shift;
        my $node_1 = shift;
        my $node_2 = shift;
        my $thread1 = threads->create(\&insert_into_table_sequence,$node_1,"test_table_sequence",50);
        my $thread2 = threads->create(\&insert_into_table_sequence,$node_2,"test_table_sequence",50);
        $thread1->join();
        $thread2->join();
        my $node1_entry = $node_1->safe_psql($dbname,"SELECT COUNT(*) FROM test_table_sequence WHERE node_name like '".$node_2->name."%'");
        my $node2_entry = $node_2->safe_psql($dbname,"SELECT COUNT(*) FROM test_table_sequence WHERE node_name like '".$node_1->name."%'");
        is($node1_entry,50,"All records replicated on " .$node_1->name."");
        is($node2_entry,50,"All records replicated on " .$node_2->name."");
        my $duplicates = $node_1->safe_psql($dbname,"SELECT COUNT(*) FROM test_table_sequence GROUP BY id HAVING COUNT(*) > 1");
        is($duplicates,'',"Unique global sequence test");
} 
