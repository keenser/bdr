\c postgres
SELECT bdr.bdr_replicate_ddl_command($DDL$ 
CREATE VIEW public.list_extension AS 
SELECT e.extname AS "Name",  n.nspname AS "Schema", c.description AS "Description"
FROM pg_catalog.pg_extension e LEFT JOIN pg_catalog.pg_namespace n ON n.oid = e.extnamespace LEFT JOIN pg_catalog.pg_description c ON c.objoid = e.oid AND c.classoid = 'pg_catalog.pg_extension'::pg_catalog.regclass
WHERE e.extname ~ '^(pg_trgm)$'
ORDER BY 1;
$DDL$);

-- create nonexistant extension
SELECT bdr.bdr_replicate_ddl_command($DDL$ CREATE EXTENSION pg_trgm SCHEMA public; $DDL$);
SELECT pg_xlog_wait_remote_apply(pg_current_xlog_location(), pid) FROM pg_stat_replication;
\c regression
SELECT * from list_extension; 

-- drop and recreate using CINE
SELECT bdr.bdr_replicate_ddl_command($DDL$ DROP EXTENSION pg_trgm; $DDL$);
SELECT pg_xlog_wait_remote_apply(pg_current_xlog_location(), pid) FROM pg_stat_replication;
\c postgres
SELECT * from list_extension; 

SELECT bdr.bdr_replicate_ddl_command($DDL$ CREATE EXTENSION IF NOT EXISTS pg_trgm SCHEMA public; $DDL$);
SELECT pg_xlog_wait_remote_apply(pg_current_xlog_location(), pid) FROM pg_stat_replication;
\c regression
SELECT * from list_extension; 

-- CINE existing extension
\set VERBOSITY terse
SELECT bdr.bdr_replicate_ddl_command($DDL$ CREATE EXTENSION IF NOT EXISTS pg_trgm SCHEMA public; $DDL$);
\set VERBOSITY default
SELECT pg_xlog_wait_remote_apply(pg_current_xlog_location(), pid) FROM pg_stat_replication;
\c postgres
SELECT * from list_extension; 

SELECT bdr.bdr_replicate_ddl_command($DDL$ DROP EXTENSION pg_trgm; $DDL$);
SELECT bdr.bdr_replicate_ddl_command($DDL$ DROP VIEW public.list_extension; $DDL$);
