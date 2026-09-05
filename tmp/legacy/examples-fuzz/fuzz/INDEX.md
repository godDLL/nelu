# Nelua Fuzz Corpus — Oracle vs. Ours

50 self-contained Nelua programs exercising parser / analyzer / codegen across a
broad spread of algorithms and language constructs.

- **Oracle** = `/usr/bin/nelua` (Nelua 0.2.0-dev.1635, build 2025-06-24).
- **Ours**   = `/home/user/Code/nelua-lang/tmp/nelua` (built with
  `nim c -d:release --path:src --nimcache:/tmp/neluanimcache -o:tmp/nelua src/main.nim`).

Every file compiles and runs cleanly under the **Oracle** (exit code 0, captured
output below). The rightmost column is the Oracle-vs-Ours verdict.

> Note on how Ours is invoked: `tmp/nelua <file>` compiles-and-runs in one step
> (its `-o <bin>` flag is broken — "no binary was produced"). Oracle is invoked
> as `nelua -o <bin> <file>` then the `<bin>` is run. Both produce the same
> stdout the program `print`s.

## Verdict summary

| Verdict | Count |
|---------|-------|
| MATCH   | 22    |
| DIFF    | 5     |
| CRASH   | 21    |
| HANG    | 2     |
| **Total** | **50** |

All 50 Oracle runs exit 0. Ours never matches the Oracle on a file that uses a
standard `require` (see the CRASH section below — 19 of the 21 CRASHes are a
single root cause: Ours cannot resolve the standard library modules
`string` / `iterators` / `math`, which the Oracle loads from
`/usr/lib/nelua/lualib`).

## Full table

