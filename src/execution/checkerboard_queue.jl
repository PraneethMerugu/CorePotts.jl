# Checkerboard queue admission, submission, settlement, and inspection.

@inline function _program_backend_open(state)
    return (@inbounds state.program_status[1]).code === ProgramStatusSuccess &&
           _lifecycle_backend_open(state.lifecycle_workspace)
end

function _clear_checkerboard_bulk!(
        execution::_CheckerboardExecutionWorkspace, state
    )
    bank = _checkerboard_authorized_bank(execution, state)
    receipt = LocalMath.execute!(execution.clear_report[bank])
    # LocalMath owns receipt failure; this bridge translates it into Core's
    # durable domain status without a host settlement boundary.
    _enqueue_localmath_failure_bridge!(
        receipt, execution.gates[bank], state.program_status,
        state.mcs + 1, ProgramStagePublication)
    _record_checkerboard_receipt!(execution.receipts.mechanics, bank, receipt)
    return receipt
end

_checkerboard_lifecycle_status_identity(::NoLifecycleWorkspace) = nothing
_checkerboard_lifecycle_status_identity(workspace::LifecycleWorkspace) =
    workspace.status

function _checkerboard_authorized_bank(execution, state)
    workspace = execution.core
    for (index, bank) in pairs((workspace.state, workspace.alternate_state))
        state.ownership === bank.ownership &&
            state.parameters === bank.parameters &&
            state.program === bank.program &&
            state.program_status === bank.program_status &&
            _checkerboard_lifecycle_status_identity(state.lifecycle_workspace) ===
                _checkerboard_lifecycle_status_identity(bank.lifecycle_workspace) &&
            return index
    end
    throw(ArgumentError(
        "checkerboard state does not belong to an authorized execution bank"
    ))
end

function _execute_compiled_checkerboard_color!(
        execution::_CheckerboardExecutionWorkspace,
        state,
        color,
        attempt_round,
        batch_size,
    )
    bank = _checkerboard_authorized_bank(execution, state)
    preparation = execution.color_laws.prepared[bank]
    mechanics = execution.receipts.mechanics[bank]
    tail = isempty(mechanics) ? nothing : last(mechanics)
    tail === nothing && throw(ArgumentError(
        "checkerboard color execution requires the initialized mechanics tail"
    ))
    dependencies = (tail,)
    try
        receipt = LocalMath.execute!(preparation;
            parameters = (
                mcs = Int64(state.mcs + 1),
                color = Int32(color),
                attempt_round = Int32(attempt_round),
                batch_size = Int32(batch_size),
            ),
            dependencies,
        )
        _enqueue_localmath_failure_bridge!(
            receipt, execution.gates[bank], state.program_status,
            state.mcs + 1, ProgramStageSelection)
        _record_checkerboard_receipt!(
            execution.receipts.mechanics, bank, receipt)
        return receipt
    catch error
        error isa LifecycleBackendFailure && rethrow()
        throw(LifecycleBackendFailure(error, state.mcs + 1, state.mcs + 1))
    end
end

function _execute_compiled_stage_boundary!(
        execution::_CheckerboardExecutionWorkspace,
        entries::Tuple,
        state,
    )
    isempty(entries) && return nothing
    bank = _checkerboard_authorized_bank(execution, state)
    receipts = execution.receipts.mechanics[bank]
    tail = isempty(receipts) ? nothing : last(receipts)
    tail === nothing && throw(ArgumentError(
        "checkerboard stage boundary requires an initialized mechanics tail"))
    for entry in entries
        preparation = entry.prepared[bank]
        for _ in 1:entry.repetitions
            try
                receipt = LocalMath.execute!(preparation;
                    parameters = (mcs = Int64(state.mcs + 1),),
                    dependencies = (tail,),
                )
                _enqueue_localmath_failure_bridge!(
                    receipt, execution.gates[bank], state.program_status,
                    state.mcs + 1, ProgramStageState)
                _record_checkerboard_receipt!(
                    execution.receipts.mechanics, bank, receipt)
                tail = receipt
            catch error
                error isa LifecycleBackendFailure && rethrow()
                throw(LifecycleBackendFailure(
                    error, state.mcs + 1, state.mcs + 1))
            end
        end
    end
    return tail
end

