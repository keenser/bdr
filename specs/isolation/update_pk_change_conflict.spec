# test conflict handling on primary key changes
conninfo "node1" "dbname=node1"
conninfo "node2" "dbname=node2"
conninfo "node3" "dbname=node3"

setup
{
 SET bdr.permit_ddl_locking = true;
 CREATE TABLE tst (a INTEGER PRIMARY KEY, b TEXT);
 INSERT INTO tst (a, b) VALUES (1, 'one');
}

teardown
{
 SET bdr.permit_ddl_locking = true;
 DROP TABLE tst;
}

session "s1"
connection "node1"
step "n1read" { SELECT * FROM tst; }
step "n1sync" { SELECT bdr.wait_slot_confirm_lsn(NULL,NULL); }
step "n1s1" { UPDATE tst SET a = 2; }
step "n1s2" { BEGIN; }
step "n1s3" { UPDATE tst SET a = 4; }
step "n1s4" { COMMIT; }

session "s2"
connection "node2"
step "n2read" { SELECT * FROM tst; }
step "n2sync" { SELECT bdr.wait_slot_confirm_lsn(NULL,NULL); }
step "n2s1" { UPDATE tst SET a = 3; }
step "n2s2" { BEGIN; }
step "n2s3" { UPDATE tst SET a = 5; }
step "n2s4" { COMMIT; }

session "s3"
connection "node3"
step "n3read" { SELECT * FROM tst; }
step "n3sync" { SELECT bdr.wait_slot_confirm_lsn(NULL,NULL); }

permutation "n1sync" "n1s1" "n1sync" "n3read" "n2s1" "n2sync" "n3read" "n1s2" "n2s2" "n1s3" "n2s3" "n1s4" "n2s4" "n1sync" "n2sync" "n1read" "n2read" "n3read"
