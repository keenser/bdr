\c postgres
-- create nonexistant extension
CREATE EXTENSION pg_trgm;
SELECT bdr.wait_slot_confirm_lsn(NULL,NULL);
\c regression
\dx pg_trgm

-- drop and recreate using CINE
DROP EXTENSION pg_trgm;
SELECT bdr.wait_slot_confirm_lsn(NULL,NULL);
\c postgres
\dx pg_trgm
CREATE EXTENSION IF NOT EXISTS pg_trgm;
SELECT bdr.wait_slot_confirm_lsn(NULL,NULL);
\c regression
\dx pg_trgm

-- CINE existing extension
CREATE EXTENSION IF NOT EXISTS pg_trgm;
SELECT bdr.wait_slot_confirm_lsn(NULL,NULL);
\c postgres
\dx pg_trgm

DROP EXTENSION pg_trgm;
