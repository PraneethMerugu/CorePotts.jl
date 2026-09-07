# Checkerboard preparation, execution identity, queue control, and settlement.

function _checkerboard_execution_identity(
        workspace::CheckerboardWorkspace,
        color_laws,
        mechanics,
        queue_mcs_capacity::Integer,
    )
    mechanical_preparations = (
        color_laws.prepared...,
        mechanics.clear_report...,
        (entry.prepared[1]
            for entry in mechanics.stage_boundaries.before)...,
        (entry.prepared[2]
            for entry in mechanics.stage_boundaries.before)...,
        (entry.prepared[1]
            for entry in mechanics.stage_boundaries.after)...,
        (entry.prepared[2]
            for entry in mechanics.stage_boundaries.after)...,
        (mechanics.lifecycle_reductions === nothing ? () : (
            mechanics.lifecycle_reductions[1].site_index,
            mechanics.lifecycle_reductions[1].request_index,
            mechanics.lifecycle_reductions[1].selection,
            mechanics.lifecycle_reductions[2].site_index,
            mechanics.lifecycle_reductions[2].request_index,
            mechanics.lifecycle_reductions[2].selection,
        ))...,
    )
    compilers = map(mechanical_preparations) do prepared
        LocalMath.lowering_identity(prepared.plan)
    end
    all(==(isempty(compilers) ? nothing : first(compilers)), compilers) || throw(ArgumentError(
        "checkerboard proposal stages disagree on provider compiler"
    ))
    compiler_identity = isempty(compilers) ?
        :corepotts_kernelabstractions_v1 : first(compilers)
    mechanisms = workspace.capability_report.key.mechanisms
    submissions_per_mcs = _checked_checkerboard_capacity_mul(
        Int(workspace.state.program.attempts_per_site),
        Int(workspace.state.program.checkerboard_plan.color_count),
        :submissions_per_mcs,
    )
    before_lifecycle_submissions = sum(
        entry.repetitions for entry in mechanics.stage_boundaries.before;
        init = 0)
    after_lifecycle_submissions = sum(
        entry.repetitions for entry in mechanics.stage_boundaries.after;
        init = 0)
    return CheckerboardExecutionIdentity(
        _CHECKERBOARD_EXECUTION_SCHEMA,
        _CHECKERBOARD_MECHANISM_IDENTITY,
        :corepotts_checkerboard_transaction_v1,
        mechanisms.descriptor_fingerprint,
        _capability_key_fingerprint(workspace.capability_report.key),
        workspace.state.program.topology_epoch,
        (
            contract_version = mechanisms.rng_contract_version,
            lowering = mechanisms.rng_lowering_identity,
        ),
        (
            clear_report = LocalMath.lowering_identity(
                mechanics.clear_report[1].plan),
            color_mechanics = LocalMath.lowering_identity(
                first(color_laws.prepared).plan),
            before_lifecycle = map(mechanics.stage_boundaries.before) do entry
                LocalMath.lowering_identity(entry.prepared[1].plan)
            end,
            after_lifecycle = map(mechanics.stage_boundaries.after) do entry
                LocalMath.lowering_identity(entry.prepared[1].plan)
            end,
            lifecycle_status = mechanics.lifecycle_reductions === nothing ?
                :not_applicable : :corepotts_lifecycle_status_ka_v1,
            lifecycle_planning_status =
                mechanics.lifecycle_reductions === nothing ?
                :not_applicable : :corepotts_lifecycle_status_ka_v1,
            lifecycle_site_index = mechanics.lifecycle_reductions === nothing ?
                :not_applicable : LocalMath.lowering_identity(
                    mechanics.lifecycle_reductions[1].site_index.plan
                ),
            lifecycle_request_index = mechanics.lifecycle_reductions === nothing ?
                :not_applicable : LocalMath.lowering_identity(
                    mechanics.lifecycle_reductions[1].request_index.plan
                ),
            lifecycle_emission = mechanics.lifecycle_reductions === nothing ?
                :not_applicable : :corepotts_lifecycle_emission_ka_v1,
            lifecycle_selection = mechanics.lifecycle_reductions === nothing ?
                :not_applicable : LocalMath.lowering_identity(
                    mechanics.lifecycle_reductions[1].selection.plan
                ),
        ),
        :KernelAbstractions,
        compiler_identity,
        (
            mcs_capacity = Int(queue_mcs_capacity),
            color_submissions_per_mcs = submissions_per_mcs,
            clear_report_submissions_per_mcs = 1,
            before_lifecycle_submissions_per_mcs =
                before_lifecycle_submissions,
            after_lifecycle_submissions_per_mcs =
                after_lifecycle_submissions,
            lifecycle_status_submissions_per_mcs = 1,
            lifecycle_planning_status_submissions_per_mcs = 3,
            lifecycle_site_index_submissions_per_mcs = 1,
            lifecycle_request_index_submissions_per_mcs = 1,
            lifecycle_emission_submissions_per_mcs = 1,
            lifecycle_selection_submissions_per_mcs = 1,
            receipt_scope = :backend_queue,
            receipt_cumulative = true,
            receipt_selective = false,
            completion = :grouped_cumulative_receipts,
        ),
        _CHECKERBOARD_CHECKPOINT_SCHEMA,
    )
