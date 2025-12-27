///|
fn is_space(ch : Char) -> Bool {
  ch == ' ' || ch == '\n' || ch == '\t' || ch == '\r'
}

///|
fn count_words(line : String) -> Int {
  let mut in_word = false
  let mut cnt = 0
  for i in 0..<line.length() {
    let ch = line.at(i).unsafe_to_char()
    if is_space(ch) {
      in_word = false
    } else if !in_word {
      in_word = true
      cnt += 1
    }
  }
  cnt
}

///|
test {
  // A small "example application" for this library:
  // - main thread dispatches lines to workers via channels
  // - workers compute partial results and send them back

  let lines = [
    "MoonBit makes native concurrency approachable.", "We count words using pthread + channels.",
    "Share nothing; communicate by message passing.", "wordcount wordcount wordcount",
  ]
  let worker_n = 3
  let (res_tx, res_rx) : (Sender[Int], Receiver[Int]) = channel(16)
  let worker_txs : Array[Sender[String]] = []
  let worker_handles : Array[Handle[Int]] = []
  for _ in 0..<worker_n {
    let (wtx, wrx) : (Sender[String], Receiver[String]) = channel(8)
    worker_txs.push(wtx)
    let tx = res_tx.clone()
    let handle = spawn(fn() {
      defer wrx.destroy()
      defer tx.destroy()
      let mut partial = 0
      while true {
        match wrx.recv() {
          Some(line) => partial += count_words(line)
          None => break
        }
      }
      tx.send(partial) |> ignore
      partial
    })
    worker_handles.push(handle)
  }

  // Dispatch work (round-robin), then close all worker channels.
  let mut i = 0
  for line in lines {
    worker_txs[i].send(line) |> ignore
    i = (i + 1) % worker_n
  }
  for tx in worker_txs {
    tx.destroy()
  }
  res_tx.destroy()
  let mut total = 0
  let mut got = 0
  while true {
    match res_rx.recv() {
      Some(v) => {
        total += v
        got += 1
      }
      None => break
    }
  }
  res_rx.destroy()

  // Join threads (workers return their local counts).
  let locals : Array[Int] = []
  for h in worker_handles {
    locals.push(h.join())
  }
  inspect(got, content="3")
  inspect(locals, content="[8, 7, 6]")
  inspect(total, content="21")
}
