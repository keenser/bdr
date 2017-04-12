SET bdr.permit_ddl_locking = false;
SELECT bdr.bdr_replicate_ddl_command($DDL$ CREATE TABLE public.should_fail ( id integer ) $DDL$);

SET bdr.permit_ddl_locking = true;
SELECT bdr.bdr_replicate_ddl_command($DDL$ CREATE TABLE public.create_ok (id integer) $DDL$);

SET bdr.permit_ddl_locking = false;
SELECT bdr.bdr_replicate_ddl_command($DDL$ ALTER TABLE public.create_ok ADD COLUMN alter_should_fail text $DDL$);

SET bdr.permit_ddl_locking = true;
SELECT bdr.bdr_replicate_ddl_command($DDL$ DROP TABLE public.create_ok $DDL$);

-- Now for the rest of the DDL tests, presume they're allowed,
-- otherwise they'll get pointlessly verbose.
SELECT bdr.bdr_replicate_ddl_command($DDL$ ALTER DATABASE regression SET bdr.permit_ddl_locking = true $DDL$);
SELECT bdr.bdr_replicate_ddl_command($DDL$ ALTER DATABASE postgres SET bdr.permit_ddl_locking = true $DDL$);
