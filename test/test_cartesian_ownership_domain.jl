using Test
import CorePotts

const C = CorePotts

@testset "checkpoints bind the complete Cartesian domain" begin
    medium = C.DomainOwnerMetadata(0, C.MediumDomainOwnerCategory, 1)
    wall = C.DomainOwnerMetadata(7, C.WallDomainOwnerCategory, 1)
    base = C.CartesianOwnershipDomain((6, 6), medium, [wall])
    fixed_face = C.CartesianOwnershipDomain(
        (6, 6), medium, [wall];
        face_kinds = (
            C.FixedExteriorCartesianFace, C.ClosedCartesianFace,
            C.PeriodicCartesianFace, C.PeriodicCartesianFace),
        face_owner_handles = (Int32(1), Int32(0), Int32(0), Int32(0)),
    )
    changed_metadata = C.CartesianOwnershipDomain(
        (6, 6), medium,
        [C.DomainOwnerMetadata(8, C.WallDomainOwnerCategory, 1)],
    )
    obstacle_handles = zeros(Int32, 6, 6)
    obstacle_handles[1, 1] = 1
    obstacle = C.CartesianOwnershipDomain(
        (6, 6), medium, [wall]; obstacle_owner_handles = obstacle_handles)

    for engine in (C.SequentialProgramEngine(), C.CheckerboardProgramEngine())
        source_program = test_program(engine; domain = base)
        source = C.initialize_program(
            source_program, test_initial(), Float64[], UInt64(0x15c10), UInt32(1))
        checkpoint = C.program_checkpoint(source)
        restored = C.restore_program_checkpoint(source_program, checkpoint)
        @test restored.ownership == source.ownership
        @test checkpoint.program_fingerprint == source_program.integrity_fingerprint

        for different_domain in (fixed_face, changed_metadata, obstacle)
            destination = test_program(engine; domain = different_domain)
            @test destination.fingerprint == source_program.fingerprint
            @test destination.integrity_fingerprint !=
                source_program.integrity_fingerprint
            @test_throws ArgumentError C.restore_program_checkpoint(
                destination, checkpoint)
        end
    end
end

@testset "checkerboard contacts reconstruct authoritative endpoints" begin
    topology = C.CartesianContactTopology(
        (3, 2),
        (
            C.FixedExteriorCartesianFace, C.ClosedCartesianFace,
            C.PeriodicCartesianFace, C.PeriodicCartesianFace,
        ),
        (Int32(1), Int32(0), Int32(0), Int32(0)),
    )
    target = CartesianIndex(1, 1)
    offsets = (
        (Int8(-1), Int8(0)),
        (Int8(-1), Int8(-1)),
        (Int8(0), Int8(-1)),
    )
    geometry = ntuple(Val(3)) do lane
        C.realize_cartesian_contact_geometry(
            topology, target, offsets[lane], lane, C.OwnerRelationAccess)
    end
    # The middle lane crosses a fixed face and a periodic alias. The last lane
    # is represented as an obstacle after owner resolution; neither later
    # semantic classification changes the geometric endpoint.
    categories = (
        UInt8(geometry[1].category),
        UInt8(geometry[2].category),
        UInt8(C.FixedObstacleCartesianNeighbor),
    )
    sites = (geometry[1].site, geometry[2].site, Int32(1))
    owners = (geometry[1].owner, geometry[2].owner, Int32(-1))
    builder = C._checkerboard_contact_neighbor_builder(
        topology, target, offsets, categories, sites, owners)
    neighbors = ntuple(builder, Val(3))
    @test map(neighbor -> neighbor.endpoint, neighbors) ==
        map(neighbor -> neighbor.endpoint, geometry)
    @test neighbors[2].endpoint == (Int64(0), Int64(2))
    @test neighbors[3].category === C.FixedObstacleCartesianNeighbor
    @test neighbors[3].endpoint == (Int64(1), Int64(2))
end