end

function _build_checkerboard_capability_report(
        direct::ProgramCapabilityReport,
        identity::CheckerboardExecutionIdentity,
    )
    capability_authorizes_execution(direct) ||
        throw(ProgramCapabilityError(:checkerboard_localmath, direct))
    identity.capability_fingerprint ==
        _capability_key_fingerprint(direct.key) || throw(ArgumentError(
        "checkerboard execution identity does not name the admitted capability key"
    ))
    return direct
end

function _prepare_checkerboard_execution(
        runtime::ProgramRuntime;
        queue_mcs_capacity::Integer = 12,
    )
    runtime.settled || throw(ArgumentError(
        "checkerboard execution preparation requires a settled runtime"
    ))
    _require_program_execution_capability(
        runtime.capability_report;
        operation = :checkerboard_localmath,
    )
    workspace = runtime.engine_workspace
    workspace isa CheckerboardWorkspace || throw(ArgumentError(
        "checkerboard execution preparation requires authoritative Core storage"
    ))
    queue_mcs_capacity > 0 || throw(ArgumentError(
        "checkerboard queue capacity must be positive"
    ))
    submissions_per_mcs = _checked_checkerboard_capacity_mul(
        Int(runtime.program.attempts_per_site),
        Int(runtime.program.checkerboard_plan.color_count),
        :compiled_color_submissions_per_mcs)
    color_lease_capacity = _checked_checkerboard_capacity_mul(
        Int(queue_mcs_capacity), submissions_per_mcs,
        :compiled_color_lease_capacity)
    color_laws = _prepare_checkerboard_color_laws(
        workspace,
        runtime.program.checkerboard_plan,
        runtime.program.proposal_offsets,
        runtime.program.descriptor_plan,
        runtime.program.stage_plan,
        runtime.program.ownership_change_handles,
        runtime.program.relationships,
        runtime.program.kind_count,
        color_lease_capacity,
    )
    mechanics = _prepare_localmath_checkerboard_mechanics(
        workspace;
        queue_mcs_capacity,
        canonical_plan = runtime.program.checkerboard_plan,
        canonical_proposal_offsets = runtime.program.proposal_offsets,
        canonical_stage_plan = runtime.program.stage_plan,
    )
    identity = _checkerboard_execution_identity(
        workspace,
        color_laws,
        mechanics,
        queue_mcs_capacity,
    )
    capability_report = _build_checkerboard_capability_report(
        runtime.capability_report, identity
    )
    execution = _CheckerboardExecutionWorkspace(
        workspace,
        color_laws,
        mechanics.clear_report,
        mechanics.stage_boundaries,
        mechanics.lifecycle_reductions,
        mechanics.gates,
        _empty_checkerboard_receipts(),
        identity,
        capability_report,
    )
    return _rebuild_program_runtime(runtime, capability_report, execution)
end

