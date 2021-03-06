#!/usr/bin/env perl
#
# Shared test code for simple BDR node management.
#
package utils::nodemanagement;

use strict;
use warnings;
use 5.8.0;
use Exporter;
use Cwd;
use Config;
use Carp;
use PostgresNode;
# Patch PostgresNode with stuff we want from post-9.6
require "t/backports/PostgresNode_96.pl";
use TestLib;
use Test::More;
use IPC::Run;
use Time::HiRes;
use vars qw($bdr_test_dbname);

use Carp 'verbose';
$SIG{__DIE__} = \&Carp::confess;

use vars qw(@ISA @EXPORT @EXPORT_OK);
@ISA         = qw(Exporter);
@EXPORT      = qw(
    $bdr_test_dbname

    make_bdr_group
    initandstart_node
    initandstart_bdr_group
    initandstart_logicaljoin_node
    bdr_logical_join
    create_bdr_group
    initandstart_physicaljoin_node
    check_join_status
    check_part_statuses
    part_nodes
    check_part_status
    stop_nodes
    part_and_check_nodes
    exec_ddl
    node_isready
    wait_for_pg_isready
    create_table
    dump_nodes_statuses
    check_joinfail_status
    initandstart_join_node
    wait_for_apply
    start_acquire_ddl_lock
    wait_acquire_ddl_lock
    cancel_ddl_lock
    release_ddl_lock
    );

# For use by other modules, but need not appear in the default namespace of
# tests.
@EXPORT_OK   = qw(
    generate_bdr_logical_join_query
    copy_transform_postgresqlconf
    start_bdr_init_copy
    wait_part_completion
);

BEGIN {
    $bdr_test_dbname = 'bdr_test';
}

my $tempdir = TestLib::tempdir;

# Make a group of BDR nodes with numbered node names
# and returns a list of the nodes.
sub make_bdr_group {
    my ($n_nodes, $name_prefix, $mode) = @_;
    $mode = 'logical' if !defined($mode);
	$name_prefix = 'node_' if !defined($name_prefix);

    die "unrecognised join mode $mode"
        if ($mode ne 'logical' && $mode ne 'physical');

    my $node_0 = get_new_node("${name_prefix}0");
    initandstart_bdr_group($node_0);
    my @nodes;
    push @nodes, $node_0;

    for (my $nodeid = 1; $nodeid < $n_nodes; $nodeid++)
    {
        my $node_n = get_new_node("${name_prefix}${nodeid}");
        push @nodes, $node_n;
        if ($mode eq 'logical')
        {
            initandstart_logicaljoin_node($node_n, $node_0);
        }
        else
        {
            initandstart_physicaljoin_node($node_n, $node_0);
        }
    }

    return \@nodes;
}

# Wrapper around bdr.bdr_group_create
#
sub create_bdr_group {
    my $node      = shift;

    $node->safe_psql(
        $bdr_test_dbname, qq{
            SELECT bdr.bdr_group_create(
                    local_node_name := '@{[ $node->name ]}',
                    node_external_dsn := '@{[ $node->connstr($bdr_test_dbname) ]}'
                    );
            }
    );
    $node->safe_psql( $bdr_test_dbname, 'SELECT bdr.bdr_node_join_wait_for_ready()' );
    $node->safe_psql( $bdr_test_dbname, 'SELECT bdr.bdr_is_active_in_db()' ) eq 't'
        or BAIL_OUT('!bdr.bdr_is_active_in_db() after bdr_group_create');
}

# Given a newly allocated PostgresNode, bring up a standalone 1-node BDR
# system using bdr_group_create.
sub initandstart_bdr_group {
    my $node      = shift;

    initandstart_node($node);
    create_bdr_group($node);
}

