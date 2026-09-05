# Complete color-law composition, storage binding, and preparation.

function _checkerboard_color_declaration(
        accepted,
        owner_capacity::Integer,
        relationships,
        tracker_plan,
        tracker_state,
    )
    owner_capacity >= 0 || throw(ArgumentError(
        "checkerboard owner capacity cannot be negative"))
    owners_space = LocalMath.Space(
        _CheckerboardClaimOwner, Int(owner_capacity))
    status_space = LocalMath.Space(_CheckerboardAcceptanceStatus, 1)
    report_space = LocalMath.Space(_CheckerboardReportBin, 5)
    gate_space = LocalMath.Space(_CheckerboardAcceptanceGate, 1)

    winners = LocalMath.Field(owners_space, Int32)
    status = LocalMath.Field(status_space, ProgramStatus)
    report = LocalMath.Field(report_space, UInt64)
    report_scratch = LocalMath.Field(report_space, UInt64)
    ownership_scratch = LocalMath.Field(
        accepted.ownership.space, eltype(accepted.ownership))
    state_scratch = map(accepted.accepted_state_fields) do field
        LocalMath.Field(field.space, eltype(field))
    end
    external_gate = LocalMath.Field(gate_space, Bool)
    initial_gate = LocalMath.Field(gate_space, Bool)
    refreshed_gate = LocalMath.Field(gate_space, Bool)
    terminal_gate = LocalMath.Field(gate_space, Bool)
    relationship_groups = _checkerboard_relationship_groups(
        accepted, relationships, accepted.relationship_bank_fields,
        terminal_gate)
    tracker_groups = _checkerboard_tracker_groups(
        accepted, tracker_plan, tracker_state, terminal_gate,
        owner_capacity)

    gate_identity = LocalMath.IdentityRelation(gate_space)
    owner_relation = LocalMath.IndexRelation(
        accepted.owners => owners_space; optional = true)
    status_relation = LocalMath.RuntimeRelation(
        accepted.source_space => status_space;
        degree_bound = 1, key_type = Int32)
    report_route = LocalMath.RuntimeRelation(
        accepted.source_space => report_space;
        degree_bound = 5, key_type = Int32)

    gate_stage(destination, label) = LocalMath.Stage(
        gate_space,
        (gate = LocalMath.Access(external_gate, gate_identity),),
        (LocalMath.Publication((LocalMath.FieldPublication(
            destination, gate_identity,
            LocalMath.PublicationValue(:gate)),), LocalMath.Unique(Bool)),),
        LocalMath.Evaluator(_CheckerboardAcceptedGateCopy()),
        LocalMath.Control(),
        LocalMath.SourceOrigin(@__FILE__, @__LINE__; label),
    )
    failure_stage = LocalMath.Stage(
        accepted.source_space,
        (
            dispositions = LocalMath.Access(
                accepted.disposition, accepted.identity; required = true),
            semantic_ids = LocalMath.Access(
                accepted.semantic, accepted.identity; required = true),
        ),
        (LocalMath.Publication((LocalMath.FieldPublication(
            status, status_relation,
            LocalMath.PublicationValue(:status)),), LocalMath.Resolve(
                Int32, ProgramStatus;
                lower = Int32(1), upper = typemax(Int32),
                onempty = LocalMath.PreserveEmpty())),),
        LocalMath.Evaluator(_CheckerboardAcceptanceEvaluator(),
            (accepted.batch_size, accepted.mcs)),
        LocalMath.Control(;
            prefix = accepted.batch_size, gate = initial_gate),
        LocalMath.SourceOrigin(@__FILE__, @__LINE__;
            label = :checkerboard_acceptance_failure),
    )
    resolve_stage = LocalMath.Stage(
        accepted.source_space,
        (
            owners = LocalMath.Access(
                accepted.owners, accepted.identity; required = true),
            priorities = LocalMath.Access(
                accepted.qualified_priority, accepted.identity;
                required = true),
            semantics = LocalMath.Access(
                accepted.semantic, accepted.identity; required = true),
            dispositions = LocalMath.Access(
                accepted.disposition, accepted.identity; required = true),
        ),
        (LocalMath.Publication((LocalMath.FieldPublication(
            winners, owner_relation,
            LocalMath.PublicationValue(:winner)),), LocalMath.Resolve(
                UInt32, Int32; maximum = 2,
                direction = LocalMath.ArgMax(),
                tie = LocalMath.TieMin{Int32}(),
                lower = UInt32(0), upper = typemax(UInt32),
                onempty = LocalMath.FillEmpty(typemax(Int32)))),),
        LocalMath.Evaluator(
            _CheckerboardClaimResolver(), (accepted.batch_size,)),
        LocalMath.Control(;
            prefix = accepted.batch_size, gate = refreshed_gate),
        LocalMath.SourceOrigin(@__FILE__, @__LINE__;
            label = :checkerboard_owner_resolution),
    )
    conjunction_stage = LocalMath.Stage(
        accepted.source_space,
        (
            owners = LocalMath.Access(
                accepted.owners, accepted.identity; required = true),
            winners = LocalMath.Access(winners, owner_relation),
            semantics = LocalMath.Access(
                accepted.semantic, accepted.identity; required = true),
            dispositions = LocalMath.Access(
                accepted.disposition, accepted.identity; required = true),
        ),
        (LocalMath.Publication((LocalMath.FieldPublication(
            accepted.disposition, accepted.identity,
            LocalMath.PublicationValue(:disposition)),),
            LocalMath.Unique(UInt8;
                coverage = LocalMath.PartialCoverage(),
                onempty = LocalMath.PreserveEmpty())),),
        LocalMath.Evaluator(
            _CheckerboardClaimConjunction(), (accepted.batch_size,)),
        LocalMath.Control(;
            prefix = accepted.batch_size, gate = refreshed_gate),
        LocalMath.SourceOrigin(@__FILE__, @__LINE__;
            label = :checkerboard_mutual_maxima),
    )
    accepted_validation_stage = if isempty(accepted.accepted_site_terms) &&
            isempty(accepted.accepted_relationship_terms)
        nothing
    else
        evaluator = _CheckerboardAcceptedValidation(
            accepted.accepted_site_terms,
            accepted.accepted_relationship_terms,
            Int32(length(accepted.source_space)))
        base_reads = (
            semantic = LocalMath.Access(
                accepted.semantic, accepted.identity; required = true),
            disposition = LocalMath.Access(
                accepted.disposition, accepted.identity; required = true),
        )
        site_reads = NamedTuple{keys(accepted.accepted_site_fields)}(map(
            field -> LocalMath.Access(
                field, accepted.identity; required = true),
            values(accepted.accepted_site_fields)))
        relationship_reads = NamedTuple{
            keys(accepted.accepted_relationship_fields)}(map(
                field -> LocalMath.Access(
                    field, accepted.identity; required = true),
                values(accepted.accepted_relationship_fields)))
        maximum_ordinal = maximum((
            term.descriptor_ordinal for term in (
                accepted.accepted_site_terms...,
                accepted.accepted_relationship_terms...)); init = Int32(1))
        LocalMath.Stage(
            accepted.source_space,
            merge(base_reads, site_reads, relationship_reads),
            (LocalMath.Publication((LocalMath.FieldPublication(
                status, status_relation,
                LocalMath.PublicationValue(:status)),), LocalMath.Resolve(
                    Int32, ProgramStatus;
                    lower = Int32(1),
                    upper = Int32(length(accepted.source_space) *
                        maximum_ordinal),
                    onempty = LocalMath.PreserveEmpty())),),
            LocalMath.Evaluator(evaluator, (accepted.mcs,)),
            LocalMath.Control(;
                prefix = accepted.batch_size, gate = refreshed_gate),
            LocalMath.SourceOrigin(@__FILE__, @__LINE__;
                label = :checkerboard_accepted_validation),
        )
    end
    accepted_state_stage = let
        state_port_names = ntuple(
            index -> Symbol(:accepted_state_, index),
            length(accepted.accepted_state_handles))
        port_names = (:accepted_ownership, state_port_names...)
        target_relation = LocalMath.IndexRelation(
            accepted.target => accepted.lattice_space; optional = false)
        state_read_names = ntuple(
            index -> Symbol(:state_, index),
            length(accepted.accepted_state_fields))
        state_reads = NamedTuple{state_read_names}(map(
            field -> LocalMath.Access(
                field, target_relation; required = true),
            accepted.accepted_state_fields))
        evaluation_reads = NamedTuple{keys(accepted.accepted_site_fields)}(map(
            field -> LocalMath.Access(
                field, accepted.identity; required = true),
            values(accepted.accepted_site_fields)))
        reads = merge((
            disposition = LocalMath.Access(
                accepted.disposition, accepted.identity; required = true),
            owners = LocalMath.Access(
                accepted.owners, accepted.identity; required = true),
        ), evaluation_reads, state_reads)
        state_publications = map(
            state_scratch, state_port_names) do field, name
            LocalMath.Publication((LocalMath.FieldPublication(
                field, target_relation,
                LocalMath.PublicationValue(name)),), LocalMath.Unique(
                    eltype(field);
                    coverage = LocalMath.PartialCoverage(),
                    onempty = LocalMath.PreserveEmpty()))
        end
        ownership_publication = LocalMath.Publication((
            LocalMath.FieldPublication(
                ownership_scratch, target_relation,
                LocalMath.PublicationValue(:accepted_ownership)),),
            LocalMath.Unique(Int32;
                coverage = LocalMath.PartialCoverage(),
                onempty = LocalMath.PreserveEmpty()))
        publications = (ownership_publication, state_publications...)
        evaluator = _checkerboard_accepted_state_publication(
            Val(port_names),
            Val(!isempty(accepted.accepted_site_terms)),
            accepted.accepted_state_handles,
            accepted.accepted_site_terms,
            accepted.ownership_change_handles)
        LocalMath.Stage(
            accepted.source_space,
            reads,
            publications,
            LocalMath.Evaluator(evaluator),
            LocalMath.Control(;
                prefix = accepted.batch_size, gate = terminal_gate),
            LocalMath.SourceOrigin(@__FILE__, @__LINE__;
                label = :checkerboard_accepted_state_publication),
        )
    end
    report_stage = LocalMath.Stage(
        accepted.source_space,
        (dispositions = LocalMath.Access(
            accepted.disposition, accepted.identity; required = true),),
        (LocalMath.Publication((LocalMath.FieldPublication(
            report_scratch, report_route,
            LocalMath.PublicationValue(:counts)),), LocalMath.Reduce(
                UInt64, +; maximum = 5,
                seed = LocalMath.ExistingSeed(),
                order = LocalMath.CanonicalLeftFold())),),
        LocalMath.Evaluator(
            _CheckerboardReportEvaluator(), (accepted.batch_size,)),
        LocalMath.Control(;
            prefix = accepted.batch_size, gate = terminal_gate),
        LocalMath.SourceOrigin(@__FILE__, @__LINE__;
            label = :checkerboard_report_counts),
    )
    validation_laws = accepted_validation_stage === nothing ? () :
        (LocalMath.LocalLaw(accepted_validation_stage),)
    state_laws = (LocalMath.LocalLaw(accepted_state_stage),)
    # Private shadows always begin as exact live-state snapshots. Only the
    # fallible transformations and shadow-to-live commits are gate-controlled.
    state_initialization_laws = (
        _checkerboard_field_copy_law(accepted.ownership, ownership_scratch,
            nothing, :checkerboard_ownership_shadow_initialize),
        Tuple(_checkerboard_field_copy_law(source, scratch, nothing,
                Symbol(:checkerboard_state_shadow_initialize_, index))
            for (index, (source, scratch)) in enumerate(zip(
                accepted.accepted_state_fields, state_scratch)))...,
    )
    state_commit_laws = (
        _checkerboard_field_copy_law(ownership_scratch, accepted.ownership,
            terminal_gate, :checkerboard_ownership_commit),
        Tuple(_checkerboard_field_copy_law(scratch, destination, terminal_gate,
                Symbol(:checkerboard_state_commit_, index))
            for (index, (scratch, destination)) in enumerate(zip(
                state_scratch, accepted.accepted_state_fields)))...,
    )
    report_initialization_law = _checkerboard_field_copy_law(
        report, report_scratch, nothing, :checkerboard_report_initialize)
    report_commit_law = _checkerboard_field_copy_law(
        report_scratch, report, terminal_gate, :checkerboard_report_commit)
    relationship_laws = map(group -> group.law, relationship_groups)
    relationship_commit_laws = _checkerboard_relationship_commit_laws(
        relationship_groups, terminal_gate)
    tracker_laws = (
        (law for group in tracker_groups
            for law in (group.initialization_laws..., group.laws...))...,)
    tracker_commit_laws = (
        (law for group in tracker_groups for law in group.commit_laws)...,)
    selection_laws = (
        validation_laws...,
        LocalMath.LocalLaw(gate_stage(
            terminal_gate, :checkerboard_selection_terminal_gate)),
        relationship_laws...,
        tracker_laws...,
        state_initialization_laws...,
        state_laws...,
        report_initialization_law,
    )
    law = LocalMath.sequence(
        accepted.law,
        LocalMath.LocalLaw(gate_stage(
            initial_gate, :checkerboard_selection_initial_gate)),
        LocalMath.LocalLaw(failure_stage),
        LocalMath.LocalLaw(gate_stage(
            refreshed_gate, :checkerboard_selection_refreshed_gate)),
        LocalMath.LocalLaw(resolve_stage),
        LocalMath.LocalLaw(conjunction_stage),
        selection_laws...,
        LocalMath.LocalLaw(report_stage),
        state_commit_laws...,
        tracker_commit_laws...,
        relationship_commit_laws...,
        report_commit_law,
    )
    return merge(accepted, (;
        law, winners, status, report, report_scratch,
        ownership_scratch, state_scratch, external_gate,
        initial_gate, refreshed_gate, terminal_gate, owner_relation,
        status_relation, report_route, relationship_groups, tracker_groups))