function _checkerboard_execution_identity_block(
        identity::CheckerboardExecutionIdentity
    )
    return (
        schema = identity.schema,
        mechanism_identity = identity.mechanism_identity,
        scientific_abi = identity.scientific_abi,
        descriptor_fingerprint = identity.descriptor_fingerprint,
        capability_fingerprint = identity.capability_fingerprint,
        topology_epoch = identity.topology_epoch,
        rng_identity = identity.rng_identity,
        lowerings = identity.lowerings,
        provider = identity.provider,
        provider_compiler = identity.provider_compiler,
        queue_policy = identity.queue_policy,
        checkpoint_schema = identity.checkpoint_schema,
    )
end

function _checkpoint_execution_block(
        runtime::ProgramRuntime{T, N, P, C, R, TS, D, SB, EW, LW}
    ) where {
        T, N, P, C, R, TS, D, SB,
        EW <: _CheckerboardExecutionWorkspace, LW,
    }
    execution = runtime.engine_workspace
    return (
        schema = _CHECKERBOARD_CHECKPOINT_SCHEMA,
        mechanism_identity = execution.identity.mechanism_identity,
        identity = _checkerboard_execution_identity_block(execution.identity),
    )
end

function _restore_checkerboard_checkpoint(
        program::CompiledPottsProgram,
        checkpoint::ProgramCheckpoint,
    )
    expected = _CHECKERBOARD_MECHANISM_IDENTITY
    _validate_program_checkpoint(program, checkpoint, expected)
    block = checkpoint.extensions.CorePotts.execution_lowering
    block.schema == _CHECKERBOARD_CHECKPOINT_SCHEMA || throw(ArgumentError(
        "checkerboard checkpoint has an unsupported execution schema"
    ))
    runtime = _restore_validated_program_checkpoint(program, checkpoint)
    runtime.engine_workspace isa CheckerboardWorkspace || return runtime
    queue_mcs_capacity = Int(block.identity.queue_policy.mcs_capacity)
    restored = _prepare_checkerboard_execution(
        runtime; queue_mcs_capacity
    )
    restored_block = _checkpoint_execution_block(restored)
    if restored_block != block
        mismatches = filter(propertynames(block.identity)) do name
            getproperty(restored_block.identity, name) !=
                getproperty(block.identity, name)
        end
        throw(ArgumentError(
            "checkerboard checkpoint execution identity does not match this environment: " *
                join(string.(mismatches), ", ")
        ))
    end
    return restored
end

function _inspect_checkerboard_execution(
        execution::_CheckerboardExecutionWorkspace
    )
    return (
        identity = _checkerboard_execution_identity_block(execution.identity),
        color_mechanics = map(
            LocalMath.inspect, execution.color_laws.prepared),
        clear_report = map(LocalMath.inspect, execution.clear_report),
        stage_boundaries = (
            before = map(execution.stage_boundaries.before) do entry
                map(LocalMath.inspect, entry.prepared)
            end,
            after = map(execution.stage_boundaries.after) do entry
                map(LocalMath.inspect, entry.prepared)
            end,
        ),
        lifecycle_reductions = execution.lifecycle_reductions === nothing ?
            nothing : map(execution.lifecycle_reductions) do reductions
                (
                    direct = _inspect_lifecycle_status_reduction(
                        reductions.direct),
                    planning = _inspect_lifecycle_status_reduction(
                        reductions.planning),
                    site_index = LocalMath.inspect(reductions.site_index),
                    request_index = LocalMath.inspect(
                        reductions.request_index
                    ),
                    emission = _inspect_lifecycle_emission(
                        reductions.emission),
                    selection = _inspect_lifecycle_selection(
                        reductions.selection
                    ),
                )
            end,
        completion_receipts = _inspect_checkerboard_receipts(
            execution.receipts),
        order = (
            :state_initialization_and_report_reset,
            :color_mechanics,
            :before_lifecycle,
            :core_lifecycle_transaction,
            :after_lifecycle,
            :bank_authorization_and_publication,
        ),
    )
end

