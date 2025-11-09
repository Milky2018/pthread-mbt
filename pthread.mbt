///|
struct Handle[_] {
  mthread_id : MThreadRef
}

///|
priv type MThreadRef

///|
priv type Any

///|
fn[A, B] cast(a : A) -> B = "%identity"

///|
#borrow(call_closure, closure)
extern "c" fn mthread_spawn(
  call_closure : FuncRef[(() -> Unit) -> Unit],
  closure : () -> Unit,
) -> MThreadRef = "mbt_mthread_spawn"

///|
#borrow(res_box)
#owned(mid)
extern "c" fn mthread_join(mid : MThreadRef, res_box : Any) -> Unit = "mbt_mthread_join"

///|
pub fn[T] spawn(entry : () -> T) -> Handle[T] {
  let entry = cast(entry)
  let mid = mthread_spawn(fn(f) { f() }, entry)
  { mthread_id: mid }
}

///|
pub fn[T] Handle::join(self : Handle[T]) -> T {
  let res_box = UninitializedArray::make(1)
  mthread_join(self.mthread_id, cast(res_box))
  res_box[0]
}

///|
struct Mutex[T] {
  mutex_ref : MutexRef
  value : Ref[T]
}

///|
priv type MutexRef

///|
extern "c" fn mutex_new() -> MutexRef = "mbt_mutex_new"

///|
#borrow(mutex)
extern "c" fn mutex_lock(mutex : MutexRef) -> Unit = "mbt_mutex_lock"

///|
#borrow(mutex)
extern "c" fn mutex_unlock(mutex : MutexRef) -> Unit = "mbt_mutex_unlock"

///|
#owned(mutex)
extern "c" fn mutex_free(mutex : MutexRef) -> Unit = "mbt_mutex_free"

///|
pub fn[T] Mutex::new(value : T) -> Mutex[T] {
  { mutex_ref: mutex_new(), value: Ref::new(value) }
}

///|
pub fn[T] Mutex::lock(self : Mutex[T]) -> (T, () -> Unit) {
  mutex_lock(self.mutex_ref)
  fn unlock() {
    mutex_unlock(self.mutex_ref)
  }

  (self.value.val, unlock)
}

///|
pub fn[T] Mutex::destroy(self : Mutex[T]) -> Unit {
  mutex_free(self.mutex_ref)
}

///|
struct Counter {
  val : Int
}

///|
let mutexes : Map[Int, Mutex[Any]] = Map::new()

///|
test {
  let counter : Mutex[Counter] = Mutex::new(Counter::{ val: 0 })
  let x = 100
  defer counter.destroy()
  let handle1 = spawn(fn() {
    // for i in 0..<100 {
    //   let (counter, unlock) = counter.lock()
    //   counter.val += 1
    //   unlock()
    // }
    "Hi"
  })
  let handle2 = spawn(fn() {
    // for i in 0..<100 {
    //   let (counter, unlock) = counter.lock()
    //   counter.val += 1
    //   unlock()
    // }
    "Hello"
  })
  inspect(handle1.join(), content="Hi")
  inspect(handle2.join(), content="Hello")
  inspect(counter.value.val.val, content="0")
}