| # | File | Algorithm | One-line description | Oracle output | Verdict |
|---|------|-----------|----------------------|---------------|---------|
| 1 | `fuzz_anagram.nelua` | Anagram check | Char-frequency comparison of two strings | `true` | CRASH |
| 2 | `fuzz_armstrong.nelua` | Armstrong (narcissistic) number | Digit power-sum equals the number? | `true` | MATCH |
| 3 | `fuzz_bfs.nelua` | Breadth-first search | BFS on a 6-node fixed graph | `0 1 2 3 4 5` | CRASH |
| 4 | `fuzz_binary_search.nelua` | Binary search | Index of 5 in a sorted array | `5` | MATCH |
| 5 | `fuzz_boyer_moore.nelua` | Boyer-Moore majority vote | Majority element of a 7-element array | `3` | MATCH |
| 6 | `fuzz_bubblesort.nelua` | Bubble sort | Sorted 8-element array | `1 1 2 3 4 5 6 9` | CRASH |
| 7 | `fuzz_checksum.nelua` | 32-bit checksum | One-at-a-time hash over 6 bytes | `648595488` | CRASH |
| 8 | `fuzz_collatz.nelua` | Collatz (3n+1) | Step count from 27 to 1 | `111` | MATCH |
| 9 | `fuzz_combinations.nelua` | Binomial coefficient | C(5,2) via multiplicative formula | `10` | MATCH |
| 10 | `fuzz_dfs.nelua` | Depth-first search | Recursive DFS on a 6-node graph | `0 1 3 5 4 2` | CRASH |
| 11 | `fuzz_digit_sum.nelua` | Sum of decimal digits | Digit sum of 12345 | `15` | MATCH |
| 12 | `fuzz_extended_gcd.nelua` | Extended Euclidean | GCD + Bezout coefficients of 48,18 | `6	-1	3` | MATCH |
| 13 | `fuzz_factorial_iterative.nelua` | Factorial (iterative) | Product loop, 10! | `3628800` | MATCH |
| 14 | `fuzz_factorial_recursive.nelua` | Factorial (recursive) | Naive recursion, 10! | `3628800` | MATCH |
| 15 | `fuzz_factorial_tailrecursive.nelua` | Factorial (tail-recursive) | Accumulator pair, 10! | `3628800` | MATCH |
| 16 | `fuzz_fibonacci_analytic.nelua` | Fibonacci (Binet) | Closed-form with sqrt(5) | `55` | CRASH |
| 17 | `fuzz_fibonacci_iterative.nelua` | Fibonacci (iterative) | Loop with multi-assign swap | `55` | **DIFF** |
| 18 | `fuzz_fibonacci_memoized.nelua` | Fibonacci (memoized) | Module-level memo table | `55` | MATCH |
| 19 | `fuzz_fibonacci_recursive.nelua` | Fibonacci (recursive) | Naive double recursion | `55` | MATCH |
| 20 | `fuzz_fibonacci_tailrecursive.nelua` | Fibonacci (tail-recursive) | Accumulator pair | `55` | MATCH |
| 21 | `fuzz_fizzbuzz.nelua` | FizzBuzz | 1..20 with switch on divisibility | `1 2Fizz 4BuzzFizz 7 8FizzBuzz 11Fizz 13 14FizzBuzz 16 17Fizz 19Buzz` | CRASH |
| 22 | `fuzz_gcd.nelua` | GCD (Euclid) | `while b ~= 0 do a,b = b, a%b end` | `6` | **HANG** |
| 23 | `fuzz_hash_djb2.nelua` | DJB2 hash | Byte-array hash | `268354746` | CRASH |
| 24 | `fuzz_hash_fnv.nelua` | FNV-1a hash | Byte-array hash with XOR/mult | `3239889306` | CRASH |
| 25 | `fuzz_heapsort.nelua` | Heap sort | Binary max-heap build + extract | `1 1 2 3 4 5 6 9` | CRASH |
| 26 | `fuzz_insertionsort.nelua` | Insertion sort | Insert each element into place | `1 1 2 3 4 5 6 9` | CRASH |
| 27 | `fuzz_is_power_of_two.nelua` | Power-of-two check | Bitwise `x & (x-1)` on uint32 | `true	false` | MATCH |
| 28 | `fuzz_isqrt_newton.nelua` | Integer sqrt (Newton) | Iterative Newton on integer | `111` | MATCH |
| 29 | `fuzz_josephus.nelua` | Josephus problem | 0-indexed recurrence, n=7 k=3 | `4` | MATCH |
| 30 | `fuzz_kadane.nelua` | Kadane's algorithm | Max subarray sum of 9 elements | `6` | MATCH |
| 31 | `fuzz_lcm.nelua` | LCM via gcd | `(a//gcd(a,b))*b` | `36` | **HANG** |
| 32 | `fuzz_matrix_multiply.nelua` | Matrix multiply | 2x2 * 2x2 triple nested loop | `19	22	43	50` | CRASH |
| 33 | `fuzz_matrix_rotate.nelua` | Matrix rotate 90° | CW rotation of 2x2 | `3	1	4	2` | MATCH |
| 34 | `fuzz_matrix_transpose.nelua` | Matrix transpose | 2x3 -> 3x2 read | `1	4	2	5	3	6` | **DIFF** |
| 35 | `fuzz_max_min_array.nelua` | Max and min | Scan an 8-element array | `9	1` | MATCH |
| 36 | `fuzz_median_array.nelua` | Median | Insertion-sort + average of middle two | `2.5` | **DIFF** |
| 37 | `fuzz_merge_sorted.nelua` | Merge sorted arrays | Merge two 3-element sorted arrays | `1 2 3 4 5 6` | CRASH |
| 38 | `fuzz_mergesort.nelua` | Merge sort | Recursive divide + merge | `1 1 2 3 4 5 6 9` | CRASH |
| 39 | `fuzz_palindrome.nelua` | Palindrome check | Compare chars from both ends | `true	false` | CRASH |
| 40 | `fuzz_power_fast.nelua` | Fast exponentiation | Binary exponentiation, 3^13 | `1594323` | MATCH |
| 41 | `fuzz_power_iterative.nelua` | Iterative exponentiation | Loop multiplication, 2^10 | `1024` | MATCH |
| 42 | `fuzz_prime_sieve.nelua` | Sieve of Eratosthenes | Count primes <= 100 | `25` | CRASH |
| 43 | `fuzz_queue.nelua` | Queue (record + methods) | FIFO enqueue/dequeue | `3	2	1` | **DIFF** |
| 44 | `fuzz_quicksort.nelua` | Quicksort (Lomuto) | Recursive partition sort | `1 1 2 3 4 5 6 9` | CRASH |
| 45 | `fuzz_radix_sort.nelua` | Radix sort (LSD) | Base-10 LSD radix sort | `2 24 45 66 75 90 99 170` | CRASH |
| 46 | `fuzz_reverse_words.nelua` | Reverse word order | Tokenize + emit backwards | `nelua from world hello` | CRASH |
| 47 | `fuzz_selectionsort.nelua` | Selection sort | Repeatedly select the minimum | `1 1 2 3 4 5 6 9` | CRASH |
| 48 | `fuzz_stack.nelua` | Stack (record + methods) | LIFO push/pop | `1	2	3` | **DIFF** |
| 49 | `fuzz_string_reverse.nelua` | String reverse | Build string backwards | `aulen` | CRASH |
| 50 | `fuzz_sum_of_squares.nelua` | Sum of squares | 1^2+2^2+3^2+4^2+5^2 | `55` | MATCH |

