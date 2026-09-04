# Checkerboard state-bank construction, adaptation, and execution workspace.

function _checkerboard_state_banks(state::CheckerboardExecutionState)
    workspace = state.lifecycle_workspace
    if workspace isa NoLifecycleWorkspace
        alternate = _checkerboard_state_with_science(
            state,
            copy(state.ownership),
            copy(state.cell_kinds),
            copy(state.cell_generations),
            copy_tracker_state(state.trackers),
            copy(state.relationships),
            copy_auxiliary_state(state.descriptor_state),
            NoLifecycleWorkspace(),
        )
        return state, alternate
    end
    primary_workspace = _lifecycle_workspace_with_staged_state(
        workspace, state
    )
    primary = _checkerboard_state_with_science(
        state,
        state.ownership,
        state.cell_kinds,
        state.cell_generations,
        state.trackers,
        state.relationships,
        state.descriptor_state,
        primary_workspace,
    )
    secondary_science = (
        ownership = workspace.staged_ownership,
        cell_kinds = workspace.staged_cell_kinds,
        cell_generations = workspace.staged_cell_generations,
        trackers = workspace.staged_trackers,
        relationships = workspace.staged_relationships,
        descriptor_state = workspace.staged_descriptor_state,
    )
    secondary_workspace = _lifecycle_workspace_with_staged_state(
        workspace, secondary_science
    )
    secondary = _checkerboard_state_with_science(
        state,
        secondary_science.ownership,
        secondary_science.cell_kinds,
        secondary_science.cell_generations,
        secondary_science.trackers,
        secondary_science.relationships,
        secondary_science.descriptor_state,
        secondary_workspace,
    )
    return primary, secondary
end

function _require_checkerboard_lifecycle_staging_aliases(state)
    workspace = state.lifecycle_workspace
    workspace isa NoLifecycleWorkspace && return state
    pairs = (
        (:ownership, workspace.staged_ownership, state.ownership),
        (:cell_kinds, workspace.staged_cell_kinds, state.cell_kinds),
        (
            :cell_generations,
            workspace.staged_cell_generations,
            state.cell_generations,
        ),
        (:trackers, workspace.staged_trackers, state.trackers),
        (
            :relationships,
            workspace.staged_relationships,
            state.relationships,
        ),
        (
            :descriptor_state,
            workspace.staged_descriptor_state,
            state.descriptor_state,
        ),
    )
    for (name, staged, science) in pairs
        staged === science || throw(ArgumentError(
            "checkerboard lifecycle staged $(name) must alias its bank science"
        ))
    end
    return state
end

function _require_checkerboard_distinct_state_banks(primary, alternate)
    return _require_distinct_program_state_copy_leaves(primary, alternate)
end

_checkerboard_compiled_extinction_policies(
    program::CheckerboardKernelProgram) =
    program.extinction_policies

_checkerboard_compiled_extinction_policies(program) =
    _checkerboard_extinction_policies(
        program.lifecycle_plan, Int(program.kind_count))

_checkerboard_compiled_relationship_layout(
    program::CheckerboardKernelProgram) = program.relationship_layout

_checkerboard_relationship_endpoint_count(
    plan::LifecycleExecutionPlan) = plan.cell_capacity
_checkerboard_relationship_endpoint_count(
    ::NoLifecycleExecutionPlan) = Int32(0)

