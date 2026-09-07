# Portable checkerboard candidate, deterministic claim, evaluation, and commit.

const _PROGRAM_CHECKERBOARD_PENDING = UInt8(0)
const _PROGRAM_CHECKERBOARD_NULL = UInt8(1)
const _PROGRAM_CHECKERBOARD_CONFLICT = UInt8(2)
const _PROGRAM_CHECKERBOARD_CONSTRAINT = UInt8(3)
const _PROGRAM_CHECKERBOARD_ENERGY = UInt8(4)
const _PROGRAM_CHECKERBOARD_ACCEPTED = UInt8(5)
const _PROGRAM_CHECKERBOARD_NONFINITE = UInt8(6)
const _PROGRAM_CHECKERBOARD_ZERO_T_DRIVE = UInt8(7)

_empty_checkerboard_receipt_bank() =
    (LocalMath.ExecutionReceipt[], LocalMath.ExecutionReceipt[])

@inline _record_checkerboard_receipt!(bank, index, ::Nothing) = nothing
@inline function _record_checkerboard_receipt!(
        bank, index, receipt::LocalMath.ExecutionReceipt,
    )
    push!(bank[Int(index)], receipt)
    return receipt
end
function _empty_checkerboard_receipts()
    return (
        mechanics = _empty_checkerboard_receipt_bank(),
        lifecycle = (
            direct = _empty_checkerboard_receipt_bank(),
            planning = _empty_checkerboard_receipt_bank(),
            site_index = _empty_checkerboard_receipt_bank(),
            request_index = _empty_checkerboard_receipt_bank(),
            emission = _empty_checkerboard_receipt_bank(),
            selection = _empty_checkerboard_receipt_bank(),
        ),
    )
end

"""Mutable queued, completed, committed, and materialized MCS position."""
mutable struct ProgramExecutionPosition
    submitted_mcs::Int
    drained_mcs::Int
    committed_mcs::Int
    materialized_mcs::Int
    settlement_count::Int
    synchronization_count::Int
    control_transfer_count::Int
    snapshot_transfer_count::Int
    lifecycle_transfer_count::Int
end

ProgramExecutionPosition(initial_mcs::Integer = 0) = ProgramExecutionPosition(
    Int(initial_mcs), Int(initial_mcs), Int(initial_mcs), Int(initial_mcs),
    0, 0, 0, 0, 0,
)

struct _CheckerboardRelationshipBankLayout{O,C,E,I,D}
    edge_offsets::O
    edge_counts::C
    endpoint_offsets::E
    incident_offsets::I
    maximum_degrees::D
    endpoint_count::Int32
    payload_count::Int32
end

struct _CheckerboardRelationshipLayout{S,B}
    slots::S
    banks::B
end

struct CheckerboardKernelProgram{T, N, O, R, TP, DR, L, H, C, E, RL}
    shape::NTuple{N, Int}
    periodic::NTuple{N, Bool}
    proposal_offsets::O
    medium_kind::Int16
    temperature::CompiledScalar{T}
    attempts_per_site::Int32
    relationships::R
    tracker_plan::TP
    domain_resources::DR
    lifecycle_plan::L
    ownership_change_handles::H
    checkerboard_plan::C
    extinction_policies::E
    relationship_layout::RL
    topology_epoch::UInt64
end

struct CheckerboardExecutionState{
        P, O, K, G, TS, R, D, L, C, PS, A,
    }
    program::P
    ownership::O
    cell_kinds::K
    cell_generations::G
    trackers::TS
    relationships::R
    descriptor_state::D
    lifecycle_workspace::L
    lifecycle_control::C
    program_status::PS
    parameters::A
    seed::UInt64
    replica::UInt32
    repeat::UInt32
    mcs::Int
end

Adapt.@adapt_structure CheckerboardKernelProgram
Adapt.@adapt_structure CheckerboardExecutionState

function _checkerboard_logical_topology_epoch(
        plan::CheckerboardPlan, proposal_offsets
    )
    for (name, storage) in (
            (:sites, plan.sites),
            (:color_offsets, plan.color_offsets),
            (:conflict_displacements, plan.conflict_displacements),
            (:proposal_offsets, proposal_offsets),
        )
        backend = KernelAbstractions.get_backend(storage)
        backend isa KernelAbstractions.CPU || throw(ArgumentError(
            "checkerboard logical topology epoch requires host-resident canonical $name"
        ))
    end
    io = IOBuffer()
    write(io, "corepotts/checkerboard-logical-topology/v1")
    foreach(value -> write(io, Int64(value)), plan.shape)
    foreach(value -> write(io, UInt8(value)), plan.periodic)
    write(io, Int64(plan.color_count))
    write(io, Int64(plan.maximum_color_size))
    write(io, Int64(length(plan.sites)))
    foreach(value -> write(io, Int64(value)), plan.sites)
    write(io, Int64(length(plan.color_offsets)))
    foreach(value -> write(io, Int64(value)), plan.color_offsets)
    write(io, Int64(size(plan.conflict_displacements, 1)))
    write(io, Int64(size(plan.conflict_displacements, 2)))
    foreach(
        value -> write(io, Int64(value)), plan.conflict_displacements
    )
    write(io, Int64(size(proposal_offsets, 1)))
    write(io, Int64(size(proposal_offsets, 2)))
    foreach(value -> write(io, Int64(value)), proposal_offsets)
    digest = SHA.sha256(take!(io))
    epoch = foldl(@view(digest[1:8]); init = zero(UInt64)) do value, byte
        (value << 8) | UInt64(byte)
    end
    return iszero(epoch) ? one(UInt64) : epoch