end

function _checkerboard_color_schedule(
        plan::CheckerboardPlan, color::Integer)
    1 <= color <= Int(plan.color_count) || throw(ArgumentError(
        "checkerboard color is outside its prepared range"))
    maximum_batch = Int(plan.maximum_color_size)
    first_index = Int(@inbounds plan.color_offsets[color])
    stop_index = Int(@inbounds plan.color_offsets[color + 1]) - 1
    count = stop_index - first_index + 1
    schedule = zeros(Int32, maximum_batch)
    count > 0 && copyto!(schedule, 1, plan.sites, first_index, count)
    return schedule, Int32(count)
end

_checkerboard_state_field_bindings(::Tuple{}, ::Tuple{}, state) = ()
function _checkerboard_state_field_bindings(fields::Tuple, handles::Tuple, state)
    return (
        first(fields) => state_block(
            state.descriptor_state, first(handles)).values,
        _checkerboard_state_field_bindings(
            Base.tail(fields), Base.tail(handles), state)...,
    )
end


_checkerboard_parameter_binding(::Nothing, state, extent) = ()
function _checkerboard_parameter_binding(
        field::LocalMath.Field{T}, state, extent,
    ) where {T<:Tuple}
    N = fieldcount(T)
    N > 0 && all(==(fieldtype(T, 1)), fieldtypes(T)) || throw(ArgumentError(
        "checkerboard parameter fields require a nonempty homogeneous tuple"))
    return (field => _checkerboard_parameter_view(
        state.parameters, Val(N), extent),)
