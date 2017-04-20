/* -------------------------------------------------------------------------
 *
 * bdr_ddlrep.c
 *      DDL replication
 *
 * Copyright (C) 2012-2015, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *      bdr_ddlrep.c
 *
 * -------------------------------------------------------------------------
 */

#include "postgres.h"

#include "bdr.h"

#include "access/xlog_fn.h"

#include "catalog/catalog.h"
#include "catalog/namespace.h"

#include "executor/executor.h"

#include "miscadmin.h"

#include "replication/origin.h"

#include "nodes/makefuncs.h"

#include "storage/lmgr.h"

#include "utils/builtins.h"
#include "utils/guc.h"
#include "utils/lsyscache.h"

bool in_bdr_replicate_ddl_command = false;

PGDLLEXPORT Datum bdr_replicate_ddl_command(PG_FUNCTION_ARGS);
PG_FUNCTION_INFO_V1(bdr_replicate_ddl_command);

/*
 * bdr_queue_ddl_command
 *
 * Insert DDL command into the bdr.bdr_queued_commands table.
 */
void
bdr_queue_ddl_command(const char *command_tag, const char *command, const char *search_path)
{
	EState		   *estate;
	TupleTableSlot *slot;
	RangeVar	   *rv;
	Relation		queuedcmds;
	HeapTuple		newtup = NULL;
	Datum			values[6];
	bool			nulls[6];

	elog(DEBUG2, "node %s enqueuing DDL command \"%s\" "
		 "with search_path \"%s\"",
		 bdr_local_node_name(), command,
		 search_path == NULL ? "" : search_path);

	if (search_path == NULL)
		search_path = "";

	/* prepare bdr.bdr_queued_commands for insert */
	rv = makeRangeVar("bdr", "bdr_queued_commands", -1);
	queuedcmds = heap_openrv(rv, RowExclusiveLock);
	slot = MakeSingleTupleTableSlot(RelationGetDescr(queuedcmds));
	estate = bdr_create_rel_estate(queuedcmds);
	ExecOpenIndices(estate->es_result_relation_info, false);

	/* lsn, queued_at, perpetrator, command_tag, command */
	MemSet(nulls, 0, sizeof(nulls));
	values[0] = pg_current_xlog_location(NULL);
	values[1] = now(NULL);
	values[2] = PointerGetDatum(cstring_to_text(GetUserNameFromId(GetUserId(), false)));
	values[3] = CStringGetTextDatum(command_tag);
	values[4] = CStringGetTextDatum(command);
	values[5] = CStringGetTextDatum(search_path);

	newtup = heap_form_tuple(RelationGetDescr(queuedcmds), values, nulls);
	simple_heap_insert(queuedcmds, newtup);
	ExecStoreTuple(newtup, slot, InvalidBuffer, false);
	UserTableUpdateOpenIndexes(estate, slot);

	ExecCloseIndices(estate->es_result_relation_info);
	ExecDropSingleTupleTableSlot(slot);
	heap_close(queuedcmds, RowExclusiveLock);
}

/*
 * bdr_replicate_ddl_command
 *
 * Queues the input SQL for replication.
 *
 * Note that we don't allow CONCURRENTLY commands here, this is mainly because
 * we queue command before we actually execute it, which we currently need
 * to make the bdr_truncate_trigger_add work correctly. As written there
 * the in_bdr_replicate_ddl_command concept is ugly.
 */
Datum
bdr_replicate_ddl_command(PG_FUNCTION_ARGS)
{
	text    *command = PG_GETARG_TEXT_PP(0);
	char    *query = text_to_cstring(command);
	int		nestlevel = -1;

	nestlevel = NewGUCNestLevel();

    /* Force everything in the query to be fully qualified. */
	(void) set_config_option("search_path", "",
							 PGC_USERSET, PGC_S_SESSION,
							 GUC_ACTION_SAVE, true, 0
#if PG_VERSION_NUM >= 90500
							 , false
#endif
							 );

	/* Execute the query locally. */
	in_bdr_replicate_ddl_command = true;

	PG_TRY();
	{
		/* Queue the query for replication. */
		bdr_queue_ddl_command("SQL", query, NULL);

		/* Execute the query locally. */
		bdr_execute_ddl_command(query, GetUserNameFromId(GetUserId(), false), "" /*search_path*/, false);
	}
	PG_CATCH();
	{
		if (nestlevel > 0)
			AtEOXact_GUC(true, nestlevel);
		in_bdr_replicate_ddl_command = false;
		PG_RE_THROW();
	}
	PG_END_TRY();

	if (nestlevel > 0)
		AtEOXact_GUC(true, nestlevel);
	in_bdr_replicate_ddl_command = false;
	PG_RETURN_VOID();
}
