///|
pub struct ParConfig {
  chunk_size : Int
  max_in_flight : Int
}

///|
pub fn ParConfig::new(chunk_size : Int, max_in_flight : Int) -> ParConfig {
  { chunk_size, max_in_flight }
}

///|
pub fn ParConfig::default(pool : ThreadPool) -> ParConfig {
  { chunk_size: 1024, max_in_flight: pool.size() * 2 }
}

///|
fn normalize_config(pool : ThreadPool, cfg : ParConfig) -> ParConfig {
  let chunk_size = if cfg.chunk_size <= 0 { 1 } else { cfg.chunk_size }
  let max_in_flight = if cfg.max_in_flight <= 0 {
    pool.size() * 2
  } else {
    cfg.max_in_flight
  }
  let max_in_flight = if max_in_flight <= 0 { 1 } else { max_in_flight }
  { chunk_size, max_in_flight }
}

///|
pub fn[T] par_each(
  iter : Iter[T],
  pool : ThreadPool,
  cfg : ParConfig,
  f : (T) -> Unit,
) -> Bool {
  let cfg = normalize_config(pool, cfg)
  let worker_n = pool.size()
  let (work_tx, work_rx) : (Sender[Array[T]], Receiver[Array[T]]) = channel(
    cfg.max_in_flight,
  )
  let (done_tx, done_rx) : (Sender[Int], Receiver[Int]) = channel(
    cfg.max_in_flight,
  )
  defer done_rx.destroy()
  let mut ok = true
  for _ in 0..<worker_n {
    let rx = receiver_clone(work_rx)
    let tx = done_tx.clone()
    if !pool.submit(fn() {
        defer rx.destroy()
        defer tx.destroy()
        while true {
          match rx.recv() {
            Some(chunk) => {
              for x in chunk {
                f(x)
              }
              tx.send(1) |> ignore
            }
            None => break
          }
        }
      }) {
      ok = false
      rx.destroy()
      tx.destroy()
    }
  }
  work_rx.destroy()
  done_tx.destroy()
  let mut inflight = 0
  let mut chunk : Array[T] = []
  chunk.reserve_capacity(cfg.chunk_size)
  while iter.next() is Some(x) {
    chunk.push(x)
    if chunk.length() >= cfg.chunk_size {
      if work_tx.send(chunk) {
        inflight += 1
      } else {
        ok = false
        break
      }
      chunk = []
      chunk.reserve_capacity(cfg.chunk_size)
      if inflight >= cfg.max_in_flight {
        match done_rx.recv() {
          Some(_) => inflight -= 1
          None => {
            inflight = 0
            break
          }
        }
      }
    }
  }
  if ok && chunk.length() > 0 {
    if work_tx.send(chunk) {
      inflight += 1
    } else {
      ok = false
    }
  }
  work_tx.destroy()
  while inflight > 0 {
    match done_rx.recv() {
      Some(_) => inflight -= 1
      None => break
    }
  }
  ok
}

