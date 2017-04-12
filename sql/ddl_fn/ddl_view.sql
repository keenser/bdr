\c postgres

SELECT bdr.bdr_replicate_ddl_command($DDL$ CREATE TABLE public.test_src_tbl(a serial, b varchar(100), c date, primary key (a,c)); $DDL$);
SELECT bdr.bdr_replicate_ddl_command($DDL$ CREATE VIEW public.test_view AS SELECT * FROM public.test_src_tbl WHERE a > 1; $DDL$);
SELECT pg_xlog_wait_remote_apply(pg_current_xlog_location(), pid) FROM pg_stat_replication;
\d+ test_view
\c regression
\d+ test_view
SELECT * FROM test_view;

INSERT INTO test_src_tbl (b,c) VALUES('a', '2014-01-01'), ('b', '2014-02-02'), ('c', '2014-03-03');
SELECT pg_xlog_wait_remote_apply(pg_current_xlog_location(), pid) FROM pg_stat_replication;
\c postgres
SELECT * FROM test_view;

UPDATE test_view SET b = a || b;
SELECT pg_xlog_wait_remote_apply(pg_current_xlog_location(), pid) FROM pg_stat_replication;
\c regression
SELECT * FROM test_src_tbl;
SELECT * FROM test_view;

SELECT bdr.bdr_replicate_ddl_command($DDL$ ALTER VIEW public.test_view  ALTER COLUMN c SET DEFAULT '2000-01-01'; $DDL$);
INSERT INTO test_view(b) VALUES('y2k');
SELECT pg_xlog_wait_remote_apply(pg_current_xlog_location(), pid) FROM pg_stat_replication;
\c postgres
SELECT * FROM test_src_tbl;
SELECT * FROM test_view;

SELECT bdr.bdr_replicate_ddl_command($DDL$ ALTER VIEW public.test_view RENAME TO renamed_test_view; $DDL$);
SELECT pg_xlog_wait_remote_apply(pg_current_xlog_location(), pid) FROM pg_stat_replication;
\c regression
INSERT INTO renamed_test_view(b) VALUES('d');
SELECT pg_xlog_wait_remote_apply(pg_current_xlog_location(), pid) FROM pg_stat_replication;
\c postgres
SELECT * FROM test_src_tbl;
SELECT * FROM renamed_test_view;

SELECT bdr.bdr_replicate_ddl_command($DDL$ DROP VIEW public.renamed_test_view; $DDL$);
SELECT pg_xlog_wait_remote_apply(pg_current_xlog_location(), pid) FROM pg_stat_replication;
\d renamed_test_view
\c regression
\d renamed_test_view

SELECT bdr.bdr_replicate_ddl_command($DDL$ CREATE VIEW public.test_view AS SELECT * FROM public.test_src_tbl; $DDL$);
\set VERBOSITY terse
SELECT bdr.bdr_replicate_ddl_command($DDL$ DROP TABLE public.test_src_tbl CASCADE; $DDL$);
SELECT pg_xlog_wait_remote_apply(pg_current_xlog_location(), pid) FROM pg_stat_replication;

\d test_view
\c postgres
\d test_view
