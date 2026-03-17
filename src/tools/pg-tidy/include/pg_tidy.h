#ifndef PG_TIDY_H
#define PG_TIDY_H

#if defined(__clang__) || defined(__GNUC__)
#define PG_NO_PADDING __attribute__((annotate("pg_no_padding")))
#define PG_REQUIRE_NO_PADDING __attribute__((annotate("pg_requires_no_padding")))
#else
#define PG_NO_PADDING
#define PG_REQUIRE_NO_PADDING
#endif

#endif