///|
pub fn[T, U] par_map_collect_unordered(
  iter : Iter[T],
  pool : ThreadPool,
  cfg : ParConfig,
  f : (T) -> U,
) -> Array[U]? {
  let cfg = normalize_config(pool, cfg)
  let worker_n = pool.size()
  let (work_tx, work_rx) : (Sender[Array[T]], Receiver[Array[T]]) = channel(
    cfg.max_in_flight,
  )
  let (out_tx, out_rx) : (Sender[Array[U]], Receiver[Array[U]]) = channel(
    cfg.max_in_flight,
  )
  defer out_rx.destroy()
  let mut ok = true
  for _ in 0..<worker_n {
    let rx = receiver_clone(work_rx)
    let tx = out_tx.clone()
    if !pool.submit(fn() {
        defer rx.destroy()
        defer tx.destroy()
        while true {
          match rx.recv() {
            Some(chunk) => {
              let mapped : Array[U] = []
              mapped.reserve_capacity(chunk.length())
              for x in chunk {
                mapped.push(f(x))
              }
              tx.send(mapped) |> ignore
            }
            None => break
          }
        }
      }) {
      ok = false
      rx.destroy()
      tx.destroy()
    }
  }
  work_rx.destroy()
  out_tx.destroy()
  let mut inflight = 0
  let mut chunk : Array[T] = []
  chunk.reserve_capacity(cfg.chunk_size)
  let out : Array[U] = []
  while iter.next() is Some(x) {
    chunk.push(x)
    if chunk.length() >= cfg.chunk_size {
      if work_tx.send(chunk) {
        inflight += 1
      } else {
        ok = false
        break
      }
      chunk = []
      chunk.reserve_capacity(cfg.chunk_size)
      if inflight >= cfg.max_in_flight {
        match out_rx.recv() {
          Some(mapped) => {
            out.append(mapped)
            inflight -= 1
          }
          None => {
            inflight = 0
            break
          }
        }
      }
    }
  }
  if ok && chunk.length() > 0 {
    if work_tx.send(chunk) {
      inflight += 1
    } else {
      ok = false
    }
  }
  work_tx.destroy()
  while inflight > 0 {
    match out_rx.recv() {
      Some(mapped) => {
        out.append(mapped)
        inflight -= 1
      }
      None => break
    }
  }
  if ok {
    Some(out)
  } else {
    None
  }
}

///|
pub fn[T] par_filter_collect_unordered(
  iter : Iter[T],
  pool : ThreadPool,
  cfg : ParConfig,
  pred : (T) -> Bool,
) -> Array[T]? {
  let cfg = normalize_config(pool, cfg)
  let worker_n = pool.size()
  let (work_tx, work_rx) : (Sender[Array[T]], Receiver[Array[T]]) = channel(
    cfg.max_in_flight,
  )
  let (out_tx, out_rx) : (Sender[Array[T]], Receiver[Array[T]]) = channel(
    cfg.max_in_flight,
  )
  defer out_rx.destroy()
  let mut ok = true
  for _ in 0..<worker_n {
    let rx = receiver_clone(work_rx)
    let tx = out_tx.clone()
    if !pool.submit(fn() {
        defer rx.destroy()
        defer tx.destroy()
        while true {
          match rx.recv() {
            Some(chunk) => {
              let kept : Array[T] = []
              for x in chunk {
                if pred(x) {
                  kept.push(x)
                }
              }
              tx.send(kept) |> ignore
            }
            None => break
          }
        }
      }) {
      ok = false
      rx.destroy()
      tx.destroy()
    }
  }
  work_rx.destroy()
  out_tx.destroy()
  let mut inflight = 0
  let mut chunk : Array[T] = []
  chunk.reserve_capacity(cfg.chunk_size)
  let out : Array[T] = []
  while iter.next() is Some(x) {
    chunk.push(x)
    if chunk.length() >= cfg.chunk_size {
      if work_tx.send(chunk) {
        inflight += 1
      } else {
        ok = false
        break
      }
      chunk = []
      chunk.reserve_capacity(cfg.chunk_size)
      if inflight >= cfg.max_in_flight {
        match out_rx.recv() {
          Some(kept) => {
            out.append(kept)
            inflight -= 1
          }
          None => {
            inflight = 0
            break
          }
        }
      }
    }
  }
  if ok && chunk.length() > 0 {
    if work_tx.send(chunk) {
      inflight += 1
    } else {
      ok = false
    }
  }
  work_tx.destroy()
  while inflight > 0 {
    match out_rx.recv() {
      Some(kept) => {
        out.append(kept)
        inflight -= 1
      }
      None => break
    }
  }
  if ok {
    Some(out)
  } else {
    None
  }
}