end

"""Prepared checkerboard banks, laws, receipts, and execution position."""
struct CheckerboardWorkspace{
        S, T, O, N, P, D, M, I, U, A, Z, CO, X, EP,
    }
    state::S
    alternate_state::S
    target_sites::T
    source_sites::O
    old_owners::N
    new_owners::P
    priorities::D
    semantic_ids::M
    dispositions::I
    report::U
    capability_report::A
    color_sizes::Z
    color_order::CO
    source_table::X
    execution::EP
end

const _CHECKERBOARD_EXECUTION_SCHEMA = v"9.0.0"
const _CHECKERBOARD_CHECKPOINT_SCHEMA = v"9.0.0"
const _CHECKERBOARD_MECHANISM_IDENTITY =
    :corepotts_localmath_mechanics_v2

"""One immutable identity for capability, checkpoint, replay, and settlement."""
struct CheckerboardExecutionIdentity{D, F, G, L, R, V, Q}
    schema::VersionNumber
    mechanism_identity::Symbol
    scientific_abi::Symbol
    descriptor_fingerprint::D
    capability_fingerprint::F
    topology_epoch::UInt64
    rng_identity::G
    lowerings::L
    provider::R
    provider_compiler::V
    queue_policy::Q
    checkpoint_schema::VersionNumber
end

"""The sole checkerboard graph, including bank initialization, compiled color
mechanics, reporting, and the remaining Core-owned lifecycle boundaries."""
mutable struct _CheckerboardExecutionWorkspace{
        W, C, Z, B, L, G, Q, I, R,
    }
    core::W
    color_laws::C
    clear_report::Z
    stage_boundaries::B
    lifecycle_reductions::L
    gates::G
    receipts::Q
    identity::I
    capability_report::R
end

struct _PreparedLifecycleStatusReduction{P,C,S,O,N,G,B}
    planning::P
    candidate_status::C
    status::S
    canonical_slots::O
    canonical_count::N
    gate::G
    backend::B
    lease_capacity::Int
end

function LocalMath.submission_capacity(
        prepared::_PreparedLifecycleStatusReduction)
    capacity = prepared.lease_capacity
    outstanding = 0
    return (; capacity, outstanding,
        available = capacity, submitted = 0, drained = 0)
end
function LocalMath.submission_capacity(prepared::_PreparedLifecycleEmission)
    capacity = typemax(Int)
    outstanding = 0
    return (; capacity, outstanding,
        available = capacity, submitted = 0, drained = 0)
end

@kernel function _lifecycle_status_reduction_kernel!(
        planning::Bool, candidate_status, status, canonical_slots,
        canonical_count, gate, limit::Int32,
    )
    index = @index(Global, Linear)
    if index == 1 && @inbounds(gate[1])
        count = planning ? @inbounds(canonical_count[1]) : limit
        for position in Int32(1):count
            request = planning ?
                @inbounds(canonical_slots[position]) : position
            candidate = @inbounds candidate_status[request]
            candidate.code === ProgramStatusSuccess && continue
            @inbounds status[1] = candidate
            break
        end
    end
end

function _run_lifecycle_status!(
        prepared::_PreparedLifecycleStatusReduction, limit::Integer)
    _lifecycle_status_reduction_kernel!(prepared.backend)(
        prepared.planning, prepared.candidate_status, prepared.status,
        prepared.canonical_slots, prepared.canonical_count, prepared.gate,
        Int32(limit); ndrange = 1)
    return nothing
end

struct _LifecycleStatusGate{S, C, D} <: AbstractVector{Bool}
    status::S
    counters::C
end

Base.size(::_LifecycleStatusGate) = (1,)
Base.length(::_LifecycleStatusGate) = 1
Base.strides(::_LifecycleStatusGate) = (1,)
Base.IndexStyle(::Type{<:_LifecycleStatusGate}) = IndexLinear()
@inline function Base.getindex(
        gate::_LifecycleStatusGate{S,C,D}, index::Integer
    ) where {S,C,D}
    @boundscheck index == 1 || throw(BoundsError(gate, index))
    return (@inbounds gate.status[1]).code === ProgramStatusSuccess &&
        (!D || @inbounds(gate.counters[_LIFECYCLE_CONTROL_DUE]) != Int32(0))
end

function KernelAbstractions.get_backend(gate::_LifecycleStatusGate)
    backend = KernelAbstractions.get_backend(gate.status)
    KernelAbstractions.get_backend(gate.counters) == backend || throw(
        ArgumentError("lifecycle status-gate parents belong to different backends")
    )
    return backend
end

function Adapt.adapt_structure(to, gate::_LifecycleStatusGate{S,C,D}) where {S,C,D}
    status = Adapt.adapt(to, gate.status)
    counters = Adapt.adapt(to, gate.counters)
    return _LifecycleStatusGate{
        typeof(status),
        typeof(counters),
        D,
    }(status, counters)