function _checkerboard_compiled_relationship_layout(program)
    storage = program.relationships
    endpoint_count = Int32(
        _checkerboard_relationship_endpoint_count(program.lifecycle_plan)
    )
    banks = map(storage.banks) do schemas
        counts = Tuple(Int32(schema.capacity) for schema in schemas)
        offsets = Vector{Int32}(undef, length(counts))
        endpoint_offsets = Vector{Int32}(undef, length(counts))
        incident_offsets = Vector{Int32}(undef, length(counts))
        maximum_degrees = Tuple(
            Int32(schema.maximum_degree) for schema in schemas
        )
        next_offset = Int32(1)
        next_endpoint = Int32(1)
        next_incident = Int32(1)
        for index in eachindex(counts)
            offsets[index] = next_offset
            endpoint_offsets[index] = next_endpoint
            incident_offsets[index] = next_incident
            next_offset += counts[index]
            next_endpoint += endpoint_count
            next_incident += endpoint_count * maximum_degrees[index]
        end
        payload_count = isempty(schemas) ? Int32(0) :
            Int32(length(first(schemas).payload_defaults))
        all(schema -> length(schema.payload_defaults) == payload_count,
            schemas) || throw(ArgumentError(
            "packed relationship bank payload schemas disagree"))
        _CheckerboardRelationshipBankLayout(
            Tuple(offsets),
            counts,
            Tuple(endpoint_offsets),
            Tuple(incident_offsets),
            maximum_degrees,
            endpoint_count,
            payload_count,
        )
    end
    return _CheckerboardRelationshipLayout(Tuple(storage.slots), banks)
end

function _checkerboard_kernel_program(program, to)
    ownership_change_handles = program.ownership_change_handles
    tracker_kernel = to === nothing ?
                     tracker_kernel_plan(program.tracker_plan) :
                     adapt_tracker_kernel_plan(to, program.tracker_plan)
    topology_epoch = _checkerboard_logical_topology_epoch(
        program.checkerboard_plan, program.proposal_offsets
    )
    extinction_policies = _checkerboard_compiled_extinction_policies(program)
    relationship_layout = _checkerboard_compiled_relationship_layout(program)
    return CheckerboardKernelProgram(
        program.shape,
        program.periodic,
        to === nothing ? program.proposal_offsets :
        Adapt.adapt(to, program.proposal_offsets),
        program.medium_kind,
        program.temperature,
        program.attempts_per_site,
        to === nothing ? program.relationships :
        Adapt.adapt(to, program.relationships),
        tracker_kernel,
        _checkerboard_adapt(to, _checkerboard_domain_resources(program)),
        to === nothing ? program.lifecycle_plan :
        Adapt.adapt(to, program.lifecycle_plan),
        to === nothing ? ownership_change_handles :
        Adapt.adapt(to, ownership_change_handles),
        to === nothing ? program.checkerboard_plan :
        Adapt.adapt(to, program.checkerboard_plan),
        extinction_policies,
        relationship_layout,
        topology_epoch,
    )
end

_checkerboard_domain_resources(program::CheckerboardKernelProgram) =
    program.domain_resources
_checkerboard_domain_resources(program) =
    program.descriptor_plan.domain_resources

tracker_source_view(program::CheckerboardKernelProgram, ownership) =
    TrackerSourceView(
        ownership,
        program.shape,
        program.periodic,
        program.domain_resources,
    )

_checkerboard_adapt(to, value) =
    to === nothing ? value : Adapt.adapt(to, value)

function _checkerboard_execution_state(
        program,
        ownership,
        cell_kinds,
        cell_generations,
        trackers,
        relationships,
        descriptor_state,
        parameters,
        seed,
        replica,
        repeat,
        initial_mcs = 0,
        to = nothing,
    )
    kernel_program = _checkerboard_kernel_program(program, to)
    lifecycle_workspace = allocate_lifecycle_workspace(
        program.lifecycle_plan,
        program,
        ownership,
        cell_kinds,
        cell_generations,
        trackers,
        relationships,
        descriptor_state,
    )
    lifecycle_control = allocate_lifecycle_backend_control(
        program.lifecycle_plan, parameters, length(ownership)
    )
    @inbounds begin
        lifecycle_control.counters[_LIFECYCLE_CONTROL_ACTIVE_BANK] =
            iseven(initial_mcs) ? Int32(1) : Int32(2)
        lifecycle_control.counters[_LIFECYCLE_CONTROL_COMMITTED_MCS] =
            Int32(initial_mcs)
    end
    program_status = if lifecycle_workspace isa LifecycleWorkspace
        lifecycle_workspace.status
    else
        StructArrays.StructArray(ProgramStatus[ProgramStatus()])
    end
    return CheckerboardExecutionState(
        kernel_program,
        _checkerboard_adapt(to, ownership),
        _checkerboard_adapt(to, cell_kinds),
        _checkerboard_adapt(to, cell_generations),
        _checkerboard_adapt(to, trackers),
        _checkerboard_adapt(to, relationships),
        _checkerboard_adapt(to, descriptor_state),
        _checkerboard_adapt(to, lifecycle_workspace),
        _checkerboard_adapt(to, lifecycle_control),
        _checkerboard_adapt(to, program_status),
        _checkerboard_adapt(to, parameters),
        UInt64(seed),
        UInt32(replica),
        UInt32(repeat),
        Int(initial_mcs),
    )
