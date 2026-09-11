include("fixtures/history_ownership_support.jl")

engines = (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
test_history_ownership_failure(engines)
test_history_ownership_change(engines)