///|
pub fn[T, U] par_map_reduce_unordered(
  iter : Iter[T],
  pool : ThreadPool,
  cfg : ParConfig,
  map : (T) -> U,
  reduce : (U, U) -> U,
) -> U? {
  let cfg = normalize_config(pool, cfg)
  let worker_n = pool.size()
  let (work_tx, work_rx) : (Sender[Array[T]], Receiver[Array[T]]) = channel(
    cfg.max_in_flight,
  )
  let (res_tx, res_rx) : (Sender[U], Receiver[U]) = channel(worker_n)
  defer res_rx.destroy()
  let mut ok = true
  for _ in 0..<worker_n {
    let rx = receiver_clone(work_rx)
    let tx = res_tx.clone()
    if !pool.submit(fn() {
        defer rx.destroy()
        defer tx.destroy()
        let mut acc : U? = None
        while true {
          match rx.recv() {
            Some(chunk) =>
              for x in chunk {
                let v = map(x)
                acc = match acc {
                  Some(a) => Some(reduce(a, v))
                  None => Some(v)
                }
              }
            None => break
          }
        }
        if acc is Some(v) {
          tx.send(v) |> ignore
        }
      }) {
      ok = false
      rx.destroy()
      tx.destroy()
    }
  }
  work_rx.destroy()
  res_tx.destroy()
  let mut chunk : Array[T] = []
  chunk.reserve_capacity(cfg.chunk_size)
  while ok && iter.next() is Some(x) {
    chunk.push(x)
    if chunk.length() >= cfg.chunk_size {
      if !work_tx.send(chunk) {
        ok = false
        break
      }
      chunk = []
      chunk.reserve_capacity(cfg.chunk_size)
    }
  }
  if ok && chunk.length() > 0 {
    if !work_tx.send(chunk) {
      ok = false
    }
  }
  work_tx.destroy()
  let mut acc : U? = None
  while true {
    match res_rx.recv() {
      Some(v) =>
        acc = match acc {
          Some(a) => Some(reduce(a, v))
          None => Some(v)
        }
      None => break
    }
  }
  if ok {
    acc
  } else {
    None
  }
}

///|
pub fn[T, U] par_array_map_reduce(
  xs : ArrayView[T],
  pool : ThreadPool,
  cfg : ParConfig,
  map : (T) -> U,
  init : () -> U,
  reduce : (U, U) -> U,
) -> U? {
  let cfg = normalize_config(pool, cfg)
  let worker_n = pool.size()
  let n = xs.length()
  if n <= 0 {
    return Some(init())
  }
  let desired_tasks = if worker_n <= 0 { 1 } else { worker_n }
  let min_chunk_size = (n + desired_tasks - 1) / desired_tasks
  let chunk_size = if cfg.chunk_size < min_chunk_size {
    min_chunk_size
  } else {
    cfg.chunk_size
  }
  let (tx, rx) : (Sender[U], Receiver[U]) = channel(cfg.max_in_flight)
  defer rx.destroy()
  let mut inflight = 0
  let mut ok = true
  let mut acc = init()
  let mut start = 0
  while start < n {
    let end = {
      let end = start + chunk_size
      if end > n {
        n
      } else {
        end
      }
    }
    let s = start
    let e = end
    let rtx = tx.clone()
    let submitted = pool.submit(fn() {
      defer rtx.destroy()
      let mut local_val = init()
      for i in s..<e {
        local_val = reduce(local_val, map(xs[i]))
      }
      rtx.send(local_val) |> ignore
    })
    if submitted {
      inflight += 1
    } else {
      ok = false
      rtx.destroy()
      break
    }
    if inflight >= cfg.max_in_flight {
      match rx.recv() {
        Some(v) => {
          acc = reduce(acc, v)
          inflight -= 1
        }
        None => {
          inflight = 0
          break
        }
      }
    }
    start = end
  }
  tx.destroy()
  while inflight > 0 {
    match rx.recv() {
      Some(v) => {
        acc = reduce(acc, v)
        inflight -= 1
      }
      None => break
    }
  }
  if ok {
    Some(acc)
  } else {
    None
  }
}