end

function _checkerboard_state_at_mcs(state::CheckerboardExecutionState, mcs)
    return CheckerboardExecutionState(
        state.program,
        state.ownership,
        state.cell_kinds,
        state.cell_generations,
        state.trackers,
        state.relationships,
        state.descriptor_state,
        state.lifecycle_workspace,
        state.lifecycle_control,
        state.program_status,
        state.parameters,
        state.seed,
        state.replica,
        state.repeat,
        Int(mcs),
    )
end

function _checkerboard_similar(prototype, ::Type{T}, dimensions...) where {T}
    values = similar(prototype, T, dimensions...)
    return values
end

function _checkerboard_color_sizes(plan::CheckerboardPlan)
    return Int32[
        plan.color_offsets[color + 1] - plan.color_offsets[color]
        for color in 1:Int(plan.color_count)
    ]
end

const _CHECKERBOARD_COLOR_ORDER_OPERATION = UInt16(5)

"""Fill one preallocated unbiased semantic-RNG permutation of realized colors."""
function _checkerboard_color_order!(
        order::Vector{Int32}, state, attempt_round::Integer
    )
    color_count = Int(state.program.checkerboard_plan.color_count)
    length(order) == color_count || throw(ArgumentError(
        "checkerboard color-order workspace has the wrong size"
    ))
    0 <= state.mcs < typemax(Int) || throw(ArgumentError(
        "checkerboard MCS is outside the semantic RNG domain"
    ))
    1 <= attempt_round <= typemax(UInt8) || throw(ArgumentError(
        "checkerboard attempt round is outside the semantic RNG domain"
    ))
    for color in 1:color_count
        @inbounds order[color] = Int32(color)
    end
    seed = _trajectory_seed(state.seed, state.replica, state.repeat)
    for position in color_count:-1:2
        address = RNGAddress(
            stream = CheckerboardColorOrderStream,
            mcs = state.mcs + 1,
            subround = attempt_round,
            operation = _CHECKERBOARD_COLOR_ORDER_OPERATION,
            entity_kind = GlobalEntity,
            entity = position,
        )
        selected = Int(bounded_uint(
            Philox4x32x10V2(), seed, address, UInt32(position)
        )) + 1
        @inbounds order[position], order[selected] =
            order[selected], order[position]
    end
    return order
end