function _preflight_checkerboard_execution_configuration(
        workspace::CheckerboardWorkspace,
        mcs::Integer,
        state_bank::CheckerboardExecutionState,
        ;
        workgroup_size::Union{Nothing, Integer} = nothing,
    )
    authorized_bank = any((workspace.state, workspace.alternate_state)) do bank
        state_bank.ownership === bank.ownership &&
            state_bank.parameters === bank.parameters &&
            state_bank.program === bank.program
    end
    authorized_bank || throw(ArgumentError(
        "checkerboard execution state is not owned by the authorized workspace"
    ))
    state = _checkerboard_state_at_mcs(state_bank, mcs)
    plan = state.program.checkerboard_plan
    backend = KernelAbstractions.get_backend(workspace.dispositions)
    workgroup_size === nothing || workgroup_size > 0 || throw(ArgumentError(
        "checkerboard workgroup size must be positive"
    ))
    return (; state, plan, backend)
end

function _execute_checkerboard_mcs!(
        execution::_CheckerboardExecutionWorkspace,
        mcs::Integer,
        state_bank::CheckerboardExecutionState,
        ;
        workgroup_size::Union{Nothing, Integer} = nothing,
    )
    workspace = execution.core
    configuration = _preflight_checkerboard_execution_configuration(
        workspace, mcs, state_bank; workgroup_size
    )
    state = configuration.state
    plan = configuration.plan
    backend = configuration.backend
    _clear_checkerboard_bulk!(execution, state)
    # The accepted CheckerboardSweep process uses one normalized sweep. Its
    # realized colors execute in an unbiased semantic-RNG permutation. The
    # preallocated host order is safe for queued CPU/GPU launches because
    # each kernel receives its color as a copied scalar argument.
    for attempt_round in 1:Int(state.program.attempts_per_site)
        color_order = _checkerboard_color_order!(
            workspace.color_order, state, attempt_round
        )
        for color_position in 1:Int(plan.color_count)
            color = Int(@inbounds color_order[color_position])
            color_size = Int(@inbounds workspace.color_sizes[color])
            batch_size = color_size
            bank = _checkerboard_authorized_bank(execution, state)
            # Geometry, bounded scientific evaluation, acceptance, owner
            # resolution, mutual-maxima conjunction, tracker/ownership
            # publication, relationships, and reporting are one ordered
            # LocalMath law and one logical receipt.
            _execute_compiled_checkerboard_color!(
                execution, state, color, attempt_round, batch_size)
        end
    end
    return workspace
end

"""Execute and settle one complete checkerboard MCS."""
function execute_checkerboard_mcs!(
        execution::_CheckerboardExecutionWorkspace,
        mcs::Integer = execution.core.state.mcs,
        state_bank::CheckerboardExecutionState = execution.core.state;
        workgroup_size::Union{Nothing, Integer} = nothing,
    )
    _require_program_execution_capability(
        execution.capability_report;
        operation = :backend_execute_checkerboard_mcs,
    )
    _execute_checkerboard_mcs!(
        execution,
        mcs,
        state_bank;
        workgroup_size,
    )
    return execution
end


@inline function _checkerboard_transaction_banks(
        workspace::CheckerboardWorkspace, current_mcs::Integer
    )
    if iseven(current_mcs)
        return workspace.state, workspace.alternate_state, Int32(2)
    end
    return workspace.alternate_state, workspace.state, Int32(1)
end

