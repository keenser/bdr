-- Verify data from preseed.sql has correctly been cloned
\c regression
\d some_local_tbl
INSERT INTO some_local_tbl(key, data) VALUES('key4', 'data4');
SELECT * FROM some_local_tbl ORDER BY id;
SELECT bdr.wait_slot_confirm_lsn(NULL,NULL);

\c postgres
\d some_local_tbl
SELECT * FROM some_local_tbl ORDER BY id;
