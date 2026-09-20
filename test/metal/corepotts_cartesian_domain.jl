using Test
import Metal
import CorePotts
import LocalMath

function _metal_fixed_owner_plan(contact_offsets)
    anchor = CorePotts.ContextExpression(
        CorePotts.ContextOperation{:energy_anchor_contact}())
    owner_a = CorePotts.OperationExpression(
        CorePotts.ResourceOperation{:contact_owner_a}(), anchor)
    owner_b = CorePotts.OperationExpression(
        CorePotts.ResourceOperation{:contact_owner_b}(), anchor)
    evaluator = CorePotts.StaticEvaluator(CorePotts.OperationExpression(
        CorePotts.OrderedFold(+),
        CorePotts.OperationExpression(
            *, CorePotts.LiteralExpression(1.0f0), owner_a),
        CorePotts.OperationExpression(
            *, CorePotts.LiteralExpression(3.0f0), owner_a, owner_b),
    ))
    descriptor = CorePotts.ProposalDescriptor(
        evaluator,
        CorePotts.ResourceAccess(
            (), (), CorePotts.ContactFootprint(),
            CorePotts.EmptyFootprint(), CorePotts.NoWriteAccess()),
        CorePotts.DescriptorSupport(true, true, true, true), (), (),
        CorePotts.HamiltonianRole(
            CorePotts.ContactEnergyDomainPlan(Int32(1)),
            CorePotts.IncidentContactsAffectedPlan(
                Int32(size(contact_offsets, 2)))),
        1,
    )
    resources = CorePotts.HamiltonianDomainResources(
        contact_offsets, ones(Float32, size(contact_offsets, 2)),
        Int32[1], Int32[size(contact_offsets, 2)], Int32[0])
    return CorePotts.DescriptorExecutionPlan(
        (CorePotts.ProposalDescriptorGroup(
            [descriptor], (), (), (family = :fixed_owner_metal,)),),
        CorePotts.StateLayout(CorePotts.StateBlockSchema[]),
        CorePotts.WorkspaceLayout(CorePotts.WorkspaceSchema[]), (),
        Any[:fixed_owner_metal], 1, "fixed-owner-metal", resources)
end

function _metal_cartesian_case(case::Symbol)
    medium = CorePotts.DomainOwnerMetadata(
        0, CorePotts.MediumDomainOwnerCategory, 1)
    wall = CorePotts.DomainOwnerMetadata(
        9, CorePotts.WallDomainOwnerCategory, 3)
    if case === :fixed_exterior
        shape = (3, 1)
        proposal_offsets = reshape(Int8[2, 0], 2, 1)
        contact_offsets = reshape(Int8[-1, 0], 2, 1)
        domain = CorePotts.CartesianOwnershipDomain(
            shape, medium, [wall];
            face_kinds = (
                CorePotts.FixedExteriorCartesianFace,
                CorePotts.ClosedCartesianFace,
                CorePotts.PeriodicCartesianFace,
                CorePotts.PeriodicCartesianFace),
            face_owner_handles = (Int32(1), Int32(0), Int32(0), Int32(0)))
        ownership = reshape(Int32[1, 1, 0], shape)
        expected = reshape(Int32[1, 1, 0], shape)
    elseif case === :fixed_obstacle
        shape = (4, 1)
        proposal_offsets = reshape(Int8[3, 0], 2, 1)
        contact_offsets = reshape(Int8[2, 0], 2, 1)
        obstacle_handles = zeros(Int32, shape)
        obstacle_handles[3, 1] = 1
        domain = CorePotts.CartesianOwnershipDomain(
            shape, medium, [wall];
            face_kinds = (
                CorePotts.ClosedCartesianFace,
                CorePotts.ClosedCartesianFace,
                CorePotts.PeriodicCartesianFace,
                CorePotts.PeriodicCartesianFace),
            obstacle_owner_handles = obstacle_handles)
        ownership = reshape(Int32[1, 1, 7, 0], shape)
        expected = reshape(Int32[1, 1, -1, 0], shape)
    else
        error("unknown Cartesian Metal case: $case")
    end
    descriptor_plan = _metal_fixed_owner_plan(contact_offsets)
    program = CorePotts.CompiledPottsProgram(
        domain, proposal_offsets, 3, CorePotts.CompiledScalar(0.0f0),
        1, Float32[], (),
        CorePotts.TrackerExecutionPlan(
            (CorePotts.OwnershipCountTracker(),),
            "fixed-owner-metal-count"),
        descriptor_plan, CorePotts.StageExecutionPlan(),
        CorePotts.CheckerboardProgramEngine(), CorePotts.CPUProgramBackend(),
        "fixed-owner-metal-$case";
        checkerboard_plan = CorePotts.CheckerboardPlan(
            domain, proposal_offsets))
    initial = CorePotts.ProgramInitialState(
        ownership, Int16[2]; scalar_type = Float32)
    return (; program, initial, expected, mutable_attempts = length(domain.mutable_sites))
end

function _run_metal_cartesian_case(case, to_backend)
    fixture = _metal_cartesian_case(case)
    host = CorePotts.initialize_program(
        fixture.program, fixture.initial, Float32[], UInt64(3), UInt32(1))
    target = first(CartesianIndices(host.ownership))
    source = last(CartesianIndices(host.ownership))
    context = CorePotts._ProposalEvaluationContext(
        host, source, target, Int32(1), Int32(0), 1, 1
    )
    contributions = Vector{CorePotts.ProposalEvaluation{Float32}}(
        undef, CorePotts._descriptor_source_count(
            fixture.program.descriptor_plan
        )
    )
    CorePotts.evaluate_proposal_contributions!(
        contributions, fixture.program.descriptor_plan, context
    )
    isolated = CorePotts.fold_proposal_contributions(
        fixture.program.descriptor_plan, contributions
    )
    # The fixed-owner contribution makes this proposal uphill. At zero
    # temperature the device must reject it; a missing contact contribution
    # would instead produce ΔH == 0 and accept, changing ownership below.
    @test isolated.delta_h == 2.0f0

    runtime = to_backend === identity ? host :
        CorePotts.adapt_program_runtime(to_backend, host)
    CorePotts.enqueue_program_through!(runtime, 1)
    receipt = CorePotts.settle_program!(
        runtime,
        CorePotts.ProgramSettlementRequest(
            CorePotts.PublicStepSettlement; full_snapshot = true))
    @test receipt.committed_mcs == 1
    @test receipt.snapshot.ownership == fixture.expected
    counters = receipt.counters
    @test counters.accepted == 0
    @test counters.rejected == 1
    @test counters.null_attempts == fixture.mutable_attempts - 1
    @test counters.accepted + counters.rejected + counters.null_attempts ==
        fixture.mutable_attempts
    if case === :fixed_obstacle
        @test receipt.snapshot.ownership[3, 1] == -1
    end
    return (
        ownership = receipt.snapshot.ownership,
        counters,
        isolated_delta = isolated.delta_h,
    )
end

@testset "fixed Cartesian owners share CPU and Metal checkerboard semantics" begin
    for case in (:fixed_exterior, :fixed_obstacle)
        cpu = _run_metal_cartesian_case(case, identity)
        metal = _run_metal_cartesian_case(case, Metal.MtlArray)
        @test metal == cpu
    end
end
