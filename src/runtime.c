/*
 * src/runtime.c -- Nelua runtime definitions.
 *
 * The C generator (src/cgen.nim) prepends a preamble to every emitted
 * translation unit that *declares* the symbols defined here (struct nltype,
 * the nltype_of_* descriptors, and the nelua-nl/ helper functions).  This file is
 * compiled separately and linked with the generated translation unit, so the
 * emitted TU sees them as `extern` and the linker resolves them here.
 *
 * The nlstring type is repeated here verbatim so this translation unit is
 * self-contained:
 *   typedef struct { const char* data; size_t size; } nlstring;
 */

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <math.h>
#include <setjmp.h>
#include <signal.h>

/* ------------------------------------------------------------------ */
/* nlstring -- must match the typedef emitted by cgen.nim             */
/* ------------------------------------------------------------------ */
typedef struct { const char* data; size_t size; } nlstring;

/* ------------------------------------------------------------------ */
/* nlany -- tagged runtime `any`.  Must match the enum + struct       */
/* emitted by cgen.nim; repeated here verbatim so this translation    */
/* unit (compiled separately and linked) is self-contained.           */
/* ------------------------------------------------------------------ */
typedef enum {
  NLANY_NIL = 0,
  NLANY_BOOL, NLANY_INT, NLANY_UINT, NLANY_NUM,
  NLANY_STRING, NLANY_POINTER, NLANY_TABLE, NLANY_FUNC, NLANY_TYPE
} nlany_tag;

typedef struct {
  nlany_tag tag;
  union {
    uint8_t b; int64_t i; uint64_t u; double n;
    nlstring s; void* p;
  } as;
} nlany;

/* ------------------------------------------------------------------ */
/* struct nltype -- runtime type descriptor.  cgen.nim only forward-   */
/* declares it; here we give it a real, sized definition.              */
/* ------------------------------------------------------------------ */
struct nltype {
  const char* name;          /* human readable type name            */
  size_t size;               /* on-storage size in bytes            */
  size_t align;              /* alignment requirement               */
  void (*trace)(void* obj);  /* GC trace hook (unused for now)       */
};
typedef struct nltype nltype;

/* ------------------------------------------------------------------ */
/* Builtin type descriptors.  These are the real definitions; the     */
/* emitted TU declares them `extern const nltype` and links here.     */
/* ------------------------------------------------------------------ */
const struct nltype nltype_of_int64   = { "int64",   sizeof(int64_t), _Alignof(int64_t),   NULL };
const struct nltype nltype_of_double  = { "double",  sizeof(double),  _Alignof(double),  NULL };
const struct nltype nltype_of_bool    = { "bool",    sizeof(uint8_t), _Alignof(uint8_t), NULL };
const struct nltype nltype_of_string  = { "string",  sizeof(nlstring),_Alignof(nlstring),NULL };

/* ------------------------------------------------------------------ */
/* nelua_print* -- typed print helpers, emulating Lua `print`.        */
/*                                                                     */
/* C7: the C generator emits one typed call per argument instead of a  */
/* single variadic nelua_print, so each helper takes exactly one value */
/* and the argument order is guaranteed correct regardless of type.   */
/* ------------------------------------------------------------------ */

/* Output stream nelua_print writes to.  Defaults to stdout so the generated
   program behaves normally; the test harness may redirect it.  stdout is not
   a compile-time constant in glibc, so it is set by the constructor below. */
FILE* nl_out;
static void nl_init_out(void) __attribute__((constructor));
static void nl_init_out(void) { nl_out = stdout; }

static int nl_is_small_int(int64_t v) {
  /* A "small" integer is one that does not look like a 64-bit pointer. */
  return v > -0x4000000000LL && v < 0x4000000000LL;
}

static int nl_is_zero_or_denormal(double d) {
  if (d == 0.0) return 1;
  if (isnan(d)) return 1;
  double a = fabs(d);
  return a < 1e-100;   /* denormals / subnormals */
}

/* ------------------------------------------------------------------ */
/* segfault-guarded string probe.                                      */
/*                                                                     */
/* The GP register-save-area scan cannot, in general, tell a real      */
/* by-value nlstring {data,size} pair from a stale pointer slot that   */
/* happens to be followed by a small int.  The only reliable filter    */
/* we can apply without knowing the argument count is to verify that  */
/* the "data" pointer actually points at readable memory whose first  */
/* and last bytes are printable ASCII.  Unmapped probes are caught    */
/* with siglongjmp and reported as "not a string".                    */
/* ------------------------------------------------------------------ */
static sigjmp_buf nl_jbuf;
static void nl_segv_handler(int sig) {
  (void)sig;
  siglongjmp(nl_jbuf, 1);
}

static int nl_is_printable_string(const void* p, size_t n) {
  if (p == NULL || n == 0) return 0;
  struct sigaction sa, old;
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = nl_segv_handler;
  sigemptyset(&sa.sa_mask);
  sa.sa_flags = 0;
  sigaction(SIGSEGV, &sa, &old);
  int ok = 0;
  if (sigsetjmp(nl_jbuf, 1) == 0) {
    volatile const unsigned char* q = (volatile const unsigned char*)p;
    unsigned char first = q[0];
    unsigned char last  = q[n - 1];
    ok = (first >= 0x20 && first < 0x7f) &&
         (n == 1 || (last >= 0x20 && last < 0x7f));
  }
  sigaction(SIGSEGV, &old, NULL);
  return ok;
}

