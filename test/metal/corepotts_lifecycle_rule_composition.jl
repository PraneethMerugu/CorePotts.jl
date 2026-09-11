using Test
import CorePotts
import Metal

isdefined(@__MODULE__, :test_program) || include(joinpath(@__DIR__, "..", "fixtures", "compiled_program_support.jl"))
include(joinpath(@__DIR__, "..", "fixtures", "lifecycle_value_support.jl"))

@testset "lifecycle rule composition on Metal" begin
    Metal.functional() || error("lifecycle rule composition requires functional Metal")
    Metal.allowscalar(false)
    test_lifecycle_rule_composition(CorePotts.CheckerboardProgramEngine(); adapt_to = Metal.MtlArray)
    @testset "scalar evaluator preserves unselected product state" begin
        test_lifecycle_scalar_evaluator(CorePotts.CheckerboardProgramEngine(); adapt_to = Metal.MtlArray)
    end
    @testset "scalar lifecycle state update" begin
        test_lifecycle_scalar_state(CorePotts.CheckerboardProgramEngine(); adapt_to = Metal.MtlArray)
    end
    @testset "removed cell preserves declared scalar state" begin
        test_lifecycle_preserved_scalar_state(CorePotts.CheckerboardProgramEngine(); adapt_to = Metal.MtlArray)
    end
    @testset "scalar retirement follows evaluator references" begin
        test_lifecycle_scalar_evaluator_order(CorePotts.CheckerboardProgramEngine(); adapt_to = Metal.MtlArray)
    end
end