end

_checkerboard_storage_zero(::Type{T}) where {T} = zero(T)
@generated function _checkerboard_storage_zero(::Type{T}) where {T<:Tuple}
    types = fieldtypes(T)
    return Expr(:tuple, (
        :(_checkerboard_storage_zero($(types[index])))
        for index in eachindex(types))...)
end
_checkerboard_storage_zero(field::LocalMath.Field) =
    _checkerboard_storage_zero(eltype(field))

_checkerboard_contact_bindings(::Nothing) = ()
function _checkerboard_contact_bindings(contact)
    return (
        contact.owners => LocalMath.Allocate(_checkerboard_storage_zero(contact.owners)),
        contact.sites => LocalMath.Allocate(_checkerboard_storage_zero(contact.sites)),
        contact.kinds => LocalMath.Allocate(_checkerboard_storage_zero(contact.kinds)),
        contact.reverse_owners => LocalMath.Allocate(
            _checkerboard_storage_zero(contact.reverse_owners)),
        contact.reverse_sites => LocalMath.Allocate(
            _checkerboard_storage_zero(contact.reverse_sites)),
        contact.reverse_kinds => LocalMath.Allocate(
            _checkerboard_storage_zero(contact.reverse_kinds)),
    )
end

_checkerboard_tracker_source_bindings(
    ::Tuple{}, ::Tuple{}, state,
) = ()
function _checkerboard_tracker_source_bindings(
        fields::Tuple, keys::Tuple, state)
    return (
        first(fields) => tracker_values(
            state.program.tracker_plan, state.trackers, first(keys)),
        _checkerboard_tracker_source_bindings(
            Base.tail(fields), Base.tail(keys), state)...,
    )
