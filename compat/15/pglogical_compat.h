#ifndef PG_LOGICAL_COMPAT_H
#define PG_LOGICAL_COMPAT_H

//extern TimeLineID ThisTimeLineID;
#define ThisTimeLineID GetWALInsertionTimeLine()

#define CreateCommandTag(raw_parsetree) \
		CreateCommandTag(raw_parsetree->stmt)

#define PGLstandard_ProcessUtility(pstmt, queryString, readOnlyTree, context, params, queryEnv, dest, sentToRemote, qc) \
		standard_ProcessUtility(pstmt, queryString, readOnlyTree, context, params, queryEnv, dest, qc)

#define PGLnext_ProcessUtility_hook(pstmt, queryString, readOnlyTree, context, params, queryEnv, dest, sentToRemote, qc) \
		next_ProcessUtility_hook(pstmt, queryString, readOnlyTree, context, params, queryEnv, dest, qc)

#define pg_analyze_and_rewrite(parsetree, query_string, paramTypes, numParams) \
		pg_analyze_and_rewrite_fixedparams(parsetree, query_string, paramTypes, numParams, NULL)

#define getObjectDescription(object) getObjectDescription(object, false)

#define GetFlushRecPtr() GetFlushRecPtr(NULL)

#endif
