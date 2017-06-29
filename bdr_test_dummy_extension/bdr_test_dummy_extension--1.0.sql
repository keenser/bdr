CREATE SCHEMA bdr_test_dummy_extension;

SET search_path = bdr_test_dummy_extension;

CREATE TABLE test_extension_table(
    dummy integer
);

INSERT INTO test_extension_table (dummy) VALUES (1);