end

_checkerboard_moment_source_bindings(::Tuple{}, ::Nothing, state) = ()
function _checkerboard_moment_source_bindings(
        fields::Tuple, descriptor::CellMomentsTracker, state)
    descriptors = state.program.tracker_plan.descriptors
    index = findfirst(==(descriptor), descriptors)
    index === nothing && throw(ArgumentError(
        "checkerboard cell-moment descriptor is unavailable at binding"))
    value = state.trackers.values[index]
    value isa CellMomentsState || throw(ArgumentError(
        "checkerboard cell-moment storage has an incompatible schema"))
    dimensions = size(value.first, 1)
    length(fields) == dimensions + dimensions * dimensions || throw(
        ArgumentError(
            "checkerboard cell-moment fields disagree with their descriptor"))
    return Tuple(map(enumerate(fields)) do indexed
        component, field = indexed
        storage = component <= dimensions ?
            view(value.first, component, :) :
            view(value.second, component - dimensions, :)
        field => storage
    end)
end

_checkerboard_relationship_science_bindings(::Tuple{}, state) = ()
function _checkerboard_relationship_science_bindings(
        declarations::Tuple, state)
    declaration = first(declarations)
    # Preparation retains the validated host location while binding the
    # corresponding packed arrays from the selected runtime bank.
    location = declaration.state_location
    bank = state.relationships.banks[Int(location.bank)]
    bank isa PackedRelationshipBank || throw(ArgumentError(
        "checkerboard relationship science binding requires packed storage"))
    degree = declaration.maximum_degree
    owner_count = length(declaration.cell_volumes.space)
    incident_offset = Int(declaration.incident_offset)
    incident_slots = reshape(Int32[
        incident_offset + (owner - 1) * degree + lane - 1
        for lane in 1:degree, owner in 1:owner_count
    ], degree, owner_count)
    execution_incident_slots = _checkerboard_similar(
        state.parameters, Int32, size(incident_slots)...
    )
    copyto!(execution_incident_slots, incident_slots)
    return (
        declaration.incident_slot_relation =>
            LocalMath.Allocate(execution_incident_slots),
        declaration.edge_keys =>
            LocalMath.Allocate(_checkerboard_storage_zero(
                declaration.edge_keys)),
        declaration.endpoint_keys =>
            LocalMath.Allocate(_checkerboard_storage_zero(
                declaration.endpoint_keys)),
        _checkerboard_relationship_science_bindings(
            Base.tail(declarations), state)...,
    )
