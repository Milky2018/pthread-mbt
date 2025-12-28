# MoonBit 引用计数（RC）与 FFI 生命周期管理笔记（重点：native/C 后端）

这份文档专门补全 MoonBit 在 **native/C 后端** 的引用计数与 FFI 生命周期管理细节，并强调一个容易踩坑的点：**引用计数并不保证线程安全**。内容偏“工程实践”，默认你会写一些 C stub 并用 `extern "c"` 绑定。

English version: `docs/moonbit-refcount.md`

> 适用范围：native/C 后端（以及部分 Wasm 后端）。JS / Wasm GC 后端的对象生命周期由宿主 GC 负责，很多细节不同。

---

## 1. 先建立直觉：MoonBit 在 C 后端是“引用计数 GC”

在 native/C 后端，MoonBit runtime 通过 **引用计数（Reference Counting, RC）** 管理绝大多数“盒装对象”（boxed objects）的生命周期。编译器会在合适的位置插入 `incref/decref`，FFI 也必须遵守同一套规则，否则会：

- **过早释放**：use-after-free、数据错乱、偶现测试失败
- **内存泄漏**：忘记 `decref` 或者错误地 `incref`
- **双重释放**：重复 `decref`、错误的 owned/borrow 语义

native/C 后端暴露的核心 API 在 `~/.moon/include/moonbit.h`：

- `void moonbit_incref(void *obj);`
- `void moonbit_decref(void *obj);`

MoonBit 对很多对象会在生成的 C 里直接 inline 引用计数增减（优化后通常是对 `header->rc` 做普通加减）。

---

## 2. 哪些值需要 RC？（值分类）

### 2.1 不需要 RC（unboxed / 标量）
这些类型在 C ABI 中是值传递，不参与引用计数：

- 数值类型：`Int/Int64/UInt/Float/Double/Bool`
- 常量 `enum`（无 payload 的枚举）

### 2.2 需要 RC（boxed）
通常会被分配为 MoonBit 对象并参与引用计数（举例）：

- `String`、`Bytes`
- `Array[T]` / `FixedArray[T]`（以及其他引用类型容器）
- `Ref[T]`
- 闭包（捕获环境的函数值）
- **抽象类型**（`type T`，不是 `#external`）

### 2.3 `#external type`：不做 RC 的“裸指针”
`#external type T` 在 C 后端是 `void*`，MoonBit runtime **不会**对它做 `incref/decref`。

这类类型适合表示：

- 不是 MoonBit 对象的外部指针
- 你希望完全自行管理生命周期（malloc/free、atomic refcount、pthread mutex 等）
- 你需要跨线程共享的句柄（见第 6 节）

---

## 3. FFI 的默认语义：参数是 owned（callee 负责释放）

MoonBit C 后端的默认调用约定是 **owned**：

- 调用者把参数的“所有权”交给被调用的 C 函数
- **被调用的 C 函数**需要在适当时机对参数执行 `moonbit_decref`（如果它最终不返回/不存储该对象）

这条规则是很多 bug 的根源：你写 C stub 时必须明确每个参数是 **borrow** 还是 **owned**。

MoonBit 通过属性来声明语义：

- `#borrow(p1, p2, ...)`：这些参数以 borrow 方式传入（C 不需要在退出时 `decref`）
- `#owned(p)`：显式声明 owned（多数情况下这是默认语义；但写出来能减少误解）

---

## 4. 规则表：写 C stub 时到底该怎么 `incref/decref`？

下面假设参数 `x` 是“需要 RC 的 MoonBit 对象”（比如 `String/Ref[T]/abstract type` 等）。

### 4.1 对 owned 参数（默认语义）
owned 的核心含义：**你拿到了“用完要负责释放”的引用**。

| 在 C 中对 owned 参数做了什么 | 需要做什么引用计数操作 |
|---|---|
| 只是读取、计算，不保存 | 结束时 `moonbit_decref(x)` |
| 存进你自己的数据结构里（之后再用） | 不需要 `incref`（因为你已经拥有它），但你必须在未来某个时刻 `decref` 释放 |
| 传给 MoonBit 函数（MoonBit 会按 owned 处理参数） | 先 `moonbit_incref(x)` 再传（因为被调方会消耗一份引用） |
| 多次使用/多处保存（需要多份引用） | 每额外保存/传递一份就 `moonbit_incref` |
| 返回给 MoonBit 作为返回值 | 直接 return（不要 `decref`） |

#### 4.1.1 owned：每种情况的例子

> 为了把例子聚焦在“引用计数动作”上，下面统一用 `Any`/`void*` 表示一个“需要 RC 的 MoonBit 盒装对象”。如果你换成 `String/Bytes/Ref[T]` 等，同样适用。

**(1) 只是读取、计算，不保存：函数末尾 `decref`**

MoonBit 声明（默认 owned）：

```mbt
extern "c" fn owned_readonly(x : Any) -> Int = "owned_readonly"
```

C 实现：

```c
#include "moonbit.h"
#include <stdint.h>

int32_t owned_readonly(void *x) {
  // ... 只读使用 x，不保存 ...
  int32_t r = x != NULL;
  moonbit_decref(x);
  return r;
}
```

