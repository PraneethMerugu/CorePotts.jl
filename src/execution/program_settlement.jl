# Sole host-wait and device-to-host publication boundary for queued programs.

"""Reason a caller requires queued work to cross a host publication boundary."""
@enum ProgramSettlementReason::UInt8 begin
    FinalizationSettlement = 0x01
    PublicStepSettlement = 0x02
    SaveSettlement = 0x03
    HostCallbackSettlement = 0x04
    CheckpointSettlement = 0x05
    IndexReadSettlement = 0x06
    IndexMutationSettlement = 0x07
    ComponentExchangeSettlement = 0x08
    ProgressSettlement = 0x09
    StatisticsSettlement = 0x0a
    ObservationSettlement = 0x0b
    InitializationSettlement = 0x0c
end
"""Settlement requested before runtime finalization."""
FinalizationSettlement
"""Settlement requested by the public one-step API."""
PublicStepSettlement
"""Settlement requested before saving logical state."""
SaveSettlement
"""Settlement requested before invoking a host callback."""
HostCallbackSettlement
"""Settlement requested before constructing an exact checkpoint."""
CheckpointSettlement
"""Settlement requested before indexed state observation."""
IndexReadSettlement
"""Settlement requested before indexed state mutation."""
IndexMutationSettlement
"""Settlement requested before component-state exchange."""
ComponentExchangeSettlement
"""Settlement requested to report execution progress."""
ProgressSettlement
"""Settlement requested to publish execution statistics."""
StatisticsSettlement
"""Settlement requested to materialize a scientific observation."""
ObservationSettlement
"""Settlement of an unpublished MCS-zero history initialization candidate."""
InitializationSettlement

"""Requested publication reason and whether a complete snapshot is required."""
struct ProgramSettlementRequest
    reason::ProgramSettlementReason
    full_snapshot::Bool
end

ProgramSettlementRequest(
    reason::ProgramSettlementReason; full_snapshot::Bool = false
) = ProgramSettlementRequest(reason, full_snapshot)

"""
Result of draining queued work and optionally materializing a logical snapshot.
A successful `InitializationSettlement` snapshot is the validated inactive candidate;
ordinary settlements and failed initialization return the active scientific bank.
"""
struct ProgramSettlementReceipt{S, F, L}
    submitted_mcs::Int
    drained_mcs::Int
    committed_mcs::Int
    materialized_mcs::Int
    counters::NamedTuple
    status::ProgramStatus
    failure::F
    lifecycle_receipt::L
    snapshot::S
end

"""Immutable public detail for one expected device-reported scientific stop."""
struct ProgramFailureReport
    code::ProgramStatusCode
    mcs::Int
    stage::ProgramExecutionStage
    source::Int32
    action_identity::UInt64
    secondary_source::Int32
    anchor::Int32
    detail::ProgramStatusDetailCode
    required::Int32
    available::Int32
    maximum::Int32
end