function checkerboard_fixed_owner_oracle_plan(contact_offsets)
    anchor = C.ContextExpression(C.ContextOperation{:energy_anchor_contact}())
    owner_a = C.OperationExpression(
        C.ResourceOperation{:contact_owner_a}(), anchor)
    owner_b = C.OperationExpression(
        C.ResourceOperation{:contact_owner_b}(), anchor)
    # f(a,b) = -a - 3ab: a medium neighbor gives +1 on removal,
    # while a fixed owner -1 gives -2, making the fixed incidence observable.
    evaluator = C.StaticEvaluator(C.OperationExpression(
        C.OrderedFold(+),
        C.OperationExpression(*, C.LiteralExpression(-1.0), owner_a),
        C.OperationExpression(*, C.LiteralExpression(-3.0), owner_a, owner_b),
    ))
    role = C.HamiltonianRole(
        C.ContactEnergyDomainPlan(Int32(1)),
        C.IncidentContactsAffectedPlan(Int32(size(contact_offsets, 2))))
    descriptor = C.ProposalDescriptor(
        evaluator,
        C.ResourceAccess(
            (), (), C.ContactFootprint(), C.EmptyFootprint(), C.NoWriteAccess()),
        C.DescriptorSupport(true, true, true, true),
        (), (), role, 1)
    resources = C.HamiltonianDomainResources(
        contact_offsets, Int32[1], Int32[size(contact_offsets, 2)], Int32[0])
    return C.DescriptorExecutionPlan(
        (C.ProposalDescriptorGroup(
            [descriptor], (), (), (family = :fixed_owner_oracle,)),),
        C.StateLayout(C.StateBlockSchema[]),
        C.WorkspaceLayout(C.WorkspaceSchema[]), (),
        Any[:fixed_owner_oracle], 1, "fixed-owner-oracle", resources)
end

