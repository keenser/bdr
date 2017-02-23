use strict;
use warnings;
use Cwd;
use Config;
use PostgresNode;
use TestLib;
use Test::More tests => 3;
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
