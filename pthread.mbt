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
fn run_closure(closure : Any) -> Any {
  let closure : () -> Any = cast(closure)
  closure()
}

///|
#borrow(callback)
#owned(data)
extern "c" fn mthread_spawn(
  callback : FuncRef[(Any) -> Any],
  data : Any,
) -> MThreadRef = "mbt_mthread_spawn"

///|
#borrow(mid, res_box)
extern "c" fn mthread_join(mid : MThreadRef, res_box : Any) -> Unit = "mbt_mthread_join"

///|
pub fn[T] spawn(entry : () -> T) -> Handle[T] {
  let entry : () -> Any = fn() { cast(Ref::new(entry())) }
  let mid = mthread_spawn(fn(closure) { run_closure(closure) }, cast(entry))
  { mthread_id: mid }
}

///|
pub fn[T] Handle::join(self : Handle[T]) -> T {
  let res_box : UninitializedArray[Ref[T]] = UninitializedArray::make(1)
  mthread_join(self.mthread_id, cast(res_box))
  res_box[0].val
}

///|
#external
priv type ChanRef

///|
priv struct Phantom[_] {}

///|
extern "c" fn chan_new(capacity : Int) -> ChanRef = "mbt_chan_new"

///|
#borrow(chan)
extern "c" fn chan_retain(chan : ChanRef) -> ChanRef = "mbt_retain"

///|
#borrow(chan)
extern "c" fn chan_sender_clone(chan : ChanRef) -> Unit = "mbt_chan_sender_clone"

///|
#borrow(chan)
extern "c" fn chan_close(chan : ChanRef) -> Unit = "mbt_chan_close"

///|
#borrow(chan)
#owned(msg)
extern "c" fn chan_send(chan : ChanRef, msg : Any) -> Bool = "mbt_chan_send"

///|
#borrow(chan)
#owned(msg)
extern "c" fn chan_try_send(chan : ChanRef, msg : Any) -> Bool = "mbt_chan_try_send"

///|
#borrow(chan, out_box)
extern "c" fn chan_recv(chan : ChanRef, out_box : Any) -> Bool = "mbt_chan_recv"

///|
#borrow(chan, out_box)
extern "c" fn chan_try_recv(chan : ChanRef, out_box : Any) -> Bool = "mbt_chan_try_recv"

///|
#borrow(chan)
extern "c" fn chan_len(chan : ChanRef) -> Int = "mbt_chan_len"

///|
#borrow(chan)
extern "c" fn chan_is_closed(chan : ChanRef) -> Bool = "mbt_chan_is_closed"

///|
#borrow(chan)
extern "c" fn chan_sender_drop(chan : ChanRef) -> Unit = "mbt_chan_sender_drop"

///|
#borrow(chan)
extern "c" fn chan_receiver_drop(chan : ChanRef) -> Unit = "mbt_chan_receiver_drop"

///|
pub struct Sender[T] {
  priv chan_ref : ChanRef
  priv _marker : Phantom[T]
}

///|
pub struct Receiver[T] {
  priv chan_ref : ChanRef
  priv _marker : Phantom[T]
}

///|
pub fn[T] channel(capacity : Int) -> (Sender[T], Receiver[T]) {
  let chan_ref = chan_new(capacity)
  let sender : Sender[T] = { chan_ref, _marker: Phantom::{  } }
  let receiver : Receiver[T] = {
    chan_ref: chan_retain(chan_ref),
    _marker: Phantom::{  },
  }
  (sender, receiver)
}

///|
pub fn[T] oneshot() -> (Sender[T], Receiver[T]) {
  channel(1)
}

///|
pub fn[T] Sender::clone(self : Sender[T]) -> Sender[T] {
  chan_sender_clone(self.chan_ref)
  { chan_ref: chan_retain(self.chan_ref), _marker: Phantom::{  } }
}

///|
pub fn[T] Sender::send(self : Sender[T], msg : T) -> Bool {
  chan_send(self.chan_ref, cast(Ref::new(msg)))
}

///|
pub fn[T] Sender::try_send(self : Sender[T], msg : T) -> Bool {
  chan_try_send(self.chan_ref, cast(Ref::new(msg)))
}

///|
pub fn[T] Sender::close(self : Sender[T]) -> Unit {
  chan_close(self.chan_ref)
}

///|
pub fn[T] Sender::destroy(self : Sender[T]) -> Unit {
  chan_sender_drop(self.chan_ref)
}

///|
pub fn[T] Receiver::recv(self : Receiver[T]) -> T? {
  let out_box : UninitializedArray[Ref[T]] = UninitializedArray::make(1)
  if chan_recv(self.chan_ref, cast(out_box)) {
    Some(out_box[0].val)
  } else {
    None
  }
}