@testset "checkerboard contact science observes fixed exterior and obstacle owners" begin
    medium = C.DomainOwnerMetadata(0, C.MediumDomainOwnerCategory, 1)
    wall = C.DomainOwnerMetadata(9, C.WallDomainOwnerCategory, 3)
    exterior_proposal_offsets = reshape(Int8[2, 0], 2, 1)

    exterior_domain = C.CartesianOwnershipDomain(
        (3, 1), medium, [wall];
        face_kinds = (
            C.FixedExteriorCartesianFace, C.ClosedCartesianFace,
            C.PeriodicCartesianFace, C.PeriodicCartesianFace),
        face_owner_handles = (Int32(1), Int32(0), Int32(0), Int32(0)))
    exterior_plan = checkerboard_fixed_owner_oracle_plan(
        reshape(Int8[-1, 0], 2, 1))
    exterior_sequential_program = C.CompiledPottsProgram(
        exterior_domain, exterior_proposal_offsets, 3, C.CompiledScalar(0.0),
        1, Float64[], (),
        C.TrackerExecutionPlan(
            (C.OwnershipCountTracker(),), "fixed-exterior-oracle-count"),
        exterior_plan, C.StageExecutionPlan(), C.SequentialProgramEngine(),
        C.CPUProgramBackend(), "fixed-exterior-sequential-oracle")
    exterior_sequential = C.initialize_program(
        exterior_sequential_program,
        C.ProgramInitialState(
            reshape(Int32[1, 1, 0], 3, 1), Int16[2]; scalar_type = Float64),
        Float64[], UInt64(3), UInt32(1))
    exterior_proposal = C._ProposalEvaluationContext(
        exterior_sequential, CartesianIndex(3, 1), CartesianIndex(1, 1),
        Int32(1), Int32(0), 1, 0)
    exterior_descriptor = only(only(exterior_plan.groups).instances)
    @test C._hamiltonian_delta(
        exterior_descriptor.evaluator, exterior_descriptor.role,
        C.BeforeProposalView(
            exterior_sequential, CartesianIndex(1, 1), Int32(1), Int32(0)),
        C.AfterProposalView(
            exterior_sequential, CartesianIndex(1, 1), Int32(1), Int32(0)),
        exterior_proposal, exterior_plan.domain_resources) == -2.0
    exterior_program = C.CompiledPottsProgram(
        exterior_domain, exterior_proposal_offsets, 3, C.CompiledScalar(0.0),
        1, Float64[], (),
        C.TrackerExecutionPlan(
            (C.OwnershipCountTracker(),), "fixed-exterior-oracle-count"),
        exterior_plan, C.StageExecutionPlan(), C.CheckerboardProgramEngine(),
        C.CPUProgramBackend(), "fixed-exterior-checkerboard-oracle";
        checkerboard_plan = C.CheckerboardPlan(
            exterior_domain, exterior_proposal_offsets))
    exterior = C.initialize_program(
        exterior_program,
        C.ProgramInitialState(
            reshape(Int32[1, 1, 0], 3, 1), Int16[2]; scalar_type = Float64),
        Float64[], UInt64(3), UInt32(1))
    C.advance_mcs!(exterior)
    @test exterior.ownership == reshape(Int32[0, 1, 0], 3, 1)
    @test (exterior.accepted, exterior.rejected, exterior.null_attempts) ==
        (1, 0, 2)

    obstacle_proposal_offsets = reshape(Int8[3, 0], 2, 1)
    obstacles = zeros(Int32, 4, 1)
    obstacles[3, 1] = 1
    obstacle_domain = C.CartesianOwnershipDomain(
        (4, 1), medium, [wall];
        face_kinds = (
            C.ClosedCartesianFace, C.ClosedCartesianFace,
            C.PeriodicCartesianFace, C.PeriodicCartesianFace),
        obstacle_owner_handles = obstacles)
    obstacle_plan = checkerboard_fixed_owner_oracle_plan(
        reshape(Int8[2, 0], 2, 1))
    obstacle_sequential_program = C.CompiledPottsProgram(
        obstacle_domain, obstacle_proposal_offsets, 3, C.CompiledScalar(0.0),
        1, Float64[], (),
        C.TrackerExecutionPlan(
            (C.OwnershipCountTracker(),), "fixed-obstacle-oracle-count"),
        obstacle_plan, C.StageExecutionPlan(), C.SequentialProgramEngine(),
        C.CPUProgramBackend(), "fixed-obstacle-sequential-oracle")
    obstacle_sequential = C.initialize_program(
        obstacle_sequential_program,
        C.ProgramInitialState(
            reshape(Int32[1, 1, 7, 0], 4, 1), Int16[2]; scalar_type = Float64),
        Float64[], UInt64(3), UInt32(1))
    obstacle_proposal = C._ProposalEvaluationContext(
        obstacle_sequential, CartesianIndex(4, 1), CartesianIndex(1, 1),
        Int32(1), Int32(0), 1, 0)
    obstacle_descriptor = only(only(obstacle_plan.groups).instances)
    @test C._hamiltonian_delta(
        obstacle_descriptor.evaluator, obstacle_descriptor.role,
        C.BeforeProposalView(
            obstacle_sequential, CartesianIndex(1, 1), Int32(1), Int32(0)),
        C.AfterProposalView(
            obstacle_sequential, CartesianIndex(1, 1), Int32(1), Int32(0)),
        obstacle_proposal, obstacle_plan.domain_resources) == -2.0
    obstacle_program = C.CompiledPottsProgram(
        obstacle_domain, obstacle_proposal_offsets, 3, C.CompiledScalar(0.0),
        1, Float64[], (),
        C.TrackerExecutionPlan(
            (C.OwnershipCountTracker(),), "fixed-obstacle-oracle-count"),
        obstacle_plan, C.StageExecutionPlan(), C.CheckerboardProgramEngine(),
        C.CPUProgramBackend(), "fixed-obstacle-checkerboard-oracle";
        checkerboard_plan = C.CheckerboardPlan(
            obstacle_domain, obstacle_proposal_offsets))
    obstacle = C.initialize_program(
        obstacle_program,
        C.ProgramInitialState(
            reshape(Int32[1, 1, 7, 0], 4, 1), Int16[2]; scalar_type = Float64),
        Float64[], UInt64(3), UInt32(1))
    C.advance_mcs!(obstacle)
    @test obstacle.ownership == reshape(Int32[0, 1, -1, 0], 4, 1)
    @test (obstacle.accepted, obstacle.rejected, obstacle.null_attempts) ==
        (1, 0, 2)
end

