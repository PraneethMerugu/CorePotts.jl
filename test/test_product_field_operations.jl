using Test
import CorePotts
import StaticArrays: SVector

@testset "product-field operations preserve heterogeneous scientific values" begin
    project = CorePotts.operation_callable(Val(:product_field), v"1.0.0")
    for T in (Float32, Float64)
        initial = (amount = T(3), polarity = SVector(T(4), T(5)), nested = (enabled = true,))
        read = CorePotts.LiteralExpression(initial)
        for (ordinal, expected) in enumerate(values(initial))
            expression = CorePotts.OperationExpression(project, read, CorePotts.LiteralExpression(ordinal))
            @test CorePotts.evaluate_expression(expression, nothing) === expected
            @test CorePotts._compiled_evaluate_expression(expression, nothing) === expected
        end
        amount = CorePotts.OperationExpression(project, read, CorePotts.LiteralExpression(1))
        polarity = CorePotts.OperationExpression(project, read, CorePotts.LiteralExpression(2))
        nested = CorePotts.OperationExpression(project, read, CorePotts.LiteralExpression(3))
        enabled = CorePotts.OperationExpression(project, nested, CorePotts.LiteralExpression(1))
        @test @inferred(CorePotts._compiled_evaluate_expression(amount, nothing)) === T(3)
        @test @inferred(CorePotts._compiled_evaluate_expression(polarity, nothing)) === initial.polarity
        @test @inferred(CorePotts._compiled_evaluate_expression(enabled, nothing)) === true
        adapted = CorePotts.Adapt.adapt(Array, polarity)
        @test @inferred(CorePotts._compiled_evaluate_expression(adapted, nothing)) === initial.polarity
        @test_throws ArgumentError CorePotts.OperationExpression(project, read, CorePotts.LiteralExpression(0))
        @test_throws ArgumentError CorePotts.OperationExpression(project, read, CorePotts.LiteralExpression(true))
        outside = CorePotts.OperationExpression(project, read, CorePotts.LiteralExpression(4))
        @test_throws BoundsError CorePotts.evaluate_expression(outside, nothing)
        @test_throws BoundsError CorePotts._compiled_evaluate_expression(outside, nothing)
        computed_ordinal = CorePotts.OperationExpression(identity, CorePotts.LiteralExpression(1))
        unspecialized = CorePotts.OperationExpression(project, read, computed_ordinal)
        @test CorePotts.evaluate_expression(unspecialized, nothing) === T(3)
    end
    @test_throws ArgumentError CorePotts.operation_callable(Val(:product_field), v"2.0.0")
end
