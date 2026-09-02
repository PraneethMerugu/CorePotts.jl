# These fixtures deliberately use only CorePotts-owned compiler values.  They
# keep the backend conformance witness independent of the high-level Potts
# authoring package that originally supplied the equivalent model.
struct _BoundaryProviderFailureOperation <:
       CorePotts.AbstractContextualOperation end

CorePotts.operation_context_supported(
    ::_BoundaryProviderFailureOperation,
    ::Type{CorePotts.AbstractProposalEvaluationContext},
) = true

@inline function (::_BoundaryProviderFailureOperation)(arguments, context)
    error("intentional checkerboard provider failure")
end

function _boundary_descriptor_plan(branch::Symbol)
    branch === :neutral && return CorePotts.DescriptorExecutionPlan(
        (),
        CorePotts.StateLayout(CorePotts.StateBlockSchema[]),
        CorePotts.WorkspaceLayout(CorePotts.WorkspaceSchema[]),
        (), Any[], 0, "boundary-descriptor-plan-v1",
        CorePotts.HamiltonianDomainResources(0, 0),
    )
    evaluator, role = if branch === :nonfinite
        (
            CorePotts.StaticEvaluator(
                CorePotts.LiteralExpression(Float32(NaN))
            ),
            CorePotts.ProposalDriveRole(),
        )
    elseif branch === :provider_failure
        (
            CorePotts.StaticEvaluator(CorePotts.OperationExpression(
                _BoundaryProviderFailureOperation(),
                CorePotts.LiteralExpression(Float32(1)),
            )),
            CorePotts.ProposalDriveRole(),
        )
    elseif branch === :gpu_unsupported
        (
            CorePotts.StaticEvaluator(
                CorePotts.LiteralExpression(Float32(0))
            ),
            CorePotts.ProposalDriveRole(),
        )
    else
        throw(ArgumentError("unknown checkerboard boundary branch `$branch`"))
    end
    access = CorePotts.ResourceAccess(
        (), (), CorePotts.EmptyFootprint(), CorePotts.EmptyFootprint(),
        CorePotts.NoWriteAccess(),
    )
    descriptor = CorePotts.ProposalDescriptor(
        evaluator, access,
        CorePotts.DescriptorSupport(
            true, true, true, branch !== :gpu_unsupported
        ),
        (), (), role, 1,
    )
    expression = descriptor.evaluator.expression
    strategy = CorePotts.DescriptorKernelStrategy{
        typeof(descriptor), typeof(expression), typeof(access),
        typeof(role), Val{:proposal},
    }()
    group = CorePotts.DescriptorGroup(
        CorePotts.DescriptorLaunch(strategy, [descriptor], (), ()),
        (family = :boundary_failure,),
    )
    return CorePotts.DescriptorExecutionPlan(
        (group,),
        CorePotts.StateLayout(CorePotts.StateBlockSchema[]),
        CorePotts.WorkspaceLayout(CorePotts.WorkspaceSchema[]),
        (), Any[(path = (:checkerboard_boundary,), local_id = branch)],
        1, "boundary-$branch-descriptor-plan-v1",
        CorePotts.HamiltonianDomainResources(0, 0),
    )
end

function test_metal_capability_rejects_cpu_only_descriptor(device_array)
    program = _boundary_program((2, 2); branch = :gpu_unsupported)
    runtime = CorePotts.initialize_program(
        program, _boundary_initial((2, 2)), Float32[],
        UInt64(0x1ca3), UInt32(3),
    )
    @test_throws CorePotts.ProgramCapabilityError begin
        CorePotts.adapt_program_runtime(device_array, runtime)
    end
    return nothing
end

function _boundary_program(
        shape::NTuple{2, Int}; branch::Symbol = :neutral
    )
    offsets = Int8[1 -1 0 0; 0 0 1 -1]
    tracker_plan = CorePotts.TrackerExecutionPlan(
        (CorePotts.OwnershipCountTracker(),),
        "boundary-tracker-plan-v1",
    )
    checkerboard_plan = CorePotts.CheckerboardPlan(
        shape, (true, true), zeros(Int8, 2, 0)
    )
    return CorePotts.CompiledPottsProgram(
        shape, (true, true), offsets, 2, 1,
        CorePotts.CompiledScalar(2.0f0), 1, Float32[], (), tracker_plan,
        _boundary_descriptor_plan(branch), CorePotts.StageExecutionPlan(),
        CorePotts.CheckerboardProgramEngine(), CorePotts.CPUProgramBackend(),
        "boundary-program-$(shape)-$branch-v1";
        medium_kinds = Bool[true, false], checkerboard_plan,
    )
