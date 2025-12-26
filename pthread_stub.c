#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <stdint.h>
#include "moonbit.h"

void *mbt_retain(void *obj) {
  if (obj) {
    moonbit_incref(obj);
  }
  return obj;
}

typedef struct mbt_thread {
  pthread_t t;
  int joined;
} mbt_thread;

typedef struct mbt_spawn_args {
  void *(*callback)(void *);
  void *data;
} mbt_spawn_args;

static void mbt_thread_finalize(void *self) {
  mbt_thread *th = (mbt_thread *)self;
  if (!th->joined) {
    pthread_detach(th->t);
    th->joined = 1;
  }
}

static void *mbt_thread_trampoline(void *arg) {
  mbt_spawn_args *a = (mbt_spawn_args *)arg;
  void *data = a->data;
  void *(*callback)(void *) = a->callback;
  void *res = callback(data);
  if (data) {
    moonbit_decref(data);
  }
  free(a);
  return res;
}

void *mbt_mthread_spawn(void *(*callback)(void *), void *data) {
  mbt_thread *th = (mbt_thread *)moonbit_make_external_object(
    mbt_thread_finalize, sizeof(mbt_thread)
  );
  mbt_spawn_args *a = (mbt_spawn_args *)malloc(sizeof(mbt_spawn_args));
  th->joined = 0;
  a->callback = callback;
  a->data = data;
  pthread_create(&th->t, NULL, mbt_thread_trampoline, a);
  return th;
}

int32_t mbt_mthread_join(void *tid_ptr, void **res_box) {
  mbt_thread *th = (mbt_thread *)tid_ptr;
  pthread_join(th->t, res_box);
  th->joined = 1;
  return 0;
}

void *mbt_mutex_new() {
  pthread_mutex_t *lock = malloc(sizeof(pthread_mutex_t));
  pthread_mutex_init(lock, NULL);
  return lock;
}

int32_t mbt_mutex_lock(void *mutex) {
  pthread_mutex_t *t = (pthread_mutex_t *)mutex;
  pthread_mutex_lock(t);
  return 0;
}

int32_t mbt_mutex_unlock(void *mutex) {
  pthread_mutex_t *t = (pthread_mutex_t *)mutex;
  pthread_mutex_unlock(t);
  return 0;
}

int32_t mbt_mutex_free(void *mutex) {
  pthread_mutex_t *t = (pthread_mutex_t *)mutex;
  pthread_mutex_destroy(t);
  free(t);
  return 0;
}

typedef struct mbt_chan {
  pthread_mutex_t mu;
  pthread_cond_t can_send;
  pthread_cond_t can_recv;
  int destroyed;
  int closed;
  int senders;
  int receivers;
  int64_t capacity;
  int64_t len;
  int64_t head;
  int64_t tail;
  void **buf;
} mbt_chan;

static void mbt_chan_drop_messages(mbt_chan *c) {
  if (!c->buf || c->capacity <= 0) {
    c->len = 0;
    c->head = 0;
    c->tail = 0;
    return;
  }
  while (c->len > 0) {
    void *msg = c->buf[c->head];
    c->buf[c->head] = NULL;
    c->head = (c->head + 1) % c->capacity;
    c->len--;
    if (msg) {
      moonbit_decref(msg);
    }
  }
  c->head = 0;
  c->tail = 0;
}

static void mbt_chan_destroy(mbt_chan *c) {
  pthread_mutex_lock(&c->mu);
  if (c->destroyed) {
    pthread_mutex_unlock(&c->mu);
    return;
  }
  c->destroyed = 1;
  c->closed = 1;
  mbt_chan_drop_messages(c);
  void **buf = c->buf;
  c->buf = NULL;
  pthread_cond_broadcast(&c->can_send);
  pthread_cond_broadcast(&c->can_recv);
  pthread_mutex_unlock(&c->mu);

  free(buf);
  pthread_cond_destroy(&c->can_send);
  pthread_cond_destroy(&c->can_recv);
  pthread_mutex_destroy(&c->mu);
  free(c);
}

