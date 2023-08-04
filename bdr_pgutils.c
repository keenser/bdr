/*-------------------------------------------------------------------------
 *
 * bdr_pgutils.c
 *		This files is used as common place for function that we took
 *		verbatim from PostgreSQL because they are declared as static and
 *		we can't use them as API.
 *		Also the internal API function that use those static functions
 *		be defined here and should start with bdr_ prefix.
 *
 * Portions Copyright (c) 1996-2015, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 *
 * IDENTIFICATION
 *	  bdr_pgutils.c
 *
 *-------------------------------------------------------------------------
 */

#ifndef FRONTEND
#include "postgres.h"
#else
#include "postgres_fe.h"
#endif

#include <sys/stat.h>
#include <unistd.h>

#include "access/xlogdefs.h"
#include "nodes/pg_list.h"

#include "bdr_internal.h"

#ifndef FRONTEND
#define log_error4(str, param, arg1)	elog(LOG, str, param, arg1)
#else
#define log_error4(str, param, arg1)	(fprintf(stderr, str, param, arg1), fputc('\n', stderr))
#endif

/*
 * Find another program in our binary's directory,
 * then make sure it is the proper version.
 *
 * BDR modified version - returns computed major version number
 */
int
bdr_find_other_exec(const char *argv0, const char *target,
					uint32 *version, char *retpath)
{
	char		cmd[MAXPGPATH];
	char		line[100];
	int			pre_dot,
				post_dot;

	if (find_my_exec(argv0, retpath) < 0)
		return -1;

	/* Trim off program name and keep just directory */
	*last_dir_separator(retpath) = '\0';
	canonicalize_path(retpath);

	/* Now append the other program's name */
	snprintf(retpath + strlen(retpath), MAXPGPATH - strlen(retpath),
			 "/%s%s", target, EXE);

	if (validate_exec(retpath) != 0)
		return -1;

	snprintf(cmd, sizeof(cmd), "\"%s\" -V", retpath);

	if (!pipe_read_line(cmd, line, sizeof(line)))
		return -1;

	if (sscanf(line, "%*s %*s %d.%d", &pre_dot, &post_dot) != 2)
		return -2;

	*version = (pre_dot * 100 + post_dot) * 100;

	return 0;
}


/*
 * End function taken from src/common/exec.c
 */