"""Queue one checkerboard MCS without publishing host-visible logical state."""
function enqueue_program_mcs!(runtime::ProgramRuntime)
    _require_program_execution_capability(
        runtime.capability_report;
        operation = :queued_mcs,
    )
    supports_queued_program_execution(runtime) || throw(ArgumentError(
        "this program does not support queued whole-MCS execution"
    ))
    program_failed(runtime) && throw(ArgumentError(
        "cannot enqueue a program runtime after a terminal scientific failure"
    ))
    workspace = runtime.engine_workspace
    execution = _checkerboard_execution_position(workspace)
    current_mcs = execution.submitted_mcs
    _preflight_checkerboard_mcs!(workspace, current_mcs)
    # From this point onward an ordered CorePotts prefix may have reached the
    # backend even if a later LocalMath admission check rejects. Keep the
    # runtime unsettled until the portable settlement boundary drains it.
    runtime.settled = false
    _enqueue_checkerboard_mcs_after_preflight!(workspace, current_mcs)
    return runtime
end

"""Queue checkerboard execution through the requested absolute MCS."""
function enqueue_program_through!(
        runtime::ProgramRuntime, target_mcs::Integer
    )
    _require_program_execution_capability(
        runtime.capability_report;
        operation = :queued_mcs_through,
    )
    supports_queued_program_execution(runtime) || throw(ArgumentError(
        "this program does not support queued whole-MCS execution"
    ))
    workspace = runtime.engine_workspace
    execution = _checkerboard_execution_position(workspace)
    target = Int(target_mcs)
    target >= execution.submitted_mcs || throw(ArgumentError(
        "queued execution target precedes the submitted MCS"
    ))
    while execution.submitted_mcs < target
        enqueue_program_mcs!(runtime)
    end
    return runtime
end

"""Drain queued work and publish it according to a settlement request."""
function settle_program!(
        runtime::ProgramRuntime, request::ProgramSettlementRequest
    )
    _require_program_execution_capability(
        runtime.capability_report;
        operation = :settle_program,
    )
    supports_queued_program_execution(runtime) || throw(ArgumentError(
        "this program does not support queued whole-MCS settlement"
    ))
    receipt = settle_program!(runtime.engine_workspace, request)
    request.full_snapshot && _publish_program_receipt!(runtime, receipt)
    return receipt
end

function _advance_checkerboard_transaction!(runtime::ProgramRuntime)
    workspace = runtime.engine_workspace
    workspace isa _CheckerboardExecutionWorkspace || error(
        "checkerboard runtime has no portable execution workspace"
    )
    enqueue_program_mcs!(runtime)
    receipt = settle_program!(
        runtime,
        ProgramSettlementRequest(PublicStepSettlement; full_snapshot = true),
    )
    receipt.snapshot === nothing && throw(LifecycleInvariantFailure(
        Int32(0), Int32(receipt.committed_mcs), :missing_program_snapshot
    ))
    return runtime
end

"""Advance one complete transactional MCS and publish only after successful settlement."""
function advance_mcs!(runtime::ProgramRuntime)
    _require_program_execution_capability(
        runtime.capability_report;
        operation = :advance_mcs,
    )
    runtime.settled ||
        throw(ArgumentError("cannot advance an unsettled program runtime"))
    program_failed(runtime) && throw(ArgumentError(
        "cannot advance a program runtime after a terminal scientific failure"
    ))
    if runtime.program.engine isa CheckerboardProgramEngine
        return _advance_checkerboard_transaction!(runtime)
    end
    if runtime.program.engine isa SequentialProgramEngine
        return _advance_sequential_transaction!(runtime)
    end
    error("unsupported program engine $(typeof(runtime.program.engine))")
end

"""Return the durable symbolic identity of a compiled program backend."""
@inline program_backend_name(::CPUProgramBackend) = :CPUBackend
@inline program_backend_name(::AdaptedProgramBackend{Name}) where {Name} = Name

"""Inspect the program's engine, backend, numerical policy, tracker plan, and RNG contract."""
function program_execution_report(program::CompiledPottsProgram)
    _validate_compiled_program_integrity(program)
    return (
        engine = nameof(typeof(program.engine)),
        backend = program_backend_name(program.backend),
        scalar_type = eltype(program.parameter_defaults),
        shape = program.shape,
        attempts_per_site = program.attempts_per_site,
        trackers = tracker_plan_report(program.tracker_plan),
        rng = :Philox4x32x10V2,
        numerical_policy = (
            math = :accurate,
            reductions = :deterministic,
            bounds = :checked,
        ),
    )
end