end

function _prepare_localmath_lifecycle_reductions(
        workspace::CheckerboardWorkspace,
        backend,
        epoch::UInt64,
        queue_mcs_capacity::Integer,
    )
    first_control = workspace.state.lifecycle_control
    first_control isa NoLifecycleBackendControl && return nothing
    capacity = length(first_control.candidate_status)
    lifecycle_plan = workspace.state.program.lifecycle_plan
    site_count = length(workspace.state.ownership)
    site_spec = _lifecycle_site_compaction_work(
        size(workspace.state.ownership), Int(lifecycle_plan.cell_capacity)
    )
    request_spec = _lifecycle_request_compaction_work(lifecycle_plan)
    site_gate_endpoints = KernelAbstractions.ones(
        backend, Int32, 1, site_count)
    request_gate_endpoints = KernelAbstractions.ones(
        backend, Int32, 1, Int(lifecycle_plan.maximum_requests))
    relation_authority = _allocate_lifecycle_relation_authority(backend, 2)
    relation_declaration(endpoints, slot) = LocalMath.MutableRelationStorage(
        (; endpoints);
        generation = relation_authority.generations,
        status = relation_authority.statuses,
        validated_generations = relation_authority.validated_generations,
        slot,
    )
    direct_leases = Int(queue_mcs_capacity)
    planning_leases = Int(queue_mcs_capacity) * 3
    return map(
            (workspace.state, workspace.alternate_state)
        ) do bank
        control = bank.lifecycle_control
        lifecycle = bank.lifecycle_workspace
        direct_gate = _LifecycleStatusGate{
            typeof(lifecycle.status), typeof(control.counters), false
        }(lifecycle.status, control.counters)
        planning_gate = _LifecycleStatusGate{
            typeof(lifecycle.status), typeof(control.counters), true
        }(lifecycle.status, control.counters)
        site_storage = _lifecycle_site_compacted_storage(nothing, lifecycle)
        request_storage = _lifecycle_request_compacted_storage(nothing, lifecycle)
        site_index = LocalMath.prepare(site_spec.law,
            site_spec.ownership => bank.ownership,
            site_spec.gate => planning_gate,
            site_spec.gate_relation => relation_declaration(
                site_gate_endpoints, 1),
            site_spec.sites => site_storage;
            backend, lease_capacity = Int(queue_mcs_capacity))
        request_index = LocalMath.prepare(request_spec.law,
            request_spec.requests => _lifecycle_request_source(lifecycle),
            request_spec.gate => planning_gate,
            request_spec.gate_relation => relation_declaration(
                request_gate_endpoints, 2),
            request_spec.canonical => request_storage;
            backend, lease_capacity = Int(queue_mcs_capacity))
        emission = _PreparedLifecycleEmission(
            bank, control.request_offsets,
            _lifecycle_emission_destination(lifecycle, control),
            lifecycle.status, planning_gate, backend)
        selection = _prepare_lifecycle_selection(
            lifecycle_plan,
            lifecycle,
            bank,
            planning_gate;
            lease_capacity = Int(queue_mcs_capacity),
        )
        direct = _PreparedLifecycleStatusReduction(
            false, control.candidate_status, lifecycle.status,
            lifecycle.request_index.records.slot,
            lifecycle.request_index.count, direct_gate, backend, direct_leases)
        planning = _PreparedLifecycleStatusReduction(
            true, control.candidate_status, lifecycle.status,
            lifecycle.request_index.records.slot,
            lifecycle.request_index.count, planning_gate, backend,
            planning_leases)
        (
            ; direct,
            planning,
            site_index,
            request_index,
            emission,
            selection,
            direct_gate,
            planning_gate,
        )
    end
end

@inline _checkerboard_core(workspace::_CheckerboardExecutionWorkspace) =
    workspace.core
@inline _checkerboard_execution_position(workspace) =
    _checkerboard_core(workspace).execution
@inline _checkerboard_runtime_capability(
    workspace::_CheckerboardExecutionWorkspace
) = workspace.capability_report
@inline _is_checkerboard_execution_workspace(
    ::_CheckerboardExecutionWorkspace
) = true
@inline _is_checkerboard_execution_workspace(::Any) = false

"""Read-only device projection of the exact Core program/lifecycle open state."""
struct _CheckerboardOpenGate{P, L} <: AbstractVector{Bool}
    program_status::P
    lifecycle_status::L
end

"""Read-only device projection for a checkerboard with no lifecycle workspace."""
struct _CheckerboardNoLifecycleOpenGate{P} <: AbstractVector{Bool}
    program_status::P
end

Base.IndexStyle(::Type{<:_CheckerboardOpenGate}) = IndexLinear()
Base.IndexStyle(::Type{<:_CheckerboardNoLifecycleOpenGate}) = IndexLinear()
Base.size(::_CheckerboardOpenGate) = (1,)
Base.size(::_CheckerboardNoLifecycleOpenGate) = (1,)
Base.length(::_CheckerboardOpenGate) = 1
Base.length(::_CheckerboardNoLifecycleOpenGate) = 1
Base.strides(::_CheckerboardOpenGate) = (1,)
Base.strides(::_CheckerboardNoLifecycleOpenGate) = (1,)

