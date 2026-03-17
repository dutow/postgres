#include "PgNoPaddingCheck.h"
#include <clang/AST/ASTContext.h>
#include <clang/AST/Attr.h>
#include <clang/AST/RecordLayout.h>
#include <clang/ASTMatchers/ASTMatchFinder.h>

using namespace clang::ast_matchers;

namespace clang::tidy::pg {

static bool recordHasPadding(const RecordDecl *RD, const ASTContext &Ctx) {
  if (RD->isUnion() || RD->isInvalidDecl() || !RD->isCompleteDefinition())
    return false;

  const ASTRecordLayout &Layout = Ctx.getASTRecordLayout(RD);
  unsigned FieldIdx = 0;
  uint64_t PrevEnd = 0;

  for (const auto *Field : RD->fields()) {
    uint64_t FieldOffset = Layout.getFieldOffset(FieldIdx);
    uint64_t FieldSize = Ctx.getTypeSize(Field->getType());

    if (FieldOffset > PrevEnd)
      return true;

    QualType FieldType = Field->getType().getCanonicalType();
    if (const auto *FieldRD = FieldType->getAsRecordDecl()) {
      if (recordHasPadding(FieldRD, Ctx))
        return true;
    }

    PrevEnd = FieldOffset + FieldSize;
    ++FieldIdx;
  }

  uint64_t RecordSize = Ctx.getTypeSize(
      RD->getTypeForDecl()->getCanonicalTypeInternal());
  return PrevEnd < RecordSize;
}

static bool hasNoPaddingAnnotation(const RecordDecl *RD) {
  for (const auto *Attr : RD->specific_attrs<AnnotateAttr>()) {
    if (Attr->getAnnotation() == "pg_no_padding")
      return true;
  }
  return false;
}

void PgNoPaddingCheck::registerMatchers(MatchFinder *Finder) {
  Finder->addMatcher(
      recordDecl(isDefinition(), hasAttr(attr::Annotate)).bind("record"),
      this);
}

void PgNoPaddingCheck::check(const MatchFinder::MatchResult &Result) {
  const auto *RD = Result.Nodes.getNodeAs<RecordDecl>("record");
  if (!RD || !hasNoPaddingAnnotation(RD))
    return;

  const ASTContext &Ctx = *Result.Context;
  checkRecordForPadding(RD, Ctx);
}

void PgNoPaddingCheck::checkRecordForPadding(const RecordDecl *RD,
                                              const ASTContext &Ctx) {
  if (RD->isUnion() || RD->isInvalidDecl() || !RD->isCompleteDefinition())
    return;

  const ASTRecordLayout &Layout = Ctx.getASTRecordLayout(RD);
  unsigned FieldIdx = 0;
  uint64_t PrevEnd = 0;

  for (const auto *Field : RD->fields()) {
    uint64_t FieldOffset = Layout.getFieldOffset(FieldIdx);
    uint64_t FieldSize = Ctx.getTypeSize(Field->getType());

    if (FieldOffset > PrevEnd) {
      uint64_t PadBytes = (FieldOffset - PrevEnd) / Ctx.getCharWidth();
      diag(Field->getLocation(),
           "%0 bytes of padding before field %1")
          << static_cast<unsigned>(PadBytes) << Field;
    }

    QualType FieldType = Field->getType().getCanonicalType();
    if (const auto *FieldRD = FieldType->getAsRecordDecl()) {
      if (FieldRD->isCompleteDefinition() && !FieldRD->isUnion()) {
        if (recordHasPadding(FieldRD, Ctx)) {
          diag(Field->getLocation(),
               "field %0 of type %1 contains internal padding")
              << Field << FieldType;
        }
      }
    }

    PrevEnd = FieldOffset + FieldSize;
    ++FieldIdx;
  }

  uint64_t RecordSize = Ctx.getTypeSize(RD->getTypeForDecl()->getCanonicalTypeInternal());
  if (PrevEnd < RecordSize) {
    uint64_t PadBytes = (RecordSize - PrevEnd) / Ctx.getCharWidth();
    diag(RD->getBraceRange().getEnd(),
         "%0 bytes of trailing padding in struct %1")
        << static_cast<unsigned>(PadBytes) << RD;
  }
}

} // namespace clang::tidy::pg
