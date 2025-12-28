# MoonBit reference counting (RC) and FFI lifetime notes (native/C backend)

This document expands on MoonBit’s **native/C backend** reference counting and FFI lifetime rules, with an emphasis on one common pitfall: **RC is not guaranteed to be thread-safe**. The focus is practical engineering for writing C stubs with `extern "c"`.

Chinese version: `docs/moonbit-refcount-zh.md`

> Scope: native/C backend (and parts of the Wasm backend). On JS / Wasm GC backends, object lifetimes are managed by the host GC and many details differ.

---

## 1. Mental model: RC-managed “GC” on the C backend

On the native/C backend, MoonBit uses **reference counting (RC)** to manage most boxed objects. The compiler inserts `incref/decref` where needed, and your FFI code must follow the same ownership rules; otherwise you’ll see:

- **Use-after-free / corruption**: flaky tests, wrong results, crashes
- **Leaks**: missing `decref` or extra `incref`
- **Double-free / premature free**: mismatched `#borrow/#owned` semantics

The core RC API lives in `~/.moon/include/moonbit.h`:

- `void moonbit_incref(void *obj);`
- `void moonbit_decref(void *obj);`

In generated C, MoonBit often inlines RC updates (typically non-atomic increments/decrements of `header->rc`).

---

## 2. What is RC-managed?

### 2.1 Not RC-managed (unboxed scalars)
These are passed by value in the C ABI and do not participate in RC:

- numeric types: `Int/Int64/UInt/Float/Double/Bool`
- constant enums (payload-free `enum`)

### 2.2 RC-managed (boxed objects)
These are typically heap allocated and reference counted:

- `String`, `Bytes`
- `Array[T]` / `FixedArray[T]` (and other reference containers)
- `Ref[T]`
- closures (captured environment)
- **abstract types** declared via `type T` (not `#external`)

### 2.3 `#external type`: raw pointers (no MoonBit RC)
On the C backend, `#external type T` is represented as a `void*`, and MoonBit **does not** apply `incref/decref` to it.

This is suitable for:

- non-MoonBit pointers
- fully manual lifetime management (malloc/free, your own refcount, mutex-protected teardown)
- thread-shared handles (see §6)

---

## 3. Default FFI ownership: parameters are owned

MoonBit’s C backend uses an **owned** calling convention by default:

- the caller transfers ownership to the callee
- the callee must `moonbit_decref` the parameter at the right time (if it doesn’t return/store it)

MoonBit provides attributes to clarify ownership:

- `#borrow(p1, p2, ...)`: borrowed parameters (callee must *not* `decref` them)
- `#owned(p)`: explicitly owned (often the default, but making it explicit avoids confusion)

---

## 4. RC rule table for C stubs (with examples)

Assume `x` is a **boxed MoonBit object** (e.g. `String/Ref[T]/abstract type`).

### 4.1 Owned parameters (default)
Owned means: **you received a reference that you must eventually release**.

| What you do with owned `x` in C | RC operations |
|---|---|
| Read/compute only, don’t store | `moonbit_decref(x)` at end of scope |
| Store into your own data structure | no `incref` needed, but you must `decref` later when releasing the structure |
| Pass to a MoonBit function (which consumes owned params) while still keeping your own reference | `moonbit_incref(x)` before the call, so the callee can consume one reference |
| Store/pass it multiple times (need multiple long-lived refs) | `incref` for each additional owned reference |
| Return it to MoonBit | just `return x;` (do not `decref`) |

#### 4.1.1 Owned examples

To keep the examples focused on RC, we use `Any` / `void*` as “some boxed MoonBit object”. The same patterns apply to `String/Bytes/Ref[T]/type T` values.

**(1) Read-only: `decref` at function end**

MoonBit declaration (default owned):

```mbt
extern "c" fn owned_readonly(x : Any) -> Int = "owned_readonly"
```

C implementation:

```c
#include "moonbit.h"
#include <stdint.h>

int32_t owned_readonly(void *x) {
  int32_t r = x != NULL;
  moonbit_decref(x);
  return r;
}
```

**(2) Store in your own structure: no `incref`, but `decref` later**

MoonBit declarations:

```mbt
#borrow(h)
extern "c" fn holder_set_owned(h : HolderRef, x : Any) -> Unit = "holder_set_owned"

#owned(h)
extern "c" fn holder_free(h : HolderRef) -> Unit = "holder_free"
```

C implementation:

```c
#include "moonbit.h"
#include <stdlib.h>

typedef struct holder {
  void *x; // owns one reference
} holder;

void holder_set_owned(holder *h, void *x) {
  if (h->x) {
    moonbit_decref(h->x);
  }
  h->x = x; // take ownership
}

void holder_free(holder *h) {
  if (!h) return;
  if (h->x) {
    moonbit_decref(h->x);
  }
  free(h);
}
```

**(3) Pass to an owned-consuming callback but keep your own reference: `incref` first**

MoonBit:

```mbt
#borrow(cb)
extern "c" fn call_cb_keep_x(cb : FuncRef[(Any) -> Unit], x : Any) -> Unit =
  "call_cb_keep_x"
```

C:

```c
#include "moonbit.h"

void call_cb_keep_x(void (*cb)(void *), void *x) {
  moonbit_incref(x); // give one owned reference to cb
  cb(x);             // cb consumes the incref'ed reference

  // still own the original reference here
  moonbit_decref(x);
}
```

**(4) Store in two places: `incref` to create a second owned reference**

MoonBit:

```mbt
#borrow(h1, h2)
extern "c" fn fanout_store_two(h1 : HolderRef, h2 : HolderRef, x : Any) -> Unit =
  "fanout_store_two"
```