@inline function Base.getindex(gate::_CheckerboardOpenGate, index::Int)
    @boundscheck index == 1 || throw(BoundsError(gate, index))
    return (@inbounds gate.program_status[1]).code === ProgramStatusSuccess &&
           (@inbounds gate.lifecycle_status[1]).code === ProgramStatusSuccess
end

@inline function Base.getindex(
        gate::_CheckerboardNoLifecycleOpenGate, index::Int
    )
    @boundscheck index == 1 || throw(BoundsError(gate, index))
    return (@inbounds gate.program_status[1]).code === ProgramStatusSuccess
end

function KernelAbstractions.get_backend(gate::_CheckerboardOpenGate)
    backend = KernelAbstractions.get_backend(gate.program_status)
    KernelAbstractions.get_backend(gate.lifecycle_status) == backend ||
        throw(ArgumentError(
            "checkerboard open-gate parents belong to different backends"
        ))
    return backend
end


KernelAbstractions.get_backend(gate::_CheckerboardNoLifecycleOpenGate) =
    KernelAbstractions.get_backend(gate.program_status)

_checkerboard_gate_storage(gate) = KernelAbstractions.allocate(
    KernelAbstractions.get_backend(gate), Bool, (1,))

function Adapt.adapt_structure(to, gate::_CheckerboardOpenGate)
    return _CheckerboardOpenGate(
        Adapt.adapt(to, gate.program_status),
        Adapt.adapt(to, gate.lifecycle_status),
    )
end

function Adapt.adapt_structure(to, gate::_CheckerboardNoLifecycleOpenGate)
    return _CheckerboardNoLifecycleOpenGate(
        Adapt.adapt(to, gate.program_status)
    )
end

function _checkerboard_open_gate(state::CheckerboardExecutionState)
    workspace = state.lifecycle_workspace
    workspace isa NoLifecycleWorkspace &&
        return _CheckerboardNoLifecycleOpenGate(state.program_status)
    workspace isa LifecycleWorkspace || throw(ArgumentError(
        "checkerboard state has an unsupported lifecycle gate"
    ))
    return _CheckerboardOpenGate(state.program_status, workspace.status)
end

struct _ProgramStateCopyEvaluator{N} end
_ProgramStateCopyEvaluator() = _ProgramStateCopyEvaluator{1}()

@generated function (::_ProgramStateCopyEvaluator{N})(
        item::Int32, reads, parameters) where {N}
    names = N == 1 ? (:value,) :
        ntuple(index -> Symbol(:value_, index), N)
    values = ntuple(N) do index
        :(LocalMath.UniqueValue(something(
            @inbounds(getfield(reads, $index)[1].value))))
    end
    return :(NamedTuple{$names}(($(values...),)))
end

function _program_state_copy_law(destinations, sources, gate_field, space)
    length(destinations) == length(sources) || throw(ArgumentError(
        "program state copy ports have inconsistent arity"))
    port_count = length(destinations)
    1 <= port_count <= 4 || throw(ArgumentError(
        "program state copy stages require one to four ports"))
    all(array -> length(array) == length(space), destinations) &&
        all(array -> length(array) == length(space), sources) ||
        throw(ArgumentError(
            "program state copy ports disagree with their shared extent"))
    source_fields = map(source -> LocalMath.Field(space, eltype(source)), sources)
    destination_fields = map(
        destination -> LocalMath.Field(space, eltype(destination)), destinations)
    identity = LocalMath.IdentityRelation(space)
    control = gate_field === nothing ? LocalMath.Control() :
        LocalMath.Control(; gate = gate_field)
    access_names = ntuple(index -> Symbol(:source_, index), port_count)
    accesses = NamedTuple{access_names}(map(source_field ->
        LocalMath.Access(source_field, identity; required = true), source_fields))
    publications = ntuple(port_count) do index
        port = port_count == 1 ? :value : Symbol(:value_, index)
        LocalMath.Publication((LocalMath.FieldPublication(
            destination_fields[index], identity,
            LocalMath.PublicationValue(port)),),
            LocalMath.Unique(eltype(destinations[index])))
    end
    stage = LocalMath.Stage(
        space,
        accesses,
        publications,
        LocalMath.Evaluator(_ProgramStateCopyEvaluator{port_count}()),
        control,
        LocalMath.SourceOrigin(@__FILE__, @__LINE__;
            label = :program_state_bank_copy),
    )
    return LocalMath.LocalLaw(stage),
        (map(Pair, source_fields, sources)...,
            map(Pair, destination_fields, destinations)...)
end

