-- test for RT-#37869
SELECT bdr.bdr_replicate_ddl_command($DDL$ 
CREATE TABLE public.add_column (
    id serial primary key,
    data text
);
$DDL$);

INSERT INTO add_column (data) SELECT generate_series(1,100,10);

SELECT bdr.bdr_replicate_ddl_command($DDL$ ALTER TABLE public.add_column ADD COLUMN other varchar(100); $DDL$);

SELECT pg_xlog_wait_remote_apply(pg_current_xlog_location(), pid) FROM pg_stat_replication;
\c postgres
SELECT id, data, other FROM add_column ORDER BY id;

UPDATE add_column SET other = 'foobar'; 

SELECT pg_xlog_wait_remote_apply(pg_current_xlog_location(), pid) FROM pg_stat_replication;
\c regression
SELECT id, data, other FROM add_column ORDER BY id;

SELECT bdr.bdr_replicate_ddl_command($DDL$ 
DROP TABLE public.add_column
$DDL$);
