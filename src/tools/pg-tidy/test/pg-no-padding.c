// RUN: %clang_tidy --load=%pg_tidy_lib -checks=-*,pg-no-padding %s \
// RUN:   -- -I%include_dir 2>&1 | %FileCheck %s
// CHECK: 10 warnings generated.

#include "pg_tidy.h"

// --- Non-annotated struct: no warnings ---
struct NotAnnotated {
  char a;
  int b;
};

// --- Annotated struct with no padding: no warnings ---
struct PG_NO_PADDING NoPadding {
  int a;
  int b;
};

// --- Annotated struct with inter-field padding ---
// CHECK: :[[@LINE+3]]:7: warning: 3 bytes of padding before field 'b' [pg-no-padding]
struct PG_NO_PADDING InterFieldPad {
  char a;
  int b;
};

// --- Annotated struct with trailing padding ---
// CHECK: :[[@LINE+4]]:1: warning: 3 bytes of trailing padding in struct 'TrailingPad' [pg-no-padding]
struct PG_NO_PADDING TrailingPad {
  int a;
  char b;
};

// --- Annotated struct with both inter-field and trailing padding ---
// CHECK: :[[@LINE+4]]:7: warning: 3 bytes of padding before field 'b' [pg-no-padding]
// CHECK: :[[@LINE+5]]:1: warning: 3 bytes of trailing padding in struct 'BothPad' [pg-no-padding]
struct PG_NO_PADDING BothPad {
  char a;
  int b;
  char c;
};

// --- Nested struct with internal padding ---
struct InnerPadded {
  char x;
  int y;
};

// CHECK: :[[@LINE+3]]:22: warning: field 'inner' of type 'struct InnerPadded' contains internal padding [pg-no-padding]
struct PG_NO_PADDING HasPaddedInner {
  int a;
  struct InnerPadded inner;
};

// --- Nested struct without padding: no extra warnings ---
struct InnerClean {
  int x;
  int y;
};

struct PG_NO_PADDING HasCleanInner {
  int a;
  struct InnerClean inner;
};

// --- Deeply nested padding ---
struct DeepInner {
  char a;
  long b;
};

struct MidLevel {
  struct DeepInner d;
};

// CHECK: :[[@LINE+4]]:19: warning: 4 bytes of padding before field 'mid' [pg-no-padding]
// CHECK: :[[@LINE+3]]:19: warning: field 'mid' of type 'struct MidLevel' contains internal padding [pg-no-padding]
struct PG_NO_PADDING DeepNest {
  int a;
  struct MidLevel mid;
};

// --- Empty annotated struct: no warnings ---
struct PG_NO_PADDING AnnotatedEmpty {};

// --- Single field, no padding ---
struct PG_NO_PADDING SingleField {
  int x;
};

// --- All same-size fields, no padding ---
struct PG_NO_PADDING AllSameSize {
  int a;
  int b;
  int c;
};

// --- Multiple padding sites ---
// CHECK: :[[@LINE+5]]:7: warning: 3 bytes of padding before field 'b' [pg-no-padding]
// CHECK: :[[@LINE+6]]:7: warning: 3 bytes of padding before field 'c' [pg-no-padding]
// CHECK: :[[@LINE+7]]:1: warning: 3 bytes of trailing padding in struct 'MultiPad' [pg-no-padding]
struct PG_NO_PADDING MultiPad {
  char a;
  int b;
  char x;
  int c;
  char z;
};

// --- Annotated struct that itself is nested in a non-annotated struct: should still check ---
struct PG_NO_PADDING AnnotatedInner {
  int a;
  int b;
};

struct OuterNotAnnotated {
  char x;
  struct AnnotatedInner inner;
};