///|
pub fn[T] Receiver::try_recv(self : Receiver[T]) -> T? {
  let out_box : UninitializedArray[Ref[T]] = UninitializedArray::make(1)
  if chan_try_recv(self.chan_ref, cast(out_box)) {
    Some(out_box[0].val)
  } else {
    None
  }
}

///|
pub fn[T] Receiver::len(self : Receiver[T]) -> Int {
  chan_len(self.chan_ref)
}

///|
pub fn[T] Receiver::is_closed(self : Receiver[T]) -> Bool {
  chan_is_closed(self.chan_ref)
}

///|
pub fn[T] Receiver::close(self : Receiver[T]) -> Unit {
  chan_close(self.chan_ref)
}

///|
pub fn[T] Receiver::destroy(self : Receiver[T]) -> Unit {
  chan_receiver_drop(self.chan_ref)
}

///|
priv type BroadcastRef

///|
extern "c" fn broadcast_new(capacity : Int) -> BroadcastRef = "mbt_bcast_new"

///|
#borrow(bcast)
extern "c" fn broadcast_retain(bcast : BroadcastRef) -> BroadcastRef = "mbt_retain"

///|
#borrow(bcast)
extern "c" fn broadcast_sender_clone(bcast : BroadcastRef) -> Unit = "mbt_bcast_sender_clone"

///|
#borrow(bcast)
extern "c" fn broadcast_close(bcast : BroadcastRef) -> Unit = "mbt_bcast_close"

///|
#borrow(bcast)
#owned(msg)
extern "c" fn broadcast_send(bcast : BroadcastRef, msg : Any) -> Int = "mbt_bcast_send"

///|
#borrow(bcast)
extern "c" fn broadcast_subscribe(bcast : BroadcastRef) -> ChanRef = "mbt_bcast_subscribe"

///|
#borrow(bcast, chan)
extern "c" fn broadcast_unsubscribe(
  bcast : BroadcastRef,
  chan : ChanRef,
) -> Unit = "mbt_bcast_unsubscribe"

///|
#borrow(bcast)
extern "c" fn broadcast_sender_drop(bcast : BroadcastRef) -> Unit = "mbt_bcast_sender_drop"

///|
pub struct BroadcastSender[T] {
  priv bcast_ref : BroadcastRef
  priv _marker : Phantom[T]
}

///|
pub struct BroadcastReceiver[T] {
  priv bcast_ref : BroadcastRef
  priv chan_ref : ChanRef
  priv _marker : Phantom[T]
}

///|
pub fn[T] broadcast(capacity : Int) -> BroadcastSender[T] {
  let bcast_ref = broadcast_new(capacity)
  { bcast_ref, _marker: Phantom::{  } }
}

///|
pub fn[T] BroadcastSender::clone(
  self : BroadcastSender[T],
) -> BroadcastSender[T] {
  broadcast_sender_clone(self.bcast_ref)
  { bcast_ref: broadcast_retain(self.bcast_ref), _marker: Phantom::{  } }
}

///|
pub fn[T] BroadcastSender::send(self : BroadcastSender[T], msg : T) -> Int {
  broadcast_send(self.bcast_ref, cast(Ref::new(msg)))
}

///|
pub fn[T] BroadcastSender::close(self : BroadcastSender[T]) -> Unit {
  broadcast_close(self.bcast_ref)
}

///|
pub fn[T] BroadcastSender::destroy(self : BroadcastSender[T]) -> Unit {
  broadcast_sender_drop(self.bcast_ref)
}

///|
pub fn[T] BroadcastSender::subscribe(
  self : BroadcastSender[T],
) -> BroadcastReceiver[T] {
  let bcast_ref = broadcast_retain(self.bcast_ref)
  let chan_ref = broadcast_subscribe(self.bcast_ref)
  { bcast_ref, chan_ref, _marker: Phantom::{  } }
}

///|
pub fn[T] BroadcastReceiver::recv(self : BroadcastReceiver[T]) -> T? {
  let out_box : UninitializedArray[Ref[T]] = UninitializedArray::make(1)
  if chan_recv(self.chan_ref, cast(out_box)) {
    Some(out_box[0].val)
  } else {
    None
  }
}

///|
pub fn[T] BroadcastReceiver::try_recv(self : BroadcastReceiver[T]) -> T? {
  let out_box : UninitializedArray[Ref[T]] = UninitializedArray::make(1)
  if chan_try_recv(self.chan_ref, cast(out_box)) {
    Some(out_box[0].val)
  } else {
    None
  }
}

///|
pub fn[T] BroadcastReceiver::destroy(self : BroadcastReceiver[T]) -> Unit {
  broadcast_unsubscribe(self.bcast_ref, self.chan_ref)
  chan_receiver_drop(self.chan_ref)
}
