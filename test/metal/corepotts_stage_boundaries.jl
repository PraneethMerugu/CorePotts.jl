using Test
import Metal
import CorePotts
import LocalMath

include(joinpath(@__DIR__, "..", "fixtures", "scientific_geometry_oracle.jl"))

struct MetalCentroidEnergy end
@inline (::MetalCentroidEnergy)(center::NTuple{2, Float32}) =
    0.125f0 * (center[1]^2 + center[2]^2)
# Cell centers are nullable even when a surrounding energy domain excludes
# empty cells. The scalar operation covers that result on both backends.
@inline (::MetalCentroidEnergy)(::Nothing) = 0.0f0

function _metal_geometry_program()
    anchor = CorePotts.ContextExpression(CorePotts.ContextOperation{:energy_anchor_cell}())
    elongation = CorePotts.OperationExpression(CorePotts.ResourceOperation{:cell_elongation}(), anchor)
    center = CorePotts.OperationExpression(CorePotts.ResourceOperation{:cell_center}(), anchor)
    energy = CorePotts.OperationExpression(
        +,
        CorePotts.OperationExpression(^, elongation, CorePotts.LiteralExpression(2)),
        CorePotts.OperationExpression(MetalCentroidEnergy(), center)
    )
    hamiltonian = CorePotts.ProposalDescriptor(
        CorePotts.StaticEvaluator(energy),
        CorePotts.ResourceAccess(
            (), (), CorePotts.OwnerFootprint(),
            CorePotts.EmptyFootprint(), CorePotts.NoWriteAccess()
        ),
        CorePotts.DescriptorSupport(true, true, true, true), (), (),
        CorePotts.HamiltonianRole(
            CorePotts.CellEnergyDomainPlan(Int16(2)),
            CorePotts.SourceTargetCellsAffectedPlan(Int32(2))
        ), 1
    )
    # Rejected proposals keep one stage-entry ownership field for the oracle;
    # the ordinary scientific stage still evaluates every actionable proposal.
    constraint = CorePotts.ProposalDescriptor(
        CorePotts.StaticEvaluator(CorePotts.LiteralExpression(false)),
        CorePotts.ResourceAccess(
            (), (), CorePotts.EmptyFootprint(),
            CorePotts.EmptyFootprint(), CorePotts.NoWriteAccess()
        ),
        CorePotts.DescriptorSupport(true, true, true, true), (), (),
        CorePotts.ProposalConstraintRole(), 2
    )
    descriptors = CorePotts.DescriptorExecutionPlan(
        (
            CorePotts.ProposalDescriptorGroup(
                [hamiltonian, constraint], (), (),
                (family = :moment_geometry,)
            ),
        ),
        CorePotts.StateLayout(CorePotts.StateBlockSchema[]),
        CorePotts.WorkspaceLayout(CorePotts.WorkspaceSchema[]), (),
        Any[:moment_geometry, :fixed_geometry_constraint], 2,
        "moment-geometry-descriptors", CorePotts.HamiltonianDomainResources(2, 2)
    )
    shape = (6, 6)
    offsets = reshape(Int8[1, 0], 2, 1)
    trackers = CorePotts.TrackerExecutionPlan(
        (
            CorePotts.OwnershipCountTracker(),
            CorePotts.CellMomentsTracker{2, Float32}(),
        ), "moment-geometry-trackers"
    )
    return CorePotts.CompiledPottsProgram(
        shape, (true, true), offsets, 2, 1,
        CorePotts.CompiledScalar(3.0f0), 1, Float32[], (), trackers, descriptors,
        CorePotts.StageExecutionPlan(), CorePotts.CheckerboardProgramEngine(),
        CorePotts.CPUProgramBackend(), "moment-geometry-program";
        medium_kinds = Bool[true, false],
        checkerboard_plan = CorePotts.CheckerboardPlan(shape, (true, true), zeros(Int8, 2, 0))
    )
end

function _independent_metal_geometry_energy(ownership)
    return sum(Int32(1):Int32(2)) do owner
        center = independent_cell_center(ownership, owner)
        center === nothing && return 0.0
        independent_cell_length(ownership, owner)^2 + 0.125 * sum(abs2, center)
    end
end

