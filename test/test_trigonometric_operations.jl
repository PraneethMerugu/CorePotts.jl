using Test
import CorePotts

@testset "scalar trigonometric callables retain standard numerical semantics" begin
    for (identity, reference) in ((:sine, sin), (:cosine, cos))
        operation = CorePotts.operation_callable(Val(identity), v"1.0.0")
        for T in (Float32, Float64), angle in (T(0), T(-0.25), T(0.75))
            @test @inferred(operation(angle)) === reference(angle)
            expression = CorePotts.OperationExpression(operation, CorePotts.LiteralExpression(angle))
            @test @inferred(CorePotts.evaluate_expression(expression, nothing)) === reference(angle)
            @test @inferred(CorePotts._compiled_evaluate_expression(expression, nothing)) === reference(angle)
        end
        @test @inferred(operation(Int32(1))) === reference(Int32(1))
        @test_throws ArgumentError CorePotts.operation_callable(Val(identity), v"2.0.0")
    end
end