end

function _checkerboard_accepted_site_binding(fields::NamedTuple, workspace)
    return map(values(fields)) do field
        field => LocalMath.Allocate(_checkerboard_storage_zero(field))
    end
end

function _checkerboard_accepted_relationship_binding(fields::NamedTuple)
    return map(values(fields)) do field
        field => LocalMath.Allocate(_checkerboard_storage_zero(field))
    end
end

_checkerboard_relationship_group_bindings(::Tuple{}, state) = ()
function _checkerboard_relationship_group_bindings(groups::Tuple, state)
    group = first(groups)
    bank = state.relationships.banks[Int(group.bank_index)]
    bank isa PackedRelationshipBank || throw(ArgumentError(
        "checkerboard relationship binding requires packed banks"))
    endpoint_bindings = map(values(group.endpoint_fields)) do field
        field => LocalMath.Allocate(_checkerboard_storage_zero(field))
    end
    lane_count = length(group.terms)
    endpoints = reshape(Int32[
        fld(item - 1, lane_count) + 1
        for item in 1:length(group.request_space)],
        1, length(group.request_space))
    execution_endpoints = _checkerboard_similar(
        state.parameters, Int32, size(endpoints)...
    )
    copyto!(execution_endpoints, endpoints)
    return (
        group.candidate_relation => execution_endpoints,
        endpoint_bindings...,
        map(field -> field => LocalMath.Allocate(
                _checkerboard_storage_zero(field)),
            values(group.shadow_fields))...,
        _checkerboard_relationship_group_bindings(Base.tail(groups), state)...,
    )
end

_checkerboard_tracker_storage(value, ::Val{:self}) = value
_checkerboard_tracker_storage(value, ::Val{:first}) = value.first
_checkerboard_tracker_storage(value, ::Val{:second}) = value.second
_checkerboard_tracker_storage(value, column::Int32) = view(value, :, Int(column))

_checkerboard_tracker_group_bindings(::Tuple{}, state) = ()
function _checkerboard_tracker_group_bindings(groups::Tuple, state)
    group = first(groups)
    value = state.trackers.values[Int(group.tracker_index)]
    source_bindings = Tuple(field => (path isa Int32 ?
            _checkerboard_tracker_storage(value, path) :
            _checkerboard_tracker_storage(value, Val(path)))
        for (field, path) in zip(group.source_fields, group.paths)
        if path !== nothing)
    scratch_bindings = map(group.fields) do field
        field => LocalMath.Allocate(_checkerboard_storage_zero(field))
    end
    return (
        source_bindings...,
        scratch_bindings...,
        _checkerboard_tracker_group_bindings(Base.tail(groups), state)...,
    )
end

function _checkerboard_extinction_policies(plan, kind_count::Integer)
    forbid = plan isa LifecycleExecutionPlan ? Tuple(plan.forbid_extinction) :
        ntuple(_ -> false, kind_count)
    length(forbid) >= kind_count || throw(ArgumentError(
        "checkerboard lifecycle extinction policy omits a declared kind"))
    retire = ntuple(length(forbid)) do kind
        _has_due_zero_volume_retirement(plan, Int16(kind))
    end
    return forbid, retire
end

function _checkerboard_relationship_bank_bindings(declaration, state)
    required = Any[]
    add_required!(field) = begin
        any(existing -> existing == field, required) || push!(required, field)
        nothing
    end
    for science in declaration.relationship_science
        add_required!(science.fields.active)
        add_required!(science.fields.endpoint_a)
        add_required!(science.fields.endpoint_b)
        foreach(add_required!, science.fields.payload)
        add_required!(science.incident_edges_field)
    end
    for group in declaration.relationship_groups
        foreach(add_required!, values(group.live_fields))
    end
    bindings = Pair[]
    for (bank_index, authority) in enumerate(
            declaration.relationship_bank_fields)
        storage = _packed_relationship_science(
            state.relationships.banks[bank_index])
        keys(authority) == keys(storage) || throw(ArgumentError(
            "checkerboard relationship authority disagrees with packed storage"))
        for (field, array) in zip(values(authority), values(storage))
            any(required_field -> required_field == field, required) &&
                push!(bindings, field => array)
        end
    end
    return Tuple(bindings)