"""
    update_program_inputs!(runtime; parameters=nothing, descriptor_state=nothing)

Publish one combined host input transaction at a settled scientific boundary.
`nothing` preserves that published input. Validate both effective inputs and
their derived quantities before copying any candidate into the host mirror or
execution banks. Candidate buffers are not retained. Ordinary validation is
failure atomic; backend-copy failures are not a general rollback guarantee.
"""
function update_program_inputs!(
        runtime::ProgramRuntime;
        parameters::Union{Nothing, AbstractVector{<:Real}} = nothing,
        descriptor_state::Union{Nothing, AuxiliaryState} = nothing,
    )
    runtime.settled ||
        throw(ArgumentError("input updates require a settled MCS boundary"))
    program_failed(runtime) && throw(ArgumentError(
        "input updates cannot repair a terminal-failed runtime"
    ))
    parameters === nothing && descriptor_state === nothing && return runtime
    replacement_parameters = if parameters === nothing
        runtime.parameters
    else
        length(parameters) == length(runtime.parameters) ||
            throw(ArgumentError("runtime parameter buffer has the wrong length"))
        _validated_program_parameters(runtime.program, parameters)
    end
    replacement_state = descriptor_state === nothing ? runtime.descriptor_state :
        _validate_auxiliary_state_candidate(
            runtime.program.descriptor_plan.state_layout,
            runtime.descriptor_state, descriptor_state,
        )
    execution_workspace = runtime.engine_workspace
    device_workspace = _is_checkerboard_execution_workspace(execution_workspace) ?
        _checkerboard_core(execution_workspace) : nothing
    active = device_workspace === nothing ? runtime :
        first(_checkerboard_transaction_banks(device_workspace, device_workspace.execution.committed_mcs))
    source = tracker_source_view(runtime.program, active.ownership;
        parameters = replacement_parameters,
        descriptor_state = descriptor_state === nothing ? active.descriptor_state : replacement_state)
    replacement_trackers = _input_tracker_candidate(
        runtime.program.tracker_plan, active.trackers, source, active.cell_kinds;
        backend = KernelAbstractions.get_backend(active.ownership),
        copy_source = descriptor_state !== nothing)
    destinations = if device_workspace !== nothing
        (runtime, device_workspace.state, device_workspace.alternate_state)
    else
        (runtime,)
    end
    for destination in destinations
        _require_auxiliary_copy_compatible(destination.descriptor_state, replacement_state)
        _require_tracker_copy_compatible(destination.trackers, replacement_trackers)
    end
    # No scientific observer runs between these copies. In particular a mixed
    # update is never evaluated with new parameters over the old source state.
    parameter_destinations = Any[]
    state_destinations = Any[]
    tracker_destinations = Any[]
    for destination in destinations
        if parameters !== nothing && !any(value -> value === destination.parameters, parameter_destinations)
            push!(parameter_destinations, destination.parameters)
            copyto!(destination.parameters, replacement_parameters)
        end
        if descriptor_state !== nothing && !any(value -> value === destination.descriptor_state, state_destinations)
            push!(state_destinations, destination.descriptor_state)
            copyto_auxiliary_state!(destination.descriptor_state, replacement_state)
        end
        if !any(value -> value === destination.trackers, tracker_destinations)
            push!(tracker_destinations, destination.trackers)
            _copy_input_tracker_state!(destination.trackers, replacement_trackers,
                runtime.program.tracker_plan, destination === runtime ? Array : identity)
        end
    end
    return runtime
end

ProgramFailureReport(status::ProgramStatus) = ProgramFailureReport(
    status.code,
    Int(status.mcs),
    status.stage,
    status.source,
    status.action_identity,
    status.secondary_source,
    status.anchor,
    status.detail,
    status.required,
    status.available,
    status.maximum,
)

@inline function program_status_is_expected(status::ProgramStatus)
    status.code in (
        ProgramStatusInadmissible,
        ProgramStatusConflict,
        ProgramStatusCellCapacity,
        ProgramStatusRelationshipCapacity,
        ProgramStatusGenerationOverflow,
        ProgramStatusAcceptance,
    ) && return true
    status.code === ProgramStatusEvaluator || return false
    return status.detail in (
        LifecycleDetailNonfiniteResult,
        LifecycleDetailSplitFractionOutOfBounds,
        LifecycleDetailStateValueInvalid,
    )
end

function _settlement_counters(values)
    return (
        accepted = UInt64(values[_PROGRAM_STAT_ACCEPTED]),
        rejected = UInt64(values[_PROGRAM_STAT_REJECTED]),
        null_attempts = UInt64(values[_PROGRAM_STAT_NULL]),
        constraint_rejections = UInt64(values[_PROGRAM_STAT_CONSTRAINT]),
        energy_rejections = UInt64(values[_PROGRAM_STAT_ENERGY]),
        retired_cells = UInt64(values[_PROGRAM_STAT_RETIRED]),
    )
end

function _materialize_program_bank(state, committed_mcs::Int)
    ownership = Adapt.adapt(Array, state.ownership)
    cell_kinds = Adapt.adapt(Array, state.cell_kinds)
    cell_generations = Adapt.adapt(Array, state.cell_generations)
    trackers = Adapt.adapt(Array, state.trackers)
    relationships = Adapt.adapt(Array, state.relationships)
    descriptor_state = Adapt.adapt(Array, state.descriptor_state)
    return ProgramSnapshot{
        eltype(state.parameters),
        ndims(ownership),
        typeof(relationships),
        typeof(descriptor_state),
        typeof(trackers),
    }(
        committed_mcs,
        ownership,
        cell_kinds,
        cell_generations,
        trackers,
        relationships,
        descriptor_state,
    )
end

function _settlement_active_state(workspace, active_bank::Int)
    active_bank == 1 && return workspace.state
    active_bank == 2 && return workspace.alternate_state
    throw(LifecycleInvariantFailure(
        Int32(0), Int32(active_bank), :invalid_active_state_bank
    ))