**(2) 存进你自己的数据结构里：不 `incref`，但未来要 `decref`**

MoonBit 声明：

```mbt
#borrow(h)
extern "c" fn holder_set_owned(h : HolderRef, x : Any) -> Unit = "holder_set_owned"

#owned(h)
extern "c" fn holder_free(h : HolderRef) -> Unit = "holder_free"
```

C 实现：

```c
#include "moonbit.h"
#include <stdlib.h>

typedef struct holder {
  void *x; // 持有一个 owned 引用
} holder;

void holder_set_owned(holder *h, void *x) {
  // x 是 owned：直接接管，存进去即可
  if (h->x) {
    moonbit_decref(h->x);
  }
  h->x = x;
  // 注意：这里不要 decref(x)，因为我们把所有权转移到 h 里了
}

void holder_free(holder *h) {
  if (!h) return;
  if (h->x) {
    moonbit_decref(h->x);
  }
  free(h);
}
```

**(3) 传给“会按 owned 消耗参数”的 MoonBit 回调：先 `incref` 再传**

这是最容易踩坑的一类：你手里有一个 owned 的 `x`，但你还需要在调用回调后继续持有/使用它，于是必须先 `incref` 生成一份新的引用给回调消耗。

MoonBit 声明：

```mbt
#borrow(cb)
extern "c" fn call_cb_keep_x(cb : FuncRef[(Any) -> Unit], x : Any) -> Unit =
  "call_cb_keep_x"
```

C 实现：

```c
#include "moonbit.h"

void call_cb_keep_x(void (*cb)(void *), void *x) {
  // x 是 owned，而 cb 也会把它当 owned 参数消耗（回调内部会 decref）
  // 但我们还想在 cb 之后继续“拥有”x，所以先额外 incref 一份给 cb 用：
  moonbit_incref(x);
  cb(x);               // cb 消耗掉上面那份引用

  // ... 此处仍可继续使用 x（因为我们还持有初始那份 owned 引用）...

  moonbit_decref(x);   // 最终我们自己这份也要释放
}
```

**(4) 多次使用/多处保存：每多一份就 `incref`**

典型场景：把同一个对象同时放到两个持有者里（两个地方都要长期持有）。

MoonBit 声明：

```mbt
#borrow(h1, h2)
extern "c" fn fanout_store_two(h1 : HolderRef, h2 : HolderRef, x : Any) -> Unit =
  "fanout_store_two"
```

C 实现：

```c
#include "moonbit.h"

typedef struct holder holder;
void holder_set_owned(holder *h, void *x); // 见上一个例子

void fanout_store_two(holder *h1, holder *h2, void *x) {
  // x 是 owned。我们要让 h1 和 h2 各自都持有一份。
  moonbit_incref(x);      // 复制出第二份引用
  holder_set_owned(h1, x);
  holder_set_owned(h2, x);
  // 注意：这里不需要 decref(x)，因为两份 owned 引用已经分别转移给 h1/h2
}
```

**(5) 返回给 MoonBit：直接 return（不要 `decref`）**

MoonBit 声明：

```mbt
extern "c" fn identity_owned(x : Any) -> Any = "identity_owned"
```

C 实现：

```c
void *identity_owned(void *x) {
  // x 是 owned，作为返回值把所有权交回 MoonBit：直接 return
  return x;
}
```

### 4.2 对 borrow 参数（`#borrow(x)`）
borrow 的核心含义：**你只是临时借用，不拥有释放责任**。

| 在 C 中对 borrow 参数做了什么 | 需要做什么引用计数操作 |
|---|---|
| 只是读取、计算，不保存 | 什么都不做（不要 `decref`） |
| 存进你自己的数据结构里（之后再用） | `moonbit_incref(x)`（因为你要把借来的引用变成你自己的引用） |
| 返回给 MoonBit 作为返回值 | `moonbit_incref(x)` 后再 return（把借来的引用升级为返回值所有权） |

#### 4.2.1 borrow：每种情况的例子

**(1) 只是读取、计算，不保存：什么都不做**

MoonBit 声明：

```mbt
#borrow(x)
extern "c" fn borrow_readonly(x : Any) -> Int = "borrow_readonly"
```

C 实现：

```c
#include <stdint.h>

int32_t borrow_readonly(void *x) {
  // ... 只读使用 x ...
  return x != NULL;
  // 不要 decref(x)
}
```

**(2) 存进你自己的数据结构里：先 `incref` 再保存（你开始拥有它）**

MoonBit 声明：

```mbt
#borrow(h, x)
extern "c" fn holder_set_borrow(h : HolderRef, x : Any) -> Unit = "holder_set_borrow"
```

C 实现：

```c
#include "moonbit.h"

typedef struct holder {
  void *x;
} holder;

void holder_set_borrow(holder *h, void *x) {
  // x 是 borrow：如果要长期保存，就必须 incref，把“借来的”变成“自己的”
  if (x) {
    moonbit_incref(x);
  }
  if (h->x) {
    moonbit_decref(h->x);
  }
  h->x = x;
}
```

