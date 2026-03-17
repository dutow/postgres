#include "PgNoPaddingCheck.h"
#include "PgNoPaddingInitCheck.h"
#include "PgRequiresNoPaddingCheck.h"
#include <clang-tidy/ClangTidyModule.h>
#include <clang-tidy/ClangTidyModuleRegistry.h>

namespace clang::tidy::pg {

class PgTidyModule : public ClangTidyModule {
public:
  void addCheckFactories(ClangTidyCheckFactories &CheckFactories) override {
    CheckFactories.registerCheck<PgNoPaddingCheck>("pg-no-padding");
    CheckFactories.registerCheck<PgNoPaddingInitCheck>("pg-no-padding-init");
    CheckFactories.registerCheck<PgRequiresNoPaddingCheck>(
        "pg-requires-no-padding");
  }
};

static ClangTidyModuleRegistry::Add<PgTidyModule>
    X("pg-module", "Checks specific to PostgreSQL.");

} // namespace clang::tidy::pg
