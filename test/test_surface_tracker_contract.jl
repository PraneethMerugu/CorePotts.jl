function surface_program(periodic::NTuple{2, Bool}, offsets::Matrix{Int8})
    resources = CorePotts.HamiltonianDomainResources(
        offsets,
        ones(Float64, size(offsets, 2)),
        Int32[1],
        Int32[size(offsets, 2)],
        Int32[0],
    )
    descriptor_plan = CorePotts.DescriptorExecutionPlan(
        (),
        CorePotts.StateLayout(CorePotts.StateBlockSchema[]),
        CorePotts.WorkspaceLayout(CorePotts.WorkspaceSchema[]),
        (),
        Any[],
        Int32(0),
        "surface-tracker-descriptor-plan-v1",
        resources,
    )
    surface = CorePotts.CellSurfaceTracker(
        Int32(1), Int16(size(offsets, 2))
    )
    tracker_plan = CorePotts.TrackerExecutionPlan(
        (CorePotts.OwnershipCountTracker(), surface),
        "surface-tracker-plan-v1",
    )
    program = CorePotts.CompiledPottsProgram(
        (6, 6),
        periodic,
        offsets,
        2,
        1,
        CorePotts.CompiledScalar(0.0),
        1,
        Float64[],
        (),
        tracker_plan,
        descriptor_plan,
        CorePotts.StageExecutionPlan(),
        CorePotts.SequentialProgramEngine(),
        CorePotts.CPUProgramBackend(),
        "surface-tracker-program-v1",
    )
    return program, surface
end


function relation_pair_program(engine; periodic = (false, false), scalar_type = Float64)
    offsets = Int8[-1 1 0 0; 0 0 -1 1]
    measures = scalar_type[0.5, 0.5, 1.5, 1.5]
    resources = CorePotts.HamiltonianDomainResources(
        offsets, measures, Int32[1], Int32[4], Int32[0],
    )
    state_layout = CorePotts.StateLayout(collect(map(
        ((:neighbor_property, scalar_type), (:predicate_mask, Bool)),
    ) do (name, element_type)
        CorePotts.StateBlockSchema(
            CorePotts.QualifiedResourceIdentity((), name), v"1.0.0", :cell,
            element_type, (4,), 4, :structure_of_arrays,
            :provided_or_zero, :shape_and_finite, :logical, :preserve,
            :declared, :bounded_write, :adapt_storage, :copy, :logical_copy,
            :qualified, true,
        )
    end))
    descriptor_plan = CorePotts.DescriptorExecutionPlan(
        (), state_layout,
        CorePotts.WorkspaceLayout(CorePotts.WorkspaceSchema[]), (), Any[],
        Int32(0), "relation-pair-descriptor-plan-v1", resources,
    )
    key = CorePotts.QualifiedTrackerKey(Val(:spatial_relation_query), 1)
    descriptor = CorePotts.CompilerSPI.SpatialRelationQueryTracker(
        key, 1; maximum_pairs = 8, maximum_contacts = 144,
        maximum_sites = 36,
    )
    tracker_plan = CorePotts.TrackerExecutionPlan(
        (CorePotts.OwnershipCountTracker(), descriptor),
        "relation-pair-tracker-plan-v1",
    )
    program = test_program(
        engine; descriptor_plan, tracker_plan, scalar_type,
    )
    property_entry = only(filter(
        entry -> entry.schema.element_type === scalar_type,
        state_layout.entries))
    mask_entry = only(filter(
        entry -> entry.schema.element_type === Bool,
        state_layout.entries))
    return program, key, descriptor, property_entry.handle, mask_entry.handle
end

function relation_query_state(program)
    values = map(program.descriptor_plan.state_layout.entries) do entry
        entry.schema.element_type === Bool ?
            Bool[false, true, false, false] : Float64[10, 20, 30, 0]
    end
    return CorePotts.allocate_auxiliary_state(
        program.descriptor_plan.state_layout, Tuple(values))
end