**(3) 返回给 MoonBit：先 `incref` 再 return（把 borrow 升级为 owned 返回值）**

MoonBit 声明：

```mbt
#borrow(x)
extern "c" fn return_borrow(x : Any) -> Any = "return_borrow"
```

C 实现：

```c
#include "moonbit.h"

void *return_borrow(void *x) {
  if (x) {
    moonbit_incref(x);
  }
  return x;
}
```

### 4.3 一个最常见的错误
把一个本该 `#borrow` 的参数写成 owned（或默认 owned），但 C stub 没有 `decref`：

- 结果：**泄漏**

反过来，把本该 owned 的参数写成 `#borrow`，C stub 又在退出时 `decref`：

- 结果：**过早释放 / 偶现崩溃**

---

## 5. `type T` vs `#external type T`：两种“指针类型”完全不同

### 5.1 `type T`（抽象类型）
- 在 C ABI 中表现为“指向 MoonBit 对象的指针”
- **会参与 MoonBit RC**（`incref/decref` 会作用在其对象头上）
- 常见搭配：`moonbit_make_external_object(finalize, payload_size)`，让 MoonBit runtime 在对象不再可达时调用 `finalize`

适用场景：资源主要在单线程使用，或者你确信不会出现跨线程并发 `incref/decref`。

### 5.2 `#external type T`
- 在 C ABI 中是 `void*`
- MoonBit runtime **不会**对它做 RC
- 你必须自行管理内存和生命周期

适用场景：你需要跨线程共享一个句柄，或者你希望完全绕开 MoonBit 的 RC。

---

## 6. 线程安全警告：MoonBit 的 RC 不是原子操作

在 native/C 后端，`moonbit_incref/decref`（以及编译器 inline 的版本）通常是对 `rc` 字段做普通加减，并不保证原子性。

这意味着：

- **同一个 MoonBit 盒装对象**如果被多个 pthread 并发 `incref/decref`，会发生数据竞争
- 结果可能是：引用计数丢失更新、过早释放、双重释放、随机数据错乱
- 这种问题往往表现为：**跑很多轮才偶现一次的 flaky 测试**

### 6.1 工程建议（很重要）
如果你要跨线程共享一个“句柄/对象”：

1. **优先用 `#external type` 表示这个句柄**
2. 在 C 侧为该句柄实现你自己的线程安全生命周期管理，例如：
   - 原子引用计数（`stdatomic.h`）
   - 或者用 `pthread_mutex_t` 保护引用计数和销毁逻辑
3. 让 MoonBit 侧的 `clone/destroy` 变成对 C 侧引用计数的 `retain/release`

### 6.2 本仓库里踩过的真实坑（channel 偶发提前关闭）
一个典型例子是“channel 句柄”：

- 句柄被多个线程持有并在不同线程 `destroy()`
- 若句柄类型是 `type ChanRef`（抽象类型），MoonBit 可能在不同线程对其做 RC
- 因为 RC 非线程安全，可能偶发“对象提前释放”，从而出现 `recv()` 提前返回 `None`，测试里 `cnt` 偶尔变小

解决办法：把 `ChanRef` 改成 `#external type`，并让 channel 自己在 C 里用锁/计数管理生命周期（避免 MoonBit RC 参与）。

---

## 7. `#borrow/#owned` 的实战检查清单

写每一个 `extern "c"` 前，逐项确认：

1. 这个参数是不是 MoonBit 盒装对象？（String/Ref/abstract type/closure/Array…）
2. 这个参数在 C 里会不会被保存到全局/结构体/队列中？
3. 这个参数会不会被返回给 MoonBit？
4. 这个参数会不会传给 MoonBit 函数（或另一个 owned 的 FFI）？
5. 是否存在跨线程并发访问（尤其是 `incref/decref`）？

然后选择：

- **只读临时用**：`#borrow(param)` 最安全（C 中不 `decref`）
- **要接管所有权**：保持默认 owned，并在 C 中保证最终释放（`decref` 或者延后释放）
- **跨线程共享句柄**：用 `#external type`，不要让 MoonBit RC 参与

---

## 8. 常见症状与排查思路

### 8.1 症状
- 某个测试偶发失败，差值看起来像“少收了一些消息/少算了一些次数”
- `recv()`/`join()` 等接口偶发提前返回
- 偶发 crash / ASAN 报告 use-after-free（如果你用 ASAN）

### 8.2 排查思路
1. 先找“跨线程共享的 MoonBit 盒装对象”：
   - 抽象类型 `type T` 的句柄
   - 捕获了共享对象的闭包
2. 检查 FFI 标注是否匹配实现：
   - `#borrow` 的参数有没有被 `decref`
   - owned 参数有没有在退出时遗漏 `decref`
3. 检查 C 侧是否把 borrow 参数保存了但没 `incref`

---

## 9. 参考

- `~/.moon/include/moonbit.h`（C 后端 ABI 与 RC API）
- MoonBit 官方文档：FFI / Lifetime management / `#borrow/#owned`（内容较简略，但定义很关键）
