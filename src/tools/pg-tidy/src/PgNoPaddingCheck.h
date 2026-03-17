#ifndef PG_NO_PADDING_CHECK_H
#define PG_NO_PADDING_CHECK_H

#include <clang-tidy/ClangTidyCheck.h>

namespace clang::tidy::pg {

class PgNoPaddingCheck : public ClangTidyCheck {
public:
  PgNoPaddingCheck(StringRef Name, ClangTidyContext *Context)
      : ClangTidyCheck(Name, Context) {}
  void registerMatchers(ast_matchers::MatchFinder *Finder) override;
  void check(const ast_matchers::MatchFinder::MatchResult &Result) override;

private:
  void checkRecordForPadding(const RecordDecl *RD, const ASTContext &Ctx);
};

} // namespace clang::tidy::pg

#endif
