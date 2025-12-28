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
  { chunk_size: 64, max_in_flight: pool.size() * 2 }
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
  iter : Iterator[T],
  pool : ThreadPool,
  cfg : ParConfig,
  f : (T) -> Unit,
) -> Bool {
  let cfg = normalize_config(pool, cfg)
  let (done_tx, done_rx) : (Sender[Int], Receiver[Int]) = channel(
    cfg.max_in_flight,
  )
  defer done_rx.destroy()
  let mut inflight = 0
  let mut ok = true
  let mut chunk : Array[T] = []
  fn schedule_chunk(chunk : Array[T]) {
    let dtx = done_tx.clone()
    let submitted = pool.submit(fn() {
      defer dtx.destroy()
      for x in chunk {
        f(x)
      }
      dtx.send(1) |> ignore
    })
    if submitted {
      inflight += 1
    } else {
      ok = false
      dtx.destroy()
    }
  }

  while iter.next() is Some(x) {
    chunk.push(x)
    if chunk.length() >= cfg.chunk_size {
      schedule_chunk(chunk)
      chunk = []
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
  if chunk.length() > 0 {
    schedule_chunk(chunk)
    chunk = []
  }
  done_tx.destroy()
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
  iter : Iterator[T],
  pool : ThreadPool,
  cfg : ParConfig,
  f : (T) -> U,
) -> Array[U]? {
  let cfg = normalize_config(pool, cfg)
  let (out_tx, out_rx) : (Sender[Array[U]], Receiver[Array[U]]) = channel(
    cfg.max_in_flight,
  )
  defer out_rx.destroy()
  let mut inflight = 0
  let mut ok = true
  let mut chunk : Array[T] = []
  let out : Array[U] = []
  fn schedule_chunk(chunk : Array[T]) {
    let tx = out_tx.clone()
    let submitted = pool.submit(fn() {
      defer tx.destroy()
      let mapped : Array[U] = []
      for x in chunk {
        mapped.push(f(x))
      }
      tx.send(mapped) |> ignore
    })
    if submitted {
      inflight += 1
    } else {
      ok = false
      tx.destroy()
    }
  }

  while iter.next() is Some(x) {
    chunk.push(x)
    if chunk.length() >= cfg.chunk_size {
      schedule_chunk(chunk)
      chunk = []
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
  if chunk.length() > 0 {
    schedule_chunk(chunk)
    chunk = []
  }
  out_tx.destroy()
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
