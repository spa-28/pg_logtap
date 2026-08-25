/* hookchain: emit_log_hook interop probe for pg_logtap's e2e suite.
 *
 * Counts hook invocations per backend and chains to the previous hook —
 * exactly the discipline pg_logtap follows. Preloaded BEFORE pg_logtap
 * (shared_preload_libraries = 'hookchain,pg_logtap'), it ends up as
 * pg_logtap's prev_hook: every captured event must pass through here
 * first, proving pg_logtap forwards to previously-installed hooks instead
 * of silently replacing them (PROBLEMS.md B1). hookchain_count() reads the
 * process-local counter, so it must be called in the session that logged.
 */
#include "postgres.h"
#include "fmgr.h"
#include "utils/elog.h"

PG_MODULE_MAGIC;

static emit_log_hook_type prev_hook = NULL;
static int hook_calls = 0;

static void count_hook(ErrorData *edata);

void _PG_init(void);

void
_PG_init(void)
{
	prev_hook = emit_log_hook;
	emit_log_hook = count_hook;
}

static void
count_hook(ErrorData *edata)
{
	hook_calls++;
	if (prev_hook)
		prev_hook(edata);
}

PG_FUNCTION_INFO_V1(hookchain_count);

Datum
hookchain_count(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT32(hook_calls);
}