@testset "Core moment geometry Hamiltonian matches an independent oracle on Metal" begin
    program = _metal_geometry_program()
    ownership = zeros(Int32, 6, 6)
    ownership[1, 1] = ownership[2, 3] = ownership[4, 5] = 1
    ownership[5, 5] = 2
    initial = CorePotts.ProgramInitialState(ownership, Int16[2, 2]; scalar_type = Float32)
    expected_before = _independent_metal_geometry_energy(ownership)
    results = map((identity, Metal.MtlArray)) do to_backend
        host = CorePotts.initialize_program(program, initial, Float32[], UInt64(0x6e01), UInt32(1))
        runtime = to_backend === identity ? host : CorePotts.adapt_program_runtime(to_backend, host)
        CorePotts.enqueue_program_through!(runtime, 1)
        receipt = CorePotts.settle_program!(
            runtime,
            CorePotts.ProgramSettlementRequest(CorePotts.PublicStepSettlement; full_snapshot = true)
        )
        @test receipt.committed_mcs == 1
        @test receipt.snapshot.ownership == ownership
        @test receipt.counters.accepted == 0
        execution = runtime.engine_workspace
        declaration = execution.color_laws.declaration
        deltas = Dict{Int32, Float32}()
        saw_extinction = false
        saw_periodic_growth = false
        saw_owner_transfer = false
        for prepared in execution.color_laws.prepared
            # These tuple-valued fields may use a structure-of-arrays layout.
            # Adapt their columns before host inspection; never scalar-index GPU storage.
            sites = CorePotts.Adapt.adapt(Array, LocalMath.storage(prepared, declaration.sites))
            owners = CorePotts.Adapt.adapt(Array, LocalMath.storage(prepared, declaration.owners))
            actionable = Array(LocalMath.storage(prepared, declaration.actionable))
            energies = Array(LocalMath.storage(prepared, declaration.evaluation.delta_h))
            for item in eachindex(actionable)
                actionable[item] || continue
                target, _ = sites[item]
                old_owner, new_owner = owners[item]
                changed = copy(ownership)
                changed[target] = new_owner
                expected = _independent_metal_geometry_energy(changed) - expected_before
                @test isapprox(energies[item], expected; rtol = 5.0e-5, atol = 5.0e-5)
                deltas[target] = energies[item]
                saw_extinction |= old_owner > 0 && count(==(old_owner), ownership) == 1
                saw_periodic_growth |= target == LinearIndices(ownership)[6, 1] && new_owner == 1
                saw_owner_transfer |= old_owner > 0 && new_owner > 0
            end
        end
        @test !isempty(deltas)
        @test any(value -> abs(value) > 1.0f-3, values(deltas))
        @test saw_extinction
        @test saw_periodic_growth
        @test saw_owner_transfer
        deltas
    end
    @test keys(first(results)) == keys(last(results))
    for target in keys(first(results))
        @test isapprox(first(results)[target], last(results)[target]; rtol = 5.0f-5, atol = 5.0f-5)
    end
end

function _metal_model_assignment_descriptor()
    schema = CorePotts.StateBlockSchema(
        CorePotts.QualifiedResourceIdentity((), :metal_model_signal),
        v"1.0.0",
        :model,
        Float32,
        (1,),
        1,
        :structure_of_arrays,
        :provided_or_zero,
        :shape_and_finite,
        :logical,
        :preserve,
        :declared,
        :bounded_write,
        :adapt_storage,
        :copy,
        :logical_copy,
        :qualified,
        true,
    )
    layout = CorePotts.StateLayout([schema])
    handle = only(layout.entries).handle
    read_model = CorePotts.OperationExpression(
        CorePotts.operation_callable(
            Val(:model_bound_state_value), v"1.0.0"
        ),
        CorePotts.StateExpression(handle),
    )
    value = CorePotts.OperationExpression(
        CorePotts.operation_callable(Val(:add), v"1.0.0"),
        read_model,
        CorePotts.LiteralExpression(1.0f0),
    )
    descriptor = CorePotts.CompiledStageDescriptor(
        CorePotts.StaticEvaluator(CorePotts.LiteralExpression(true)),
        CorePotts.StaticEvaluator(value),
        CorePotts.ModelAssignmentEffect(handle),
        CorePotts.AfterMCSStage(),
        CorePotts.ResourceAccess(
            (handle,),
            (handle,),
            CorePotts.EmptyFootprint(),
            CorePotts.ModelFootprint(),
            CorePotts.ExclusiveWriteAccess(),
        ),
        CorePotts.DescriptorSupport(true, true, true, true),
        1,
        1,
    )
    return descriptor, layout
end

@testset "CorePotts model-stage compiler executes through LocalMath on Metal" begin
    Metal.allowscalar(false)
    backend = Metal.MetalBackend()
    descriptor, layout = _metal_model_assignment_descriptor()
    stage_plan = CorePotts.StageExecutionPlan((), (CorePotts.StageDescriptorGroup([descriptor]),), (), 0, 0, "metal-model-assignment")
    gate_space = LocalMath.Space(CorePotts._CheckerboardStageGateDomain, 1)
    external_gate = LocalMath.Field(gate_space, Bool)
    declaration = CorePotts._compile_identity_assignment_law(
        descriptor,
        (:metal_model_assignment,),
        LocalMath.Space(CorePotts._CheckerboardStageModelDomain, 1),
        external_gate,
        layout,
        stage_plan,
        (UInt64(0), UInt64(0)),
        CorePotts._SCHEDULED_BEFORE_LIFECYCLE,
        Float32,
    )
    model_storage = Metal.MtlArray(Float32[2])
    status_storage = Metal.MtlArray(
        CorePotts.ProgramStatus[CorePotts.ProgramStatus()]
    )
    prepared = LocalMath.prepare(
        LocalMath.sequence(declaration.evaluation, declaration.publication),
        only(declaration.fields) => model_storage,
        declaration.scratch => LocalMath.Allocate(CorePotts.StageEvaluation(false, 0.0f0)),
        declaration.status_field => status_storage,
        declaration.initial_gate => LocalMath.Allocate(false),
        declaration.refreshed_gate => LocalMath.Allocate(false),
        external_gate => Metal.MtlArray(Bool[true]);
        backend,
    )
    wait(LocalMath.execute!(prepared; parameters = (mcs = Int64(1), invocation = UInt32(0))))
    @test Array(model_storage) == Float32[3]
    @test Array(status_storage)[1].code === CorePotts.ProgramStatusSuccess
end
