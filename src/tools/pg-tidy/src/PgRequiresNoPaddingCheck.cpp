#include "PgRequiresNoPaddingCheck.h"
#include <clang/AST/ASTContext.h>
#include <clang/AST/Attr.h>
#include <clang/AST/Expr.h>
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

static const QualType resolveArgType(const Expr *Arg) {
  Arg = Arg->IgnoreParenImpCasts();

  if (const auto *UO = dyn_cast<UnaryOperator>(Arg)) {
    if (UO->getOpcode() == UO_AddrOf) {
      return UO->getSubExpr()->IgnoreParenImpCasts()->getType().getCanonicalType();
    }
  }

  QualType T = Arg->getType().getCanonicalType();
  if (T->isPointerType())
    return T->getPointeeType().getCanonicalType();
  if (T->isArrayType())
    return T->getAsArrayTypeUnsafe()->getElementType().getCanonicalType();

  return QualType();
}

void PgRequiresNoPaddingCheck::registerMatchers(MatchFinder *Finder) {
  Finder->addMatcher(callExpr().bind("call"), this);
}

void PgRequiresNoPaddingCheck::check(const MatchFinder::MatchResult &Result) {
  const auto *Call = Result.Nodes.getNodeAs<CallExpr>("call");
  if (!Call)
    return;

  const FunctionDecl *FD = Call->getDirectCallee();
  if (!FD)
    return;

  for (unsigned i = 0; i < FD->getNumParams() && i < Call->getNumArgs(); ++i) {
    const ParmVarDecl *Param = FD->getParamDecl(i);
    if (!hasAnnotation(Param, "pg_requires_no_padding"))
      continue;

    const Expr *Arg = Call->getArg(i);
    QualType ArgType = resolveArgType(Arg);

    if (ArgType.isNull()) {
      diag(Arg->getExprLoc(),
           "cannot verify no-padding requirement on void* argument");
      continue;
    }

    if (ArgType->isVoidType()) {
      diag(Arg->getExprLoc(),
           "cannot verify no-padding requirement on void* argument");
      continue;
    }

    if (ArgType->isBuiltinType())
      continue;

    const RecordDecl *RD = ArgType->getAsRecordDecl();
    if (!RD) {
      diag(Arg->getExprLoc(),
           "cannot verify no-padding requirement on void* argument");
      continue;
    }

    if (!hasAnnotation(RD, "pg_no_padding")) {
      diag(Arg->getExprLoc(),
           "argument type %0 passed to no-padding parameter lacks "
           "pg_no_padding annotation")
          << ArgType;
    }
  }
}

} // namespace clang::tidy::pg