@testset "generation-qualified relation-pair tracker" begin
    @test_throws r"same handle" CorePotts.CompilerSPI.SpatialRelationQueryTracker(
        CorePotts.QualifiedTrackerKey(Val(:spatial_relation_query), 2), 1;
        maximum_pairs = 8, maximum_contacts = 144, maximum_sites = 36,
    )
    for engine in (
            CorePotts.SequentialProgramEngine(),
            CorePotts.CheckerboardProgramEngine(),
        )
        program, key, descriptor, property_handle, mask_handle =
            relation_pair_program(engine)
        resources = program.descriptor_plan.domain_resources
        @test CorePotts.CompilerSPI.relation_measures(resources, Int32(1)) ==
            Float64[0.5, 0.5, 1.5, 1.5]
        @test CorePotts.CompilerSPI.relation_measure(resources, Int32(1), 3) == 1.5
        ownership = zeros(Int32, 6, 6)
        ownership[3:4, 3] .= 1
        ownership[3:4, 4] .= 2
        runtime = CorePotts.initialize_program(
            program,
            CorePotts.ProgramInitialState(
                ownership, Int16[2, 2]; scalar_type = Float64,
                cell_generations = UInt32[5, 7],
                descriptor_state = relation_query_state(program),
            ),
            Float64[], UInt64(0x10ca), UInt32(1),
        )
        filter = CorePotts.CompilerSPI.SpatialOwnerFilterRecipe(
            CorePotts.CompilerSPI.StableOwnerIdentityFilter;
            identity_owner = 2, identity_generation = 7)
        read = CorePotts.CompilerSPI.SpatialQueryRead(
            1, filter; metric_handle = 1)
        context = CorePotts._CellStageEvaluationContext(runtime, Int32(1), nothing)
        @test CorePotts.CompilerSPI.qualified_tracker_operation_call(
            CorePotts.ResourceOperation{:contact_edge_count}(), (1,),
            context, Val(:spatial_relation_query), Int32(1), read,
        ) == Int32(2)
        @test CorePotts.CompilerSPI.qualified_tracker_operation_call(
            CorePotts.ResourceOperation{:contact_measure}(), (1,),
            context, Val(:spatial_relation_query), Int32(1), read,
        ) == 3.0
        finite = CorePotts.CompilerSPI.SpatialOwnerFilterRecipe(
            CorePotts.CompilerSPI.OwnerCategoryFilter;
            category = CorePotts.CompilerSPI.FiniteCellOwner)
        finite_read = CorePotts.CompilerSPI.SpatialQueryRead(1, finite)
        @test CorePotts.CompilerSPI.qualified_tracker_operation_call(
            CorePotts.ResourceOperation{:boundary_site_count}(), (1,),
            context, Val(:spatial_relation_query), Int32(1), finite_read,
        ) == Int32(2)
        @test CorePotts.CompilerSPI.qualified_tracker_operation_call(
            CorePotts.ResourceOperation{:neighbor_cell_count}(), (1,),
            context, Val(:spatial_relation_query), Int32(1), finite_read,
        ) == Int32(1)
        property_read = CorePotts.CompilerSPI.SpatialQueryRead(
            1, finite; property_handle)
        @test CorePotts.CompilerSPI.qualified_tracker_operation_call(
            CorePotts.ResourceOperation{:neighbor_property_sum}(), (1,),
            context, Val(:spatial_relation_query), Int32(1), property_read,
        ) == 20.0
        @test CorePotts.CompilerSPI.qualified_tracker_operation_call(
            CorePotts.ResourceOperation{:neighbor_property_mean}(), (1,),
            context, Val(:spatial_relation_query), Int32(1), property_read,
        ) == 20.0
        predicate = CorePotts.CompilerSPI.SpatialOwnerFilterRecipe(
            CorePotts.CompilerSPI.PublishedOwnerPredicateFilter;
            predicate_mask = mask_handle)
        predicate_read = CorePotts.CompilerSPI.SpatialQueryRead(1, predicate)
        @test CorePotts.CompilerSPI.qualified_tracker_operation_call(
            CorePotts.ResourceOperation{:neighbor_cell_count}(), (1,),
            context, Val(:spatial_relation_query), Int32(1), predicate_read,
        ) == Int32(1)
        missing = CorePotts.CompilerSPI.SpatialOwnerFilterRecipe(
            CorePotts.CompilerSPI.StableOwnerIdentityFilter;
            identity_owner = 3, identity_generation = 1)
        empty_read = CorePotts.CompilerSPI.SpatialQueryRead(
            1, missing; property_handle,
            empty = CorePotts.CompilerSPI.ReturnEmptySpatialMean(-1.0))
        @test CorePotts.CompilerSPI.qualified_tracker_operation_call(
            CorePotts.ResourceOperation{:neighbor_property_mean}(), (1,),
            context, Val(:spatial_relation_query), Int32(1), empty_read,
        ) == -1.0
        global_read = CorePotts.CompilerSPI.GlobalSpatialQueryRead(
            1, filter,
            CorePotts.CompilerSPI.SpatialOwnerFilterRecipe(
                CorePotts.CompilerSPI.StableOwnerIdentityFilter;
                identity_owner = 1, identity_generation = 5),
            1,
        )
        model_context = CorePotts._SiteStageEvaluationContext(runtime, 1, nothing)
        @test CorePotts.CompilerSPI.qualified_tracker_operation_call(
            CorePotts.ResourceOperation{:global_interface_measure}(), (),
            model_context, Val(:spatial_relation_query), Int32(1), global_read,
        ) == 3.0

        union_ownership = zeros(Int32, 6, 6)
        union_ownership[3, 3] = 1
        union_ownership[2, 3] = union_ownership[4, 3] = 2
        union_ownership[3, 2] = union_ownership[3, 4] = 3
        union_runtime = CorePotts.initialize_program(
            program,
            CorePotts.ProgramInitialState(
                union_ownership, Int16[2, 2, 2]; scalar_type = Float64,
                cell_generations = UInt32[5, 7, 9],
                descriptor_state = relation_query_state(program),
            ),
            Float64[], UInt64(0x10cb), UInt32(1),
        )
        union_context = CorePotts._CellStageEvaluationContext(
            union_runtime, Int32(1), nothing)
        @test CorePotts.CompilerSPI.qualified_tracker_operation_call(
            CorePotts.ResourceOperation{:boundary_site_count}(), (1,),
            union_context, Val(:spatial_relation_query), Int32(1), finite_read,
        ) == Int32(1)
        @test CorePotts.CompilerSPI.qualified_tracker_operation_call(
            CorePotts.ResourceOperation{:neighbor_cell_count}(), (1,),
            union_context, Val(:spatial_relation_query), Int32(1), finite_read,
        ) == Int32(2)
        @test CorePotts.validate_tracker_state!(
            program.tracker_plan, runtime.trackers, runtime.ownership,
            runtime.cell_kinds, program;
            cell_generations = runtime.cell_generations,
        ) === runtime.trackers

        checkpoint = CorePotts.program_checkpoint(runtime)
        @test checkpoint.snapshot.trackers.values[2] === nothing
        restored = CorePotts.restore_program_checkpoint(program, checkpoint)
        restored_context = CorePotts._CellStageEvaluationContext(
            restored, Int32(1), nothing)
        @test CorePotts.CompilerSPI.qualified_tracker_operation_call(
            CorePotts.ResourceOperation{:contact_edge_count}(), (1,),
            restored_context, Val(:spatial_relation_query), Int32(1), read,
        ) == Int32(2)

        for _ in 1:2
            CorePotts.advance_mcs!(runtime)
            @test !CorePotts.program_failed(runtime)
            @test CorePotts.validate_tracker_state!(
                program.tracker_plan, runtime.trackers, runtime.ownership,
                runtime.cell_kinds, program;
                cell_generations = runtime.cell_generations,
            ) === runtime.trackers
        end
        @test CorePotts.tracker_contract(descriptor).checkpoint isa
            CorePotts.ReconstructTrackerCheckpoint
    end
