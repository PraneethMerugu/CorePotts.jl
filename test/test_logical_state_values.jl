import StaticArrays: SVector, SMatrix, MVector

struct CustomStoredNumber <: Number
    value::Float64
end

function _logical_value_schema(T; name = :polarity, domain = :site, shape = (2, 2))
    return CorePotts.CompilerSPI.StateBlockSchema(
        CorePotts.CompilerSPI.QualifiedResourceIdentity((), name),
        v"1.0.0", domain, T, shape, prod(shape), :structure_of_arrays,
        :provided_or_zero, :shape_and_finite, :logical, :preserve,
        :declared, :bounded_write, :adapt_storage, :copy, :logical_copy,
        :qualified, true,
    )
end

@testset "model stages publish logical values without scalar conversion" begin
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine()), value in (
                true, Int32(7), SVector(1.0f0, 2.0f0),
                (active = true, count = Int32(3), polarity = SVector(1.0f0, 2.0f0)),
            )
        schema = _logical_value_schema(typeof(value); domain = :model, shape = (1,))
        layout = CorePotts.StateLayout([schema])
        handle = only(layout.entries).handle
        descriptor_plan = CorePotts.DescriptorExecutionPlan(
            (), layout, CorePotts.WorkspaceLayout(CorePotts.WorkspaceSchema[]),
            (), Any[:logical_model], 0, "logical-model-values",
            CorePotts.HamiltonianDomainResources(0, 0),
        )
        descriptor = CorePotts.CompiledStageDescriptor(
            CorePotts.StaticEvaluator(CorePotts.LiteralExpression(true)),
            CorePotts.StaticEvaluator(CorePotts.LiteralExpression(value)),
            CorePotts.ModelAssignmentEffect(handle), CorePotts.AfterMCSStage(),
            CorePotts.ResourceAccess((handle,), (handle,), CorePotts.EmptyFootprint(), CorePotts.ModelFootprint(), CorePotts.ExclusiveWriteAccess()),
            CorePotts.DescriptorSupport(true, true, true, true), 1, 1,
        )
        stages = CorePotts.StageExecutionPlan((), (CorePotts.StageDescriptorGroup([descriptor]),), (), 0, 0, "logical-model-stages")
        program = test_program(engine; descriptor_plan, stage_plan = stages)
        base = test_initial()
        initial = CorePotts.ProgramInitialState(base.ownership, base.cell_kinds; scalar_type = Float64, descriptor_state = CorePotts.allocate_auxiliary_state(layout))
        runtime = CorePotts.initialize_program(program, initial, Float64[], UInt64(17), UInt32(1))
        CorePotts.advance_mcs!(runtime)
        values = CorePotts.state_block(runtime.descriptor_state, handle).values
        @test only(values) == value
        @test eltype(values) === typeof(value)
        checkpoint = CorePotts.program_checkpoint(runtime)
        restored = CorePotts.restore_program_checkpoint(program, checkpoint)
        @test CorePotts.state_block(restored.descriptor_state, handle).values == values
    end
end

@testset "custom stored numbers retain their declared validation protocol" begin
    value = CustomStoredNumber(2.0)
    schema = _logical_value_schema(CustomStoredNumber)
    @test all(value -> value.value == 2.0, CorePotts.allocate_state_block(schema, fill(value, 2, 2)).values)
end

@testset "mutable fixed-array zeros are independently owned" begin
    schema = _logical_value_schema(NamedTuple{(:polarity,), Tuple{MVector{2, Float32}}})
    block = CorePotts.allocate_state_block(schema)
    block.values[1].polarity[1] = 3.0f0
    @test block.values[2].polarity == MVector(0.0f0, 0.0f0)
    @test block.values[1].polarity == MVector(3.0f0, 0.0f0)
end

@testset "logical values preserve types and validate every numeric leaf" begin
    for value in (
            true, Int32(7), 2.0f0, SVector(1.0f0, 2.0f0),
            SMatrix{2, 2}(1.0, 2.0, 3.0, 4.0),
            (active = true, count = Int32(3), polarity = SVector(1.0f0, 2.0f0)),
            (Int16(2), (enabled = false, amount = 1.0)),
        )
        schema = _logical_value_schema(typeof(value))
        block = CorePotts.allocate_state_block(schema, fill(value, 2, 2))
        @test size(block.values) == (2, 2)
        @test eltype(block.values) === typeof(value)
        @test all(==(value), block.values)
        initial = CorePotts.allocate_state_block(schema)
        @test eltype(initial.values) === typeof(value)
        @test size(initial.values) == (2, 2)
        exported = CorePotts.settled_state_export(schema, block)
        @test exported == block.values
        @test exported !== block.values
        payload = CorePotts.encode_state_checkpoint(schema, block)
        restored = CorePotts.reconstruct_state_block(schema, payload)
        @test restored.values == block.values
        @test restored.values !== payload
        @test_throws ArgumentError CorePotts.allocate_state_block(schema, fill(value, 3))
    end
    for value in (
            SVector(1.0f0, Inf32),
            SMatrix{2, 2}(1.0, 2.0, NaN, 4.0),
            (active = true, count = Int32(3), polarity = SVector(NaN32, 2.0f0)),
            (Int16(2), (enabled = false, amount = Inf)),
        )
        schema = _logical_value_schema(typeof(value))
        @test_throws ArgumentError CorePotts.allocate_state_block(schema, fill(value, 2, 2))
        @test_throws ArgumentError CorePotts.reconstruct_state_block(schema, fill(value, 2, 2))
    end
    schema = _logical_value_schema(NamedTuple{(:active, :count, :polarity), Tuple{Bool, Int32, SVector{2, Float32}}})
    @test all(==((active = false, count = Int32(0), polarity = SVector(0.0f0, 0.0f0))), CorePotts.allocate_state_block(schema).values)
end
