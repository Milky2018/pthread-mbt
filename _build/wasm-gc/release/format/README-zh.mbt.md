# Milky2018/pthread

一个面向 MoonBit `native` 后端的多线程并发库，主打 **share-nothing + message passing**：
尽量避免跨线程共享可变内存，通过类型安全的通道传递消息来协调工作。

提供的能力：

- 线程：`spawn(() -> T) -> Handle[T]` / `Handle[T]::join() -> T`
- MPSC：`channel[T](capacity) -> (Sender[T], Receiver[T])`
- Broadcast：`broadcast[T](capacity) -> BroadcastSender[T]`
- 线程池：`ThreadPool`
- 并行 Iterator（Rayon `par_bridge` 风格起步版）：`par_each` / `par_map_collect_unordered` / `par_filter_collect_unordered`
- 并行归约：`par_map_reduce_unordered` / `par_array_map_reduce`
- 可失败 API：`try_spawn` / `try_channel` / `try_broadcast` / `Handle::try_join`

## 运行示例

本文档代码块用 <code>```moonbit check</code> 标注，可直接运行：

- `moon test README.mbt.md`

下面例子都包含必要的 `destroy()`/`shutdown()`，避免资源泄露。

## 线程：spawn/join

```moonbit check
///|
test {
  let h = spawn(fn() { 40 + 2 })
  inspect(h.join(), content="42")
}
```

## MPSC Channel：多发送者/单接收者

语义要点：

- `Sender::clone()` 增加发送者引用；当所有 sender 都 `destroy()` 后 channel 自动关闭
- `Receiver::recv()` 在“队列为空且已关闭”时返回 `None`

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

## Broadcast：一对多、尽力投递

语义要点：

- `BroadcastSender::send` 返回“成功写入订阅者队列”的数量（满了会丢）
- `BroadcastSender::close/destroy` 后，订阅者在 drain 完队列后 `recv()` 返回 `None`

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

## 线程池：ThreadPool

`ThreadPool::submit_with_result` 会为每个任务创建一个 oneshot `Receiver[T]` 取回结果。

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

## 并行 Iterator（par_bridge 起步版）

`par_*` 系列直接接收 MoonBit 内置 `Iterator[T]`。实现方式类似 Rayon 的 `par_bridge`：

- **单线程**顺序调用 `Iterator::next()` 拉取元素
- 按 `ParConfig.chunk_size` 打包成任务，提交到 `ThreadPool`
- `ParConfig.max_in_flight` 控制最多同时在跑的任务数（背压）

所有 `*_unordered` 都 **不保证输出顺序**（按任务完成顺序汇总），因此示例用“长度 + 和”来做确定性校验。

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

`par_each` 适合并行执行副作用（例如写入另一个 channel）。返回 `Bool` 表示是否全部成功提交（线程池已关闭时会失败）。

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

## API 概览

- `channel[T](capacity) -> (Sender[T], Receiver[T])`
  - `Sender::{clone, send, try_send, close, destroy}`
  - `Receiver::{recv, try_recv, len, is_closed, close, destroy}`
- `broadcast[T](capacity) -> BroadcastSender[T]`
  - `BroadcastSender::{clone, send, close, destroy, subscribe}`
  - `BroadcastReceiver::{recv, try_recv, destroy}`
- `ThreadPool::{new, size, submit, submit_with_result, close, destroy, join, shutdown}`
- `ParConfig::{new, default}`
- `par_each / par_map_collect_unordered / par_filter_collect_unordered`

## 线程安全与 FFI 生命周期（必读）

native/C 后端的引用计数并非线程安全原子操作；跨线程共享“会被 MoonBit RC 管理的对象”可能导致偶现错误。

- 详细说明见：`docs/moonbit-refcount.md`
  - 中文版：`docs/moonbit-refcount-zh.md`