end

function _checkerboard_color_bindings(
        declaration, workspace, state, schedule, gate,
    )
    maximum_batch = length(declaration.source_space)
    sites = StructArrays.StructArray{NTuple{2,Int32}}((
        workspace.target_sites, workspace.source_sites))
    owners = StructArrays.StructArray{NTuple{2,Int32}}((
        workspace.old_owners, workspace.new_owners))
    volumes = tracker_values(
        state.program.tracker_plan, state.trackers, Val(:cell_volume))
    parameter_binding = _checkerboard_parameter_binding(
        declaration.science_parameters, state, maximum_batch)
    state_bindings = _checkerboard_state_field_bindings(
        declaration.state_fields, declaration.state_handles, state)
    contact_bindings = _checkerboard_contact_bindings(declaration.contact)
    tracker_source_bindings = _checkerboard_tracker_source_bindings(
        declaration.tracker_source_fields, declaration.tracker_keys, state)
    moment_source_bindings = _checkerboard_moment_source_bindings(
        declaration.moment_source_fields,
        declaration.moment_descriptor, state)
    relationship_science_bindings =
        _checkerboard_relationship_science_bindings(
            declaration.relationship_science, state)
    relationship_bank_bindings =
        _checkerboard_relationship_bank_bindings(declaration, state)
    tracker_pair_bindings = map(declaration.tracker_pair_fields) do field
        field => LocalMath.Allocate(_checkerboard_storage_zero(field))
    end
    accepted_site_binding = _checkerboard_accepted_site_binding(
        declaration.accepted_site_fields, workspace)
    accepted_relationship_binding =
        _checkerboard_accepted_relationship_binding(
            declaration.accepted_relationship_fields)
    relationship_group_bindings =
        _checkerboard_relationship_group_bindings(
            declaration.relationship_groups, state)
    tracker_group_bindings = _checkerboard_tracker_group_bindings(
        declaration.tracker_groups, state)
    state_scratch_bindings = map(declaration.state_scratch) do field
        field => LocalMath.Allocate(_checkerboard_storage_zero(field))
    end
    generation_binding = isempty(declaration.relationship_groups) ? () :
        (declaration.cell_generations => state.cell_generations,)
    return (
        declaration.target_options => LocalMath.Allocate(schedule),
        declaration.target => LocalMath.Allocate(zero(Int32)),
        declaration.sites => sites,
        declaration.semantic => workspace.semantic_ids,
        declaration.priority => workspace.priorities,
        declaration.ownership => state.ownership,
        declaration.owners => owners,
        declaration.actionable => LocalMath.Allocate(false),
        declaration.cell_kinds => state.cell_kinds,
        declaration.cell_volumes => volumes,
        generation_binding...,
        declaration.kinds => LocalMath.Allocate(
            _checkerboard_storage_zero(declaration.kinds)),
        declaration.volumes => LocalMath.Allocate(
            _checkerboard_storage_zero(declaration.volumes)),
        parameter_binding...,
        state_bindings...,
        contact_bindings...,
        tracker_source_bindings...,
        moment_source_bindings...,
        relationship_bank_bindings...,
        relationship_science_bindings...,
        tracker_pair_bindings...,
        accepted_site_binding...,
        accepted_relationship_binding...,
        relationship_group_bindings...,
        tracker_group_bindings...,
        declaration.evaluation.delta_h => LocalMath.Allocate(
            zero(eltype(declaration.evaluation.delta_h))),
        declaration.evaluation.drive_energy => LocalMath.Allocate(
            zero(eltype(declaration.evaluation.drive_energy))),
        declaration.evaluation.drive_log_bias => LocalMath.Allocate(
            zero(eltype(declaration.evaluation.drive_log_bias))),
        declaration.evaluation.kinetic_modifier => LocalMath.Allocate(
            zero(eltype(declaration.evaluation.kinetic_modifier))),
        declaration.evaluation.constraints_allowed => LocalMath.Allocate(true),
        declaration.disposition => workspace.dispositions,
        declaration.failure_code => LocalMath.Allocate(zero(UInt8)),
        declaration.failure_identity => LocalMath.Allocate(zero(Int32)),
        declaration.winners => LocalMath.Allocate(typemax(Int32)),
        declaration.status => state.program_status,
        declaration.report => workspace.report,
        declaration.report_scratch => LocalMath.Allocate(zero(UInt64)),
        declaration.ownership_scratch => LocalMath.Allocate(zero(Int32)),
        state_scratch_bindings...,
        declaration.external_gate => gate,
        declaration.initial_gate => LocalMath.Allocate(false),
        declaration.refreshed_gate => LocalMath.Allocate(false),
        declaration.terminal_gate => LocalMath.Allocate(false),
    )