# Init and start node with BDR, create the test DB and install the BDR
# extension.
sub initandstart_node {
    my ($node, $bdr_test_dbname, %kwopts) = @_;

    $node->init( hba_permit_replication => 1, allows_streaming => 1,
				 %{$kwopts{extra_init_opts}//{}} );
    bdr_update_postgresql_conf( $node );
    $node->start;
    _create_db_and_exts( $node, $bdr_test_dbname );

}

# Edit postgresql.conf with required parameters for BDR
sub bdr_update_postgresql_conf {
    my ($node) = shift;

    # Setting bdr.trace_replay=on here can be a big help, so added for
    # discoverability.
    $node->append_conf(
        'postgresql.conf', q{
            wal_level = logical
            track_commit_timestamp = on
            shared_preload_libraries = 'bdr'
            max_connections = 100
            max_wal_senders = 20
            max_replication_slots = 20
            # Make sure there are enough background worker slots for BDR to run
            max_worker_processes = 20
            log_min_messages = debug2
            #bdr.trace_replay = off
            log_line_prefix = '%m %p %d [%a] %c:%l (%v:%t) '
            }
    );
}

sub _create_db_and_exts {
    my $node = shift;

    $node->safe_psql( 'postgres', qq{CREATE DATABASE $bdr_test_dbname;} );
    $node->safe_psql( $bdr_test_dbname,    q{CREATE EXTENSION btree_gist;} );
    $node->safe_psql( $bdr_test_dbname,    q{CREATE EXTENSION bdr;} );

}
sub initandstart_join_node {
    my $join_node          = shift;
    my $upstream_node      = shift;
    my $type          = shift;

    if ( $type eq 'logical' ) {
        initandstart_logicaljoin_node( $join_node, $upstream_node );
    }
    elsif ( $type eq 'physical' ) {
        initandstart_physicaljoin_node( $join_node, $upstream_node );
    }
}
# Shortcut for creating a new node, joining to upstream and validating
# the join with some TAP tests.
sub initandstart_logicaljoin_node {
    my $join_node          = shift;
    my $upstream_node      = shift;
    my $join_node_name     = $join_node->name();
    my $upstream_node_name = $upstream_node->name();

    initandstart_node($join_node);
    bdr_logical_join( $join_node, $upstream_node );
    check_join_status( $join_node,$upstream_node);
}

#
# Generate a query for bdr.bdr_group_join
#
# Caller is responsible for quote escaping on extra params.
#
sub generate_bdr_logical_join_query {
    my ($local_node, $join_node, %params) = @_;

    my $join_query = qq{
            SELECT bdr.bdr_group_join(
                    local_node_name := '@{[$local_node->name]}',
                    node_external_dsn := '@{[ $local_node->connstr($bdr_test_dbname) ]}',
                    join_using_dsn := '@{[ $join_node->connstr($bdr_test_dbname) ]}'};

    while (my ($k,$v) = each(%params)) {
        $join_query .= ", $k := '$v'";
    }

    $join_query .= ");";

    return $join_query;
}

# BDR group join with optional extra params passed directly to bdr.bdr_group_join
#
# Caller is responsible for quote escaping on extra params.
#
sub bdr_logical_join {
    my ($local_node, $join_node, %params) = @_;

    my $nowait = delete $params{nowait} // 0;

    my $join_query = generate_bdr_logical_join_query($local_node, $join_node, %params);
    $local_node->safe_psql($bdr_test_dbname, $join_query);

    if (!$nowait) {
        $local_node->safe_psql( $bdr_test_dbname,
            'SELECT bdr.bdr_node_join_wait_for_ready()' );
    }
}

# Copy postgresql.conf from an existing node to a temporary
# location, changing the port to match the generated port for
# a new node.
#
sub copy_transform_postgresqlconf {
    my ($join_node, $upstream_node) = @_;
    my $join_node_name = $join_node->name();
    my $outfile_name   = "$tempdir/postgresql.conf.$join_node_name";

    open( my $upstream_conf,
        "<", $upstream_node->data_dir . '/postgresql.conf' )
      or die("can't open node_a conf file for reading: $!");

    open( my $joinnode_conf, ">", $outfile_name )
      or die("can't open node_b conf file for writing: $!");

    while (<$upstream_conf>) {
        if ( $_ =~ "^port" ) {
            print $joinnode_conf "port = " . $join_node->port . "\n";
        }
        else {
            print $joinnode_conf $_;
        }
    }
    close($upstream_conf) or die("failed to close old postgresql.conf: $!");
    close($joinnode_conf) or die("failed to close new postgresql.conf: $!");

    return $outfile_name;
}

#
# Run bdr_init_copy and return an IPC::Run::Handle for it, which can be waited
# on with $h->finish, result code tested with $h->result (for unix return code
# from process) or $h->full_result(0) (for shell result including signal codes),
# etc.
#
# An optional 3rd argument is an arrayref of extra arguments to IPC::Run::start,
# like
#
#     ['timeout', 30]
#
# If called in array context, handles to stdout and stderr are returned,
# otherwise they're left connected to the system file handles.
#
# IPC::Run exceptions will be thrown to the caller.
#
sub start_bdr_init_copy {
    my ($join_node, $upstream_node, $new_conf_file, $extra_ipc_run_opts) = @_;
    
    my @ipcrun_opts = (
        [
            'bdr_init_copy',     '-v',
            '-D',                $join_node->data_dir,
            "-n",                $join_node->name,
            '-d',                $upstream_node->connstr($bdr_test_dbname),
            '--local-dbname',    $bdr_test_dbname,
            '--local-port',      $join_node->port,
            '--postgresql-conf', $new_conf_file
        ],
    );

    my $stdout = '';
    my $stderr = '';
    
    
    if (wantarray) {
        push @ipcrun_opts, '>', \$stdout, '2>', \$stderr;
    }

    my $h = IPC::Run::start(@ipcrun_opts,
                            ref $extra_ipc_run_opts ? @{$extra_ipc_run_opts} : undef);

    if (wantarray) {
        return ($h, $stdout, $stderr);
    } else { 
        return $h;
    }
}

# Initialize a node and do a physical join to upstream node using
# bdr_init_copy.
#
# A new config file is generated by copying the upstream's file and changing
# the port. (If we need to add extra params to the new node's config file we
# can add an extra option to this function containing a string of params
# to append after copy.)
#
# Adds 4 tests.
#
sub initandstart_physicaljoin_node {
    my ($join_node, $upstream_node) = @_;

    my $new_conf_file = copy_transform_postgresqlconf( $join_node, $upstream_node );
    my $h = start_bdr_init_copy($join_node, $upstream_node, $new_conf_file);
    $h->finish;
    is($h->result(0), 0, 'bdr_init_copy exited without error');

    # wait for Pg to start
    wait_for_pg_isready($join_node);

    # wait for BDR to come up
    $join_node->safe_psql( $bdr_test_dbname, 'SELECT bdr.bdr_node_join_wait_for_ready()' );

    $join_node->safe_psql( $bdr_test_dbname, 'SELECT bdr.bdr_is_active_in_db()' ) eq 't'
        or BAIL_OUT('!bdr.bdr_is_active_in_db() after bdr_group_create');

    # PostgresNode doesn't know we started the node since we didn't
    # use any of its methods, so we'd better tell it to check. Otherwise
    # it'll ignore the node for things like pg_ctl stop.
    $join_node->_update_pid(1);

    check_join_status($join_node, $upstream_node);
}

# 1. Check BDR is_active status is 't'
# 2. Check node status is ready 'r' on self and upstream node.
# 3. Ensure active replication slots present on both ends
#
sub check_join_status {
    my $join_node          = shift;
    my $upstream_node      = shift;
    my $join_node_name     = $join_node->name();
    my $upstream_node_name = $upstream_node->name();

    is( $join_node->safe_psql( $bdr_test_dbname, 'SELECT bdr.bdr_is_active_in_db()' ),
        't', qq(BDR is_active status on $join_node_name after join) );

    is(
        $join_node->safe_psql(
            $bdr_test_dbname,
            "SELECT node_status FROM bdr.bdr_nodes WHERE node_name = '$join_node_name'"
        ),
        'r',
        qq($join_node_name status is 'r' on new node)
    );

    is(
        $upstream_node->safe_psql(
            $bdr_test_dbname,
            "SELECT node_status FROM bdr.bdr_nodes WHERE node_name = '$join_node_name'"
        ),
        'r',
        qq($join_node_name status is 'r' on upstream node)
    );

    # The new node's slot on the join target must be created
    is(
        $upstream_node->safe_psql($bdr_test_dbname, qq[SELECT EXISTS (SELECT 1 FROM bdr.bdr_node_slots WHERE node_name = '$join_node_name')]),
        't',
        qq(replication slot for $join_node_name on $upstream_node_name has been created)
    );

    # The join target's slot on the new node must be created
    is(
        $join_node->safe_psql($bdr_test_dbname, qq[SELECT EXISTS (SELECT 1 FROM bdr.bdr_node_slots WHERE node_name = '$upstream_node_name')]),
        't',
        qq(replication slot for $upstream_node_name on $join_node_name has been created)
    );

    # The join target must have an active connection to the new node
    is(
        $join_node->safe_psql($bdr_test_dbname, qq[SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE application_name = '$upstream_node_name:send')]),
        't',
        qq(replication connection for $upstream_node_name on $join_node_name is present)
    );

    # The new node must have an active connection to the join target
    is(
        $upstream_node->safe_psql($bdr_test_dbname, qq[SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE application_name = '$join_node_name:send')]),
        't',
        qq(replication connection for $join_node_name on $upstream_node_name is present)
    );
}

sub wait_part_completion {
    my ($part_node, $upstream_node) = @_;

    if (!$upstream_node->poll_query_until($bdr_test_dbname, qq[SELECT NOT EXISTS (SELECT 1 FROM bdr.bdr_node_slots WHERE node_name = '] . $part_node->name . "')")) {
        cluck("replication slot for node " . $part_node->name . " on " . $upstream_node->name . " was not removed, trying to continue anyway");
    }
}

# Remove one or mote nodes from cluster using 'bdr_part_by_node_names'.
#
# Does not check part status.
#
# Thread safe.
sub part_nodes {
    my $part_nodes         = shift;
    my $upstream_node      = shift;
    my $upstream_node_name = $upstream_node->name();

    for my $part_node (@{$part_nodes}) {
        my $part_node_name = $part_node->name();
        $upstream_node->safe_psql($bdr_test_dbname, qq[SELECT EXISTS (SELECT 1 FROM bdr.bdr_node_slots WHERE node_name = '$part_node_name')])
            or BAIL_OUT("could not find existing slot for $part_node_name on $upstream_node_name before parting");
    }

    my $nodelist = "ARRAY['" . join("','", map { $_->name } @{$part_nodes}) . "']";

    $upstream_node->safe_psql( $bdr_test_dbname,
        "SELECT bdr.bdr_part_by_node_names($nodelist)" );

    # We can tell a part has taken effect when the downstream's slot vanishes
    # on the upstream.
    for my $part_node (@{$part_nodes}) {
        wait_part_completion($part_node, $upstream_node);
    }
}

# Stop all nodes passed. Trivial wrapper around PostgresNode::stop
#
# Thread safe.
sub stop_nodes {
    my ($stop_nodes, $mode) = @_;

    for my $stop_node (@{$stop_nodes}) {
        $stop_node->stop($mode);
    }
}

# Check node status is 'k' on self and upstream node
# for each parted node
sub check_part_statuses {
    my $part_nodes         = shift;
    my $upstream_node      = shift;
    my $upstream_node_name = $upstream_node->name();

    foreach my $part_node (@$part_nodes) {
        my $part_node_name     = $part_node->name();

        is(
            $upstream_node->safe_psql(
                $bdr_test_dbname,
                "SELECT node_status FROM bdr.bdr_nodes WHERE node_name = '$part_node_name'"
            ),
            'k',
            qq($part_node_name status on upstream node after part is 'k')
        );

        # It is unsafe/incorrect to expect the parted node to know it's parted and
        # have a 'k' state. Sometimes it will, sometimes it won't, it depends on a
        # race between the parting node terminating its connections and it
        # receiving notification of its own parting. That's a bit of a wart in BDR,
        # but won't be fixed in 2.0 and is actually very hard to truly "fix" in a
        # distributed system. So we allow the local node status to be 'k' or 'r'.
        #
        like(
            $part_node->safe_psql(
                $bdr_test_dbname,
                "SELECT node_status FROM bdr.bdr_nodes WHERE node_name = '$part_node_name'"
            ),
            qr/^(k|r)$/,
            qq($part_node_name status on local node after part is 'k' or 'r')
        );

        # The downstream's slot on the upstream MUST be gone
        is(
            $upstream_node->safe_psql($bdr_test_dbname, qq[SELECT EXISTS (SELECT 1 FROM bdr.bdr_node_slots WHERE node_name = '$part_node_name')]),
            'f',
            qq(replication slot for $part_node_name on $upstream_node_name has been removed)
        );

        # The upstream's slot on the downstream MAY be gone, or may be present, so
        # there's no point checking. But the upstream's connection to the downstream
        # MUST be gone, so we can look for the apply worker's connection.
        is(
            $part_node->safe_psql($bdr_test_dbname, qq[SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE application_name = '$upstream_node_name:send')]),
            'f',
            qq(replication connection for $upstream_node_name on $part_node_name is gone)
        );
    }
}

# Shorthand for part_nodes(), check_part_statuses(), stop_nodes()
sub part_and_check_nodes {
    my ($part_nodes, $upstream_node) = @_;
    part_nodes($part_nodes, $upstream_node);
    check_part_statuses($part_nodes, $upstream_node);
    stop_nodes($part_nodes);
}

# 
# Remove the bdr.bdr_nodes entry for a parted node, so that its node name may
# be re-used.  The node must already be marked as parted.
#
sub delete_parted_node_from_catalog {
    my ($parted_node, $upstream_node) = @_;
    my $part_node_name     = $parted_node->name();
    my $upstream_node_name = $upstream_node->name();

    my $deleted = $upstream_node->safe_psql( $bdr_test_dbname,
        "DELETE FROM bdr.bdr_nodes WHERE node_name = '$part_node_name' and node_status = 'k' returning 1"
    );

    if ($deleted ne '1') {
        BAIL_OUT("attempt to delete bdr.bdr_nodes row for $part_node_name from $upstream_node_name failed, node not found or status <> k");
    }
}

# Execute the specified DDL string on the BDR test DB using bdr.bdr_replicate_ddl_command
#
# Threadsafe.
sub exec_ddl {
    my ($node, $ddl_string) = @_;

    $node->safe_psql($bdr_test_dbname, qq{
        SELECT bdr.bdr_replicate_ddl_command(\$DDL\$ $ddl_string \$DDL\$);
    });
}

# Invoke pg_isready and return result. 0 is success/ready.
#
# Threadsafe.
sub node_isready {
    my $node = shift;
    IPC::Run::run([
        'pg_isready', '-d', $node->connstr('postgres')
        ]);
    return $?;
}

# Wait until pg_isready says a node is up or timeout (if supplied) exceeded. Returns
# 0 on timeout, 1 on success.
#
# Threadsafe.
sub wait_for_pg_isready {
    my ($node, $maxwait) = @_;

    my $waited = 0;
    my $wait_secs = 0.5;
    while (1) {
        my $ret = node_isready($node);
        last if $ret == 0;
        sleep($wait_secs);
        $waited += $wait_secs;
        if ($maxwait && ($waited > $maxwait))
        {
            diag "gave up waiting for node " . $node->name . " to become ready after $maxwait seconds, last result was $ret";
            return 0;
        }
    };

    return 1;
}

# Print out bdr.bdr_nodes status info for a node
#
# Threadsafe(ish)?
sub dump_nodes_statuses {
    my $node = shift;
    note "Nodes table from " . $node->name . " is:\n" . $node->safe_psql('bdr_test', q[select node_name, node_status from bdr.bdr_nodes]) . "\n";
}

# Create a dummy table on a node, with single field 'id'.
#
# Threadsafe.
sub create_table {
    my ($node, $table_name) = @_;
    exec_ddl($node,qq{ CREATE TABLE public.$table_name( id integer primary key);});
}

# Check that no slots or nodes entries are created for failed join on peer
# nodes.
#
sub check_joinfail_status {
    my ($join_node, $join_node_sysid, $join_node_timeline, @peer_nodes) = @_;
    my $join_node_name = $join_node->name();

#   die "join node sysid and timeline must be passed"
#       unless ($join_node_sysid and $join_node_timeline);
#
#   die "join node sysid and timeline must be scalars"
#       if (ref $join_node_sysid || ref $join_node_timeline);

    foreach my $node (@peer_nodes){
        is($node->safe_psql($bdr_test_dbname, "SELECT node_status FROM bdr.bdr_nodes WHERE node_name = '$join_node_name'"), '', "no nodes entry on ". $node->name() . " from " . $join_node_name . " after failed join" );
    }
    my ($sysid, $timeline, $dboid);
    eval {
         ($sysid, $timeline, $dboid) = split(qr/\|/, $join_node->safe_psql($bdr_test_dbname, 'SELECT * FROM bdr.bdr_get_local_nodeid()'));
    };
    if ($@) {
        die("couldn't query joining node for its sysid and timeline: $@");
    }
    foreach my $node (@peer_nodes) {
        my $slotname = $node->safe_psql($bdr_test_dbname, qq[SELECT bdr.bdr_format_slot_name('$sysid', '$timeline', '$dboid', '');]);
        is($node->slot($slotname)->{'slot_name'}, '', "slot for " . $join_node_name . " not created on peer node " . $node->name)
            or diag "slot name is $slotname";
        
    }
}

# Wait until a peer has caught up
sub wait_for_apply {
    my ($self, $peer) = @_;
    # On node <self>, wait until the send pointer on the replication slot with
    # application_name "<peer>:send" to passes the xlog flush position on node
    # <self> at the time of this call.
    my $lsn = $self->lsn('flush');
    die('no lsn to catch up to') if !defined $lsn;
    $self->wait_for_catchup($peer->name . ":send", 'replay', $lsn);
}

# Acquire a global ddl lock on $node in $mode using a background
# psql session and return the IPC::Run handle for the session
# along with a hash its stdin, stdout and stderr handles.
#
# $timer, if supplied, may be an IPC::Run::Timer or IPC::Run::Timeout
# object to time-limit the acquisition attempt. Timeouts die() on expiry,
# timers must be passed to wait_acquire_ddl_lock.
sub start_acquire_ddl_lock {
    my ($node, $mode, $timer) = @_;
    my ($psql_stdout, $psql_stderr) = ('','');

    my $psql_stdin = qq[
BEGIN;
SELECT pg_backend_pid() || '=pid';
SELECT 'acquired' FROM bdr.acquire_global_lock('$mode');
];

    my $psql = IPC::Run::start(
        ['psql', '-qAtX', '-d', $node->connstr($bdr_test_dbname), '-f', '-'],
        '<', \$psql_stdin, '>', \$psql_stdout, '2>', \$psql_stderr,
        $timer);

    $psql->pump until $psql_stdout =~ qr/([[:digit:]]+)=pid/;

    my $backend_pid = $1;
    print("pid of backend acquiring ddl lock is $backend_pid\n");

    # Acquire should be in progress or finished
    if ($node->safe_psql($bdr_test_dbname, qq[SELECT 1 FROM pg_stat_activity WHERE query LIKE '%bdr.acquire_global_lock%' AND pid = $backend_pid;]) ne '1')
    {
        croak("cannot find expected query   SELECT 'acquired' FROM bdr.acquire_global_lock...   in pg_stat_activity\n");
    }

	$node->poll_query_until($bdr_test_dbname, q[SELECT lock_state <> 'nolock' FROM bdr.bdr_locks]);

    my $status = $node->safe_psql($bdr_test_dbname, q[SELECT lock_state, lock_mode, owner_is_my_node, owner_is_my_backend FROM bdr.bdr_locks]);
	if (not ($status =~ qr/(?:acquire_acquired|acquire_tally_confirmations)\|$mode\|t\|f/))
	{
		croak("expected lock info (acquire_acquired|acquire_tally_confirmations)|$mode|t|f, got $status");
	}

	print("lock acquire in progress...\n");

    return {
        handle => $psql,
        stdin => \$psql_stdin,
        stdout => \$psql_stdout,
        stderr => \$psql_stderr,
        node => $node,
        backend_pid => $backend_pid,
        mode => $mode
    };
}

# Wait to acquire global ddl lock on handle supplied by start_acquire_ddl_lock.
#
# By default waits forever (or until timeout supplied at start),
# and dies if acquisition fails.
#
sub wait_acquire_ddl_lock {
    my ($psql, $timer, $no_error_die) = @_;
    my $success = 1;

    do {
        $psql->{'handle'}->pump;
        last if defined($timer) && $timer->is_expired;
    }
    until (${$psql->{'stdout'}} =~ 'acquired' or ${$psql->{'stderr'}} =~ 'ERROR' or !$psql->{'handle'}->pumpable);

    print("acquired or failed\n");

    if (${$psql->{stderr}} =~ 'ERROR')
    {
        ${$psql->{stdin}} .= "\\q\n";
        $psql->{handle}->pump;
        $psql->{handle}->kill_kill;
        croak("could not acquire global ddl lock in mode " . $psql->{mode} . " on " . $psql->{node}->name . ": " . ${$psql->{stderr}})
            unless($no_error_die);
    }

	# TODO: double check against bdr.bdr_locks
    return ${$psql->{'stdout'}} =~ 'acquired';
}

sub cancel_ddl_lock {
    my $psql = shift;
    $psql->{node}->safe_psql($bdr_test_dbname, "SELECT pg_terminate_backend(" . $psql->{backend_pid} . ")");
}

sub release_ddl_lock {
    my $psql = shift;

    ${$psql->{stdin}} .= "ROLLBACK;\n\\echo ROLLBACK\n\\q";
    $psql->{handle}->finish;
}

1;
