using Test
import CorePotts
include("fixtures/history_lifecycle_support.jl")

@testset "stochastic retained-state policies require a declared sample correlation" begin
    C = CorePotts
    key = only(C.rng_operation_keys(((namespace = C.RNGNamespace((UInt64(1), UInt64(2))), identity = "history-test-draw"),)))
    expression = C.OperationExpression(
        C.operation_callable(Val(:draw), v"1.0.0"),
        C.LiteralExpression(UInt8(2)), C.LiteralExpression(0.0f0),
        C.LiteralExpression(1.0f0), C.LiteralExpression(key)
    )
    @test_throws r"retained-sample correlation" history_lifecycle_program(C.SequentialProgramEngine(), -1.0f0; expression)
end

@testset "history lifecycle transforms retain cell identity and roll back late samples" begin
    test_history_lifecycle_transactions(
        (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
    )
end

@testset "planned lifecycle state reads the candidate for ordinary and retained state" begin
    C = CorePotts
    runtime, memory = history_lifecycle_program(C.SequentialProgramEngine(), -1.0f0)
    source = only(entry.handle for entry in runtime.program.descriptor_plan.state_layout.entries if entry.schema.identity.name === :source)
    workspace = runtime.lifecycle_workspace
    C.state_block(workspace.staged_descriptor_state, source).values .= Float32[81, 0]
    C.state_block(workspace.staged_descriptor_state, memory).values .= Float32[11 12 13; 10 20 30]
    planned = C._LifecycleRequestView(runtime, workspace, only(runtime.program.lifecycle_plan.descriptors), Int32(1))
    function context(handle, lag)
        C._LifecycleStateContext(
            runtime, planned, UInt64(101), UInt64(201),
            Int32(0), Int32(0), Int32(1), Int32(1), UInt32(1),
            Int32(1), UInt32(1), Int32(0), UInt32(0), C.SourceLifecycleStateRole,
            UInt64(1), handle, CartesianIndex(3, 3), Int32(lag)
        )
    end
    @test C.lifecycle_before_state_value(context(source, 0)) === 8.0f0
    @test C.lifecycle_planned_state_value(context(source, 0)) === 81.0f0
    for lag in 0:2
        @test C.lifecycle_before_state_value(context(memory, lag)) === Float32(3 - lag)
        @test C.lifecycle_planned_state_value(context(memory, lag)) === Float32(13 - lag)
    end
    @test C.state_block(runtime.descriptor_state, memory).values == Float32[1 2 3; 10 20 30]
end
