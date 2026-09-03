# Logical snapshots, checkpoints, and exact continuation validation.

"""Independently owned logical state published at one settled MCS boundary."""
struct ProgramSnapshot{T <: AbstractFloat, N, R, D, TS}
    mcs::Int
    ownership::Array{Int32, N}
    cell_kinds::Vector{Int16}
    cell_generations::Vector{UInt32}
    trackers::TS
    relationships::R
    descriptor_state::D
end

"""
Return an independently owned copy of a logical snapshot's descriptor state.

The returned state may be inspected or transformed by a backend integration
without mutating the settled logical snapshot from which it was derived.
"""
function program_snapshot_descriptor_state(snapshot::ProgramSnapshot)
    state = snapshot.descriptor_state
    state isa AuxiliaryState || throw(ArgumentError(
        "the program snapshot descriptor state is not a CorePotts AuxiliaryState"
    ))
    return copy_auxiliary_state(state)
end

"""Checksummed exact-continuation payload for one compiled program identity."""
struct ProgramCheckpoint{S, P, E}
    schema::VersionNumber
    program_fingerprint::String
    snapshot::S
    parameters::P
    seed::UInt64
    replica::UInt32
    repeat::UInt32
    accepted::UInt64
    rejected::UInt64
    null_attempts::UInt64
    constraint_rejections::UInt64
    energy_rejections::UInt64
    retired_cells::UInt64
    extensions::E
    checksum::String
end

const _CORE_CHECKPOINT_CAPABILITY_SCHEMA = v"3.0.0"

function _exact_execution_contract(key::ProgramCapabilityKey)
    lifecycle = key.lifecycle
    component_state = key.component_state
    mechanisms = key.mechanisms
    return (
        engine = key.engine,
        backend = key.backend,
        device = key.device,
        dimension = key.dimension,
        topology = key.topology,
        scalar_type = string(key.scalar_type),
        math_policy = (
            math = key.math_policy.math,
            reductions = key.math_policy.reductions,
            bounds = key.math_policy.bounds,
        ),
        lifecycle = (
            family = lifecycle.family,
            effect_mask = lifecycle.effect_mask,
            division_variant_mask = lifecycle.division_variant_mask,
            relationship_action_mask = lifecycle.relationship_action_mask,
            state_action_masks = lifecycle.state_action_masks,
            fingerprint = lifecycle.fingerprint,
        ),
        component_state = (
            scope = component_state.scope,
            identities = component_state.identities,
            domains = component_state.domains,
            schema_fingerprint = component_state.schema_fingerprint,
        ),
        mechanisms = (
            proposal_fingerprint = mechanisms.proposal_fingerprint,
            descriptor_fingerprint = mechanisms.descriptor_fingerprint,
            stage_fingerprint = mechanisms.stage_fingerprint,
            relationship_fingerprint = mechanisms.relationship_fingerprint,
            tracker_fingerprint = mechanisms.tracker_fingerprint,
            checkerboard_fingerprint = mechanisms.checkerboard_fingerprint,
            rng_contract_version = mechanisms.rng_contract_version,
            rng_lowering_identity = mechanisms.rng_lowering_identity,
            code_identities = mechanisms.code_identities,
            authority = mechanisms.authority,
            support_family = mechanisms.support_family,
            exact_replay = mechanisms.exact_replay,
        ),
        environment = key.environment,
        replay = key.replay,
    )
end

function _core_checkpoint_capability_block(program::CompiledPottsProgram)
    key = program_capability_report(program).key
    return (
        schema = _CORE_CHECKPOINT_CAPABILITY_SCHEMA,
        execution_contract = _exact_execution_contract(key),
        rng = (
            contract_version = RNG_CONTRACT_VERSION,
            lowering_identity = RNG_LOWERING_IDENTITY,
        ),
    )
end

_checkpoint_execution_block(runtime) = nothing
function _owned_checkpoint_extensions(
        program, extensions, execution_block = nothing
    )
    extensions isa NamedTuple || throw(ArgumentError(
        "checkpoint extensions must be a named tuple"
    ))
    hasproperty(extensions, :CorePotts) && throw(ArgumentError(
        "checkpoint extension owner `CorePotts` is reserved"
    ))
    core_block = _core_checkpoint_capability_block(program)
    execution_block === nothing ||
        (core_block = merge(
            core_block, (; execution_lowering = execution_block)
        ))
    return merge(
        (CorePotts = core_block,),
        deepcopy(extensions),
    )