end

function _prepare_checkerboard_color_laws(
        workspace,
        checkerboard::CheckerboardPlan,
        proposal_offsets::AbstractMatrix{<:Integer},
        descriptor_plan::DescriptorExecutionPlan,
        stage_plan::StageExecutionPlan,
        ownership_change_handles::Tuple,
        relationship_schemas::RelationshipStorage,
        kind_count::Integer,
        queue_capacity::Integer,
    )
    queue_capacity > 0 || throw(ArgumentError(
        "checkerboard color preparation requires positive queue capacity"))
    state = workspace.state
    plan = state.program.checkerboard_plan
    validated = _validate_checkerboard_stage_program_preparation(
        workspace, plan, checkerboard, proposal_offsets,
        "host and adapted checkerboard compiler inputs disagree")
    T = eltype(state.parameters)
    kind_count = Int(kind_count)
    kind_count > 0 || throw(ArgumentError(
        "checkerboard compiler requires at least one cell kind"))
    cell_capacity = length(state.cell_kinds)
    forbid, retire = state.program.extinction_policies
    scientific = _checkerboard_scientific_declaration(
        checkerboard, proposal_offsets,
        state.seed, state.replica, state.repeat,
        descriptor_plan, stage_plan, state.program.tracker_plan,
        ownership_change_handles,
        relationship_schemas, state.relationships,
        state.program.temperature.parameter_index,
        cell_capacity, T)
    accepted = _checkerboard_acceptance_declaration(
        scientific, state.program.temperature, forbid, retire,
        state.seed, state.replica, state.repeat)
    declaration = _checkerboard_color_declaration(
        accepted, cell_capacity, state.relationships,
        state.program.tracker_plan, state.trackers)
    gates = (
        _checkerboard_open_gate(workspace.state),
        _checkerboard_open_gate(workspace.alternate_state),
    )
    schedules = ntuple(Int(checkerboard.color_count)) do color
        _checkerboard_color_schedule(checkerboard, color)
    end
    schedule_arrays = map(first, schedules)
    combined_schedule = collect(zip(schedule_arrays...))
    execution_schedule = _checkerboard_similar(
        state.parameters, eltype(combined_schedule), length(combined_schedule)
    )
    copyto!(execution_schedule, combined_schedule)
    prepare_bank = function (bank, gate)
        return LocalMath.prepare(
            declaration.law,
            _checkerboard_color_bindings(
                declaration, workspace, bank, execution_schedule, gate)...;
            backend = validated.backend, lease_capacity = queue_capacity,
            dependency_arity = 1)
    end
    prepared = (
        prepare_bank(workspace.state, gates[1]),
        prepare_bank(workspace.alternate_state, gates[2]),
    )
    typeof(prepared[1]) === typeof(prepared[2]) || throw(ArgumentError(
        "checkerboard banks produced different PreparedPlan types"))
    batch_sizes = Int32[last(schedule) for schedule in schedules]
    return (; declaration, prepared, batch_sizes, gates,
        backend = validated.backend)
end
const _CHECKERBOARD_RELATIONSHIP_MAXIMUM_DEGREE = Int32(16)
const _CHECKERBOARD_RELATIONSHIP_INCIDENT_WRITES = 32

@inline function _checkerboard_endpoint_value(value::Integer)
    value isa Bool && return (false, Int32(0))
    typemin(Int32) <= value <= typemax(Int32) || return (false, Int32(0))
    return (true, Int32(value))
end

@inline function _checkerboard_endpoint_value(value::AbstractFloat)
    isfinite(value) || return (false, Int32(0))
    lower = typeof(value)(-2147483648)
    upper = typeof(value)(2147483648)
    lower <= value < upper || return (false, Int32(0))
    trunc(value) == value || return (false, Int32(0))
    return (true, Int32(value))
end

@inline _checkerboard_endpoint_value(_value) = (false, Int32(0))

@inline function _checkerboard_payload_value(prototype::T, value) where {
        T <: AbstractFloat,
    }
    value isa Real || return (false, zero(T))
    converted = T(value)
    return (isfinite(converted), converted)
end

