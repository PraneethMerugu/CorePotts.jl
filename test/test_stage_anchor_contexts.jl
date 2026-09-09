include("fixtures/stage_anchor_support.jl")

@testset "scheduled anchors identify the selected cell and site" begin
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
        @testset "$(nameof(typeof(engine)))" begin
            runtime, handles = stage_anchor_runtime(engine)
            stage_anchor_contract(runtime, handles)
        end
    end
    @test !CorePotts.operation_context_supported(CorePotts.ContextOperation{:energy_anchor_cell}(), CorePotts.AbstractSiteStageEvaluationContext)
    @test !CorePotts.operation_context_supported(CorePotts.ContextOperation{:energy_anchor_site}(), CorePotts.AbstractCellStageEvaluationContext)
end
