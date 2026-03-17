// RUN: %clang_tidy --load=%pg_tidy_lib -checks=-*,pg-no-padding-init %s \
// RUN:   -- -I%include_dir 2>&1 | %FileCheck %s
// CHECK: 1 warning generated.

#include "pg_tidy.h"

struct PG_NO_PADDING AnnotatedStruct {
  int a;
  int b;
};

struct PlainStruct {
  int a;
  int b;
};

void test(void) {
  // CHECK: :[[@LINE+1]]:26: warning: variable 'bad' of type 'struct AnnotatedStruct' (marked pg_no_padding) is not zero-initialized [pg-no-padding-init]
  struct AnnotatedStruct bad;
  bad.a = 1;
  bad.b = 2;

  struct AnnotatedStruct good = {0};
  good.a = 1;

  struct PlainStruct no_warning;
  no_warning.a = 1;
}