end

function _settlement_inactive_state(workspace, active_bank::Int)
    active_bank == 1 && return workspace.alternate_state
    active_bank == 2 && return workspace.state
    throw(LifecycleInvariantFailure(
        Int32(0), Int32(active_bank), :invalid_active_state_bank
    ))
end

function _settlement_lifecycle_receipt(
        backend,
        active_state,
        before_state,
        committed::Int,
        previous_drained::Int,
        failure,
    )
    failure === nothing || return nothing
    committed > previous_drained || return nothing
    plan = active_state.program.lifecycle_plan
    workspace = active_state.lifecycle_workspace
    before_kinds = before_state.cell_kinds
    before_generations = before_state.cell_generations
    after_kinds = active_state.cell_kinds
    after_generations = active_state.cell_generations
    if !(backend isa KernelAbstractions.CPU) &&
            !(plan isa NoLifecycleExecutionPlan)
        # Receipt publication is part of settlement.  A device lifecycle plan
        # therefore crosses to owned host storage here, never from a kernel or
        # from an indexing/observation helper.  The no-lifecycle case needs no
        # transfer and still publishes an empty transaction receipt.
        plan = Adapt.adapt(Array, plan)
        workspace = Adapt.adapt(Array, workspace)
        before_kinds = Adapt.adapt(Array, before_kinds)
        before_generations = Adapt.adapt(Array, before_generations)
        after_kinds = Adapt.adapt(Array, after_kinds)
        after_generations = Adapt.adapt(Array, after_generations)
    end
    return _materialize_lifecycle_receipt(
        plan,
        workspace,
        before_kinds,
        before_generations,
        after_kinds,
        after_generations,
        committed,
        active_state.seed,
        active_state.replica,
        active_state.repeat,
    )
end

"""
    settle_program!(workspace, request)

Drain all work submitted to a checkerboard program's ordered backend queue, inspect its sticky
status and cumulative counters, and optionally materialize the last coherent scientific bank.
This is the only production operation permitted to synchronize or transfer checkerboard program
state to the host.
"""
function _settle_program_after_wait!(
        workspace::CheckerboardWorkspace,
        request::ProgramSettlementRequest,
        did_synchronize::Bool,
    )
    execution = workspace.execution
    submitted = execution.submitted_mcs
    previous_drained = execution.drained_mcs
    backend = KernelAbstractions.get_backend(workspace.state.ownership)
    did_synchronize && (execution.synchronization_count += 1)
    execution.drained_mcs = submitted
    execution.settlement_count += 1

    status_values = Adapt.adapt(Array, workspace.state.program_status)
    counter_values = Adapt.adapt(
        Array, workspace.state.lifecycle_control.counters
    )
    statistic_values = Adapt.adapt(
        Array, workspace.state.lifecycle_control.statistics
    )
    execution.control_transfer_count += 1
    status = only(status_values)
    committed = Int(counter_values[_LIFECYCLE_CONTROL_COMMITTED_MCS])
    active_bank = Int(counter_values[_LIFECYCLE_CONTROL_ACTIVE_BANK])
    execution.committed_mcs = committed

    failure = _translate_program_status(status)
    if failure !== nothing && !program_status_is_expected(status)
        throw(failure)
    end
    if failure === nothing && committed != submitted
        throw(LifecycleInvariantFailure(
            Int32(0), Int32(committed), :committed_submission_mismatch
        ))
    end
    initializing = request.reason === InitializationSettlement
    if initializing && !(submitted == committed == previous_drained == 0)
        throw(ArgumentError("history initialization settlement requires the initial MCS-zero boundary"))
    end
    if failure !== nothing
        if !(initializing && status.mcs == 0)
            0 < status.mcs <= submitted || throw(
                LifecycleInvariantFailure(
                    status.source, status.anchor, :invalid_failure_mcs
                )
            )
            committed < status.mcs || throw(
                LifecycleInvariantFailure(
                    status.source, status.anchor, :failure_after_publication
                )
            )
        end
    end

    active_state = _settlement_active_state(workspace, active_bank)
    before_state = _settlement_inactive_state(workspace, active_bank)
    lifecycle_receipt = _settlement_lifecycle_receipt(
        backend,
        active_state,
        before_state,
        committed,
        previous_drained,
        failure,
    )
    if !(backend isa KernelAbstractions.CPU) &&
            !(active_state.program.lifecycle_plan isa NoLifecycleExecutionPlan) &&
            lifecycle_receipt !== nothing
        execution.lifecycle_transfer_count += 1
    end
    snapshot = if request.full_snapshot
        snapshot_state = initializing && failure === nothing ? before_state : active_state
        value = _materialize_program_bank(snapshot_state, committed)
        execution.materialized_mcs = committed
        execution.snapshot_transfer_count += 1
        value
    else
        nothing
    end
    return ProgramSettlementReceipt(
        submitted,
        execution.drained_mcs,
        committed,
        execution.materialized_mcs,
        _settlement_counters(statistic_values),
        status,
        failure,
        lifecycle_receipt,
        snapshot,
    )