end

function _boundary_initial(shape::NTuple{2, Int})
    ownership = zeros(Int32, shape)
    if prod(shape) == 1
        ownership[1] = Int32(1)
    else
        for first_dimension in axes(ownership, 1)
            isodd(first_dimension) &&
                (ownership[first_dimension, 1] = Int32(1))
        end
    end
    return CorePotts.ProgramInitialState(
        ownership, Int16[2]; scalar_type = Float32
    )
end

function _localmath_canonical_runtime(
        array_convert, program, initial, seed, replica
    )
    runtime = CorePotts.initialize_program(
        program, initial, Float32[], seed, replica
    )
    return array_convert === identity ? runtime :
           CorePotts.adapt_program_runtime(array_convert, runtime)
end

function _test_localmath_receipt_parity(cpu, device)
    @test cpu.submitted_mcs == device.submitted_mcs
    @test cpu.drained_mcs == device.drained_mcs
    @test cpu.committed_mcs == device.committed_mcs
    @test cpu.materialized_mcs == device.materialized_mcs
    @test cpu.counters == device.counters
    @test cpu.status == device.status
    @test typeof(cpu.failure) === typeof(device.failure)
    @test cpu.snapshot.ownership == device.snapshot.ownership
    @test cpu.snapshot.cell_kinds == device.snapshot.cell_kinds
    @test cpu.snapshot.cell_generations == device.snapshot.cell_generations
    @test cpu.snapshot.trackers.values == device.snapshot.trackers.values
    @test collect(cpu.snapshot.relationships) ==
          collect(device.snapshot.relationships)
    @test cpu.snapshot.descriptor_state == device.snapshot.descriptor_state
    return nothing
end

function _test_boundary_scientific_oracle(receipt, program)
    snapshot = receipt.snapshot
    ownership = snapshot.ownership
    owner_count = length(snapshot.cell_kinds)
    expected_volume = zeros(Int32, owner_count)
    for owner in ownership
        if !(0 <= owner <= owner_count)
            @test false
            continue
        end
        owner > 0 && (expected_volume[Int(owner)] += Int32(1))
    end
    @test only(snapshot.trackers.values) == expected_volume
    @test sum(expected_volume) == count(>(0), ownership)
    attempted = receipt.counters.accepted + receipt.counters.rejected +
                receipt.counters.null_attempts
    @test attempted == UInt64(
        receipt.committed_mcs * length(ownership) *
        Int(program.attempts_per_site)
    )
    return nothing
end

function _test_checkpoint_continuation(
        array_convert, program, cpu, device, checkpoint_mcs
    )
    cpu_checkpoint = CorePotts.program_checkpoint(cpu)
    cpu_restored = CorePotts.restore_program_checkpoint(
        program, cpu_checkpoint
    )
    device_restored_host = CorePotts.restore_program_checkpoint(
        program, cpu_checkpoint
    )
    device_restored = array_convert === identity ? device_restored_host :
                      CorePotts.adapt_program_runtime(
        array_convert, device_restored_host
    )
    continuation_mcs = checkpoint_mcs + 2
    CorePotts.enqueue_program_through!(cpu, continuation_mcs)
    CorePotts.enqueue_program_through!(device, continuation_mcs)
    CorePotts.enqueue_program_through!(cpu_restored, continuation_mcs)
    CorePotts.enqueue_program_through!(device_restored, continuation_mcs)
    request = CorePotts.ProgramSettlementRequest(
        CorePotts.PublicStepSettlement; full_snapshot = true
    )
    cpu_receipt = CorePotts.settle_program!(cpu, request)
    device_receipt = CorePotts.settle_program!(device, request)
    restored_cpu_receipt = CorePotts.settle_program!(cpu_restored, request)
    restored_device_receipt = CorePotts.settle_program!(
        device_restored, request
    )
    _test_localmath_receipt_parity(cpu_receipt, device_receipt)
    _test_localmath_receipt_parity(cpu_receipt, restored_cpu_receipt)
    _test_localmath_receipt_parity(
        cpu_receipt, restored_device_receipt
    )
    return CorePotts.program_checkpoint(cpu_restored).checksum
end

