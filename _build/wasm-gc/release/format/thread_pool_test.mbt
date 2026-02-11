///|
test {
  let pool = ThreadPool::new(4, 32)
  let rxs : Array[Receiver[Int]] = []
  for i in 0..<50 {
    let v = i
    rxs.push(pool.submit_with_result(fn() { v }))
  }
  pool.shutdown()
  let mut sum = 0
  for rx in rxs {
    match rx.recv() {
      Some(v) => sum += v
      None => ()
    }
    rx.destroy()
  }
  inspect(sum, content="1225")
}