function _allocate_checkerboard_workspace(
        state::CheckerboardExecutionState;
        capability_report,
        color_sizes = _checkerboard_color_sizes(
            state.program.checkerboard_plan
        ),
        color_order = collect(
            Int32, 1:Int(state.program.checkerboard_plan.color_count)
        ),
        source_table = (),
        alternate_state = nothing,
        execution = ProgramExecutionPosition(state.mcs),
    )
    if alternate_state === nothing
        state, alternate_state = _checkerboard_state_banks(state)
    end
    _require_checkerboard_lifecycle_staging_aliases(state)
    _require_checkerboard_lifecycle_staging_aliases(alternate_state)
    _require_checkerboard_distinct_state_banks(state, alternate_state)
    plan = state.program.checkerboard_plan
    plan isa CheckerboardPlan || error(
        "checkerboard workspace requires a realized-domain plan"
    )
    maximum_batch = Int(plan.maximum_color_size)
    maximum_batch > 0 || error("checkerboard schedule has no candidates")
    target_sites = _checkerboard_similar(
        state.parameters, Int32, maximum_batch
    )
    source_sites = similar(target_sites)
    old_owners = similar(target_sites)
    new_owners = similar(target_sites)
    priorities = _checkerboard_similar(
        state.parameters, UInt32, maximum_batch
    )
    semantic_ids = _checkerboard_similar(
        state.parameters, Int32, maximum_batch
    )
    dispositions = _checkerboard_similar(
        state.parameters, UInt8, maximum_batch
    )
    report = _checkerboard_similar(state.parameters, UInt64, 5)
    return CheckerboardWorkspace(
        state,
        alternate_state,
        target_sites,
        source_sites,
        old_owners,
        new_owners,
        priorities,
        semantic_ids,
        dispositions,
        report,
        capability_report,
        color_sizes,
        color_order,
        source_table,
        execution,
    )
end

function allocate_program_engine_workspace(
        program,
        ownership,
        cell_kinds,
        cell_generations,
        trackers,
        relationships,
        descriptor_state,
        stage_buffers,
        parameters,
        seed,
        replica,
        repeat,
        initial_mcs = 0,
    )
    program.engine isa SequentialProgramEngine && return (
        allocate_sequential_transaction_workspace(
            program,
            ownership,
            cell_kinds,
            cell_generations,
            trackers,
            relationships,
            descriptor_state,
        )
    )
    program.engine isa CheckerboardProgramEngine || error(
        "unreachable program engine"
    )
    state = _checkerboard_execution_state(
        program,
        ownership,
        cell_kinds,
        cell_generations,
        trackers,
        relationships,
        descriptor_state,
        parameters,
        seed,
        replica,
        repeat,
        initial_mcs,
    )
    return _allocate_checkerboard_workspace(
        state;
        capability_report = program_capability_report(program),
        source_table = program.descriptor_plan.source_table,
    )
end

function initialize_program_execution_statistics!(
        workspace::CheckerboardWorkspace,
        accepted,
        rejected,
        null_attempts,
        constraint_rejections,
        energy_rejections,
        retired_cells,
    )
    control = workspace.state.lifecycle_control
    values = (
        accepted,
        rejected,
        null_attempts,
        constraint_rejections,
        energy_rejections,
        retired_cells,
    )
    for (index, value) in enumerate(values)
        value >= 0 || throw(ArgumentError(
            "program execution statistics must be nonnegative"
        ))
        @inbounds control.statistics[index] = UInt64(value)
    end
    return workspace
end

function _validate_gpu_descriptor_plan(
        plan::DescriptorExecutionPlan, source_table
    )
    for group in plan.groups
        for descriptor in group.instances
            support = descriptor_support(descriptor)
            support isa DescriptorSupport || throw(ArgumentError(
                "descriptor support must be a DescriptorSupport value"
            ))
            source_handle = Int(descriptor_source_handle(descriptor))
            qualified_source = 1 <= source_handle <= length(source_table) ?
                repr(source_table[source_handle]) :
                "<missing qualified source for handle $source_handle>"
            support.gpu || throw(ArgumentError(
                "descriptor source $qualified_source " *
                "does not declare GPU support (reason code " *
                "$(support.reason_code))"
            ))
        end
    end
    return nothing
end