void *mbt_chan_new(int32_t capacity) {
  if (capacity <= 0) {
    capacity = 1;
  }
  mbt_chan *c = (mbt_chan *)malloc(sizeof(mbt_chan));
  if (!c) {
    return NULL;
  }
  pthread_mutex_init(&c->mu, NULL);
  pthread_cond_init(&c->can_send, NULL);
  pthread_cond_init(&c->can_recv, NULL);
  c->destroyed = 0;
  c->closed = 0;
  c->senders = 1;
  c->receivers = 1;
  c->capacity = capacity;
  c->len = 0;
  c->head = 0;
  c->tail = 0;
  c->buf = (void **)calloc((size_t)capacity, sizeof(void *));
  if (!c->buf) {
    pthread_cond_destroy(&c->can_send);
    pthread_cond_destroy(&c->can_recv);
    pthread_mutex_destroy(&c->mu);
    free(c);
    return NULL;
  }
  return c;
}

int32_t mbt_chan_sender_clone(void *chan) {
  mbt_chan *c = (mbt_chan *)chan;
  if (!c) {
    return 0;
  }
  pthread_mutex_lock(&c->mu);
  if (!c->destroyed) {
    c->senders++;
  }
  pthread_mutex_unlock(&c->mu);
  return 0;
}

int32_t mbt_chan_receiver_clone(void *chan) {
  mbt_chan *c = (mbt_chan *)chan;
  if (!c) {
    return 0;
  }
  pthread_mutex_lock(&c->mu);
  if (!c->destroyed) {
    c->receivers++;
  }
  pthread_mutex_unlock(&c->mu);
  return 0;
}

int32_t mbt_chan_close(void *chan) {
  mbt_chan *c = (mbt_chan *)chan;
  if (!c) {
    return 0;
  }
  pthread_mutex_lock(&c->mu);
  if (!c->destroyed) {
    c->closed = 1;
    pthread_cond_broadcast(&c->can_send);
    pthread_cond_broadcast(&c->can_recv);
  }
  pthread_mutex_unlock(&c->mu);
  return 0;
}

int32_t mbt_chan_send(void *chan, void *msg) {
  mbt_chan *c = (mbt_chan *)chan;
  if (!c) {
    if (msg) {
      moonbit_decref(msg);
    }
    return 0;
  }
  pthread_mutex_lock(&c->mu);
  while (!c->destroyed && !c->closed && c->receivers > 0 && c->len == c->capacity) {
    pthread_cond_wait(&c->can_send, &c->mu);
  }
  if (c->destroyed || c->closed || c->receivers == 0) {
    pthread_mutex_unlock(&c->mu);
    if (msg) {
      moonbit_decref(msg);
    }
    return 0;
  }
  c->buf[c->tail] = msg;
  c->tail = (c->tail + 1) % c->capacity;
  c->len++;
  pthread_cond_signal(&c->can_recv);
  pthread_mutex_unlock(&c->mu);
  return 1;
}

int32_t mbt_chan_try_send(void *chan, void *msg) {
  mbt_chan *c = (mbt_chan *)chan;
  if (!c) {
    if (msg) {
      moonbit_decref(msg);
    }
    return 0;
  }
  pthread_mutex_lock(&c->mu);
  if (c->destroyed || c->closed || c->receivers == 0 || c->len == c->capacity) {
    pthread_mutex_unlock(&c->mu);
    if (msg) {
      moonbit_decref(msg);
    }
    return 0;
  }
  c->buf[c->tail] = msg;
  c->tail = (c->tail + 1) % c->capacity;
  c->len++;
  pthread_cond_signal(&c->can_recv);
  pthread_mutex_unlock(&c->mu);
  return 1;
}

int32_t mbt_chan_recv(void *chan, void **out_box) {
  mbt_chan *c = (mbt_chan *)chan;
  if (!c) {
    return 0;
  }
  pthread_mutex_lock(&c->mu);
  while (!c->destroyed && !c->closed && c->len == 0) {
    pthread_cond_wait(&c->can_recv, &c->mu);
  }
  if (c->destroyed || c->len == 0) {
    pthread_mutex_unlock(&c->mu);
    return 0;
  }
  void *msg = c->buf[c->head];
  c->buf[c->head] = NULL;
  c->head = (c->head + 1) % c->capacity;
  c->len--;
  pthread_cond_signal(&c->can_send);
  pthread_mutex_unlock(&c->mu);
  out_box[0] = msg;
  return 1;
}

