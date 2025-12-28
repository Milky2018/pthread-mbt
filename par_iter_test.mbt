///|
test {
  let pool = ThreadPool::new(4, 64)
  let xs : Array[Int] = []
  for i in 0..<1000 {
    xs.push(i)
  }
  let cfg = ParConfig::default(pool)
  match par_map_collect_unordered(xs.iterator(), pool, cfg, fn(x) { x * 2 }) {
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
  pool.shutdown()
}
