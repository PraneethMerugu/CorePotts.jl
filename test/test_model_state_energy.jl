function model_volume_energy_plan()
    schema = CorePotts.StateBlockSchema(
        CorePotts.QualifiedResourceIdentity((), :volume_coefficient), v"1.0.0",
        :model, Float32, (), 1, :structure_of_arrays, :provided_or_zero,
        :shape_and_finite, :logical, :preserve, :declared, :bounded_write,
        :adapt_storage, :copy, :logical_copy, :qualified, true,
    )
    layout = CorePotts.StateLayout([schema])
    handle = only(layout.entries).handle
    coefficient = CorePotts.OperationExpression(
        CorePotts.operation_callable(Val(:model_bound_state_value), v"1.0.0"),
        CorePotts.StateExpression(handle),
    )
    anchor = CorePotts.ContextExpression(CorePotts.ContextOperation{:energy_anchor_cell}())
    volume = CorePotts.OperationExpression(CorePotts.ResourceOperation{:cell_volume}(), anchor)
    expression = CorePotts.OperationExpression(
        *, coefficient,
        CorePotts.OperationExpression(^, volume, CorePotts.LiteralExpression(2))
    )
    role = CorePotts.HamiltonianRole(
        CorePotts.CellEnergyDomainPlan(Int16(2)),
        CorePotts.SourceTargetCellsAffectedPlan(Int32(2)),
    )
    descriptor = CorePotts.ProposalDescriptor(
        CorePotts.StaticEvaluator(expression),
        CorePotts.ResourceAccess(
            (handle,), (), CorePotts.OwnerFootprint(),
            CorePotts.EmptyFootprint(), CorePotts.NoWriteAccess()
        ),
        CorePotts.DescriptorSupport(true, true, true, true), (handle,), (), role, 1,
    )
    plan = CorePotts.DescriptorExecutionPlan(
        (CorePotts.ProposalDescriptorGroup([descriptor], (handle,), (), :unsplit),),
        layout, CorePotts.WorkspaceLayout(CorePotts.WorkspaceSchema[]), (),
        Any[:model_volume_energy], 1, "model-volume-energy",
        CorePotts.HamiltonianDomainResources(2, 0),
    )
    return plan, descriptor, handle
end

@testset "model coefficients scale conservative volume energy changes" begin
    plan, descriptor, handle = model_volume_energy_plan()
    for coefficient in (2.0f0, -0.5f0)
        initial_base = test_initial(Float32)
        initial = CorePotts.ProgramInitialState(
            initial_base.ownership, initial_base.cell_kinds;
            scalar_type = Float32,
            descriptor_state = CorePotts.allocate_auxiliary_state(plan.state_layout, [fill(coefficient)])
        )
        program = test_program(CorePotts.SequentialProgramEngine(); descriptor_plan = plan, scalar_type = Float32)
        runtime = CorePotts.initialize_program(program, initial, Float32[], UInt64(17), UInt32(1))
        proposal = CorePotts._ProposalEvaluationContext(
            runtime, CartesianIndex(3, 3),
            CartesianIndex(2, 3), Int32(0), Int32(1), 1, 1
        )
        # Independent energy difference for one four-site cell gaining a site.
        expected = coefficient * (5^2 - 4^2)
        @test CorePotts._compiled_hamiltonian_delta(descriptor.evaluator, descriptor.role, proposal) == expected
        gathered = CorePotts._GatheredProposalContext(;
            source = CartesianIndex(3, 3), target = CartesianIndex(2, 3), target_linear = Int32(14),
            old_owner = Int32(0), new_owner = Int32(1), old_kind = Int16(1), new_kind = Int16(2),
            volumes = (Int32(0), Int32(4)), semantic = Int32(1), mcs = Int64(1), color = Int32(1),
            trajectory_key = (UInt64(17), UInt64(0)), scalar_zero = 0.0f0, parameters = (),
            state_values = ((sites = (coefficient, coefficient), contacts = (), reverse_contacts = ()),),
            contact_sites = (), contact_owners = (), contact_kinds = (),
            reverse_contact_sites = (), reverse_contact_owners = (), reverse_contact_kinds = (),
            contact_ranges = ((), ()), tracker_values = (), bounded_tracker_samples = (),
            tracker_descriptors = (), bounded_tracker_descriptors = (), moment_first = (),
            moment_second = (), moment_descriptor = nothing, relationship_resources = (),
        )
        terms = CorePotts._compile_proposal_terms(plan)
        @test CorePotts._fold_executable_proposal_terms(terms, gathered, Float32).delta_h == expected
        @test only(CorePotts.state_block(CorePotts.program_snapshot(runtime).descriptor_state, handle).values) == coefficient
    end
end
