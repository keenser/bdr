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
 * Start function taken from src/common/exec.c
 */

static int	validate_exec(const char *path);

/*
 * validate_exec -- validate "path" as an executable file
 *
 * returns 0 if the file is found and no error is encountered.
 *		  -1 if the regular file "path" does not exist or cannot be executed.
 *		  -2 if the file is otherwise valid but cannot be read.
 */
static int
validate_exec(const char *path)
{
	struct stat buf;
	int			is_r;
	int			is_x;

#ifdef WIN32
	char		path_exe[MAXPGPATH + sizeof(".exe") - 1];

	/* Win32 requires a .exe suffix for stat() */
	if (strlen(path) >= strlen(".exe") &&
		pg_strcasecmp(path + strlen(path) - strlen(".exe"), ".exe") != 0)
	{
		strlcpy(path_exe, path, sizeof(path_exe) - 4);
		strcat(path_exe, ".exe");
		path = path_exe;
	}
#endif

	/*
	 * Ensure that the file exists and is a regular file.
	 *
	 * XXX if you have a broken system where stat() looks at the symlink
	 * instead of the underlying file, you lose.
	 */
	if (stat(path, &buf) < 0)
		return -1;

	if (!S_ISREG(buf.st_mode))
		return -1;

	/*
	 * Ensure that the file is both executable and readable (required for
	 * dynamic loading).
	 */
#ifndef WIN32
	is_r = (access(path, R_OK) == 0);
	is_x = (access(path, X_OK) == 0);
#else
	is_r = buf.st_mode & S_IRUSR;
	is_x = buf.st_mode & S_IXUSR;
#endif
	return is_x ? (is_r ? 0 : -2) : -1;
}


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
