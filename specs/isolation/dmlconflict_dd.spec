conninfo "node1" "dbname=node1"
conninfo "node2" "dbname=node2"
conninfo "node3" "dbname=node3"

setup
{
	BEGIN;
    SET LOCAL bdr.permit_ddl_locking = true;
	CREATE TABLE test_dmlconflict(a text, b int primary key, c text);
	INSERT INTO test_dmlconflict VALUES('x', 1, 'foo');
	COMMIT;
	SELECT bdr.wait_slot_confirm_lsn(NULL,NULL);
}

teardown
{
    SET bdr.permit_ddl_locking = true;
	DROP TABLE test_dmlconflict;
}


session "snode1"
connection "node1"
setup { TRUNCATE bdr.bdr_conflict_history; }
step "s1i" { DELETE FROM test_dmlconflict; }
step "s1w" { SELECT bdr.wait_slot_confirm_lsn(NULL,NULL); }
step "s1s" { SELECT * FROM test_dmlconflict; }
step "s1h" { SELECT object_schema, object_name, conflict_type, conflict_resolution, local_tuple, remote_tuple, error_sqlstate FROM bdr.bdr_conflict_history ORDER BY conflict_id; }

session "snode2"
connection "node2"
setup { TRUNCATE bdr.bdr_conflict_history; }
step "s2i" { DELETE FROM test_dmlconflict; }
step "s2w" { SELECT bdr.wait_slot_confirm_lsn(NULL,NULL); }
step "s2s" { SELECT * FROM test_dmlconflict; }
step "s2h" { SELECT object_schema, object_name, conflict_type, conflict_resolution, local_tuple, remote_tuple, error_sqlstate FROM bdr.bdr_conflict_history ORDER BY conflict_id; }

session "snode3"
connection "node3"
setup { TRUNCATE bdr.bdr_conflict_history; }
step "s3i" { DELETE FROM test_dmlconflict; }
step "s3w" { SELECT bdr.wait_slot_confirm_lsn(NULL,NULL); }
step "s3s" { SELECT * FROM test_dmlconflict; }
step "s3h" { SELECT object_schema, object_name, conflict_type, conflict_resolution, local_tuple, remote_tuple, error_sqlstate FROM bdr.bdr_conflict_history ORDER BY conflict_id; }

permutation "s1i" "s2i" "s3i" "s1w" "s2w" "s3w" "s1s" "s2s" "s3s" "s1h" "s2h" "s3h"