"""
Validate one complete checkerboard submission without appending backend work.

ProgramRuntime uses this boundary before marking itself unsettled. Once that
mark is visible, any later rejection may have an ordered CorePotts prefix to
drain and must not make checkpointing or adaptation appear safe.
"""
function _preflight_checkerboard_mcs!(
        execution,
        current_mcs::Integer,
        ;
        workgroup_size::Union{Nothing, Integer} = nothing,
    )
    workspace = _checkerboard_core(execution)
    capability = _checkerboard_runtime_capability(execution)
    _require_program_execution_capability(
        capability;
        operation = :backend_enqueue_checkerboard_mcs,
    )
    current_mcs >= 0 || throw(ArgumentError(
        "current MCS must be nonnegative"
    ))
    current_mcs == workspace.execution.submitted_mcs || throw(ArgumentError(
        "checkerboard submission must be contiguous: expected current MCS " *
        "$(workspace.execution.submitted_mcs), received $current_mcs"
    ))
    policy = execution.identity.queue_policy
    outstanding_mcs = _checked_checkerboard_capacity_sub(
        Int(current_mcs),
        workspace.execution.drained_mcs,
        :outstanding_checkerboard_mcs,
    )
    outstanding_mcs < policy.mcs_capacity || throw(ArgumentError(
        "checkerboard queue capacity cannot encode one complete MCS"
    ))
    _, destination, _ = _checkerboard_transaction_banks(
        workspace, current_mcs
    )
    destination = _checkerboard_state_at_mcs(destination, current_mcs)
    _preflight_checkerboard_execution_configuration(
        workspace, current_mcs, destination; workgroup_size
    )
    destination_bank_index = _checkerboard_authorized_bank(
        execution, destination
    )
    preparations = ((
        :clear_report,
        execution.clear_report[destination_bank_index],
        policy.clear_report_submissions_per_mcs,
    ), (
        :color_mechanics,
        execution.color_laws.prepared[destination_bank_index],
        policy.color_submissions_per_mcs,
    ))
    for (boundary, entries, required) in (
            (:before_lifecycle, execution.stage_boundaries.before,
                policy.before_lifecycle_submissions_per_mcs),
            (:after_lifecycle, execution.stage_boundaries.after,
                policy.after_lifecycle_submissions_per_mcs),
        )
        sum(entry.repetitions for entry in entries; init = 0) == required ||
            throw(ArgumentError(
                "checkerboard $boundary submission policy is inconsistent"))
        for entry in entries
            preparations = (preparations..., (
                boundary, entry.prepared[destination_bank_index],
                entry.repetitions))
        end
    end
    if execution.lifecycle_reductions !== nothing
        reductions = execution.lifecycle_reductions[destination_bank_index]
        preparations = (
            preparations...,
            (
                :lifecycle_status,
                reductions.direct,
                policy.lifecycle_status_submissions_per_mcs,
            ),
            (
                :lifecycle_planning_status,
                reductions.planning,
                policy.lifecycle_planning_status_submissions_per_mcs,
            ),
            (
                :lifecycle_site_index,
                reductions.site_index,
                policy.lifecycle_site_index_submissions_per_mcs,
            ),
            (
                :lifecycle_request_index,
                reductions.request_index,
                policy.lifecycle_request_index_submissions_per_mcs,
            ),
            (
                :lifecycle_emission,
                reductions.emission,
                policy.lifecycle_emission_submissions_per_mcs,
            ),
            (
                :lifecycle_selection,
                reductions.selection.publication,
                policy.lifecycle_selection_submissions_per_mcs,
            ),
        )
    end
    for (name, prepared, required) in preparations
        capacity = LocalMath.submission_capacity(prepared)
        capacity.available >= required || throw(ArgumentError(
            "LocalMath $name preparation cannot encode one complete MCS"
        ))
    end
    return nothing
end

function _enqueue_checkerboard_mcs_after_preflight!(
        execution,
        current_mcs::Integer;
        workgroup_size::Union{Nothing, Integer} = nothing,
    )
    workspace = _checkerboard_core(execution)
    source, destination, destination_bank = _checkerboard_transaction_banks(
        workspace, current_mcs
    )
    destination = _checkerboard_state_at_mcs(destination, current_mcs)
    execute_checkerboard_mcs!(execution, current_mcs, destination; workgroup_size)
    bank = _checkerboard_authorized_bank(execution, destination)
    _execute_compiled_stage_boundary!(
        execution, execution.stage_boundaries.before, destination)
    lifecycle_receipts = enqueue_lifecycle_backend_index!(
        destination,
        execution.lifecycle_reductions === nothing ? nothing :
            execution.lifecycle_reductions[bank];
        workgroup_size,
    )
    lifecycle_receipts === nothing || begin
        current = execution.receipts.lifecycle
        _record_checkerboard_receipt!(
            current.direct, bank, lifecycle_receipts.direct)
        _record_checkerboard_receipt!(
            current.planning, bank, lifecycle_receipts.planning)
        _record_checkerboard_receipt!(
            current.site_index, bank, lifecycle_receipts.site_index)
        _record_checkerboard_receipt!(
            current.request_index, bank, lifecycle_receipts.request_index)
        _record_checkerboard_receipt!(
            current.emission, bank, lifecycle_receipts.emission)
        _record_checkerboard_receipt!(
            current.selection, bank, lifecycle_receipts.selection)
    end
    _execute_compiled_stage_boundary!(
        execution, execution.stage_boundaries.after, destination)
    _enqueue_program_bank_publication!(
        destination, workspace.report, destination_bank, current_mcs + 1
    )
    workspace.execution.submitted_mcs = Int(current_mcs) + 1
    return destination
end

function _enqueue_checkerboard_mcs!(
        execution,
        current_mcs::Integer;
        workgroup_size::Union{Nothing, Integer} = nothing,
    )
    _preflight_checkerboard_mcs!(execution, current_mcs; workgroup_size)
    return _enqueue_checkerboard_mcs_after_preflight!(
        execution, current_mcs; workgroup_size
    )
end

"""Enqueue one checkerboard MCS while leaving host mirrors unpublished."""
function enqueue_checkerboard_mcs!(
        execution::_CheckerboardExecutionWorkspace,
        current_mcs::Integer;
        workgroup_size::Union{Nothing, Integer} = nothing,
    )
    return _enqueue_checkerboard_mcs!(
        execution, current_mcs; workgroup_size
    )
end