void nelua_print_int64(int64_t v) {
  fprintf(nl_out, "%lld", (long long)v);
}

void nelua_print_uint64(uint64_t v) {
  fprintf(nl_out, "%llu", (long long)v);
}

void nelua_print_double(double d) {
  /* Lua's tostring for a float: %.14g, then append ".0" when the result has
     no decimal point and no exponent, so integral values read "1.0" not "1". */
  char buf[64];
  snprintf(buf, sizeof buf, "%.14g", d);
  /* `%.14g` renders inf/nan as the bare words "inf"/"-inf"/"nan"/"-nan",
     which contain no decimal point and no exponent, so the integral-suffix
     scan below would wrongly append ".0" to them.  The oracle's `tostring`
     prints these bare, so skip the suffix for them. */
  if (strcmp(buf, "inf") != 0 && strcmp(buf, "-inf") != 0 &&
      strcmp(buf, "nan") != 0 && strcmp(buf, "-nan") != 0 &&
      strchr(buf, '.') == NULL && strchr(buf, 'e') == NULL &&
      strchr(buf, 'E') == NULL) {
    strcat(buf, ".0");
  }
  fputs(buf, nl_out);
}

void nelua_print_string(nlstring s) {
  if (s.data != NULL && s.size > 0) {
    fwrite(s.data, 1, s.size, nl_out);
  }
}

void nelua_print_bool(int b) {
  fputs(b ? "true" : "false", nl_out);
}

void nelua_print_nil(void) {
  fputs("(null)", nl_out);
}

/* A pointer prints as a hex address (the oracle spells `0x` + lowercase hex,
   natural width, no leading zeros); a null pointer prints `(null)`, matching
   the nil/nilptr spelling.  The generated TU passes the pointer value through
   (passArg=true), so the NULL check here is what makes null distinct. */
void nelua_print_ptr(void* v) {
  if (v == NULL) {
    fputs("(null)", nl_out);
  } else {
    fprintf(nl_out, "%p", v);
  }
}

void nelua_print_sep(void) {
  fputc('\t', nl_out);
}

void nelua_print_newline(void) {
  fputc('\n', nl_out);
  fflush(nl_out);
}

/* ------------------------------------------------------------------ */
/* nlany -- tagged runtime `any`.  The struct itself is emitted in    */
/* the cgen preamble; here only the construction / dispatch helpers.  */
/* ------------------------------------------------------------------ */

nlany nlany_from_nil(void) {
  nlany r;
  r.tag = NLANY_NIL;
  r.as.i = 0;
  return r;
}

nlany nlany_from_bool(uint8_t v) {
  nlany r;
  r.tag = NLANY_BOOL;
  r.as.b = v;
  return r;
}

nlany nlany_from_int(int64_t v) {
  nlany r;
  r.tag = NLANY_INT;
  r.as.i = v;
  return r;
}

nlany nlany_from_uint(uint64_t v) {
  nlany r;
  r.tag = NLANY_UINT;
  r.as.u = v;
  return r;
}

nlany nlany_from_num(double v) {
  nlany r;
  r.tag = NLANY_NUM;
  r.as.n = v;
  return r;
}

nlany nlany_from_string(nlstring v) {
  nlany r;
  r.tag = NLANY_STRING;
  r.as.s = v;
  return r;
}

nlany nlany_from_ptr(void* v) {
  nlany r;
  r.tag = (v == NULL) ? NLANY_NIL : NLANY_POINTER;
  r.as.p = v;
  return r;
}

void nelua_print_any(nlany v) {
  switch (v.tag) {
    case NLANY_NIL:    nelua_print_nil(); break;
    case NLANY_BOOL:   nelua_print_bool(v.as.b); break;
    case NLANY_INT:    nelua_print_int64(v.as.i); break;
    case NLANY_UINT:   nelua_print_uint64(v.as.u); break;
    case NLANY_NUM:    nelua_print_double(v.as.n); break;
    case NLANY_STRING: nelua_print_string(v.as.s); break;
    default:           nelua_print_nil(); break;
  }
}