C:

```c
#include "moonbit.h"

typedef struct holder holder;
void holder_set_owned(holder *h, void *x);

void fanout_store_two(holder *h1, holder *h2, void *x) {
  moonbit_incref(x);   // create a second reference
  holder_set_owned(h1, x);
  holder_set_owned(h2, x);
}
```

**(5) Return owned value to MoonBit: just return**

MoonBit:

```mbt
extern "c" fn identity_owned(x : Any) -> Any = "identity_owned"
```

C:

```c
void *identity_owned(void *x) {
  return x;
}
```

### 4.2 Borrowed parameters (`#borrow(x)`)
Borrowed means: **you temporarily borrow the reference and must not release it**.

| What you do with borrowed `x` in C | RC operations |
|---|---|
| Read/compute only, don’t store | nothing (do not `decref`) |
| Store into your own structure | `moonbit_incref(x)` first (upgrade borrowed to owned) |
| Return it to MoonBit | `moonbit_incref(x)` then return (return value is owned) |

#### 4.2.1 Borrow examples

**(1) Read-only borrow: do nothing**

MoonBit:

```mbt
#borrow(x)
extern "c" fn borrow_readonly(x : Any) -> Int = "borrow_readonly"
```

C:

```c
#include <stdint.h>

int32_t borrow_readonly(void *x) {
  return x != NULL;
}
```

**(2) Store a borrowed value: `incref` before storing**

MoonBit:

```mbt
#borrow(h, x)
extern "c" fn holder_set_borrow(h : HolderRef, x : Any) -> Unit = "holder_set_borrow"
```

C:

```c
#include "moonbit.h"

typedef struct holder {
  void *x;
} holder;

void holder_set_borrow(holder *h, void *x) {
  if (x) moonbit_incref(x); // take ownership of a new reference
  if (h->x) moonbit_decref(h->x);
  h->x = x;
}
```

**(3) Return a borrowed value: `incref` before returning**

MoonBit:

```mbt
#borrow(x)
extern "c" fn return_borrow(x : Any) -> Any = "return_borrow"
```

C:

```c
#include "moonbit.h"

void *return_borrow(void *x) {
  if (x) moonbit_incref(x);
  return x;
}
```

### 4.3 The most common mistake

- Mark something as owned (or leave it owned by default) but forget to `decref`: **leak**.
- Mark something as `#borrow` but still `decref` it: **premature free / crashes / flakiness**.

---

## 5. `type T` vs `#external type T`: two very different “pointer types”

### 5.1 `type T` (abstract type)
- Represented as a pointer to a MoonBit-managed object
- Participates in MoonBit RC (`incref/decref` apply to its object header)
- Often paired with `moonbit_make_external_object(finalize, payload_size)` so the runtime calls `finalize` when the object is no longer reachable

Use this when the resource is effectively single-threaded, or when you can guarantee no concurrent RC operations from multiple threads.

### 5.2 `#external type T`
- Represented as `void*`
- No MoonBit RC is applied
- You own memory and lifetime management

Use this for thread-shared handles or whenever you want full control.

---

## 6. Threading warning: RC updates are not atomic

On the native/C backend, `moonbit_incref/decref` (and inlined variants) typically perform non-atomic updates of `rc`. Therefore:

- If multiple pthreads concurrently `incref/decref` the same boxed MoonBit object, you have a data race.
- Consequences include lost updates, premature free, double free, corrupted state.
- Symptoms are often flaky: “fails once in N runs”.

### 6.1 Practical recommendations

If you need a handle/object to be shared across threads:

1. Prefer representing it as `#external type` on the MoonBit side.
2. Implement thread-safe lifetime management in C:
   - atomic refcount (`stdatomic.h`), or
   - a mutex guarding refcount + teardown
3. Make MoonBit’s `clone/destroy` map to your C `retain/release`.

### 6.2 A real pitfall: channels closing early (flaky)

A typical failure mode is a channel handle being RC-managed and dropped across threads:

- different threads call `destroy()` on different clones
- the underlying handle participates in non-atomic RC updates
- occasionally the object is finalized early, leading to `recv()` returning `None` unexpectedly

Fix: represent the handle as `#external type` and manage its lifetime entirely in C (thread-safe, explicit).

---

## 7. `#borrow/#owned` checklist

Before writing an `extern "c"` binding, verify:

1. Is the parameter boxed/RC-managed? (`String/Ref/Array/closure/abstract type`…)
2. Will the C function store it beyond the call?
3. Will it be returned to MoonBit?
4. Will it be passed into a MoonBit function (owned-consuming)?
5. Will there be cross-thread access (especially concurrent RC ops)?

Choose:

- Read-only temporary use: `#borrow(param)` is safest (no `decref`).
- Take ownership: keep it owned and ensure a matching `decref` at the right time.
- Cross-thread shared handle: use `#external type` and avoid MoonBit RC entirely.

---

## 8. Symptoms and debugging approach

### 8.1 Symptoms
- flaky tests: “missing messages”, “count smaller than expected”
- `recv()`/`join()` sometimes returns early
- crashes / ASAN reports (use-after-free)

### 8.2 Debugging
1. Look for RC-managed values shared across threads (abstract handles, captured boxed values).
2. Verify FFI annotations match implementation:
   - borrowed params are not decref’ed
   - owned params are decref’ed exactly once (unless returned/stored)
3. Verify that storing a borrowed param is paired with `incref`.

---

## 9. References

- `~/.moon/include/moonbit.h` (native/C backend ABI and RC API)
- MoonBit official docs: FFI / lifetime management / `#borrow/#owned` (definitions are important even if brief)
