/* hookchain: PostgreSQL hook interop probe for pg_logtap's e2e suite.
 *
 * Preloaded BEFORE pg_logtap (shared_preload_libraries =
 * 'hookchain,pg_logtap'), it installs emit_log_hook plus both shared-memory
 * hooks. pg_logtap must forward to all three instead of silently replacing
 * them (PROBLEMS.md B1). hookchain_count() reads the process-local log-hook
 * counter, so it must be called in the session that logged.
 *
 * hookchain_arm(true) turns on the hostile mode: every hook invocation also
 * LOGS (elog from inside the hook, audit-extension style). A consumer that
 * forwards to prev_hook without its re-entrancy guard up recurses
 * hook → elog → hook until the backend's stack dies.
 */
#include "postgres.h"
#include "fmgr.h"
#include "miscadmin.h"
#include "storage/ipc.h"
#include "storage/shmem.h"
#include "utils/elog.h"

PG_MODULE_MAGIC;

#define HOOKCHAIN_MAGIC 0x484f4f4bU

typedef struct HookchainState
{
    uint32 magic;
} HookchainState;

static emit_log_hook_type prev_hook = NULL;
static shmem_request_hook_type prev_shmem_request_hook = NULL;
static shmem_startup_hook_type prev_shmem_startup_hook = NULL;
static HookchainState *hookchain_state = NULL;
static int hook_calls = 0;
static bool armed = false;

static void count_hook(ErrorData *edata);
static void request_hook(void);
static void startup_hook(void);

void _PG_init(void);

void
_PG_init(void)
{
    prev_shmem_request_hook = shmem_request_hook;
    shmem_request_hook = request_hook;
    prev_shmem_startup_hook = shmem_startup_hook;
    shmem_startup_hook = startup_hook;
    prev_hook = emit_log_hook;
    emit_log_hook = count_hook;
}

static void
request_hook(void)
{
    if (prev_shmem_request_hook)
        prev_shmem_request_hook();
    RequestAddinShmemSpace(MAXALIGN(sizeof(HookchainState)));
}

static void
startup_hook(void)
{
    bool found;

    if (prev_shmem_startup_hook)
        prev_shmem_startup_hook();
    hookchain_state = ShmemInitStruct("hookchain:state",
                                     sizeof(HookchainState), &found);
    if (!found)
        hookchain_state->magic = HOOKCHAIN_MAGIC;
}

static void
count_hook(ErrorData *edata)
{
    hook_calls++;
    if (armed)
        elog(NOTICE, "hookchain nested call %d", hook_calls);
    if (prev_hook)
        prev_hook(edata);
}

PG_FUNCTION_INFO_V1(hookchain_count);
PG_FUNCTION_INFO_V1(hookchain_arm);
PG_FUNCTION_INFO_V1(hookchain_shmem_ready);

Datum
hookchain_count(PG_FUNCTION_ARGS)
{
    PG_RETURN_INT32(hook_calls);
}

/* Arms/disarms the logging mode and returns the call count, so an e2e run
 * can read both from one statement (void returns print no psql row). */
Datum
hookchain_arm(PG_FUNCTION_ARGS)
{
    armed = PG_GETARG_BOOL(0);
    PG_RETURN_INT32(hook_calls);
}

Datum
hookchain_shmem_ready(PG_FUNCTION_ARGS)
{
    PG_RETURN_BOOL(hookchain_state != NULL &&
                   hookchain_state->magic == HOOKCHAIN_MAGIC);
}