end

function _validate_checkpoint_capability(
        program::CompiledPottsProgram, extensions
    )
    extensions isa NamedTuple || throw(ArgumentError(
        "checkpoint extensions must be a named tuple"
    ))
    hasproperty(extensions, :CorePotts) || throw(ArgumentError(
        "checkpoint is missing its CorePotts exact-configuration identity"
    ))
    block = getproperty(extensions, :CorePotts)
    block isa NamedTuple &&
        all(
            name -> hasproperty(block, name),
            (:schema, :execution_contract, :rng),
        ) || throw(ArgumentError(
            "checkpoint has an incomplete CorePotts capability block"
        ))
    block.schema == _CORE_CHECKPOINT_CAPABILITY_SCHEMA || throw(ArgumentError(
        "unsupported CorePotts checkpoint capability schema"
    ))
    key = program_capability_report(program).key
    expected_rng = (
        contract_version = key.mechanisms.rng_contract_version,
        lowering_identity = key.mechanisms.rng_lowering_identity,
    )
    block.rng == expected_rng || throw(ArgumentError(
        "checkpoint RNG contract version or lowering identity mismatch"
    ))
    block.execution_contract == _exact_execution_contract(key) ||
        throw(ArgumentError(
            "checkpoint exact-configuration execution contract mismatch"
        ))
    return block
end

function _checkpoint_extension_payload(value::NamedTuple)
    return string(
        "named(",
        join((
            string(
                repr(name), "=>",
                _checkpoint_extension_payload(getproperty(value, name)),
            ) for name in keys(value)
        ), ','),
        ')',
    )
end

function _checkpoint_extension_payload(value::Tuple)
    return string(
        "tuple(",
        join((_checkpoint_extension_payload(item) for item in value), ','),
        ')',
    )
end

function _checkpoint_extension_payload(value::Pair)
    return string(
        "pair(",
        _checkpoint_extension_payload(first(value)), ',',
        _checkpoint_extension_payload(last(value)),
        ')',
    )
end

function _checkpoint_extension_payload(value::AbstractArray)
    return string(
        "array(", repr(typeof(value)), ';', repr(size(value)), ';',
        join((_checkpoint_extension_payload(item) for item in value), ','),
        ')',
    )
end

_checkpoint_extension_payload(value::Nothing) = "nothing"
_checkpoint_extension_payload(value::Missing) = "missing"
function _checkpoint_extension_payload(
        value::Union{Bool, Integer, AbstractFloat, Symbol, AbstractString,
                     VersionNumber, Enum}
    )
    return string(repr(typeof(value)), '(', repr(value), ')')
end

function _checkpoint_extension_payload(value)
    throw(ArgumentError(
        "checkpoint extension payloads must use deterministic logical values; " *
        "unsupported value type $(typeof(value))"
    ))
end

function _relationship_checkpoint_payload(state)
    return string(
        join(state.active, ','),
        ';', join(state.endpoint_a, ','),
        ';', join(state.endpoint_b, ','),
        ';', join(state.generation_a, ','),
        ';', join(state.generation_b, ','),
        ';', join((join(values, ',') for values in state.payload), '|'),
        ';', join(state.degree, ','),
        ';', join(vec(state.incident_edges), ','),
    )
end

_relationship_checkpoint_payload(states::RelationshipStorage) =
    join((_relationship_checkpoint_payload(state) for state in states), "||")

function _validate_runtime_relationships!(runtime)
    length(runtime.relationships) == length(runtime.program.relationships) ||
        throw(ArgumentError(
            "runtime relationship state and compiled schemas are misaligned"
        ))
    for slot in eachindex(runtime.relationships)
        validate_relationship_integrity(
            runtime.relationships[slot],
            runtime.program.relationships[slot],
            runtime.cell_kinds,
            runtime.cell_generations,
        )
    end
    return runtime
end

function _program_checkpoint_checksum(
        schema,
        fingerprint,
        snapshot,
        parameters,
        seed,
        replica,
        repeat,
        accepted,
        rejected,
        null_attempts,
        constraint_rejections,
        energy_rejections,
        retired_cells,
        extensions,
    )
    payload = string(
        schema, '\n',
        fingerprint, '\n',
        snapshot.mcs, '\n',
        size(snapshot.ownership), '\n',
        join(vec(snapshot.ownership), ','), '\n',
        join(snapshot.cell_kinds, ','), '\n',
        join(snapshot.cell_generations, ','), '\n',
        repr(snapshot.trackers), '\n',
        repr(snapshot.descriptor_state), '\n',
        _relationship_checkpoint_payload(snapshot.relationships), '\n',
        join(parameters, ','), '\n',
        seed, '\n',
        replica, '\n',
        repeat, '\n',
        accepted, '\n',
        rejected, '\n',
        null_attempts, '\n',
        constraint_rejections, '\n',
        energy_rejections, '\n',
        retired_cells, '\n',
        _checkpoint_extension_payload(extensions),
    )
    return bytes2hex(SHA.sha256(codeunits(payload)))
