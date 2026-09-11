include("fixtures/lifecycle_value_support.jl")

@testset "lifecycle rules update only declared state targets" begin
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
        @testset "$(nameof(typeof(engine)))" begin
            test_lifecycle_rule_composition(engine)
            @testset "scalar evaluator preserves unselected product state" begin
                test_lifecycle_scalar_evaluator(engine)
            end
            @testset "scalar lifecycle state update" begin
                test_lifecycle_scalar_state(engine)
            end
            @testset "removed cell preserves declared scalar state" begin
                test_lifecycle_preserved_scalar_state(engine)
            end
            @testset "scalar retirement follows evaluator references" begin
                test_lifecycle_scalar_evaluator_order(engine)
            end
        end
    end
end
