/* 0.3.0 → 0.4.0: variable-width message slots (pg_logtap.message_max) —
   an internal shmem/worker rework with no SQL-visible surface: the same
   functions, the same stats JSON keys and view columns. No-op script;
   exists so the extension version advances and the loader checks the
   binary. Shared memory layout changed (though byte-identical at the
   default message_max) — restart the server after updating the binary,
   as with any preload library. */