end

"""Capture a validated exact-replay checkpoint at a settled MCS boundary."""
function program_checkpoint(runtime; extensions = NamedTuple())
    runtime.settled || throw(ArgumentError(
        "a checkpoint requires a settled complete-MCS boundary"
    ))
    program_failed(runtime) && throw(ArgumentError(
        "a terminal failed runtime cannot be checkpointed"
    ))
    _validate_compiled_program_integrity(runtime.program)
    _require_program_replay_capability(
        runtime.capability_report;
        operation = :checkpoint,
    )
    schema = v"3.0.0"
    logical_snapshot = program_snapshot(runtime)
    trackers = encode_tracker_checkpoint(
        runtime.program.tracker_plan, runtime.trackers
    )
    descriptor_state = encode_auxiliary_state_checkpoint(
        runtime.program.descriptor_plan.state_layout,
        runtime.descriptor_state,
    )
    snapshot = ProgramSnapshot{
        eltype(runtime.parameters),
        ndims(runtime.ownership),
        typeof(logical_snapshot.relationships),
        typeof(descriptor_state),
        typeof(trackers),
    }(
        logical_snapshot.mcs,
        logical_snapshot.ownership,
        logical_snapshot.cell_kinds,
        logical_snapshot.cell_generations,
        trackers,
        logical_snapshot.relationships,
        descriptor_state,
    )
    parameters = copy(runtime.parameters)
    # Extension owners provide logical values, never functions or live solver
    # objects.  Validate before copying so one outer checksum owns the complete
    # cross-package checkpoint rather than layering a second codec around Core.
    _checkpoint_extension_payload(extensions)
    owned_extensions = _owned_checkpoint_extensions(
        runtime.program,
        extensions,
        _checkpoint_execution_block(runtime),
    )
    checksum = _program_checkpoint_checksum(
        schema,
        runtime.program.fingerprint,
        snapshot,
        parameters,
        runtime.seed,
        runtime.replica,
        runtime.repeat,
        runtime.accepted,
        runtime.rejected,
        runtime.null_attempts,
        runtime.constraint_rejections,
        runtime.energy_rejections,
        runtime.retired_cells,
        owned_extensions,
    )
    return ProgramCheckpoint(
        schema,
        runtime.program.fingerprint,
        snapshot,
        parameters,
        runtime.seed,
        runtime.replica,
        runtime.repeat,
        runtime.accepted,
        runtime.rejected,
        runtime.null_attempts,
        runtime.constraint_rejections,
        runtime.energy_rejections,
        runtime.retired_cells,
        owned_extensions,
        checksum,
    )
end

function _validate_checkpoint_execution_lowering(
        extensions, expected_execution
    )
    block = getproperty(extensions, :CorePotts)
    has_execution = hasproperty(block, :execution_lowering)
    if expected_execution === nothing
        has_execution && throw(ArgumentError(
            "checkerboard execution checkpoint cannot restore into a runtime without that execution graph"
        ))
        return nothing
    end
    has_execution || throw(ArgumentError(
        "checkerboard checkpoint is missing its current execution identity"
    ))
    execution = block.execution_lowering
    execution isa NamedTuple &&
        hasproperty(execution, :mechanism_identity) &&
        execution.mechanism_identity === expected_execution ||
        throw(ArgumentError(
            "checkpoint execution-lowering identity mismatch"
        ))
    return execution
end