end

function independent_surface_counts(
        ownership::AbstractMatrix{Int32},
        offsets::Matrix{Int8};
        periodic::NTuple{2, Bool},
        capacity::Integer,
    )
    counts = zeros(Int32, capacity)
    shape = size(ownership)
    for site in CartesianIndices(ownership)
        owner = ownership[site]
        owner > 0 || continue
        observed = Set{CartesianIndex{2}}()
        for column in axes(offsets, 2)
            coordinates = ntuple(2) do dimension
                value = site[dimension] + Int(offsets[dimension, column])
                periodic[dimension] ? mod1(value, shape[dimension]) : value
            end
            all(
                dimension -> 1 <= coordinates[dimension] <= shape[dimension],
                1:2,
            ) || continue
            neighbor = CartesianIndex(coordinates)
            neighbor == site && continue
            neighbor in observed && continue
            push!(observed, neighbor)
            ownership[neighbor] == owner || (counts[Int(owner)] += 1)
        end
    end
    return counts
end

@testset "surface tracker equals an independent ownership oracle" begin
    von_neumann = Int8[
        1 -1 0 0
        0 0 1 -1
    ]
    for periodic in ((false, false), (true, true))
        program, descriptor = surface_program(periodic, von_neumann)
        key = CorePotts.tracker_quantity(descriptor)
        @test key isa CorePotts.QualifiedTrackerKey
        @test CorePotts.tracker_contract(descriptor).checkpoint isa
              CorePotts.ReconstructTrackerCheckpoint

        fixtures = Matrix{Int32}[]
        single = zeros(Int32, 6, 6)
        single[3, 3] = 1
        push!(fixtures, single)
        pair = zeros(Int32, 6, 6)
        pair[3, 3:4] .= 1
        push!(fixtures, pair)
        square = zeros(Int32, 6, 6)
        square[3:4, 3:4] .= 1
        push!(fixtures, square)
        seam = zeros(Int32, 6, 6)
        seam[1, 3] = seam[6, 3] = 1
        push!(fixtures, seam)

        for ownership in fixtures
            runtime = CorePotts.initialize_program(
                program,
                CorePotts.ProgramInitialState(
                    ownership, Int16[2]; scalar_type = Float64
                ),
                Float64[],
                UInt64(0x5fa),
                UInt32(1),
            )
            expected = independent_surface_counts(
                ownership,
                von_neumann;
                periodic,
                capacity = 1,
            )
            @test CorePotts.program_tracker_values(runtime, key) == expected
            @test CorePotts.validate_tracker_state!(
                program.tracker_plan,
                runtime.trackers,
                runtime.ownership,
                runtime.cell_kinds,
                program,
            ) === runtime.trackers

            checkpoint = CorePotts.program_checkpoint(runtime)
            @test checkpoint.snapshot.trackers.values[2] === nothing
            restored = CorePotts.restore_program_checkpoint(program, checkpoint)
            @test CorePotts.program_tracker_values(restored, key) == expected
        end

        ownership = zeros(Int32, 6, 6)
        ownership[3:4, 3:4] .= 1
        runtime = CorePotts.initialize_program(
            program,
            CorePotts.ProgramInitialState(
                ownership, Int16[2]; scalar_type = Float64
            ),
            Float64[],
            UInt64(0x5fb),
            UInt32(1),
        )
        target = CartesianIndex(3, 3)
        source = CorePotts.tracker_source_view(program, runtime.ownership)
        CorePotts.commit_tracker_updates!(
            runtime.trackers,
            program.tracker_plan,
            source,
            target,
            Int32(1),
            Int32(0),
        )
        runtime.ownership[target] = 0
        @test CorePotts.program_tracker_values(runtime, key) ==
              independent_surface_counts(
                  runtime.ownership,
                  von_neumann;
                  periodic,
                  capacity = 1,
              )
        @test CorePotts.validate_tracker_state!(
            program.tracker_plan,
            runtime.trackers,
            runtime.ownership,
            runtime.cell_kinds,
            program,
        ) === runtime.trackers
    end
end