function _program_state_copy_sequence(targets, values, gate_field)
    laws = Any[]
    bindings = Pair[]
    groups = Pair{Int,Vector{Int}}[]
    for index in eachindex(targets, values)
        isempty(targets[index].linear) && continue
        extent = length(targets[index].linear)
        group = findfirst(pair -> first(pair) == extent &&
            length(last(pair)) < 4, groups)
        if group === nothing
            push!(groups, extent => Int[index])
        else
            push!(last(groups[group]), index)
        end
    end
    spaces = Dict{Int,LocalMath.Space}()
    for (extent, indices) in groups
        space = get!(spaces, extent) do
            LocalMath.Space(extent)
        end
        destinations = Tuple(targets[index].linear for index in indices)
        sources = Tuple(values[index].linear for index in indices)
        law, leaf_bindings = _program_state_copy_law(
            destinations, sources, gate_field, space)
        push!(laws, law)
        append!(bindings, leaf_bindings)
    end
    isempty(laws) && throw(ArgumentError(
        "program state requires at least one nonempty scientific copy leaf"))
    return (; laws = Tuple(laws), bindings = Tuple(bindings))
end

_program_copy_linear(array::AbstractVector) = array
_program_copy_linear(array::AbstractArray) = reshape(array, length(array))

struct _ProgramStateCopyLeaf{A, L, X, S, B, D}
    path::Symbol
    original::A
    linear::L
    axes::X
    strides::S
    backend::B
    device::D
end

function _program_array_device_identity(array)
    backend = KernelAbstractions.get_backend(array)
    device = KernelAbstractions.device(backend)
    return (backend = typeof(backend), device = device)
end

function _program_state_copy_leaf(path::Symbol, array::AbstractArray)
    return _ProgramStateCopyLeaf(
        path,
        array,
        _program_copy_linear(array),
        axes(array),
        strides(array),
        KernelAbstractions.get_backend(array),
        _program_array_device_identity(array),
    )
end

function _program_state_copy_schema(state)
    Base.@nospecialize state
    leaves = Any[
        _program_state_copy_leaf(:ownership, state.ownership),
        _program_state_copy_leaf(:cell_kinds, state.cell_kinds),
        _program_state_copy_leaf(:cell_generations, state.cell_generations),
    ]
    for (index, tracker) in enumerate(state.trackers.values)
        if tracker isa CellMomentsState
            push!(leaves,
                _program_state_copy_leaf(
                    Symbol(:tracker_, index, :_first), tracker.first
                ))
            push!(leaves,
                _program_state_copy_leaf(
                    Symbol(:tracker_, index, :_second), tracker.second
                ))
        else
            tracker isa AbstractArray || error(
                "unsupported mutable tracker state $(typeof(tracker))"
            )
            push!(leaves,
                _program_state_copy_leaf(Symbol(:tracker_, index), tracker))
        end
    end
    for (bank_index, bank) in enumerate(state.relationships.banks)
        bank isa PackedRelationshipBank || error(
            "runtime relationship storage must be packed"
        )
        for (name, array) in pairs(_packed_relationship_science(bank))
            push!(leaves,
                _program_state_copy_leaf(
                    Symbol(:relationship_, bank_index, :_, name), array
                ))
        end
    end
    for (index, bank) in enumerate(state.descriptor_state.banks)
        push!(leaves,
            _program_state_copy_leaf(Symbol(:descriptor_, index), bank.values))
    end
    return Tuple(leaves)
end

_program_state_copy_leaves(state) = map(
    leaf -> leaf.path => leaf.linear, _program_state_copy_schema(state)
)

function _validate_program_copy_array(target, source, path; values = false)
    axes(target) == axes(source) && eltype(target) === eltype(source) &&
        typeof(target) === typeof(source) && strides(target) == strides(source) &&
        KernelAbstractions.get_backend(target) ==
            KernelAbstractions.get_backend(source) &&
        _program_array_device_identity(target) ==
            _program_array_device_identity(source) || throw(ArgumentError(
        "program state banks have incompatible copy schema at $path"
    ))
    values && Adapt.adapt(Array, target) != Adapt.adapt(Array, source) && throw(ArgumentError(
        "program state banks have incompatible canonical metadata at $path"
    ))
    return nothing
end

function _validate_relationship_copy_schema(destination, source)
    Adapt.adapt(Array, destination.slots) == Adapt.adapt(Array, source.slots) ||
        throw(ArgumentError(
        "program state banks have incompatible relationship slots"
    ))
    length(destination.banks) == length(source.banks) || throw(ArgumentError(
        "program state banks have incompatible relationship bank counts"
    ))
    for bank_index in eachindex(destination.banks, source.banks)
        target = destination.banks[bank_index]
        values = source.banks[bank_index]
        target isa PackedRelationshipBank && values isa PackedRelationshipBank ||
            throw(ArgumentError("runtime relationship storage must be packed"))
        keys(_packed_relationship_science(target)) ==
            keys(_packed_relationship_science(values)) || throw(ArgumentError(
            "program state banks have incompatible relationship payload arity"
        ))
        target_schema = _packed_relationship_schema(target)
        source_schema = _packed_relationship_schema(values)
        keys(target_schema) == keys(source_schema) || throw(ArgumentError(
            "program state banks have incompatible relationship metadata"
        ))
        for name in keys(target_schema)
            _validate_program_copy_array(
                getproperty(target_schema, name),
                getproperty(source_schema, name),
                Symbol(:relationship_, bank_index, :_, name);
                values = true,
            )
        end
    end
    return nothing
end