end

"""
    initialize_history!(runtime)

Capture only histories whose declared cadence is `AtMCSCadence` at zero, after
the initial source values have settled. Replace each newest sample while
preserving older prehistory. This does not execute ordinary boundary processes,
advance time, or change scientific counters. Capture uses an unpublished candidate
and the ordinary validated state publisher, so a failure leaves active state unchanged.

Call once when explicitly deferring `initialize_program`'s automatic fresh capture.
Checkpoint restoration never calls this operation automatically.
"""
function initialize_history!(runtime::ProgramRuntime)
    runtime.settled && runtime.mcs == 0 || throw(
        ArgumentError(
            "history initialization requires a settled MCS-zero boundary"
        )
    )
    program_failed(runtime) && throw(
        ArgumentError(
            "cannot initialize history after a terminal scientific failure"
        )
    )
    descriptors = Tuple(
        descriptor for descriptor in _history_descriptors(runtime.program.stage_plan)
            if _completed_mcs_due(descriptor.effect.cadence, descriptor.effect.cadence_value, 0)
    )
    isempty(descriptors) && return runtime
    execution = runtime.engine_workspace
    if execution isa SequentialTransactionWorkspace
        candidate = execution.descriptor_state
        copyto_auxiliary_state!(candidate, runtime.descriptor_state)
        for descriptor in descriptors
            _apply_history_effect!(candidate, descriptor.effect, 0)
        end
        return update_program_inputs!(runtime; descriptor_state = candidate)
    end
    execution isa _CheckerboardExecutionWorkspace || throw(
        ArgumentError(
            "history initialization requires a prepared program execution workspace"
        )
    )
    workspace = execution.core
    position = workspace.execution
    position.submitted_mcs == position.drained_mcs == position.committed_mcs == 0 ||
        throw(ArgumentError("history initialization cannot cross queued or committed MCS work"))
    _, candidate, _ = _checkerboard_transaction_banks(workspace, 0)
    entries = Tuple(
        entry for entry in (execution.stage_boundaries.before..., execution.stage_boundaries.after...)
            if entry.effect isa ShiftAppendEffect &&
            _completed_mcs_due(entry.effect.cadence, entry.effect.cadence_value, 0)
    )
    runtime.settled = false
    _clear_checkerboard_bulk!(execution, candidate; completed_mcs = 0)
    _execute_compiled_stage_boundary!(execution, entries, candidate; completed_mcs = 0)
    receipt = settle_program!(execution, ProgramSettlementRequest(InitializationSettlement; full_snapshot = true))
    runtime.failure_status = receipt.status
    runtime.settled = true
    receipt.failure === nothing || throw(receipt.failure)
    return update_program_inputs!(runtime; descriptor_state = receipt.snapshot.descriptor_state)
end

function _checkerboard_settlement_events(
        execution::_CheckerboardExecutionWorkspace
    )
    identity = execution.identity
    identity.scientific_abi ===
        :corepotts_checkerboard_transaction_v1 || throw(ArgumentError(
        "checkerboard settlement received an unknown scientific ABI"
    ))
    identity.queue_policy.completion ===
        :grouped_cumulative_receipts || throw(ArgumentError(
        "checkerboard settlement received an unsupported completion policy"
    ))
    identity.queue_policy.receipt_cumulative === true &&
        identity.queue_policy.receipt_selective === false ||
        throw(ArgumentError(
            "checkerboard settlement requires cumulative provider-tail receipts"
        ))
    lifecycle = execution.receipts.lifecycle
    banks = (execution.receipts.mechanics, values(lifecycle)...)
    return Tuple(receipt for family in banks for bank in family for receipt in bank)
