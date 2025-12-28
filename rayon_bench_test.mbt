///|
fn make_data(n : Int) -> Array[Int] {
  let xs : Array[Int] = []
  for i in 0..<n {
    xs.push(i)
  }
  xs
}

///|
fn seq_map_collect_sum(xs : Array[Int]) -> Int {
  let ys : Array[Int] = []
  for x in xs {
    ys.push(x * 2)
  }
  let mut sum = 0
  for y in ys {
    sum += y
  }
  sum
}

///|
fn seq_filter_collect_sum(xs : Array[Int]) -> Int {
  let ys : Array[Int] = []
  for x in xs {
    if x % 2 == 0 {
      ys.push(x)
    }
  }
  let mut sum = 0
  for y in ys {
    sum += y
  }
  sum
}

///|
test "bench rayon-like: map_collect + sum" (b : @bench.T) {
  let n = 1_000_000
  let xs = make_data(n)
  let pool = ThreadPool::new(4, 256)
  defer pool.shutdown()
  let cfg = ParConfig::new(256, pool.size() * 2)
  b.bench(name="seq", fn() { b.keep(seq_map_collect_sum(xs)) }, count=1)
  b.bench(
    name="par_map_collect_unordered",
    fn() {
      match
        par_map_collect_unordered(xs.iterator(), pool, cfg, fn(x) { x * 2 }) {
        Some(ys) => {
          let mut sum = 0
          for y in ys {
            sum += y
          }
          b.keep(sum)
        }
        None => b.keep(0)
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
        fn(x) { x * 2 },
        fn(a, b) { a + b },
      ) {
        Some(sum) => b.keep(sum)
        None => b.keep(0)
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
        fn(x) { x * 2 },
        fn() { 0 },
        fn(a, b) { a + b },
      ) {
        Some(sum) => b.keep(sum)
        None => b.keep(0)
      }
    },
    count=1,
  )
}

///|
test "bench rayon-like: filter_collect + sum" (b : @bench.T) {
  let n = 50_000
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
          let mut sum = 0
          for y in ys {
            sum += y
          }
          b.keep(sum)
        }
        None => b.keep(0)
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
        fn(x) { if x % 2 == 0 { x } else { 0 } },
        fn(a, b) { a + b },
      ) {
        Some(sum) => b.keep(sum)
        None => b.keep(0)
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
        fn(x) { if x % 2 == 0 { x } else { 0 } },
        fn() { 0 },
        fn(a, b) { a + b },
      ) {
        Some(sum) => b.keep(sum)
        None => b.keep(0)
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
