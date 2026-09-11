import StaticArrays: SVector

@testset "ownership changes clear the complete logical site value" begin
    values = (
        (2.0f0, 0.0f0),
        (
            (active = true, count = Int32(7), polarity = SVector(1.0f0, 2.0f0)),
            (active = false, count = Int32(0), polarity = SVector(0.0f0, 0.0f0)),
        ),
    )
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine()),
            (initial_value, cleared_value) in values
        @testset "$(nameof(typeof(engine))) $(typeof(initial_value))" begin
            schema = CorePotts.StateBlockSchema(
                CorePotts.QualifiedResourceIdentity((), :ownership_marker),
                v"1.0.0", :site, typeof(initial_value), (6, 6), 36,
                :structure_of_arrays, :provided_or_zero, :shape_and_finite,
                :logical, (declared = :ClearOnOwnershipChange,), :declared,
                :bounded_write, :adapt_storage, :copy, :logical_copy,
                :qualified, true,
            )
            layout = CorePotts.StateLayout([schema])
            handle = only(layout.entries).handle
            descriptor_plan = CorePotts.DescriptorExecutionPlan(
                (), layout, CorePotts.WorkspaceLayout(CorePotts.WorkspaceSchema[]),
                (), Any[:ownership_marker], 0, "logical-ownership-state",
                CorePotts.HamiltonianDomainResources(0, 0),
            )
            program = test_program(
                engine; descriptor_plan, ownership_change_handles = (handle,),
                scalar_type = Float32,
            )
            base = test_initial(Float32)
            initial = CorePotts.ProgramInitialState(
                base.ownership, base.cell_kinds; scalar_type = Float32,
                descriptor_state = CorePotts.allocate_auxiliary_state(
                    layout, (fill(initial_value, 6, 6),),
                ),
            )
            runtime = CorePotts.initialize_program(
                program, initial, Float32[], UInt64(1), UInt32(1),
            )
            before = CorePotts.program_snapshot(runtime)
            CorePotts.advance_mcs!(runtime)
            @test !CorePotts.program_failed(runtime)
            @test runtime.accepted > 0
            after = CorePotts.program_snapshot(runtime)
            changed = after.ownership .!= before.ownership
            @test any(changed)
            stored = CorePotts.state_block(after.descriptor_state, handle).values
            @test eltype(stored) === typeof(initial_value)
            @test all(==(cleared_value), stored[changed])
            @test any(==(cleared_value), stored)
            @test any(==(initial_value), stored)
            @test count(==(cleared_value), stored) <= runtime.accepted
            @test all(value -> value == initial_value || value == cleared_value, stored)
            checkpoint = CorePotts.program_checkpoint(runtime)
            restored = CorePotts.restore_program_checkpoint(program, checkpoint)
            @test CorePotts.state_block(restored.descriptor_state, handle).values == stored
        end
    end
end
