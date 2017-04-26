#!/usr/bin/perl
#
# Test global sequences with various parameter settings 
#
use strict;
use warnings;
use lib 't/';
use Cwd;
use Config;
use PostgresNode;
use TestLib;
use Test::More tests => 3;
use utils::nodemanagement;


# Create an upstream node and bring up bdr
my $node_a = get_new_node('node_a');
initandstart_bdr_group($node_a);
my ($ret, $stdout, $stderr);

# Create global sequence
exec_ddl( $node_a, qq{CREATE SEQUENCE public.test_seq;} );
exec_ddl( $node_a, qq{ALTER SEQUENCE public.test_seq MINVALUE -10;} );
exec_ddl( $node_a, qq{ALTER SEQUENCE public.test_seq  INCREMENT BY -1;} );

# Try nextval on the sequence
TODO: {
   todo_skip 'Assertion failure on bdr.global_seq_nextval', 1;
   ($ret, $stdout, $stderr) = $node_a->safe_psql($bdr_test_dbname, 
   qq{ SELECT bdr.global_seq_nextval('test_seq'::regclass) FROM generate_series(1,3::bigint); });
   like($stderr, qr/ERROR:  nextval: reached minimum value of sequence/, "psql error message for nextval reaching minvalue");
}

# alter global sequence for positive increment and set a max value.
# psql should error out on reaching maxvalue
exec_ddl( $node_a, qq{ALTER SEQUENCE public.test_seq NO MINVALUE;} );
exec_ddl( $node_a, qq{ALTER SEQUENCE public.test_seq  INCREMENT BY 2;} );
exec_ddl( $node_a, qq{ALTER SEQUENCE public.test_seq MAXVALUE 3;} );
exec_ddl( $node_a, qq{ALTER SEQUENCE public.test_seq RESTART;} );

($ret, $stdout, $stderr) = $node_a->psql($bdr_test_dbname,
qq{ SELECT bdr.global_seq_nextval('test_seq'::regclass) FROM generate_series(1,3::bigint); });
like($stderr, qr/ERROR:  nextval: reached maximum value of sequence/, "psql error message for nextval reaching maxvalue");


# Now make is_cycled true and try nextval to cross maxvalue

exec_ddl( $node_a, qq{ALTER SEQUENCE public.test_seq RESTART;} );
exec_ddl( $node_a, qq{ALTER SEQUENCE public.test_seq CYCLE;} );

TODO: {
	todo_skip 'Assertion failure on bdr.global_seq_nextval', 1;
    ($ret, $stdout, $stderr) = $node_a->safe_psql($bdr_test_dbname,
    qq{ SELECT bdr.global_seq_nextval('test_seq'::regclass) FROM generate_series(1,3::bigint); });
    like($stderr, qr/ERROR:  nextval: reached maximum value of sequence/, "psql error message for nextval reaching maxvalue");
}