function _validate_program_checkpoint(
        program::CompiledPottsProgram,
        checkpoint::ProgramCheckpoint,
        expected_execution,
    )
    _validate_compiled_program_integrity(program)
    _require_program_replay_capability(
        program; operation = :checkpoint_restore
    )
    checkpoint.schema == v"3.0.0" ||
        throw(ArgumentError("unsupported CorePotts checkpoint schema"))
    checkpoint.program_fingerprint == program.fingerprint ||
        throw(ArgumentError("checkpoint executable identity does not match"))
    expected = _program_checkpoint_checksum(
        checkpoint.schema,
        checkpoint.program_fingerprint,
        checkpoint.snapshot,
        checkpoint.parameters,
        checkpoint.seed,
        checkpoint.replica,
        checkpoint.repeat,
        checkpoint.accepted,
        checkpoint.rejected,
        checkpoint.null_attempts,
        checkpoint.constraint_rejections,
        checkpoint.energy_rejections,
        checkpoint.retired_cells,
        checkpoint.extensions,
    )
    expected == checkpoint.checksum ||
        throw(ArgumentError("checkpoint integrity checksum mismatch"))
    _validate_checkpoint_capability(program, checkpoint.extensions)
    _validate_checkpoint_execution_lowering(
        checkpoint.extensions, expected_execution
    )
    return checkpoint
end

function _public_checkpoint_execution_identity(checkpoint::ProgramCheckpoint)
    core_block = hasproperty(checkpoint.extensions, :CorePotts) ?
        checkpoint.extensions.CorePotts : nothing
    core_block === nothing && return nothing
    hasproperty(core_block, :execution_lowering) || return nothing
    execution = core_block.execution_lowering
    is_current_execution = execution isa NamedTuple &&
        hasproperty(execution, :mechanism_identity) &&
        execution.mechanism_identity ===
            _CHECKERBOARD_MECHANISM_IDENTITY
    is_current_execution || throw(ArgumentError(
        "checkpoint uses an obsolete or unsupported checkerboard execution identity"
    ))
    return execution.mechanism_identity
end

"""Validate checksum, schema, program identity, state, and exact execution contract."""
function validate_program_checkpoint(
        program::CompiledPottsProgram, checkpoint::ProgramCheckpoint
    )
    expected = _public_checkpoint_execution_identity(checkpoint)
    if program.engine isa CheckerboardProgramEngine
        expected === _CHECKERBOARD_MECHANISM_IDENTITY ||
            throw(ArgumentError(
                "checkerboard checkpoint uses an obsolete execution schema"
            ))
    end
    return _validate_program_checkpoint(program, checkpoint, expected)
end

function _restore_validated_program_checkpoint(
        program::CompiledPottsProgram, checkpoint::ProgramCheckpoint
    )
    descriptor_state = reconstruct_auxiliary_state(
        program.descriptor_plan.state_layout,
        checkpoint.snapshot.descriptor_state,
    )
    initial = ProgramInitialState(
        checkpoint.snapshot.ownership,
        checkpoint.snapshot.cell_kinds;
        scalar_type = eltype(program.parameter_defaults),
        cell_generations = checkpoint.snapshot.cell_generations,
        relationships = checkpoint.snapshot.relationships,
        descriptor_state,
    )
    return _materialize_program(
        program,
        initial,
        checkpoint.parameters,
        checkpoint.seed,
        checkpoint.replica;
        repeat = checkpoint.repeat,
        initial_mcs = checkpoint.snapshot.mcs,
        tracker_checkpoint = checkpoint.snapshot.trackers,
        counters = (
            accepted = checkpoint.accepted,
            rejected = checkpoint.rejected,
            null_attempts = checkpoint.null_attempts,
            constraint_rejections = checkpoint.constraint_rejections,
            energy_rejections = checkpoint.energy_rejections,
            retired_cells = checkpoint.retired_cells,
        ),
    )
end

"""Restore an exact-replay runtime after validating program and checkpoint identity."""
function restore_program_checkpoint(
        program::CompiledPottsProgram, checkpoint::ProgramCheckpoint
    )
    expected = _public_checkpoint_execution_identity(checkpoint)
    if program.engine isa CheckerboardProgramEngine
        expected === _CHECKERBOARD_MECHANISM_IDENTITY ||
            throw(ArgumentError(
                "checkerboard checkpoint uses an obsolete execution schema"
            ))
        return _restore_checkerboard_checkpoint(program, checkpoint)
    end
    validate_program_checkpoint(program, checkpoint)
    runtime = _restore_validated_program_checkpoint(program, checkpoint)
    runtime.engine_workspace isa CheckerboardWorkspace || return runtime
    return _prepare_checkerboard_execution(runtime)
end

function _accepted_copy_batch_bound(program::CompiledPottsProgram)
    plan = program.checkerboard_plan
    return plan isa CheckerboardPlan ?
           Int(plan.maximum_color_size) * Int(program.attempts_per_site) : 1
end