int32_t mbt_chan_try_recv(void *chan, void **out_box) {
  mbt_chan *c = (mbt_chan *)chan;
  if (!c) {
    return 0;
  }
  pthread_mutex_lock(&c->mu);
  if (c->destroyed || c->len == 0) {
    pthread_mutex_unlock(&c->mu);
    return 0;
  }
  void *msg = c->buf[c->head];
  c->buf[c->head] = NULL;
  c->head = (c->head + 1) % c->capacity;
  c->len--;
  pthread_cond_signal(&c->can_send);
  pthread_mutex_unlock(&c->mu);
  out_box[0] = msg;
  return 1;
}

int32_t mbt_chan_len(void *chan) {
  mbt_chan *c = (mbt_chan *)chan;
  if (!c) {
    return 0;
  }
  pthread_mutex_lock(&c->mu);
  int32_t n = c->destroyed ? 0 : (int32_t)c->len;
  pthread_mutex_unlock(&c->mu);
  return n;
}

int32_t mbt_chan_is_closed(void *chan) {
  mbt_chan *c = (mbt_chan *)chan;
  if (!c) {
    return 1;
  }
  pthread_mutex_lock(&c->mu);
  int32_t v = c->destroyed ? 1 : c->closed;
  pthread_mutex_unlock(&c->mu);
  return v;
}

int32_t mbt_chan_sender_drop(void *chan) {
  mbt_chan *c = (mbt_chan *)chan;
  if (!c) {
    return 0;
  }
  pthread_mutex_lock(&c->mu);
  if (c->destroyed) {
    pthread_mutex_unlock(&c->mu);
    return 0;
  }
  int dropped = 0;
  if (c->senders > 0) {
    c->senders--;
    dropped = 1;
  }
  if (c->senders == 0) {
    c->closed = 1;
    pthread_cond_broadcast(&c->can_send);
    pthread_cond_broadcast(&c->can_recv);
  }
  int should_cleanup = (c->senders == 0 && c->receivers == 0);
  pthread_mutex_unlock(&c->mu);
  if (dropped && should_cleanup) {
    mbt_chan_destroy(c);
  }
  return 0;
}

int32_t mbt_chan_receiver_drop(void *chan) {
  mbt_chan *c = (mbt_chan *)chan;
  if (!c) {
    return 0;
  }
  pthread_mutex_lock(&c->mu);
  if (c->destroyed) {
    pthread_mutex_unlock(&c->mu);
    return 0;
  }
  int dropped = 0;
  if (c->receivers > 0) {
    c->receivers--;
    dropped = 1;
  }
  if (c->receivers == 0) {
    c->closed = 1;
    mbt_chan_drop_messages(c);
    pthread_cond_broadcast(&c->can_send);
    pthread_cond_broadcast(&c->can_recv);
  }
  int should_cleanup = (c->senders == 0 && c->receivers == 0);
  pthread_mutex_unlock(&c->mu);
  if (dropped && should_cleanup) {
    mbt_chan_destroy(c);
  }
  return 0;
}

typedef struct mbt_bcast {
  pthread_mutex_t mu;
  int destroyed;
  int closed;
  int senders;
  int32_t capacity;
  int64_t subs_len;
  int64_t subs_cap;
  void **subs;
} mbt_bcast;

static void mbt_bcast_cleanup(mbt_bcast *b) {
  pthread_mutex_lock(&b->mu);
  if (b->destroyed) {
    pthread_mutex_unlock(&b->mu);
    return;
  }
  b->destroyed = 1;
  b->closed = 1;
  void **subs = b->subs;
  int64_t n = b->subs_len;
  b->subs = NULL;
  b->subs_len = 0;
  b->subs_cap = 0;
  for (int64_t i = 0; i < n; i++) {
    void *ch = subs[i];
    if (ch) {
      mbt_chan_sender_drop(ch);
    }
  }
  pthread_mutex_unlock(&b->mu);
  free(subs);
}

static void mbt_bcast_finalize(void *self) {
  mbt_bcast *b = (mbt_bcast *)self;
  mbt_bcast_cleanup(b);
  pthread_mutex_destroy(&b->mu);
}

void *mbt_bcast_new(int32_t capacity) {
  if (capacity <= 0) {
    capacity = 1;
  }
  mbt_bcast *b = (mbt_bcast *)moonbit_make_external_object(
    mbt_bcast_finalize, sizeof(mbt_bcast)
  );
  pthread_mutex_init(&b->mu, NULL);
  b->destroyed = 0;
  b->closed = 0;
  b->senders = 1;
  b->capacity = capacity;
  b->subs_len = 0;
  b->subs_cap = 0;
  b->subs = NULL;
  return b;
}