## DIFFs — side by side

Ours compiles and runs these but produces different output than the Oracle.

### `fuzz_fibonacci_iterative.nelua` — multi-assign swap
```
ORACLE: 55
OURS:   1
```
`local a, b = 0, 1; for i=1,n do a, b = b, a + b end` — Ours evaluates the
right-hand side with the *old* `a` on both sides of the swap, so the accumulator
never advances and the loop returns `1`. The Oracle correctly returns fib(10)=55.

### `fuzz_matrix_transpose.nelua` — 2D array indexing
```
ORACLE: 1	4	2	5	3	6
OURS:   1	4	2	5	4	0
```
Reading `a[0][2]` and `a[1][2]` from a `local a: [2][3]integer =
{{1,2,3},{4,5,6}}`. Ours returns `4 0` for the last two elements instead of
`3 6` — a 2D fixed-array indexing/codegen bug.

### `fuzz_median_array.nelua` — multi-assign swap inside sort
```
ORACLE: 2.5
OURS:   1.5
```
Insertion sort uses `a[j-1], a[j] = a[j], a[j-1]`. The same multi-assign bug as
above leaves the array only partially sorted, so the median of {3,1,4,2} comes
out as (1+2)/2 = 1.5 instead of (2+3)/2 = 2.5.

### `fuzz_queue.nelua` / `fuzz_stack.nelua` — argument evaluation order
```
queue:  ORACLE: 3	2	1   |   OURS: 1	2	3
stack:  ORACLE: 1	2	3   |   OURS: 3	2	1
```
Both call `print(f():pop(), f():pop(), f():pop())` where the calls mutate shared
state. The **Oracle evaluates function arguments right-to-left**; **Ours
evaluates them left-to-right**. The two outputs are exact reverses of each other
for both stack and queue — a genuine semantic divergence in argument-order
evaluation.

## HANGs — side by side

Ours never terminates (killed by an 8-second timeout, rc=124); Oracle exits 0.

### `fuzz_gcd.nelua`
```
ORACLE: 6
OURS:   (no output; infinite loop)
```
`while b ~= 0 do a, b = b, a % b end` with gcd(48,18). The broken multi-assign
leaves `b` unchanged, so the loop never converges.

### `fuzz_lcm.nelua`
```
ORACLE: 36
OURS:   (no output; infinite loop)
```
Same root cause — `lcm` calls `gcd`, whose multi-assign loop hangs.

## CRASHes — side by side

Ours exits non-zero (or SIGSEGVs) where the Oracle exits 0.

### Root cause A: standard library modules not resolvable (19 files)
Files that `require 'string'`, `require 'iterators'`, or `require 'math'` all fail
in Ours with `require '<module>': module not found` (rc=1). The Oracle loads
these from `/usr/lib/nelua/lualib/nelua/utils/*.lua`. Ours' `luainit.lua` derives
its module path from `arg[0]` (hard-coded to `"nelua.lua"` in
`src/luaengine.nim`), which does not resolve to the installed lualib, so the
standard modules are invisible.

