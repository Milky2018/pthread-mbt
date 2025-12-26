///|
test "two external senders" {
  let (tx, rx) : (Sender[Int], Receiver[Int]) = channel(16)
  let tx1 = tx.clone()
  let tx2 = tx.clone()
  tx.destroy()
  let handle1 = spawn(fn() {
    defer tx1.destroy()
    for i in 0..<100 {
      tx1.send(i) |> ignore
    }
  })
  let handle2 = spawn(fn() {
    defer tx2.destroy()
    for i in 100..<200 {
      tx2.send(i) |> ignore
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
  handle1.join()
  handle2.join()
  inspect(cnt, content="200")
  inspect(sum, content="19900")
}

///|
test "two internal senders" {
  for _ in 0..<50 {
    let (tx, rx) : (Sender[Int], Receiver[Int]) = channel(16)
    let tx1 = tx.clone()
    let tx2 = tx.clone()
    tx.destroy()
    let handle1 = spawn(fn() {
      defer tx1.destroy()
      for i in 0..<100 {
        tx1.send(i) |> ignore
      }
    })
    let handle2 = spawn(fn() {
      defer tx2.destroy()
      for i in 100..<200 {
        tx2.send(i) |> ignore
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
    handle1.join()
    handle2.join()
    assert_eq(cnt, 200)
    assert_eq(sum, 19900)
  }
}

///|
test "send and receive" {
  let (tx, rx) : (Sender[String], Receiver[String]) = channel(1)
  tx.try_send("hello") |> ignore
  inspect(rx.len(), content="1")
  inspect(rx.try_recv(), content="Some(\"hello\")")
  inspect(rx.len(), content="0")
  tx.destroy()
  inspect(rx.recv(), content="None")
  rx.destroy()
}

///|
test "broadcast basic usage" {
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