@testset "owner keys include the durable owner namespace" begin
    finite = C.OwnerKey(C.FiniteCellOwnerCategory, UInt64(7))
    medium = C.OwnerKey(C.MediumDomainOwnerCategory, UInt64(7))
    same = C.OwnerKey(C.FiniteCellOwnerCategory, UInt64(7))
    @test finite == same
    @test isequal(finite, same)
    @test hash(finite) == hash(same)
    @test finite != medium
    @test !isequal(finite, medium)
    @test length(Set((finite, same, medium))) == 2
end

@testset "Cartesian ownership domain is the sole owner authority" begin
    medium = C.DomainOwnerMetadata(0, C.MediumDomainOwnerCategory, 1)
    wall = C.DomainOwnerMetadata(2, C.WallDomainOwnerCategory, 2)
    reservoir = C.DomainOwnerMetadata(3, C.MediumDomainOwnerCategory, 1)

    @test_throws ArgumentError C.DomainOwnerMetadata(
        UInt64(1), C.InvalidOwnerCategory, Int16(0)
    )
    @test_throws ArgumentError C.CartesianOwnershipDomain(
        (3, 3), medium, [C.DomainOwnerMetadata(0, C.MediumDomainOwnerCategory, 1)]
    )
    @test_throws ArgumentError C.CartesianOwnershipDomain(
        (3, 3), wall, C.DomainOwnerMetadata[])
    @test_throws ArgumentError C.CartesianOwnershipDomain(
        (typemax(Int), 2), medium, C.DomainOwnerMetadata[]
    )
    @test C._validate_checkerboard_site_count(typemax(Int32) - 1) ==
        typemax(Int32) - 1
    @test_throws ArgumentError C._validate_checkerboard_site_count(typemax(Int32))

    obstacles = zeros(Int32, 3, 3)
    obstacles[2, 2] = 1
    domain = C.CartesianOwnershipDomain(
        (3, 3), medium, [wall, reservoir];
        face_kinds = (
            C.ClosedCartesianFace,
            C.FixedExteriorCartesianFace,
            C.PeriodicCartesianFace,
            C.PeriodicCartesianFace,
        ),
        face_owner_handles = (Int32(0), Int32(2), Int32(0), Int32(0)),
        obstacle_owner_handles = obstacles,
    )
    ownership = fill(Int32(7), 3, 3)
    @test C.owner_at(domain, ownership, CartesianIndex(2, 2)) == -1
    @test C.owner_at(domain, ownership, CartesianIndex(1, 1)) == 7
    @test C.domain_owner_code(domain, wall) == -1
    @test_throws ArgumentError C.domain_owner_code(
        domain,
        C.DomainOwnerMetadata(2, C.MediumDomainOwnerCategory, 2),
    )
    @test_throws ArgumentError C.domain_owner_code(
        domain,
        C.DomainOwnerMetadata(2, C.WallDomainOwnerCategory, 3),
    )
    @test length(domain.mutable_sites) == 8
    @test domain.mutable_mask[2, 2] == 0
    report = @inferred C.cartesian_domain_report(domain)
    @test isconcretetype(Core.Compiler.return_type(
        C.cartesian_domain_report, Tuple{typeof(domain)}))
    @test report.domain_owners == domain.domain_owners
    @test report.domain_owners !== domain.domain_owners
    @test report.obstacles == [(site = Int32(5), owner_handle = Int32(1))]

    offsets = reshape(Int8[1, 0], 2, 1)
    obstacle = C.realize_cartesian_neighbor(
        domain, ownership, CartesianIndex(1, 2), offsets, 1,
        C.OwnerRelationAccess,
    )
    @test obstacle.category === C.FixedObstacleCartesianNeighbor
    @test obstacle.owner == -1
    proposal = C.realize_cartesian_neighbor(
        domain, ownership, CartesianIndex(1, 2), offsets, 1,
        C.MutableSiteRelationAccess,
    )
    @test proposal.category === C.AbsentCartesianNeighbor

    @test C.owner_directory_index(domain, 8, 0) == 9
    @test C.owner_directory_index(domain, 8, -1) == 10
    @test C.owner_directory_index(domain, 8, -2) == 11
    @test C.owner_directory_count(domain, 8) == 11
    layout = C.owner_directory_layout(domain, 8)
    @test C.owner_directory_index(layout, Int32(8)) == 8
    @test C.owner_directory_index(layout, Int32(0)) == 9
    @test C.owner_directory_index(layout, Int32(-2)) == 11
    @test_throws ArgumentError C.owner_directory_index(layout, Int32(9))
    @test_throws ArgumentError C.owner_directory_index(layout, Int32(-3))
    @test_throws ArgumentError C.owner_directory_count(domain, -1)
    @test_throws ArgumentError C.owner_directory_count(domain, typemax(Int32))
    @test_throws ArgumentError C.owner_directory_index(domain, 1, 2)
    @test_throws ArgumentError C.owner_directory_index(
        domain, 8, Int128(typemax(Int32)) + 1
    )
    @test C.domain_owner_code(domain, UInt64(0)) == 0
    @test C.domain_owner_code(domain, reservoir) == -2
    @test_throws ArgumentError C.domain_owner_code(domain, UInt64(99))
    @test C.owner_key(domain, UInt32[0, 0], 2) !=
        C.owner_key(domain, UInt32[0, 0], -1)

    prefix = C._standard_cartesian_ownership_domain(
        (2, 2), (true, true), 2, 1, Bool[true, false]
    )
    @test_throws ArgumentError C.owner_directory_index(prefix, 4, -2)

    default_obstacle_mask = falses(2, 2)
    default_obstacle_mask[2, 1] = true
    default_fixed = C.CartesianOwnershipDomain(
        (2, 2), medium, C.DomainOwnerMetadata[];
        face_kinds = (
            C.FixedExteriorCartesianFace, C.ClosedCartesianFace,
            C.ClosedCartesianFace, C.ClosedCartesianFace),
        face_owner_handles = ntuple(_ -> Int32(0), 4),
        obstacle_owner_handles = zeros(Int32, 2, 2),
        obstacle_mask = default_obstacle_mask,
    )
    backing = fill(Int32(7), 2, 2)
    @test C.owner_at(default_fixed, backing, CartesianIndex(2, 1)) == 0
    default_exterior = C.realize_cartesian_neighbor(
        default_fixed, backing, CartesianIndex(1, 1),
        reshape(Int8[-1, 0], 2, 1), 1, C.OwnerRelationAccess)
    @test default_exterior.category === C.FixedExteriorCartesianNeighbor
    @test default_exterior.owner == 0
    default_obstacle = C.realize_cartesian_neighbor(
        default_fixed, backing, CartesianIndex(1, 1),
        reshape(Int8[1, 0], 2, 1), 1, C.OwnerRelationAccess)
    @test default_obstacle.category === C.FixedObstacleCartesianNeighbor
    @test default_obstacle.owner == 0
    default_runtime = C.initialize_program(
        test_program(C.SequentialProgramEngine(); domain = default_fixed),
        C.ProgramInitialState(
            fill(Int32(1), 2, 2), Int16[2]; scalar_type = Float64),
        Float64[], UInt64(4), UInt32(1))
    @test default_runtime.ownership[2, 1] == 0
    @test C.program_tracker_values(
        default_runtime, Val(:cell_volume))[1] == 3
    ignored_handles = zeros(Int32, 2, 2)
    ignored_handles[2, 2] = 1
    @test_throws ArgumentError C.CartesianOwnershipDomain(
        (2, 2), medium, [wall];
        obstacle_owner_handles = ignored_handles,
        obstacle_mask = falses(2, 2))
    @test_throws ArgumentError C.CartesianOwnershipDomain(
        (2, 2), medium, [wall]; obstacle_mask = zeros(Int, 2, 2))
    @test_throws ArgumentError C.CartesianOwnershipDomain(
        (2, 2), medium, [wall]; obstacle_mask = falses(3, 2))
