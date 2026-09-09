function empty_logical_schema(name, shape; element_type = Float32)
    return CorePotts.StateBlockSchema(
        CorePotts.QualifiedResourceIdentity((), name), v"1.0.0", :cell,
        element_type, shape, 1, :structure_of_arrays, :provided_or_zero,
        :shape_and_finite, :logical, :preserve, :declared, :bounded_write,
        :adapt_storage, :copy, :logical_copy, :qualified, true,
    )
end

@testset "empty logical blocks preserve bank boundaries" begin
    for shapes in (((0,), (2,), (0,), (1,), (0,)), ((0,), (0,)))
        schemas = [empty_logical_schema(Symbol(:signal_, index), shape) for (index, shape) in enumerate(shapes)]
        layout = CorePotts.StateLayout(schemas)
        state = CorePotts.allocate_auxiliary_state(layout)
        for (index, entry) in enumerate(layout.entries)
            values = CorePotts.state_block(state, entry.handle).values
            @test size(values) == shapes[index]
            @test eltype(values) === Float32
            if isempty(values)
                @test_throws BoundsError values[1]
                @test_throws BoundsError values[1] = 9.0f0
            else
                fill!(values, Float32(index))
            end
        end
        for transformed in (CorePotts.copy_auxiliary_state(layout, state), CorePotts.adapt_auxiliary_state(Array, layout, state))
            for (index, entry) in enumerate(layout.entries)
                original = CorePotts.state_block(state, entry.handle).values
                copied = CorePotts.state_block(transformed, entry.handle).values
                @test size(copied) == shapes[index]
                @test copied == original
                @test all(==(Float32(index)), copied)
                payload = CorePotts.encode_state_checkpoint(entry.schema, CorePotts.DenseStateBlock(Array(original)))
                @test CorePotts.reconstruct_state_block(entry.schema, payload).values == original
            end
        end
    end
    for shape in ((0,), (2, 0), (0, 3))
        schema = empty_logical_schema(:empty_product, shape; element_type = NamedTuple{(:enabled, :value), Tuple{Bool, Float32}})
        values = CorePotts.allocate_state_block(schema).values
        @test isempty(values)
        @test size(values) == shape
        @test eltype(values) === schema.element_type
    end
    @test_throws ArgumentError CorePotts.BlockLocation(0, (0,))
    @test_throws ArgumentError CorePotts.BlockLocation(1, (-1,))
    maximum_index = Int64(typemax(Int32))
    @test CorePotts.BlockLocation(maximum_index, (0, maximum_index)).offset == maximum_index
    @test CorePotts.BlockLocation(1, (0, maximum_index)).shape == (0, maximum_index)
    @test CorePotts.BlockLocation(1, ()).shape == ()
    @test_throws r"offset.*Int32" CorePotts.BlockLocation(maximum_index + 1, (0,))
    @test_throws r"dimensions.*Int32" CorePotts.BlockLocation(1, (0, maximum_index + 1))
    @test_throws ArgumentError CorePotts.StateLayout([empty_logical_schema(:negative, (-1,))])
    @test_throws ArgumentError CorePotts.allocate_state_block(empty_logical_schema(:negative, (-1,)))
end
