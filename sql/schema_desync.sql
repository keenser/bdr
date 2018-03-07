-- RT#60660

SELECT * FROM public.bdr_regress_variables()
\gset

\c :writedb1

SELECT bdr.bdr_replicate_ddl_command($DDL$
CREATE TABLE public.desync (
   id integer primary key not null,
   n1 integer not null
);
$DDL$);

\d desync

SELECT bdr.wait_slot_confirm_lsn(NULL,NULL);

-- basic builtin datatypes
\c :writedb2

\d desync

\c :writedb1

-- Add a new attribute on this node only
BEGIN;
SET LOCAL bdr.skip_ddl_replication = on;
SET LOCAL bdr.skip_ddl_locking = on;
ALTER TABLE desync ADD COLUMN dropme integer;
COMMIT;

-- Create an natts=3 tuple with null RHS. This should apply fine on the other
-- side, it'll disregard the righthand NULL.
INSERT INTO desync(id, n1, dropme) VALUES (1, 1, NULL);

SELECT * FROM desync ORDER BY id;

-- This must ROLLBACK not ERROR
BEGIN;
SET LOCAL statement_timeout = '2s';
SELECT bdr.acquire_global_lock('ddl_lock');
ROLLBACK;

-- Drop the attribute; we're still natts=3, but one is dropped
BEGIN;
SET LOCAL bdr.skip_ddl_replication = on;
SET LOCAL bdr.skip_ddl_locking = on;
ALTER TABLE desync DROP COLUMN dropme;
COMMIT;

-- create second natts=3 tuple on db1
--
-- This will also apply on the other side, because dropped columns are always
-- sent as nulls.
INSERT INTO desync(id, n1) VALUES (2, 2);

SELECT * FROM desync ORDER BY id;

-- This must ROLLBACK not ERROR
BEGIN;
SET LOCAL statement_timeout = '2s';
SELECT bdr.acquire_global_lock('ddl_lock');
ROLLBACK;

\c :writedb2

-- Both new tuples should've arrived
SELECT * FROM desync ORDER BY id;

-- create natts=2 tuple on db2
--
-- This should apply to writedb1 because we right-pad rows with low natts if
-- the other side col is dropped (or nullable)
INSERT INTO desync(id, n1) VALUES (3, 3);

SELECT bdr.wait_slot_confirm_lsn(NULL,NULL);

-- This must ROLLBACK not ERROR
BEGIN;
SET LOCAL statement_timeout = '10s';
SELECT bdr.acquire_global_lock('ddl_lock');
ROLLBACK;

SELECT * FROM desync ORDER BY id;

-- Make our side confirm to the remote schema again
BEGIN;
SET LOCAL bdr.skip_ddl_replication = on;
SET LOCAL bdr.skip_ddl_locking = on;
ALTER TABLE desync ADD COLUMN dropme integer;
ALTER TABLE desync DROP COLUMN dropme;
COMMIT;

\c :writedb1

-- So now this side should apply too
SELECT bdr.wait_slot_confirm_lsn(NULL,NULL);

-- This must ROLLBACK not ERROR
BEGIN;
SET LOCAL statement_timeout = '10s';
SELECT bdr.acquire_global_lock('ddl_lock');
ROLLBACK;

-- Yay!
SELECT * FROM desync ORDER BY id;

\c :writedb2
-- Yay! Again!
SELECT * FROM desync ORDER BY id;

SELECT bdr.bdr_replicate_ddl_command($DDL$
DROP TABLE public.desync;
$DDL$);
