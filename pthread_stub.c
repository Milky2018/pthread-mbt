#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include "moonbit.h"

void *mbt_mthread_spawn(void *(*callback)(void *), void *data)
{
  pthread_t *t = malloc(sizeof(pthread_t));
  pthread_create(t, NULL, callback, data);
  return t;
}

void mbt_mthread_join(void *tid_ptr, void **res_box)
{
  pthread_t *t = (pthread_t *)tid_ptr;
  pthread_join(*t, res_box);
  free(t);
}

void *mbt_mutex_new() {
  pthread_mutex_t *lock = malloc(sizeof(pthread_mutex_t));
  pthread_mutex_init(lock, NULL);
  return lock;
}

void mbt_mutex_lock(void *mutex) {
  pthread_mutex_t *t = (pthread_mutex_t *)mutex;
  pthread_mutex_lock(t);
}

void mbt_mutex_unlock(void *mutex) {
  pthread_mutex_t *t = (pthread_mutex_t *)mutex;
  pthread_mutex_unlock(t);
}

void mbt_mutex_free(void *mutex) {
  pthread_mutex_t *t = (pthread_mutex_t *)mutex;
  pthread_mutex_destroy(t);
  free(t);
}
