SELECT bdr.bdr_replicate_ddl_command($DDL$ ALTER DATABASE regression RESET bdr.permit_ddl_locking; $DDL$);
SELECT bdr.bdr_replicate_ddl_command($DDL$ ALTER DATABASE postgres RESET bdr.permit_ddl_locking; $DDL$);
