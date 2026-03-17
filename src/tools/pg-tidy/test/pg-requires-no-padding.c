// RUN: %clang_tidy --load=%pg_tidy_lib -checks=-*,pg-requires-no-padding %s \
// RUN:   -- -I%include_dir 2>&1 | %FileCheck %s
// CHECK: 3 warnings generated.

#include "pg_tidy.h"

typedef unsigned int uint32;

struct PG_NO_PADDING AnnotatedStruct {
  int a;
  int b;
};

struct NotAnnotatedStruct {
  int a;
  int b;
};

extern void XLogRegisterData(const void *data PG_REQUIRE_NO_PADDING, uint32 len);

extern void NormalFunc(const void *data, uint32 len);

void test_functions(void) {
  struct AnnotatedStruct good;
  struct NotAnnotatedStruct bad;
  int primitive;
  void *opaque = &good;

  XLogRegisterData(&good, sizeof(good));

  // CHECK: :[[@LINE+1]]:20: warning: argument type 'struct NotAnnotatedStruct' passed to no-padding parameter lacks pg_no_padding annotation [pg-requires-no-padding]
  XLogRegisterData(&bad, sizeof(bad));

  XLogRegisterData(&primitive, sizeof(primitive));

  // CHECK: :[[@LINE+1]]:20: warning: cannot verify no-padding requirement on void* argument [pg-requires-no-padding]
  XLogRegisterData(opaque, sizeof(good));

  NormalFunc(&bad, sizeof(bad));
  NormalFunc(opaque, sizeof(good));
}

void test_pointer_variable(void) {
  struct AnnotatedStruct good;
  struct NotAnnotatedStruct bad;

  struct AnnotatedStruct *good_ptr = &good;
  struct NotAnnotatedStruct *bad_ptr = &bad;

  XLogRegisterData(good_ptr, sizeof(*good_ptr));

  // CHECK: :[[@LINE+1]]:20: warning: argument type 'struct NotAnnotatedStruct' passed to no-padding parameter lacks pg_no_padding annotation [pg-requires-no-padding]
  XLogRegisterData(bad_ptr, sizeof(*bad_ptr));
}
