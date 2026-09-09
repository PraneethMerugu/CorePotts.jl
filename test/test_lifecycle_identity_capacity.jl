isdefined(@__MODULE__, :CellStageIncrement) || include("fixtures/cell_stage_support.jl")
isdefined(@__MODULE__, :cell_stage_lifecycle_runtime) || include("fixtures/cell_stage_lifecycle_support.jl")

@testset "lifecycle request capacity covers declared identity domains" begin
    test_lifecycle_identity_preparation()
end

@testset "selection rejects inconsistent identity capacity before mutation" begin
    runtime, handle = cell_stage_lifecycle_runtime(CorePotts.SequentialProgramEngine())
    before = CorePotts.program_snapshot(runtime)
    plan = runtime.program.lifecycle_plan
    for lengths in ((1, 2), (3, 2), (2, 1), (2, 3))
        science = (cell_kinds = zeros(Int16, lengths[1]), cell_generations = zeros(UInt32, lengths[2]))
        @test_throws r"identity storage must match" CorePotts._prepare_lifecycle_selection(
            plan, runtime.lifecycle_workspace, science, Bool[true]
        )
        after = CorePotts.program_snapshot(runtime)
        @test after.ownership == before.ownership
        @test after.cell_kinds == before.cell_kinds
        @test after.cell_generations == before.cell_generations
        @test CorePotts.state_block(after.descriptor_state, handle).values ==
            CorePotts.state_block(before.descriptor_state, handle).values
    end
end

@testset "lifecycle allocation traverses the declared identity capacity" begin
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
        @testset "$(nameof(typeof(engine)))" begin
            test_lifecycle_identity_capacity(engine)
        end
    end
end