function _require_nonalias_program_copy_schema(leaves, label)
    for left in eachindex(leaves), right in (left + 1):length(leaves)
        first = leaves[left].original
        second = leaves[right].original
        (first === second || Base.mightalias(first, second)) && throw(
            ArgumentError(
                "$label aliases copy leaves $(leaves[left].path) and " *
                "$(leaves[right].path)"
            )
        )
    end
    return nothing
end

function _validated_program_state_copy_schema(destination, source)
    Base.@nospecialize destination source
    _validate_relationship_copy_schema(
        destination.relationships, source.relationships
    )
    targets = _program_state_copy_schema(destination)
    values = _program_state_copy_schema(source)
    length(targets) == length(values) || throw(ArgumentError(
        "program state banks have incompatible scientific leaf counts"
    ))
    for index in eachindex(targets, values)
        target = targets[index]
        value = values[index]
        target.path === value.path || throw(ArgumentError(
            "program state banks have incompatible semantic copy paths"
        ))
        _validate_program_copy_array(
            target.original, value.original, target.path
        )
    end
    _require_nonalias_program_copy_schema(targets, "destination bank")
    _require_nonalias_program_copy_schema(values, "source bank")
    return targets, values
end

function _validated_program_state_copy_leaves(destination, source)
    targets, values = _validated_program_state_copy_schema(destination, source)
    return map(leaf -> leaf.path => leaf.linear, targets),
        map(leaf -> leaf.path => leaf.linear, values)
end

function _require_distinct_program_state_copy_leaves(destination, source)
    Base.@nospecialize destination source
    targets, values = _validated_program_state_copy_schema(destination, source)
    for target in targets, value in values
            (target.original === value.original ||
                Base.mightalias(target.original, value.original)) && throw(
                ArgumentError(
                    "checkerboard state banks alias scientific copy leaves " *
                    "$(target.path) and $(value.path)"
                )
            )
    end
    return nothing
end

function _program_state_copy_declaration(workspace, gate_field)
    Base.@nospecialize workspace
    destination = workspace.alternate_state
    source = workspace.state
    targets, values = _validated_program_state_copy_schema(destination, source)
    return (
        _program_state_copy_sequence(values, targets, gate_field),
        _program_state_copy_sequence(targets, values, gate_field),
    )
end

function _validate_checkerboard_identity_order(plan::CheckerboardPlan)
    for color in 1:Int(plan.color_count)
        first_index = Int(plan.color_offsets[color])
        stop_index = Int(plan.color_offsets[color + 1]) - 1
        sites = @view plan.sites[first_index:stop_index]
        issorted(sites; lt = <) && all(>(Int32(0)), sites) ||
            throw(ArgumentError(
                "LocalMath candidate requires canonical increasing color sites"
            ))
    end
    return nothing
end

function _checked_checkerboard_capacity_mul(
        left::Integer, right::Integer, quantity::Symbol
    )
    try
        return Base.Checked.checked_mul(Int(left), Int(right))
    catch error
        error isa Union{OverflowError, InexactError} || rethrow()
        throw(ArgumentError(
            "LocalMath checkerboard $quantity exceeds the bounded Int capacity"
        ))
    end
end

function _checked_checkerboard_capacity_sub(
        left::Integer, right::Integer, quantity::Symbol
    )
    try
        value = Base.Checked.checked_sub(Int(left), Int(right))
        value >= 0 || throw(ArgumentError(
            "LocalMath checkerboard $quantity cannot be negative"
        ))
        return value
    catch error
        error isa Union{OverflowError, InexactError} || rethrow()
        throw(ArgumentError(
            "LocalMath checkerboard $quantity exceeds the bounded Int capacity"
        ))
    end
end

function _validate_checkerboard_stage_program_preparation(
        workspace::CheckerboardWorkspace,
        plan::CheckerboardPlan,
        host_plan::CheckerboardPlan,
        canonical_proposal_offsets,
        plan_mismatch::String,
    )
    _validate_checkerboard_identity_order(host_plan)
    host_plan.shape == plan.shape &&
        host_plan.periodic == plan.periodic &&
        host_plan.color_count == plan.color_count &&
        host_plan.maximum_color_size == plan.maximum_color_size ||
        throw(ArgumentError(plan_mismatch))
    state = workspace.state
    size(canonical_proposal_offsets) == size(state.program.proposal_offsets) ||
        throw(ArgumentError(
            "canonical and execution proposal-offset layouts disagree"
        ))
    maximum_batch = Int(plan.maximum_color_size)
    maximum_batch > 0 || throw(ArgumentError(
        "checkerboard candidate capacity must be positive"
    ))
    maximum_semantic_id = _checked_checkerboard_capacity_mul(
        Int(state.program.attempts_per_site),
        length(state.ownership),
        :maximum_semantic_identity,
    )
    maximum_semantic_id <= typemax(Int32) || throw(ArgumentError(
        "checkerboard semantic identities exceed the positive Int32 domain"
    ))
    candidate_epoch = _checkerboard_logical_topology_epoch(
        host_plan, canonical_proposal_offsets
    )
    candidate_epoch == state.program.topology_epoch &&
        candidate_epoch == workspace.alternate_state.program.topology_epoch ||
        throw(ArgumentError(
            "canonical and executing checkerboard topology contents disagree"
        ))
    backend = KernelAbstractions.get_backend(workspace.dispositions)
    return (; maximum_batch, candidate_epoch, backend)
