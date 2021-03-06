/*
 * Tests to ensure that objects/data that exists pre-clone is successfully
 * cloned. The results are checked, after the clone, in preseed_check.sql.
 */

SELECT current_setting('bdrtest.origdb') AS origdb
\gset
\c :origdb

DO $DO$BEGIN
IF bdr.have_global_sequences() THEN
    SET default_sequenceam = local;
END IF;
END; $DO$;

CREATE SEQUENCE some_local_seq;
CREATE TABLE some_local_tbl(id serial primary key, key text unique not null, to_be_dropped int, data text);
ALTER TABLE some_local_tbl DROP COLUMN to_be_dropped;
INSERT INTO some_local_tbl(key, data) VALUES('key1', 'data1');
INSERT INTO some_local_tbl(key, data) VALUES('key2', NULL);
INSERT INTO some_local_tbl(key, data) VALUES('key3', 'data3');
