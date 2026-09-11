using Test
import CorePotts
import StaticArrays: SVector

@testset "fixed-vector operation callables retain concrete numerical values" begin
    construct = CorePotts.operation_callable(Val(:fixed_vector), v"1.0.0")
    index = CorePotts.operation_callable(Val(:fixed_index), v"1.0.0")
    subtract = CorePotts.operation_callable(Val(:subtract), v"1.0.0")
    for T in (Float32, Float64)
        initial = SVector(T(3), T(4))
        @test @inferred(construct(T(3), T(4))) === initial
        @test @inferred(index(initial, 2)) === T(4)
        read = CorePotts.LiteralExpression(initial)
        expression = CorePotts.OperationExpression(
            construct,
            CorePotts.OperationExpression(
                subtract,
                CorePotts.OperationExpression(index, read, CorePotts.LiteralExpression(2)),
            ),
            CorePotts.OperationExpression(index, read, CorePotts.LiteralExpression(1)),
        )
        @test @inferred(CorePotts.evaluate_expression(expression, nothing)) === SVector(T(-4), T(3))
        @test @inferred(CorePotts._compiled_evaluate_expression(expression, nothing)) === SVector(T(-4), T(3))
    end
    @test_throws ArgumentError CorePotts.operation_callable(Val(:fixed_vector), v"2.0.0")
    @test_throws ArgumentError CorePotts.operation_callable(Val(:fixed_index), v"2.0.0")
end