end


@testset "fixed endpoints canonicalize periodic aliases" begin
    default_owner = C.DomainOwnerMetadata(0, C.MediumDomainOwnerCategory, 1)
    wall = C.DomainOwnerMetadata(1, C.WallDomainOwnerCategory, 2)
    domain = C.CartesianOwnershipDomain(
        (2, 1), default_owner, [wall];
        face_kinds = (
            C.FixedExteriorCartesianFace,
            C.ClosedCartesianFace,
            C.PeriodicCartesianFace,
            C.PeriodicCartesianFace,
        ),
        face_owner_handles = (Int32(1), Int32(0), Int32(0), Int32(0)),
    )
    offsets = Int8[-1 -1; 0 1]
    first_lane = C.realize_cartesian_neighbor(
        domain, zeros(Int32, 2, 1), CartesianIndex(1, 1), offsets, 1,
        C.OwnerRelationAccess,
    )
    alias_lane = C.realize_cartesian_neighbor(
        domain, zeros(Int32, 2, 1), CartesianIndex(1, 1), offsets, 2,
        C.OwnerRelationAccess,
    )
    @test first_lane.category === C.FixedExteriorCartesianNeighbor
    @test first_lane.endpoint == alias_lane.endpoint == (Int64(0), Int64(1))
end