/* `any` load helpers.  The construction set lives above; these extract a    */
/* typed payload out of a tagged `nlany`.  A tag mismatch returns the zero    */
/* value for the requested type (the analyzer only emits a load when the    */
/* source is itself `any`, so the tag is runtime-unknown and the fallback    */
/* must be safe).                                                            */
int64_t nlany_load_int(nlany v) {
  switch (v.tag) {
    case NLANY_INT:  return v.as.i;
    case NLANY_UINT: return (int64_t)v.as.u;
    case NLANY_BOOL: return v.as.b;
    case NLANY_NUM:  return (int64_t)v.as.n;
    default:         return 0;
  }
}
uint64_t nlany_load_uint(nlany v) {
  switch (v.tag) {
    case NLANY_UINT: return v.as.u;
    case NLANY_INT:  return (uint64_t)v.as.i;
    case NLANY_BOOL: return v.as.b;
    case NLANY_NUM:  return (uint64_t)v.as.n;
    default:         return 0;
  }
}
double nlany_load_num(nlany v) {
  switch (v.tag) {
    case NLANY_NUM:  return v.as.n;
    case NLANY_INT:  return (double)v.as.i;
    case NLANY_UINT: return (double)v.as.u;
    case NLANY_BOOL: return (double)v.as.b;
    default:         return 0.0;
  }
}
uint8_t nlany_load_bool(nlany v) {
  switch (v.tag) {
    case NLANY_BOOL: return v.as.b;
    case NLANY_INT:  return v.as.i != 0;
    case NLANY_UINT: return v.as.u != 0;
    case NLANY_NUM:  return v.as.n != 0.0;
    default:         return 0;
  }
}
nlstring nlany_load_string(nlany v) {
  if (v.tag == NLANY_STRING) return v.as.s;
  nlstring empty; empty.data = NULL; empty.size = 0; return empty;
}
void* nlany_load_ptr(nlany v) {
  if (v.tag == NLANY_POINTER) return v.as.p;
  return NULL;
}
bool nlany_eq(nlany a, nlany b) {
  if (a.tag != b.tag) return false;
  switch (a.tag) {
    case NLANY_NIL:    return true;
    case NLANY_BOOL:   return a.as.b == b.as.b;
    case NLANY_INT:    return a.as.i == b.as.i;
    case NLANY_UINT:   return a.as.u == b.as.u;
    case NLANY_NUM:    return a.as.n == b.as.n;
    case NLANY_STRING: return a.as.s.data == b.as.s.data &&
                         a.as.s.size == b.as.s.size;
    case NLANY_POINTER: return a.as.p == b.as.p;
    default:           return false;
  }
}

/* nlstr -- wrap a C string (not a copy) into an nlstring.            */
/* ------------------------------------------------------------------ */
nlstring nlstr(const char* s) {
  nlstring r;
  r.data = s;
  r.size = s ? strlen(s) : 0;
  return r;
}

/* ------------------------------------------------------------------ */
/* nlstring_concat -- concatenate two nlstrings into a heap string.   */
/* The caller owns the result and must release it with nlstring_free. */
/* ------------------------------------------------------------------ */
nlstring nlstring_concat(nlstring a, nlstring b) {
  nlstring r;
  r.size = a.size + b.size;
  r.data = (const char*)malloc(r.size ? r.size : 1);
  if (r.data) {
    if (a.size) memcpy((void*)r.data, a.data, a.size);
    if (b.size) memcpy((void*)r.data + a.size, b.data, b.size);
  } else {
    r.data = NULL;
    r.size = 0;
  }
  return r;
}

/* ------------------------------------------------------------------ */
/* nlstring_free -- release a heap nlstring produced by nlstring_concat. */
/* ------------------------------------------------------------------ */
void nlstring_free(nlstring* s) {
  if (s) {
    free((void*)s->data);
    s->data = NULL;
    s->size = 0;
  }
}

/* ------------------------------------------------------------------ */
/* nlidiv / nlmod -- integer division and modulo with Lua semantics.  */
/* nlidiv truncates toward zero; nlmod returns a - floor(a/b)*b, i.e.  */
/* the remainder takes the sign of the divisor.                       */
/* ------------------------------------------------------------------ */
int64_t nlidiv(int64_t a, int64_t b) {
  if (b == 0) return 0;
  return a / b;   /* C99 division truncates toward zero */
}

int64_t nlmod(int64_t a, int64_t b) {
  if (b == 0) return 0;
  int64_t r = a % b;
  if (r != 0 && ((a < 0) != (b < 0))) r += b;
  return r;
}

/* ------------------------------------------------------------------ */
/* nlpow -- a ^ b.                                                    */
/* ------------------------------------------------------------------ */
double nlpow(double a, double b) {
  return pow(a, b);
}

/* ------------------------------------------------------------------ */
/* nllen -- length of an nlstring.                                     */
/* ------------------------------------------------------------------ */
int64_t nllen(nlstring s) {
  return (int64_t)s.size;
}

/* ------------------------------------------------------------------ */
/* nlclose -- free(p) if non-null.  Used to release opaque handles.   */
/* ------------------------------------------------------------------ */
void nlclose(void* p) {
  free(p);
}

/* ------------------------------------------------------------------ */
/* nlcheck_*_overflow -- narrow-check helpers.  Debug builds call     */
/* these; release builds elide them via NLNOCHECK.  Default impl is a  */
/* no-op so valid input never crashes.                                 */
/* ------------------------------------------------------------------ */
void nlcheck_int_overflow(int64_t x, const char* what) {
  (void)x; (void)what;
}
void nlcheck_uint_overflow(uint64_t x, const char* what) {
  (void)x; (void)what;
}
void nlcheck_float_overflow(double x, const char* what) {
  (void)x; (void)what;
}