| File | Oracle | Ours stderr |
|------|--------|-------------|
| `fuzz_anagram.nelua` | `true` | `require 'string': module not found` |
| `fuzz_bfs.nelua` | `0 1 2 3 4 5` | `require 'string': module not found` |
| `fuzz_bubblesort.nelua` | `1 1 2 3 4 5 6 9` | `require 'string': module not found` |
| `fuzz_checksum.nelua` | `648595488` | `require 'iterators': module not found` |
| `fuzz_dfs.nelua` | `0 1 3 5 4 2` | `require 'string': module not found` |
| `fuzz_fibonacci_analytic.nelua` | `55` | `require 'math': module not found` |
| `fuzz_fizzbuzz.nelua` | `1 2Fizz 4BuzzFizz 7 8FizzBuzz 11Fizz 13 14FizzBuzz 16 17Fizz 19Buzz` | `require 'string': module not found` |
| `fuzz_hash_djb2.nelua` | `268354746` | `require 'iterators': module not found` |
| `fuzz_hash_fnv.nelua` | `3239889306` | `require 'iterators': module not found` |
| `fuzz_heapsort.nelua` | `1 1 2 3 4 5 6 9` | `require 'string': module not found` |
| `fuzz_insertionsort.nelua` | `1 1 2 3 4 5 6 9` | `require 'string': module not found` |
| `fuzz_merge_sorted.nelua` | `1 2 3 4 5 6` | `require 'string': module not found` |
| `fuzz_mergesort.nelua` | `1 1 2 3 4 5 6 9` | `require 'string': module not found` |
| `fuzz_palindrome.nelua` | `true	false` | `require 'string': module not found` |
| `fuzz_quicksort.nelua` | `1 1 2 3 4 5 6 9` | `require 'string': module not found` |
| `fuzz_radix_sort.nelua` | `2 24 45 66 75 90 99 170` | `require 'string': module not found` |
| `fuzz_reverse_words.nelua` | `nelua from world hello` | `require 'string': module not found` |
| `fuzz_selectionsort.nelua` | `1 1 2 3 4 5 6 9` | `require 'string': module not found` |
| `fuzz_string_reverse.nelua` | `aulen` | `require 'string': module not found` |

### Root cause B: runtime SIGSEGV in generated code (1 file)

### `fuzz_prime_sieve.nelua`
```
ORACLE: 25
OURS:   (empty stdout, rc=255 — the generated binary SIGSEGVs at runtime)
```
Uses a `comptime` bound, a `[N+1]boolean` sieve array, and a stepped inner loop
`for j = i+i, N, i do`. Ours generates C that compiles and links, but the
resulting binary segfaults. (Running the emitted binary directly gives
`SIGSEGV: Illegal storage access`, rc=139; the compiler surfaces that as rc=255.)

### Root cause C: C compile error in generated code (1 file)

### `fuzz_matrix_multiply.nelua`
```
ORACLE: 19	22	43	50
OURS:   (rc=1) C compile failed:
  .../fuzz_matrix_multiply.c:163:52: error: incompatible types when assigning
  to type 'int64_t' from type 'nlany'
      c[i][j] = nlany_from_int(s);
```
Ours emits `nlany` (a generic any-type wrapper) where the C target expects an
`int64_t` for the 2x2 result array — a codegen bug for nested-loop writes into a
multi-dimensional fixed array.

## MATCHes (22)

These compile and run identically under both compilers, same stdout, rc=0:

`fuzz_armstrong`, `fuzz_binary_search`, `fuzz_boyer_moore`, `fuzz_collatz`,
`fuzz_combinations`, `fuzz_digit_sum`, `fuzz_extended_gcd`,
`fuzz_factorial_iterative`, `fuzz_factorial_recursive`,
`fuzz_factorial_tailrecursive`, `fuzz_fibonacci_memoized`,
`fuzz_fibonacci_recursive`, `fuzz_fibonacci_tailrecursive`,
`fuzz_is_power_of_two`, `fuzz_isqrt_newton`, `fuzz_josephus`, `fuzz_kadane`,
`fuzz_matrix_rotate`, `fuzz_max_min_array`, `fuzz_power_fast`,
`fuzz_power_iterative`, `fuzz_sum_of_squares`.

## Notes on corpus construction

- Underscore digit separators (`1_000`, `0xFF_FF`) are **not** accepted by the
  0.2.0-dev Oracle ("literal suffix '_FF' is undefined"), so the corpus uses
  plain hex (`0x0F`, `0xDEADBEEF`) instead.
- Direct `for _, v in array do` over a fixed-size array is **not** accepted by
  the Oracle ("cannot call type 'array(int64, 5)'"); the corpus uses
  `for i = 0, #a - 1 do` for fixed arrays and `for _, v in ipairs(a) do` (with
  `require 'iterators'`) where iteration is needed.
- Closures / upvalues are **not** supported ("closures are not supported"), so
  nested functions in the corpus never capture an outer local. The memoized
  Fibonacci uses a module-level array instead.
- `tostring` is part of the `string` module, so any file building output strings
  with it `require 'string'`.
- All 50 files are deterministic: no randomness, no timing, no file I/O, no SDL.