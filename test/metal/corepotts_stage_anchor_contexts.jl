include("../fixtures/compiled_program_support.jl")
include("../fixtures/stage_anchor_support.jl")

@testset "scheduled cell and site anchors on Metal" begin
    host, handles = stage_anchor_runtime(CorePotts.CheckerboardProgramEngine())
    runtime = CorePotts.adapt_program_runtime(Metal.MtlArray, host)
    stage_anchor_contract(runtime, handles)
end
