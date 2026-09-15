/*
 * Per-connection registration wrapper for the vendored Vec1 source.
 *
 * VEC1_STATIC keeps Vec1 on SQLite's ordinary C API instead of its loadable
 * extension indirection. Including the byte-for-byte upstream source here
 * lets this wrapper call its internal initExtension() without modifying it.
 */
#define VEC1_STATIC 1
#include "Vendor/vec1.c"

int tractanda_vec1_register(sqlite3 *db, char **errorMessage){
  return initExtension(db, errorMessage, 0);
}
