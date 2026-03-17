#ifndef PG_NO_PADDING_INIT_CHECK_H
#define PG_NO_PADDING_INIT_CHECK_H

#include <clang-tidy/ClangTidyCheck.h>

namespace clang::tidy::pg {

class PgNoPaddingInitCheck : public ClangTidyCheck {
public:
  PgNoPaddingInitCheck(StringRef Name, ClangTidyContext *Context)
      : ClangTidyCheck(Name, Context) {}
  void registerMatchers(ast_matchers::MatchFinder *Finder) override;
  void check(const ast_matchers::MatchFinder::MatchResult &Result) override;
};

} // namespace clang::tidy::pg

#endif