function run_localmath_checkerboard_vertical(
        device_array;
        backend_name,
        mcs_count = 12,
    )
    program = _boundary_program((6, 6); branch = :neutral)
    initial = _boundary_initial((6, 6))
    seed = UInt64(0x1ca1)
    replica = UInt32(3)
    cpu = _localmath_canonical_runtime(
        identity, program, initial, seed, replica
    )
    device = _localmath_canonical_runtime(
        device_array, program, initial, seed, replica
    )
    CorePotts.enqueue_program_through!(cpu, mcs_count)
    CorePotts.enqueue_program_through!(device, mcs_count)
    request = CorePotts.ProgramSettlementRequest(
        CorePotts.PublicStepSettlement; full_snapshot = true
    )
    cpu_receipt = CorePotts.settle_program!(cpu, request)
    device_receipt = CorePotts.settle_program!(device, request)
    _test_localmath_receipt_parity(cpu_receipt, device_receipt)
    _test_boundary_scientific_oracle(device_receipt, program)
    continuation_checksum = _test_checkpoint_continuation(
        device_array, program, cpu, device, mcs_count
    )

    return (
        backend = backend_name,
        submitted_mcs = device_receipt.submitted_mcs,
        committed_mcs = device_receipt.committed_mcs,
        continuation_mcs = mcs_count + 2,
        continuation_checksum,
        ownership_checksum = sum(
            index * Int(owner) for (index, owner) in
                enumerate(device_receipt.snapshot.ownership)
        ),
    )
end

function run_localmath_checkerboard_failures(
        device_array;
        backend_name,
        mcs_count = 12,
        require_provider_failure = true,
    )
    initial = _boundary_initial((6, 6))
    seed = UInt64(0x1ca2)
    replica = UInt32(3)
    request = CorePotts.ProgramSettlementRequest(
        CorePotts.PublicStepSettlement; full_snapshot = true
    )

    # A scientific acceptance failure closes the CorePotts status gate. It is
    # a successful provider execution: no MCS publishes and no prepared work
    # is poisoned.
    failure_program = _boundary_program((6, 6); branch = :nonfinite)
    cpu = _localmath_canonical_runtime(
        identity, failure_program, initial, seed, replica
    )
    device = _localmath_canonical_runtime(
        device_array, failure_program, initial, seed, replica
    )
    CorePotts.enqueue_program_through!(cpu, mcs_count)
    CorePotts.enqueue_program_through!(device, mcs_count)
    cpu_receipt = CorePotts.settle_program!(cpu, request)
    device_receipt = CorePotts.settle_program!(device, request)
    _test_localmath_receipt_parity(cpu_receipt, device_receipt)
    @test device_receipt.failure isa CorePotts.ProposalAcceptanceFailure
    @test device_receipt.committed_mcs == 0
    @test device_receipt.materialized_mcs == 0
    @test device_receipt.snapshot.ownership == initial.ownership
    @test device_receipt.counters == (
        accepted = UInt64(0),
        rejected = UInt64(0),
        null_attempts = UInt64(0),
        constraint_rejections = UInt64(0),
        energy_rejections = UInt64(0),
        retired_cells = UInt64(0),
    )

    # An owner-local contextual operation deliberately fails during proposal
    # evaluation. This exercises CorePotts' provider-failure translation
    # without mutating prepared storage or relying on undefined device access.
    provider_failure = nothing
    if require_provider_failure
        provider_program = _boundary_program(
            (6, 6); branch = :provider_failure
        )
        provider_runtime = _localmath_canonical_runtime(
            device_array, provider_program, initial, seed, replica
        )
        provider_failure = try
            CorePotts.enqueue_program_mcs!(provider_runtime)
            CorePotts.settle_program!(provider_runtime, request)
            nothing
        catch error
            error
        end
        @test provider_failure isa CorePotts.LifecycleBackendFailure
        @test provider_failure.first_possible_mcs == 1
        @test provider_failure.last_possible_mcs == 1
    end

    return (
        backend = backend_name,
        scientific_failure = nameof(typeof(device_receipt.failure)),
        scientific_failure_commit = device_receipt.committed_mcs,
        provider_failure_type = provider_failure === nothing ? nothing :
                                nameof(typeof(provider_failure)),
        provider_failure_range = provider_failure === nothing ? nothing : (
            provider_failure.first_possible_mcs,
            provider_failure.last_possible_mcs,
        ),
    )
end