@testset "Cartesian multi-face realization rejects incompatible owners" begin
    default_owner = C.DomainOwnerMetadata(0, C.MediumDomainOwnerCategory, 1)
    owners = [
        C.DomainOwnerMetadata(1, C.WallDomainOwnerCategory, 2),
        C.DomainOwnerMetadata(2, C.WallDomainOwnerCategory, 2),
    ]
    domain = C.CartesianOwnershipDomain(
        (2, 2), default_owner, owners;
        face_kinds = ntuple(_ -> C.FixedExteriorCartesianFace, 4),
        face_owner_handles = (Int32(1), Int32(2), Int32(2), Int32(2)),
    )
    diagonal = reshape(Int8[-1, -1], 2, 1)
    @test_throws ArgumentError C.validate_cartesian_relation_realization(
        domain, diagonal, C.OwnerRelationAccess
    )
    @test C.validate_cartesian_relation_realization(
        domain, diagonal, C.MutableSiteRelationAccess
    ) == diagonal
    null_proposal = C.realize_cartesian_neighbor(
        domain, zeros(Int32, 2, 2), CartesianIndex(1, 1), diagonal, 1,
        C.MutableSiteRelationAccess,
    )
    @test null_proposal.category === C.AbsentCartesianNeighbor

    same_owner_domain = C.CartesianOwnershipDomain(
        (2, 2), default_owner, owners;
        face_kinds = ntuple(_ -> C.FixedExteriorCartesianFace, 4),
        face_owner_handles = ntuple(_ -> Int32(1), 4),
    )
    @test C.validate_cartesian_relation_realization(
        same_owner_domain, diagonal, C.OwnerRelationAccess
    ) == diagonal
    corner = C.realize_cartesian_neighbor(
        same_owner_domain, zeros(Int32, 2, 2), CartesianIndex(1, 1),
        diagonal, 1, C.OwnerRelationAccess,
    )
    @test corner.category === C.FixedExteriorCartesianNeighbor
    @test corner.owner == -1
end


