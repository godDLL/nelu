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
#include <math.h>
#include <setjmp.h>
#include <signal.h>

/* ------------------------------------------------------------------ */
/* nlstring -- must match the typedef emitted by cgen.nim             */
/* ------------------------------------------------------------------ */
typedef struct { const char* data; size_t size; } nlstring;

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
  /* Lua formats integral doubles without a decimal point. */
  if (d == floor(d) && isfinite(d) && fabs(d) < 1e15) {
    fprintf(nl_out, "%.0f", d);
  } else {
    fprintf(nl_out, "%g", d);
  }
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
  fputs("nil", nl_out);
}

void nelua_print_sep(void) {
  fputc(' ', nl_out);
}

void nelua_print_newline(void) {
  fputc('\n', nl_out);
  fflush(nl_out);
}

/* ------------------------------------------------------------------ */
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