end

struct _CheckerboardReportSite end
struct _CheckerboardReportBin end
struct _CheckerboardReportGate end

struct _CheckerboardReportClear end
@inline (::_CheckerboardReportClear)(item::Int32, reads, parameters) =
    (value = LocalMath.UniqueValue(UInt64(0)),)

@inline function _localmath_failure_status(
        next_mcs::Int32, stage::ProgramExecutionStage,
    )
    return ProgramStatus(
        ProgramStatusInvariant,
        next_mcs,
        stage,
        Int32(0),
        UInt64(0),
        Int32(0),
        Int32(0),
        LifecycleDetailEvaluationError,
        Int32(0),
        Int32(0),
        Int32(0),
    )
end

@kernel function _localmath_failure_bridge_kernel!(
        success, status, next_mcs::Int32, stage::ProgramExecutionStage,
    )
    item = @index(Global, Linear)
    if item == 1 &&
            (@inbounds status[1]).code === ProgramStatusSuccess &&
            !(@inbounds success[1])
        @inbounds status[1] = _localmath_failure_status(next_mcs, stage)
    end
end

function _enqueue_localmath_failure_bridge!(
        receipt::LocalMath.ExecutionReceipt, parent, status,
        next_mcs::Integer, stage::ProgramExecutionStage,
    )
    gate = LocalMath.success_gate(receipt, parent)
    backend = KernelAbstractions.get_backend(status)
    _localmath_failure_bridge_kernel!(backend)(
        gate, status, Int32(next_mcs), stage; ndrange = 1)
    return receipt
end

struct _CheckerboardReportEvaluator end
@inline function (::_CheckerboardReportEvaluator)(
        item::Int32, reads, parameters,
    )
    disposition = something(@inbounds(reads[1][1].value))
    accepted = disposition == _PROGRAM_CHECKERBOARD_ACCEPTED
    rejected = disposition == _PROGRAM_CHECKERBOARD_CONFLICT ||
        disposition == _PROGRAM_CHECKERBOARD_CONSTRAINT ||
        disposition == _PROGRAM_CHECKERBOARD_ENERGY
    null = disposition == _PROGRAM_CHECKERBOARD_NULL
    constraint = disposition == _PROGRAM_CHECKERBOARD_CONSTRAINT
    energy = disposition == _PROGRAM_CHECKERBOARD_ENERGY
    return (counts = (
        LocalMath.RoutedContribution(Int32(1), UInt64(accepted)),
        LocalMath.RoutedContribution(Int32(2), UInt64(rejected)),
        LocalMath.RoutedContribution(Int32(3), UInt64(null)),
        LocalMath.RoutedContribution(Int32(4), UInt64(constraint)),
        LocalMath.RoutedContribution(Int32(5), UInt64(energy)),
    ),)
end

struct _CheckerboardAcceptanceSite end
struct _CheckerboardAcceptanceStatus end
struct _CheckerboardAcceptanceGate end

struct _CheckerboardAcceptanceEvaluator end
@inline function (::_CheckerboardAcceptanceEvaluator)(
        item::Int32, reads, parameters,
    )
    disposition = something(@inbounds(reads[1][1].value))
    semantic = something(@inbounds(reads[2][1].value))
    next_mcs = parameters[2]
    failed = disposition == _PROGRAM_CHECKERBOARD_NONFINITE ||
        disposition == _PROGRAM_CHECKERBOARD_ZERO_T_DRIVE
    code = disposition == _PROGRAM_CHECKERBOARD_NONFINITE ?
        ProposalAcceptanceNonfinite : ProposalAcceptanceZeroTemperatureDrive
    status = _acceptance_failure_status(code, next_mcs, semantic)
    return (status = LocalMath.RoutedResolutionValue(
        Int32(1), semantic, status, failed),)
end

function _prepare_localmath_checkerboard_initialization(
        workspace, validated, gates, queue_mcs_capacity::Integer,
    )
    bins = LocalMath.Space(_CheckerboardReportBin, 5)
    gate_space = LocalMath.Space(_CheckerboardReportGate, 1)
    report = LocalMath.Field(bins, UInt64)
    external_gate = LocalMath.Field(gate_space, Bool)
    validated_gate = LocalMath.Field(gate_space, Bool)
    bin_identity = LocalMath.IdentityRelation(bins)
    gate_identity = LocalMath.IdentityRelation(gate_space)
    gate_stage = LocalMath.Stage(
        gate_space,
        (gate = LocalMath.Access(external_gate, gate_identity),),
        (LocalMath.Publication((LocalMath.FieldPublication(
            validated_gate, gate_identity,
            LocalMath.PublicationValue(:gate)),), LocalMath.Unique(Bool)),),
        LocalMath.Evaluator(_CheckerboardAcceptedGateCopy()),
        LocalMath.Control(),
        LocalMath.SourceOrigin(@__FILE__, @__LINE__;
            label = :checkerboard_report_gate),
    )
    clear_stage = LocalMath.Stage(
        bins, NamedTuple(),
        (LocalMath.Publication((LocalMath.FieldPublication(
            report, bin_identity, LocalMath.PublicationValue(:value)),),
            LocalMath.Unique(UInt64)),),
        LocalMath.Evaluator(_CheckerboardReportClear()),
        LocalMath.Control(; gate = validated_gate),
        LocalMath.SourceOrigin(@__FILE__, @__LINE__;
            label = :checkerboard_report_reset),
    )
    state_initialization = _program_state_copy_declaration(
        workspace, validated_gate)
    return map(state_initialization, gates) do initialization, gate
        clear_law = LocalMath.sequence(
            LocalMath.LocalLaw(gate_stage), initialization.laws...,
            LocalMath.LocalLaw(clear_stage))
        LocalMath.prepare(clear_law, initialization.bindings...,
            report => workspace.report,
            external_gate => gate,
            validated_gate => _checkerboard_gate_storage(gate);
            backend = validated.backend,
            lease_capacity = Int(queue_mcs_capacity),
        )
    end
