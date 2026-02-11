# Milky2018/pthread

A MoonBit `native` multithreading library built around **share-nothing + message passing**.
Instead of sharing mutable memory across threads, you coordinate work via typed channels.

Chinese version: `README-zh.mbt.md`

## Features

- Threads: `spawn(() -> T) -> Handle[T]` / `Handle[T]::join() -> T`
- MPSC channels: `channel[T](capacity) -> (Sender[T], Receiver[T])`
- Broadcast: `broadcast[T](capacity) -> BroadcastSender[T]`
- Thread pool: `ThreadPool`
- Parallel Iterator bridge (Rayon-style `par_bridge`, initial): `par_each`, `par_map_collect_unordered`, `par_filter_collect_unordered`
- Parallel reductions: `par_map_reduce_unordered`, `par_array_map_reduce`
- Fallible APIs: `try_spawn`, `try_channel`, `try_broadcast`, `Handle::try_join`

## Runnable examples

All code blocks start with <code>```moonbit check</code> and can be verified with:

- `moon test README.mbt.md`

Each example includes the required `destroy()` / `shutdown()` calls to avoid leaking resources.

## Threads: spawn/join

```moonbit check
///|
test {
  let h = spawn(fn() { 40 + 2 })
  inspect(h.join(), content="42")
}
```

## MPSC channel: multiple senders, single receiver

Key semantics:

- `Sender::clone()` increments the sender count; once all senders are `destroy()`-ed the channel closes
- `Receiver::recv()` returns `None` only after the queue is drained and the channel is closed

```moonbit check
///|
test {
  let (tx, rx) : (Sender[Int], Receiver[Int]) = channel(16)
  let tx1 = tx.clone()
  tx.destroy()
  let h = spawn(fn() {
    defer tx1.destroy()
    for i in 0..<10 {
      tx1.send(i) |> ignore
    }
  })
  let mut sum = 0
  let mut cnt = 0
  while true {
    match rx.recv() {
      Some(v) => {
        sum += v
        cnt += 1
      }
      None => break
    }
  }
  rx.destroy()
  h.join()
  inspect(cnt, content="10")
  inspect(sum, content="45")
}
```

## Broadcast: one-to-many, best-effort

Key semantics:

- `BroadcastSender::send` returns how many subscribers accepted the message (full subscribers drop it)
- After `close/destroy`, subscribers return `None` once their local buffers are drained

```moonbit check
///|
test {
  let b : BroadcastSender[Int] = broadcast(4)
  let r1 = b.subscribe()
  let r2 = b.subscribe()
  inspect(b.send(1), content="2")
  inspect(b.send(2), content="2")
  b.destroy()
  inspect(r1.recv(), content="Some(1)")
  inspect(r1.recv(), content="Some(2)")
  inspect(r1.recv(), content="None")
  inspect(r2.recv(), content="Some(1)")
  inspect(r2.recv(), content="Some(2)")
  inspect(r2.recv(), content="None")
  r1.destroy()
  r2.destroy()
}
```

## Thread pool: ThreadPool

`ThreadPool::submit_with_result` creates a oneshot `Receiver[T]` for each task to retrieve its result.

```moonbit check
///|
test {
  let pool = ThreadPool::new(4, 64)
  defer pool.shutdown()
  let rx = pool.submit_with_result(fn() { 40 + 2 })
  defer rx.destroy()
  inspect(rx.recv(), content="Some(42)")
}
```

## Parallel Iterator bridge (initial `par_bridge`)

The `par_*` helpers take MoonBit's builtin `Iterator[T]` (the one used by `for x in ...`).
This implementation is equivalent to Rayon’s `par_bridge`:

- A **single thread** pulls items by calling `Iterator::next()`
- Items are batched into chunks of size `ParConfig.chunk_size` and submitted to the `ThreadPool`
- `ParConfig.max_in_flight` limits how many chunk-tasks can run concurrently (backpressure)

All `*_unordered` helpers **do not preserve order**, so examples check deterministic invariants (length + sum).

### par_map_collect_unordered

```moonbit check
///|
test {
  let pool = ThreadPool::new(4, 64)
  defer pool.shutdown()
  let xs : Array[Int] = []
  for i in 0..<1000 {
    xs.push(i)
  }
  let cfg = ParConfig::default(pool)
  match par_map_collect_unordered(xs.iter(), pool, cfg, fn(x) { x * 2 }) {
    Some(ys) => {
      inspect(ys.length(), content="1000")
      let mut sum = 0
      for y in ys {
        sum += y
      }
      inspect(sum, content="999000")
    }
    None => fail("par_map_collect_unordered failed")
  }
}
```

### par_filter_collect_unordered

```moonbit check
///|
test {
  let pool = ThreadPool::new(4, 64)
  defer pool.shutdown()
  let xs : Array[Int] = []
  for i in 0..<1000 {
    xs.push(i)
  }
  let cfg = ParConfig::default(pool)
  match
    par_filter_collect_unordered(xs.iter(), pool, cfg, fn(x) { x % 2 == 0 }) {
    Some(ys) => {
      inspect(ys.length(), content="500")
      let mut sum = 0
      for y in ys {
        sum += y
      }
      inspect(sum, content="249500")
    }
    None => fail("par_filter_collect_unordered failed")
  }
}
```

### par_each

`par_each` is for side-effectful work (e.g. sending into another channel).
It returns `Bool` to indicate whether all chunks were successfully submitted.

```moonbit check
///|
test {
  let pool = ThreadPool::new(4, 64)
  defer pool.shutdown()
  let xs : Array[Int] = []
  for i in 0..<1000 {
    xs.push(i)
  }
  let (tx, rx) : (Sender[Int], Receiver[Int]) = channel(128)
  let consumer = spawn(fn() {
    defer rx.destroy()
    let mut sum = 0
    while true {
      match rx.recv() {
        Some(v) => sum += v
        None => break
      }
    }
    sum
  })
  let cfg = ParConfig::default(pool)
  let ok = par_each(xs.iter(), pool, cfg, fn(x) { tx.send(x) |> ignore })
  tx.destroy()
  let sum = consumer.join()
  inspect(ok, content="true")
  inspect(sum, content="499500")
}
```

## API overview

- `channel[T](capacity) -> (Sender[T], Receiver[T])`
  - `Sender::{clone, send, try_send, close, destroy}`
  - `Receiver::{recv, try_recv, len, is_closed, close, destroy}`
- `broadcast[T](capacity) -> BroadcastSender[T]`
  - `BroadcastSender::{clone, send, close, destroy, subscribe}`
  - `BroadcastReceiver::{recv, try_recv, destroy}`
- `ThreadPool::{new, size, submit, submit_with_result, close, destroy, join, shutdown}`
- `ParConfig::{new, default}`
- `try_spawn / try_channel / try_broadcast / Handle::try_join`
- `par_each / par_map_collect_unordered / par_filter_collect_unordered / par_map_reduce_unordered / par_array_map_reduce`

## Thread-safety & FFI lifetimes (important)

On the native/C backend, reference counting is not guaranteed to be atomic/thread-safe.
Sharing RC-managed MoonBit objects across threads can lead to flaky bugs.

- Details: `docs/moonbit-refcount.md` (English) / `docs/moonbit-refcount-zh.md` (Chinese)
