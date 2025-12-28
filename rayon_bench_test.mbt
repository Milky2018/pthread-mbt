///|
fn make_data(n : Int) -> Array[Int] {
  let xs : Array[Int] = []
  for i in 0..<n {
    xs.push(i)
  }
  xs
}

///|
fn splitmix64(x : UInt64) -> UInt64 {
  let mut z = x + 0x9E3779B97F4A7C15UL
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL
  z ^ (z >> 31)
}

///|
fn heavy(x : Int) -> UInt64 {
  let mut v = x.to_uint64()
  for _ in 0..<50 {
    v = splitmix64(v)
  }
  v
}

///|
fn seq_map_collect_sum(xs : Array[Int]) -> UInt64 {
  let ys : Array[UInt64] = []
  for x in xs {
    ys.push(heavy(x))
  }
  let mut sum = 0UL
  for y in ys {
    sum += y
  }
  sum
}

///|
fn seq_filter_collect_sum(xs : Array[Int]) -> UInt64 {
  let ys : Array[UInt64] = []
  for x in xs {
    if x % 2 == 0 {
      ys.push(heavy(x))
    }
  }
  let mut sum = 0UL
  for y in ys {
    sum += y
  }
  sum
}

///|
test "bench rayon-like: map_collect + sum" (b : @bench.T) {
  // Use a CPU-heavy per-item workload (not `x * 2`) so parallelism has a chance
  // to amortize scheduling and channel overhead.
  let n = 200_000
  let xs = make_data(n)
  let pool = ThreadPool::new(4, 256)
  defer pool.shutdown()
  let cfg = ParConfig::new(256, pool.size() * 2)
  b.bench(name="seq", fn() { b.keep(seq_map_collect_sum(xs)) }, count=1)
  b.bench(
    name="par_map_collect_unordered",
    fn() {
      match
        par_map_collect_unordered(xs.iterator(), pool, cfg, fn(x) { heavy(x) }) {
        Some(ys) => {
          let mut sum = 0UL
          for y in ys {
            sum += y
          }
          b.keep(sum)
        }
        None => b.keep(0UL)
      }
    },
    count=1,
  )
  b.bench(
    name="par_map_reduce_unordered",
    fn() {
      match par_map_reduce_unordered(
        xs.iterator(),
        pool,
        cfg,
        fn(x) { heavy(x) },
        fn(a, b) { a + b },
      ) {
        Some(sum) => b.keep(sum)
        None => b.keep(0UL)
      }
    },
    count=1,
  )
  b.bench(
    name="par_array_map_reduce",
    fn() {
      match par_array_map_reduce(
        xs[:],
        pool,
        cfg,
        fn(x) { heavy(x) },
        fn() { 0UL },
        fn(a, b) { a + b },
      ) {
        Some(sum) => b.keep(sum)
        None => b.keep(0UL)
      }
    },
    count=1,
  )
}

///|
test "bench rayon-like: filter_collect + sum" (b : @bench.T) {
  let n = 200_000
  let xs = make_data(n)
  let pool = ThreadPool::new(4, 256)
  defer pool.shutdown()
  let cfg = ParConfig::new(256, pool.size() * 2)
  b.bench(name="seq", fn() { b.keep(seq_filter_collect_sum(xs)) }, count=1)
  b.bench(
    name="par_filter_collect_unordered",
    fn() {
      match
        par_filter_collect_unordered(xs.iterator(), pool, cfg, fn(x) {
          x % 2 == 0
        }) {
        Some(ys) => {
          let mut sum = 0UL
          for y in ys {
            sum += heavy(y)
          }
          b.keep(sum)
        }
        None => b.keep(0UL)
      }
    },
    count=1,
  )
  b.bench(
    name="par_map_reduce_unordered (filter-as-map)",
    fn() {
      match par_map_reduce_unordered(
        xs.iterator(),
        pool,
        cfg,
        fn(x) { if x % 2 == 0 { heavy(x) } else { 0UL } },
        fn(a, b) { a + b },
      ) {
        Some(sum) => b.keep(sum)
        None => b.keep(0UL)
      }
    },
    count=1,
  )
  b.bench(
    name="par_array_map_reduce (filter-as-map)",
    fn() {
      match par_array_map_reduce(
        xs[:],
        pool,
        cfg,
        fn(x) { if x % 2 == 0 { heavy(x) } else { 0UL } },
        fn() { 0UL },
        fn(a, b) { a + b },
      ) {
        Some(sum) => b.keep(sum)
        None => b.keep(0UL)
      }
    },
    count=1,
  )
}

///|
test "bench rayon-like: threadpool submit_with_result" (b : @bench.T) {
  let pool = ThreadPool::new(4, 256)
  defer pool.shutdown()
  b.bench(
    name="submit_with_result + recv",
    fn() {
      let rx = pool.submit_with_result(fn() { 1 })
      match rx.recv() {
        Some(v) => b.keep(v)
        None => b.keep(0)
      }
      rx.destroy()
    },
    count=1,
  )
}
