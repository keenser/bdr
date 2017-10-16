SET bdr.permit_unsafe_ddl_commands = true;
SET bdr.skip_ddl_replication = true;
SET LOCAL search_path = bdr;

CREATE FUNCTION
bdr.wait_slot_confirm_lsn(slotname name, target pg_lsn)
RETURNS void LANGUAGE c AS 'bdr','bdr_wait_slot_confirm_lsn';

COMMENT ON FUNCTION bdr.wait_slot_confirm_lsn(name,pg_lsn) IS
'wait until slotname (or all slots, if null) has passed specified lsn (or current lsn, if null)';

ALTER TABLE bdr.bdr_conflict_history
ADD COLUMN local_commit_time   timestamptz;

COMMENT ON COLUMN bdr_conflict_history.local_commit_time IS
'The time the local transaction involved in this conflict committed';

RESET bdr.permit_unsafe_ddl_commands;
RESET bdr.skip_ddl_replication;
RESET search_path;