end

function _clear_checkerboard_settlement_events!(execution)
    lifecycle = execution.receipts.lifecycle
    banks = (execution.receipts.mechanics, values(lifecycle)...)
    for family in banks, bank in family
        empty!(bank)
    end
    return nothing
end

function _wait_checkerboard_execution!(
        execution::_CheckerboardExecutionWorkspace,
        backend,
    )
    submitted = _checkerboard_settlement_events(execution)
    did_synchronize = execution.core.execution.submitted_mcs !=
        execution.core.execution.drained_mcs ||
        any(LocalMath.ispending, submitted)
    isempty(submitted) || LocalMath.waitall(submitted)
    KernelAbstractions.synchronize(backend)
    _clear_checkerboard_settlement_events!(execution)
    return did_synchronize
end

function _synchronize_checkerboard_execution!(
        execution::_CheckerboardExecutionWorkspace,
        backend,
    )
    submitted = _checkerboard_settlement_events(execution)
    isempty(submitted) || LocalMath.waitall(submitted)
    KernelAbstractions.synchronize(backend)
    _clear_checkerboard_settlement_events!(execution)
    return nothing
end

function settle_program!(
        execution_graph::_CheckerboardExecutionWorkspace,
        request::ProgramSettlementRequest,
    )
    workspace = execution_graph.core
    capability = execution_graph.capability_report
    _require_program_execution_capability(
        capability;
        operation = :backend_settle_program,
    )
    execution = workspace.execution
    submitted = execution.submitted_mcs
    previous_drained = execution.drained_mcs
    backend = KernelAbstractions.get_backend(workspace.state.ownership)
    did_synchronize = try
        _wait_checkerboard_execution!(execution_graph, backend)
    catch error
        throw(LifecycleBackendFailure(
            error, previous_drained + 1, submitted
        ))
    end
    return _settle_program_after_wait!(
        workspace, request, did_synchronize
    )
end

@inline _is_receipt_owner_failure(error) =
    error isa LocalMath.LocalMathValidationError &&
    error.contract === :receipt_owner

function _recover_checkerboard_program_step!(runtime; prefix_submitted = nothing)
    graph = runtime.engine_workspace
    workspace = graph.core
    backend = KernelAbstractions.get_backend(workspace.state.ownership)
    try
        _synchronize_checkerboard_execution!(graph, backend)
    catch error
        # The public diagnostic distinguishes ownership rejection from a
        # settled numerical failure. Neither a foreign task nor a pending
        # receipt establishes permission to discard the journal or roll back.
        error isa LocalMath.LocalMathValidationError || rethrow()
        _is_receipt_owner_failure(error) && rethrow()
        any(LocalMath.ispending, _checkerboard_settlement_events(graph)) && rethrow()
        KernelAbstractions.synchronize(backend)
        _clear_checkerboard_settlement_events!(graph)
    end
    status = only(Adapt.adapt(Array, workspace.state.program_status))
    control = Adapt.adapt(Array, workspace.state.lifecycle_control.counters)
    statistics = Adapt.adapt(Array, workspace.state.lifecycle_control.statistics)
    workspace.execution.control_transfer_count += 1
    committed = Int(control[_LIFECYCLE_CONTROL_COMMITTED_MCS])
    if program_status_is_expected(status)
        # An earlier ordered scientific rejection outranks an incidental later
        # launch error. Preserve it for the ordinary settlement/publication path.
        workspace.execution.submitted_mcs = max(workspace.execution.submitted_mcs, Int(status.mcs))
        runtime.failure_status = status
        runtime.settled = false
        return _translate_program_status(status)
    end
    prefix_submitted === nothing || committed == prefix_submitted || throw(
        LifecycleInvariantFailure(Int32(0), Int32(committed), :committed_submission_mismatch)
    )
    _rollback_checkerboard_program_step!(runtime, Tuple(statistics); committed_mcs = committed)
    _, destination, _ = _checkerboard_transaction_banks(workspace, committed)
    wait(_clear_checkerboard_bulk!(graph, destination; completed_mcs = committed + 1))
    _clear_checkerboard_settlement_events!(graph)
    runtime.failure_status = ProgramStatus()
    # A completed queued prefix is still unpublished to the host. Its caller
    # must explicitly settle it; recovery discards only the incomplete MCS.
    runtime.settled = committed == runtime.mcs
    return nothing
end
