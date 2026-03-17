#include "PgNoPaddingInitCheck.h"
#include <clang/AST/ASTContext.h>
#include <clang/AST/Attr.h>
#include <clang/ASTMatchers/ASTMatchFinder.h>

using namespace clang::ast_matchers;

namespace clang::tidy::pg {

static bool hasAnnotation(const Decl *D, StringRef Anno) {
  for (const auto *Attr : D->specific_attrs<AnnotateAttr>()) {
    if (Attr->getAnnotation() == Anno)
      return true;
  }
  return false;
}

void PgNoPaddingInitCheck::registerMatchers(MatchFinder *Finder) {
  Finder->addMatcher(
      varDecl(hasLocalStorage(), unless(parmVarDecl())).bind("var"), this);
}

void PgNoPaddingInitCheck::check(const MatchFinder::MatchResult &Result) {
  const auto *VD = Result.Nodes.getNodeAs<VarDecl>("var");
  if (!VD)
    return;

  QualType T = VD->getType().getCanonicalType();
  const RecordDecl *RD = T->getAsRecordDecl();
  if (!RD)
    return;

  if (!hasAnnotation(RD, "pg_no_padding"))
    return;

  if (VD->hasInit())
    return;

  diag(VD->getLocation(),
       "variable %0 of type %1 (marked pg_no_padding) is not zero-initialized")
      << VD << T;
}

} // namespace clang::tidy::pg