@testset "fixed exterior owners contribute to contact-energy deltas" begin
    anchor = C.ContextExpression(C.ContextOperation{:energy_anchor_contact}())
    owner_a = C.OperationExpression(
        C.ResourceOperation{:contact_owner_a}(), anchor
    )
    evaluator = C.StaticEvaluator(C.OperationExpression(
        C.OrderedFold(+),
        C.OperationExpression(*, C.LiteralExpression(10.0), owner_a),
        C.OperationExpression(C.ResourceOperation{:contact_owner_b}(), anchor),
    ))
    role = C.HamiltonianRole(
        C.ContactEnergyDomainPlan(Int32(1)),
        C.IncidentContactsAffectedPlan(Int32(2)),
    )
    descriptor = C.ProposalDescriptor(
        evaluator,
        C.ResourceAccess(
            (), (), C.ContactFootprint(), C.EmptyFootprint(), C.NoWriteAccess()
        ),
        C.DescriptorSupport(true, true, true, true),
        (), (), role, 1,
    )
    resources = C.HamiltonianDomainResources(
        Int8[-1 2; 0 0], Int32[1], Int32[2], Int32[0]
    )
    descriptor_plan = C.DescriptorExecutionPlan(
        (C.ProposalDescriptorGroup(
            [descriptor], (), (), (family = :fixed_contact_oracle,)
        ),),
        C.StateLayout(C.StateBlockSchema[]),
        C.WorkspaceLayout(C.WorkspaceSchema[]),
        (), Any[:fixed_contact_oracle], 1, "fixed-contact-oracle", resources,
    )
    default_owner = C.DomainOwnerMetadata(0, C.MediumDomainOwnerCategory, 1)
    wall = C.DomainOwnerMetadata(9, C.WallDomainOwnerCategory, 3)
    domain = C.CartesianOwnershipDomain(
        (3, 2), default_owner, [wall];
        face_kinds = (
            C.FixedExteriorCartesianFace, C.ClosedCartesianFace,
            C.ClosedCartesianFace, C.ClosedCartesianFace,
        ),
        face_owner_handles = (Int32(1), Int32(0), Int32(0), Int32(0)),
    )
    program = C.CompiledPottsProgram(
        domain, Int8[-1 1; 0 0], 3, C.CompiledScalar(0.0),
        1, Float64[], (),
        C.TrackerExecutionPlan((C.OwnershipCountTracker(),), "fixed-contact-count"),
        descriptor_plan, C.StageExecutionPlan(), C.SequentialProgramEngine(),
        C.CPUProgramBackend(), "fixed-contact-program",
    )
    @test C.CompilerSPI.cartesian_domain(program) === program.domain
    runtime = C.initialize_program(
        program,
        C.ProgramInitialState(
            Int32[1 0; 0 0; 0 0], Int16[2]; scalar_type = Float64
        ),
        Float64[], UInt64(1), UInt32(1),
    )
    source = CartesianIndex(2, 1)
    target = CartesianIndex(1, 1)
    proposal = C._ProposalEvaluationContext(
        runtime, source, target,
        Int32(1), Int32(0),
        1, 0,
    )
    @test proposal.target == target
    @test C.owner_at(domain, runtime.ownership, target) == proposal.old_owner == 1
    fixed = C._proposal_science_neighbor(
        runtime, target, resources.contact_offsets, 1
    )
    @test fixed.category === C.FixedExteriorCartesianNeighbor
    @test fixed.owner == -1
    @test C._proposal_science_reverse_neighbor(
        runtime, target, resources.contact_offsets, 1
    ) == CartesianIndex(2, 1)
    @test C._proposal_science_reverse_neighbor(
        runtime, target, resources.contact_offsets, 2
    ) === nothing
    before = C.BeforeProposalView(
        runtime, proposal.target, Int32(1), Int32(0)
    )
    after = C.AfterProposalView(
        runtime, proposal.target, Int32(1), Int32(0)
    )
    # Before: (10*1-1) + (10*1+0) = 19. After: -1 + 0 = -1.
    @test C._hamiltonian_delta(
        evaluator, role, before, after, proposal, resources
    ) == -20.0

    checkerboard_program = C.CompiledPottsProgram(
        domain, Int8[-1 1; 0 0], 3, C.CompiledScalar(0.0),
        1, Float64[], (),
        C.TrackerExecutionPlan((C.OwnershipCountTracker(),), "fixed-contact-count"),
        descriptor_plan, C.StageExecutionPlan(), C.CheckerboardProgramEngine(),
        C.CPUProgramBackend(), "fixed-contact-checkerboard-program";
        checkerboard_plan = C.CheckerboardPlan(
            domain, Int8[-1 1; 0 0]),
    )
    checkerboard = C.initialize_program(
        checkerboard_program,
        C.ProgramInitialState(
            Int32[1 0; 0 0; 0 0], Int16[2]; scalar_type = Float64
        ),
        Float64[], UInt64(1), UInt32(1),
    )
    C.advance_mcs!(checkerboard)
    @test checkerboard.accepted + checkerboard.rejected +
        checkerboard.null_attempts == length(domain.mutable_sites)
    @test checkerboard.mcs == 1
end