int32_t mbt_bcast_sender_clone(void *bcast) {
  mbt_bcast *b = (mbt_bcast *)bcast;
  pthread_mutex_lock(&b->mu);
  if (!b->destroyed) {
    b->senders++;
  }
  pthread_mutex_unlock(&b->mu);
  return 0;
}

int32_t mbt_bcast_close(void *bcast) {
  mbt_bcast *b = (mbt_bcast *)bcast;
  pthread_mutex_lock(&b->mu);
  if (b->destroyed || b->closed) {
    pthread_mutex_unlock(&b->mu);
    return 0;
  }
  b->closed = 1;
  void **subs = b->subs;
  int64_t n = b->subs_len;
  b->subs = NULL;
  b->subs_len = 0;
  b->subs_cap = 0;
  for (int64_t i = 0; i < n; i++) {
    void *ch = subs[i];
    if (ch) {
      mbt_chan_sender_drop(ch);
    }
  }
  pthread_mutex_unlock(&b->mu);
  free(subs);
  return 0;
}

static int mbt_bcast_add_subscriber_locked(mbt_bcast *b, void *chan) {
  if (b->subs_len == b->subs_cap) {
    int64_t new_cap = b->subs_cap == 0 ? 4 : b->subs_cap * 2;
    void **new_subs = (void **)realloc(b->subs, (size_t)new_cap * sizeof(void *));
    if (!new_subs) {
      return 0;
    }
    b->subs = new_subs;
    b->subs_cap = new_cap;
  }
  b->subs[b->subs_len++] = chan;
  return 1;
}

void *mbt_bcast_subscribe(void *bcast) {
  mbt_bcast *b = (mbt_bcast *)bcast;
  pthread_mutex_lock(&b->mu);
  int closed = b->destroyed || b->closed;
  int32_t cap = b->capacity;
  pthread_mutex_unlock(&b->mu);

  void *ch = mbt_chan_new(cap);
  if (closed) {
    mbt_chan_sender_drop(ch);
    return ch;
  }

  pthread_mutex_lock(&b->mu);
  if (b->destroyed || b->closed) {
    pthread_mutex_unlock(&b->mu);
    mbt_chan_sender_drop(ch);
    return ch;
  }
  int ok = mbt_bcast_add_subscriber_locked(b, ch);
  pthread_mutex_unlock(&b->mu);
  if (!ok) {
    mbt_chan_sender_drop(ch);
  }
  return ch;
}

int32_t mbt_bcast_unsubscribe(void *bcast, void *chan) {
  mbt_bcast *b = (mbt_bcast *)bcast;
  int found = 0;
  pthread_mutex_lock(&b->mu);
  if (!b->destroyed && b->subs_len > 0) {
    for (int64_t i = 0; i < b->subs_len; i++) {
      if (b->subs[i] == chan) {
        b->subs[i] = b->subs[b->subs_len - 1];
        b->subs_len--;
        found = 1;
        break;
      }
    }
  }
  pthread_mutex_unlock(&b->mu);
  if (found) {
    mbt_chan_sender_drop(chan);
  }
  return 0;
}

int32_t mbt_bcast_send(void *bcast, void *msg) {
  mbt_bcast *b = (mbt_bcast *)bcast;

  pthread_mutex_lock(&b->mu);
  if (b->destroyed || b->closed) {
    pthread_mutex_unlock(&b->mu);
    if (msg) {
      moonbit_decref(msg);
    }
    return 0;
  }
  int32_t delivered = 0;
  for (int64_t i = 0; i < b->subs_len; i++) {
    void *ch = b->subs[i];
    if (!ch) {
      continue;
    }
    if (msg) {
      moonbit_incref(msg);
    }
    if (mbt_chan_try_send(ch, msg)) {
      delivered++;
    }
  }
  pthread_mutex_unlock(&b->mu);
  if (msg) {
    moonbit_decref(msg);
  }
  return delivered;
}

int32_t mbt_bcast_sender_drop(void *bcast) {
  mbt_bcast *b = (mbt_bcast *)bcast;
  pthread_mutex_lock(&b->mu);
  if (b->destroyed) {
    pthread_mutex_unlock(&b->mu);
    return 0;
  }
  if (b->senders > 0) {
    b->senders--;
  }
  int should_cleanup = (b->senders == 0);
  pthread_mutex_unlock(&b->mu);
  if (should_cleanup) {
    mbt_bcast_cleanup(b);
  }
  return 0;
}
