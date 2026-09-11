include("fixtures/lifecycle_product_conversion_support.jl")

@testset "product conversion guard follows Julia shape and name rules" begin
    tuple_type = Tuple{Int32, Bool}
    named_type = NamedTuple{(:count, :enabled), tuple_type}
    nested_named_type = NamedTuple{(:total, :flags), Tuple{Int32, named_type}}
    for (target_type, value) in (
            (Tuple{}, ()),
            (NamedTuple{(), Tuple{}}, NamedTuple()),
            (tuple_type, (1.0f0, 1.0f0)),
            (tuple_type, (1.0f0,)),
            (tuple_type, (1.0f0, 1.0f0, 2.0f0)),
            (named_type, (1.0f0, 1.0f0)),
            (named_type, (; count = 1.0f0, enabled = 1.0f0)),
            (named_type, (; enabled = 1.0f0, count = 1.0f0)),
            (named_type, (; count = 1.0f0, other = 1.0f0)),
            (tuple_type, (; count = 1.0f0, enabled = 1.0f0)),
            (nested_named_type, (; total = 2.0f0, flags = (; count = 1.0f0, enabled = 1.0f0))),
            (nested_named_type, (; flags = (; count = 1.0f0, enabled = 1.0f0), total = 2.0f0)),
            (nested_named_type, (; total = 2.0f0, flags = (; enabled = 1.0f0, count = 1.0f0))),
            (nested_named_type, (; flags = (; enabled = 1.0f0, count = 1.0f0), total = 2.0f0)),
        )
        expected = try
            convert(target_type, value)
            true
        catch exception
            exception isa Union{MethodError, ArgumentError, InexactError} || rethrow()
            false
        end
        @test (@inferred CorePotts._lifecycle_value_convertible(target_type, value)) === expected
        if expected
            @test (@inferred CorePotts._convert_lifecycle_state_value(target_type, value)) ==
                convert(target_type, value)
        end
    end
end

@testset "nested native product conversion remains concrete" begin
    for (target_type, value) in (
            (
                Tuple{Int32, Tuple{Bool, StaticArrays.SVector{2, Int32}}},
                (2.0f0, (1.0f0, StaticArrays.SVector(3.0f0, 4.0f0))),
            ),
            (
                NamedTuple{(:count, :nested), Tuple{Int32, Tuple{Bool, StaticArrays.SVector{2, Int32}}}},
                (; count = 2.0f0, nested = (1.0f0, StaticArrays.SVector(3.0f0, 4.0f0))),
            ),
            (
                Tuple{Int32, Tuple{Bool, Tuple{Int32, StaticArrays.SVector{2, Int32}}}},
                (2.0f0, (1.0f0, (3.0f0, StaticArrays.SVector(4.0f0, 5.0f0)))),
            ),
        )
        @test (@inferred CorePotts._lifecycle_value_convertible(target_type, value))
        @test (@inferred CorePotts._convert_lifecycle_state_value(target_type, value)) ==
            convert(target_type, value)
    end
end

@testset "nested lifecycle product conversion preserves or rolls back state" begin
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
        @testset "$(nameof(typeof(engine)))" begin
            test_lifecycle_product_conversions(engine)
        end
    end
end