@generated function _checkerboard_payload_values(
        prototype::P, values::V
    ) where {P <: Tuple, V <: Tuple}
    fieldcount(P) == fieldcount(V) || return :((false, prototype))
    assignments = Expr[]
    valid = Expr(:call, :(&),
        [Symbol(:valid_, i) for i in 1:fieldcount(P)]...)
    converted = Expr(:tuple,
        [Symbol(:converted_, i) for i in 1:fieldcount(P)]...)
    for index in 1:fieldcount(P)
        push!(assignments, quote
            $(Symbol(:valid_, index)), $(Symbol(:converted_, index)) =
                _checkerboard_payload_value(
                    getfield(prototype, $index), getfield(values, $index))
        end)
    end
    isempty(assignments) && return :((true, ()))
    return Expr(:block, assignments..., :(($valid, $converted)))
end

@inline _checkerboard_fold_edge_offset(reads, slot::Int32) =
    @inbounds reads.edge_offsets[slot]
@inline _checkerboard_fold_endpoint_offset(reads, slot::Int32) =
    @inbounds reads.endpoint_offsets[slot]
@inline _checkerboard_fold_incident_offset(reads, slot::Int32) =
    @inbounds reads.incident_offsets[slot]
@inline _checkerboard_fold_maximum_degree(reads, slot::Int32) =
    @inbounds reads.maximum_degrees[slot]

@inline function _checkerboard_fold_degree_index(
        reads, slot::Int32, endpoint::Int32)
    return _checkerboard_fold_endpoint_offset(reads, slot) + endpoint - Int32(1)
end

@inline function _checkerboard_fold_incident_index(
        reads, slot::Int32, endpoint::Int32, position::Int32)
    return _checkerboard_fold_incident_offset(reads, slot) +
        (endpoint - Int32(1)) * _checkerboard_fold_maximum_degree(reads, slot) +
        position - Int32(1)
end

@inline function _checkerboard_fold_relationship_edge(
        state, reads, slot::Int32, a::Int32, b::Int32)
    degree_a = Int32(@inbounds state.degree[
        _checkerboard_fold_degree_index(reads, slot, a)])
    degree_b = Int32(@inbounds state.degree[
        _checkerboard_fold_degree_index(reads, slot, b)])
    endpoint = degree_a <= degree_b ? a : b
    degree = min(degree_a, degree_b)
    edge_offset = _checkerboard_fold_edge_offset(reads, slot)
    for position in Int32(1):degree
        edge = @inbounds state.incident_edges[
            _checkerboard_fold_incident_index(
                reads, slot, endpoint, position)]
        edge > 0 || continue
        flat_edge = edge_offset + edge - Int32(1)
        if @inbounds(state.active[flat_edge]) &&
                @inbounds(state.endpoint_a[flat_edge]) == a &&
                @inbounds(state.endpoint_b[flat_edge]) == b
            return edge
        end
    end
    return Int32(0)
end

@inline function _checkerboard_fold_available_edge(
        state, reads, slot::Int32)
    offset = _checkerboard_fold_edge_offset(reads, slot)
    count = @inbounds reads.edge_counts[slot]
    for edge in Int32(1):count
        @inbounds(state.active[offset + edge - Int32(1)]) || return edge
    end
    return Int32(0)
end

@inline function _checkerboard_fold_insertion_position(
        state, reads, slot::Int32, endpoint::Int32, edge::Int32,
        degree::Int32)
    position = degree + Int32(1)
    while position > Int32(1)
        previous = @inbounds state.incident_edges[
            _checkerboard_fold_incident_index(
                reads, slot, endpoint, position - Int32(1))]
        previous > edge || break
        position -= Int32(1)
    end
    return position
end

@inline function _checkerboard_fold_incident_write(
        state, reads, slot::Int32, endpoint_a::Int32,
        position_a::Int32, degree_a::Int32, endpoint_b::Int32,
        position_b::Int32, degree_b::Int32, edge::Int32, lane::Int32)
    count_a = degree_a - position_a + Int32(2)
    if lane <= count_a
        position = position_a + lane - Int32(1)
        destination = _checkerboard_fold_incident_index(
            reads, slot, endpoint_a, position)
        value = position == position_a ? edge : @inbounds(
            state.incident_edges[destination - Int32(1)])
        return (destination, value)
    end
    local_lane = lane - count_a
    count_b = degree_b - position_b + Int32(2)
    if local_lane <= count_b
        position = position_b + local_lane - Int32(1)
        destination = _checkerboard_fold_incident_index(
            reads, slot, endpoint_b, position)
        value = position == position_b ? edge : @inbounds(
            state.incident_edges[destination - Int32(1)])
        return (destination, value)
    end
    return (Int32(1), Int32(0))
end

struct _CheckerboardAcceptedGateCopy end
@inline function (::_CheckerboardAcceptedGateCopy)(
        item::Int32, reads, parameters,
    )
    return (gate = LocalMath.UniqueValue(
        something(@inbounds(reads[1][1].value))),)
end