"""Adapt every checkerboard runtime bank after whole-program admission."""
function _adapt_checkerboard_workspace(
        to, workspace::CheckerboardWorkspace;
        capability_report,
    )
    state = workspace.state
    primary_science = (
        ownership = Adapt.adapt(to, state.ownership),
        cell_kinds = Adapt.adapt(to, state.cell_kinds),
        cell_generations = Adapt.adapt(to, state.cell_generations),
        trackers = Adapt.adapt(to, state.trackers),
        relationships = Adapt.adapt(to, state.relationships),
        descriptor_state = Adapt.adapt(to, state.descriptor_state),
    )
    execution = ProgramExecutionPosition(
        workspace.execution.submitted_mcs,
        workspace.execution.drained_mcs,
        workspace.execution.committed_mcs,
        workspace.execution.materialized_mcs,
        workspace.execution.settlement_count,
        workspace.execution.synchronization_count,
        workspace.execution.control_transfer_count,
        workspace.execution.snapshot_transfer_count,
        workspace.execution.lifecycle_transfer_count,
    )
    if state.lifecycle_workspace isa NoLifecycleWorkspace
        alternate_source = workspace.alternate_state
        program_status = Adapt.adapt(to, state.program_status)
        adapted = CheckerboardExecutionState(
            _checkerboard_kernel_program(state.program, to),
            primary_science.ownership,
            primary_science.cell_kinds,
            primary_science.cell_generations,
            primary_science.trackers,
            primary_science.relationships,
            primary_science.descriptor_state,
            NoLifecycleWorkspace(),
            Adapt.adapt(to, state.lifecycle_control),
            program_status,
            Adapt.adapt(to, state.parameters),
            state.seed,
            state.replica,
            state.repeat,
            state.mcs,
        )
        alternate = _checkerboard_state_with_science(
            adapted,
            Adapt.adapt(to, alternate_source.ownership),
            Adapt.adapt(to, alternate_source.cell_kinds),
            Adapt.adapt(to, alternate_source.cell_generations),
            Adapt.adapt(to, alternate_source.trackers),
            Adapt.adapt(to, alternate_source.relationships),
            Adapt.adapt(to, alternate_source.descriptor_state),
            NoLifecycleWorkspace(),
        )
        return _allocate_checkerboard_workspace(
            adapted;
            capability_report,
            color_sizes = workspace.color_sizes,
            color_order = copy(workspace.color_order),
            source_table = workspace.source_table,
            alternate_state = alternate,
            execution,
        )
    end
    shared_workspace = Adapt.adapt(
        to,
        _lifecycle_workspace_with_staged_state(
            state.lifecycle_workspace, workspace.alternate_state
        ),
    )
    secondary_science = (
        ownership = shared_workspace.staged_ownership,
        cell_kinds = shared_workspace.staged_cell_kinds,
        cell_generations = shared_workspace.staged_cell_generations,
        trackers = shared_workspace.staged_trackers,
        relationships = shared_workspace.staged_relationships,
        descriptor_state = shared_workspace.staged_descriptor_state,
    )
    primary_workspace = _lifecycle_workspace_with_staged_state(
        shared_workspace, primary_science
    )
    secondary_workspace = _lifecycle_workspace_with_staged_state(
        shared_workspace, secondary_science
    )
    adapted = CheckerboardExecutionState(
        _checkerboard_kernel_program(state.program, to),
        primary_science.ownership,
        primary_science.cell_kinds,
        primary_science.cell_generations,
        primary_science.trackers,
        primary_science.relationships,
        primary_science.descriptor_state,
        primary_workspace,
        Adapt.adapt(to, state.lifecycle_control),
        primary_workspace.status,
        Adapt.adapt(to, state.parameters),
        state.seed,
        state.replica,
        state.repeat,
        state.mcs,
    )
    alternate = _checkerboard_state_with_science(
        adapted,
        secondary_science.ownership,
        secondary_science.cell_kinds,
        secondary_science.cell_generations,
        secondary_science.trackers,
        secondary_science.relationships,
        secondary_science.descriptor_state,
        secondary_workspace,
    )
    return _allocate_checkerboard_workspace(
        adapted;
        capability_report,
        color_sizes = workspace.color_sizes,
        color_order = copy(workspace.color_order),
        source_table = workspace.source_table,
        alternate_state = alternate,
        execution,
    )
end