end

function _prepare_core_checkerboard_mechanics(
        workspace, validated, queue_mcs_capacity, canonical_stage_plan)
    state = workspace.state
    maximum_batch = Int32(validated.maximum_batch)
    gates = (
        _checkerboard_open_gate(workspace.state),
        _checkerboard_open_gate(workspace.alternate_state),
    )
    initialization = _prepare_localmath_checkerboard_initialization(
        workspace, validated, gates, queue_mcs_capacity)
    lifecycle_reductions = _prepare_localmath_lifecycle_reductions(
        workspace, validated.backend, validated.candidate_epoch,
        queue_mcs_capacity)
    canonical_stage_plan isa StageExecutionPlan || throw(ArgumentError(
        "checkerboard preparation requires the Core-owned stage plan"))
    stage_boundaries = _prepare_checkerboard_stage_boundaries(
        workspace, canonical_stage_plan, validated.backend,
        queue_mcs_capacity)
    return (; clear_report = initialization,
        stage_boundaries, lifecycle_reductions, gates)
end

function _prepare_localmath_checkerboard_mechanics(
        workspace::CheckerboardWorkspace;
        queue_mcs_capacity::Integer = 12,
        canonical_plan = nothing,
        canonical_proposal_offsets = workspace.state.program.proposal_offsets,
        canonical_stage_plan = nothing,
    )
    state = workspace.state
    plan = state.program.checkerboard_plan
    host_plan = canonical_plan === nothing ? plan : canonical_plan
    validated = _validate_checkerboard_stage_program_preparation(
        workspace,
        plan,
        host_plan,
        canonical_proposal_offsets,
        "host and adapted checkerboard mechanical capacities disagree",
    )
    return _prepare_core_checkerboard_mechanics(
        workspace, validated, queue_mcs_capacity, canonical_stage_plan)
end

struct _CheckerboardClaimSite end
struct _CheckerboardClaimOwner end
struct _CheckerboardClaimGate end

struct _CheckerboardClaimResolver end
@inline function (::_CheckerboardClaimResolver)(item::Int32, reads, parameters)
    owners = something(@inbounds(reads[1][1].value))
    priority = something(@inbounds(reads[2][1].value))
    semantic = something(@inbounds(reads[3][1].value))
    accepted = something(@inbounds(reads[4][1].value)) ==
        _PROGRAM_CHECKERBOARD_ACCEPTED
    return (winner = (
        LocalMath.ResolutionValue(priority, semantic, semantic,
            accepted && @inbounds(owners[1]) > 0),
        LocalMath.ResolutionValue(priority, semantic, semantic,
            accepted && @inbounds(owners[2]) > 0),
    ),)
end

struct _CheckerboardClaimConjunction end
@inline function (::_CheckerboardClaimConjunction)(
        item::Int32, reads, parameters,
    )
    owners = something(@inbounds(reads[1][1].value))
    winners = @inbounds reads[2]
    semantic = something(@inbounds(reads[3][1].value))
    disposition = something(@inbounds(reads[4][1].value))
    accepted = disposition == _PROGRAM_CHECKERBOARD_ACCEPTED
    first = @inbounds winners[1]
    second = @inbounds winners[2]
    selected = accepted &&
        (@inbounds(owners[1]) <= 0 ||
            (first.present && first.value == semantic)) &&
        (@inbounds(owners[2]) <= 0 ||
            (second.present && second.value == semantic))
    result = selected ? disposition :
        (disposition == _PROGRAM_CHECKERBOARD_ACCEPTED ?
            _PROGRAM_CHECKERBOARD_CONFLICT : disposition)
    return (disposition = LocalMath.UniqueValue(result),)
end

@inline function _checkerboard_state_with_science(
        state,
        ownership,
        cell_kinds,
        cell_generations,
        trackers,
        relationships,
        descriptor_state,
        lifecycle_workspace,
    )
    program_status = lifecycle_workspace isa LifecycleWorkspace ?
                     lifecycle_workspace.status : state.program_status
    return CheckerboardExecutionState(
        state.program,
        ownership,
        cell_kinds,
        cell_generations,
        trackers,
        relationships,
        descriptor_state,
        lifecycle_workspace,
        state.lifecycle_control,
        program_status,
        state.parameters,
        state.seed,
        state.replica,
        state.repeat,
        state.mcs,
    )
end
