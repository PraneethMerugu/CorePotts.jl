#!/usr/bin/env julia

# Reproducible compiler-shape evidence for prepared lifecycle runtime
# boundaries. Raw IR, payload, allocation, and timing values are longitudinal
# evidence, never machine-independent pass/fail limits.

import CorePotts
import KernelAbstractions
import LocalMath
import SHA
import TOML

include(joinpath(@__DIR__, "corepotts_flagship.jl"))

function _boundary_call_count(value)
    value isa Expr || return 0
    here = value.head in (:call, :invoke, :foreigncall) ? 1 : 0
    return here + sum(_boundary_call_count, value.args; init = 0)
end

function _any_syntax_class(value)
    value isa Union{Core.GotoNode, Core.GotoIfNot, Core.ReturnNode} &&
        return "non_value_control"
    value isa Core.PhiNode && return "phi"
    value isa Core.PhiCNode && return "phi_c"
    value isa Core.PiNode && return "pi"
    value isa Core.UpsilonNode && return "upsilon"
    value isa Expr && value.head in (:call, :invoke, :foreigncall) &&
        return "call_expression"
    value isa Expr && value.head in (:new, :splatnew) &&
        return "allocation_expression"
    return "other"
end

function _payload_record(name, value, origin, field_origins)
    return Dict{String, Any}(
        "name" => name,
        "type" => string(typeof(value)),
        "summary_bytes" => Base.summarysize(value),
        "isbits" => isbitstype(typeof(value)),
        "semantic_origin" => origin,
        "field_origins" => field_origins,
    )
end

function _typed_boundary_record(
        measured, names, arguments, origins, field_origins;
        role, signature,
    )
    length(names) == length(arguments) == length(origins) ==
        length(field_origins) || error(
        "compiler-boundary payload provenance does not match its arguments",
    )
    typed_results = measured.value
    info, return_type = only(typed_results)
    any_indices = info.ssavaluetypes isa Vector ?
        findall(==(Any), info.ssavaluetypes) : Int[]
    any_syntax = Dict{String, Int}()
    for index in any_indices
        syntax = _any_syntax_class(info.code[index])
        any_syntax[syntax] = get(any_syntax, syntax, 0) + 1
    end
    payload = collect(map(
        _payload_record, names, arguments, origins, field_origins,
    ))
    return Dict{String, Any}(
        "role" => role,
        "signature" => signature,
        "measurement" => "optimized_code_typed_fallback",
        "typed_statements" => length(info.code),
        "typed_calls" => sum(_boundary_call_count, info.code; init = 0),
        "any_argument_slots" => info.slottypes === nothing ? -1 :
            count(==(Any), info.slottypes),
        "any_ssa_total" => length(any_indices),
        "any_ssa_syntax" => any_syntax,
        "return_type" => string(return_type),
        "return_is_concrete" => isconcretetype(return_type),
        "typed_method_matches" => length(typed_results),
        "analysis_seconds" => measured.time,
        "analysis_allocated_bytes" => measured.bytes,
        "aggregate_payload_summary_bytes" => Base.summarysize(arguments),
        "sum_argument_summary_bytes" => sum(
            field["summary_bytes"] for field in payload
        ),
        "payload" => payload,
    )
end

function _host_boundary_record(
        function_value, names, arguments, origins, field_origins;
        role, signature,
    )
    measured = @timed Base.code_typed(
        function_value, Tuple{map(typeof, arguments)...}; optimize = true,
    )
    return _typed_boundary_record(
        measured, names, arguments, origins, field_origins; role, signature,
    )
end

function _kernel_boundary_record(
        kernel, names, arguments, origins, field_origins;
        role, signature,
    )
    measured = @timed KernelAbstractions.ka_code_typed(
        kernel, Tuple{map(typeof, arguments)...};
        ndrange = 1, optimize = true,
    )
    return _typed_boundary_record(
        measured, names, arguments, origins, field_origins; role, signature,
    )
end

function _lifecycle_boundary_runtime(engine)
    fixture = _flagship_fixture()
    program = CorePotts.CompiledPottsProgram(
        fixture.program.domain,
        fixture.program.proposal_offsets,
        fixture.program.kind_count,
        fixture.program.temperature,
        fixture.program.attempts_per_site,
        fixture.program.parameter_defaults,
        fixture.program.relationships,
        fixture.program.tracker_plan,
        fixture.program.descriptor_plan,
        fixture.program.stage_plan,
        engine,
        fixture.program.backend,
        "compiler-lifecycle-runtime-boundaries-v1";
        lifecycle_plan = fixture.program.lifecycle_plan,
    )
    return CorePotts.initialize_program(
        program,
        fixture.initial,
        Float64[],
        UInt64(0x6c6966656379636c),
        UInt32(1),
    )
end

function _owner_transfer_arguments()
    runtime = _lifecycle_boundary_runtime(
        CorePotts.SequentialProgramEngine(),
    )
    workspace = runtime.lifecycle_workspace
    copyto!(workspace.staged_ownership, runtime.ownership)
    copyto!(workspace.staged_cell_kinds, runtime.cell_kinds)
    copyto!(workspace.staged_cell_generations, runtime.cell_generations)
    CorePotts.copyto_tracker_state!(
        workspace.staged_trackers, runtime.trackers,
    )
    CorePotts.copyto_auxiliary_state!(
        workspace.staged_descriptor_state, runtime.descriptor_state,
    )
    source = CorePotts.tracker_source_view(
        runtime.program, workspace.staged_ownership;
        parameters = runtime.parameters,
        descriptor_state = workspace.staged_descriptor_state,
    )
    recipe = CorePotts._ownership_transfer_recipe(
        runtime, runtime.program.lifecycle_plan,
    )
    state = CorePotts._lifecycle_owner_change_state(
        CorePotts.HostLifecycleExecution(), runtime, workspace,
    )
    linear = LinearIndices(runtime.ownership)[3, 3]
    return (
        CorePotts.HostLifecycleExecution(), recipe, state, source,
        linear, Int32(-1),
    )
end


function _relationship_boundary_runtime(;
        destination_kind = 4,
        relationship_rule_count = 1,
    )
    descriptor = _flagship_descriptor(
        ; effect = CorePotts.TransitionCellLifecycleEffect,
        destination_kind,
        relationship_rule_count,
    )
    relationship_rules = CorePotts.LifecycleRelationshipRule[
        CorePotts.LifecycleRelationshipRule(
            Int32(1),
            CorePotts.RemoveIncompatibleLifecycleRelationship,
            Int16(destination_kind),
            Int16(3),
        )
        for _ in 1:relationship_rule_count
    ]
    lifecycle_plan = CorePotts.LifecycleExecutionPlan(
        [descriptor],
        CorePotts.LifecycleEvaluatorStorage(
            Any[CorePotts.StaticEvaluator(CorePotts.LiteralExpression(true))],
            [:lifecycle_trigger],
        ),
        CorePotts.LifecycleStateRuleStorage(Any[]),
        relationship_rules,
        (),
        NTuple{2, Int16}[],
        CorePotts.LifecycleRelationStorage((), Val(2)),
        CorePotts.StablePriorityLifecycleConflicts,
        3,
        3,
        1,
        0,
        falses(5),
    )
    schema = CorePotts.RelationshipStoreSchema(2, 2)
    offsets = Int8[
        1 -1 0 0
        0 0 1 -1
    ]
    domain = CorePotts._standard_cartesian_ownership_domain(
        (6, 6), (true, true), 5, 1,
        Bool[true, false, false, false, false],
    )
    program = CorePotts.CompiledPottsProgram(
        domain,
        offsets,
        5,
        CorePotts.CompiledScalar(3.0f0),
        1,
        Float32[],
        CorePotts.RelationshipStorage((schema,)),
        CorePotts.TrackerExecutionPlan(
            (CorePotts.OwnershipCountTracker(),),
            "compiler-relationship-boundary-tracker-v1",
        ),
        _empty_descriptor_plan(),
        CorePotts.StageExecutionPlan(),
        CorePotts.CheckerboardProgramEngine(),
        CorePotts.CPUProgramBackend(),
        "compiler-relationship-boundary-v1";
        lifecycle_plan,
        checkerboard_plan = CorePotts.CheckerboardPlan(domain, offsets),
    )
    ownership = zeros(Int32, 6, 6)
    ownership[1] = 1
    ownership[2] = 2
    ownership[3] = 3
    kinds = Int16[2, 3, 5]
    generations = UInt32[1, 1, 1]
    relationships = CorePotts.ProgramRelationshipState(Float32, 2, 3, 2)
    CorePotts.apply_relationship_requests!(
        relationships,
        kinds,
        generations,
        schema,
        [
            CorePotts.CreateRelationshipRequest(1, 2; identity = 1),
            CorePotts.CreateRelationshipRequest(1, 3; identity = 2),
        ],
    )
    initial = CorePotts.ProgramInitialState(
        ownership,
        kinds;
        scalar_type = Float32,
        cell_generations = generations,
        relationships = CorePotts.RelationshipStorage((relationships,)),
    )
    return CorePotts.initialize_program(
        program, initial, Float32[], UInt64(0x51a7e), UInt32(1),
    )
end

function _relationship_boundary_arguments(; kwargs...)
    runtime = _relationship_boundary_runtime(; kwargs...)
    execution = CorePotts._checkerboard_core(runtime.engine_workspace)
    backend_state = execution.alternate_state
    workspace = backend_state.lifecycle_workspace
    recipe = CorePotts._lifecycle_relationship_recipe(
        backend_state.program.lifecycle_plan,
    )
    state = CorePotts._lifecycle_relationship_state(workspace)
    cadence = CorePotts._lifecycle_cadence_control(
        backend_state.lifecycle_control,
    )
    return (recipe, state, cadence, Val(:remove_incompatible))
end

function _kernel_method_call(kernel, arguments)
    ndrange, _, iterspace, dynamic = KernelAbstractions.launch_config(
        kernel, 1, nothing,
    )
    block = first(KernelAbstractions.blocks(iterspace))
    context = KernelAbstractions.mkcontext(
        kernel, block, ndrange, iterspace, dynamic,
    )
    return kernel.f, (context, arguments...)
end

function _observed_identity_count(values)
    representatives = Any[]
    for value in values
        any(existing -> existing === value, representatives) ||
            push!(representatives, value)
    end
    return length(representatives)
end

function _specialization_variant(
        label, function_value, arguments, baseline_instance, baseline_typed,
    )
    argument_types = Tuple{map(typeof, arguments)...}
    typed_results = Base.code_typed(
        function_value, argument_types; optimize = true, debuginfo = :none,
    )
    instances = Base.method_instances(
        function_value, argument_types, Base.get_world_counter(),
    )
    instance = only(instances)
    info, return_type = only(typed_results)
    baseline_info, baseline_return = baseline_typed
    same_typed_ir = info.code == baseline_info.code &&
        info.ssavaluetypes == baseline_info.ssavaluetypes &&
        return_type == baseline_return
    method = instance.def
    return Dict{String, Any}(
        "label" => label,
        "boundary_argument_types" =>
            collect(string.(map(typeof, Base.tail(arguments)))),
        "typed_method_matches" => length(typed_results),
        "method_instance_matches" => length(instances),
        "specialization_signature" => string(instance.specTypes),
        "same_method_instance_as_baseline" => instance === baseline_instance,
        "same_method_definition_as_baseline" =>
            method === baseline_instance.def,
        "typed_ir_equal_to_baseline" => same_typed_ir,
        "typed_statements" => length(info.code),
        "typed_calls" => sum(_boundary_call_count, info.code; init = 0),
        "return_type" => string(return_type),
        "method" => Dict(
            "name" => string(method.name),
            "module" => string(method.module),
            "file" => string(method.file),
            "line" => method.line,
            "declared_signature" => string(method.sig),
        ),
        "_instance" => instance,
    )
end

function _relationship_specialization_report(kernel)
    baseline_arguments = _relationship_boundary_arguments()
    value_arguments = _relationship_boundary_arguments(destination_kind = 3)
    count_arguments = _relationship_boundary_arguments(
        relationship_rule_count = 2,
    )
    incident_arguments = (
        baseline_arguments[1:3]..., Val(:remove_incident),
    )
    baseline_types = map(typeof, baseline_arguments)
    map(typeof, value_arguments) == baseline_types || error(
        "relationship numerical values changed the kernel argument types",
    )
    map(typeof, count_arguments) == baseline_types || error(
        "relationship recipe count changed the kernel argument types",
    )
    map(typeof, incident_arguments[1:3]) == baseline_types[1:3] || error(
        "relationship action probe changed a non-action argument type",
    )

    function_value, baseline_call = _kernel_method_call(
        kernel, baseline_arguments,
    )
    _, value_call = _kernel_method_call(kernel, value_arguments)
    _, count_call = _kernel_method_call(kernel, count_arguments)
    _, incident_call = _kernel_method_call(kernel, incident_arguments)
    baseline_type_tuple = Tuple{map(typeof, baseline_call)...}
    baseline_instance = only(Base.method_instances(
        function_value, baseline_type_tuple, Base.get_world_counter(),
    ))
    baseline_typed = only(Base.code_typed(
        function_value, baseline_type_tuple;
        optimize = true, debuginfo = :none,
    ))
    variants = [
        _specialization_variant(
            "baseline_remove_incompatible", function_value, baseline_call,
            baseline_instance, baseline_typed,
        ),
        _specialization_variant(
            "numerical_value_change", function_value, value_call,
            baseline_instance, baseline_typed,
        ),
        _specialization_variant(
            "relationship_rule_count_two", function_value, count_call,
            baseline_instance, baseline_typed,
        ),
        _specialization_variant(
            "remove_incident_action_family", function_value, incident_call,
            baseline_instance, baseline_typed,
        ),
    ]
    instances = [pop!(variant, "_instance") for variant in variants]
    return Dict{String, Any}(
        "scope" => "explicitly exercised variants in this fresh process",
        "observed_unique_method_instances" =>
            _observed_identity_count(instances),
        "observed_method_definitions" =>
            _observed_identity_count(map(instance -> instance.def, instances)),
        "value_and_count_reuse_baseline_instance" =>
            instances[2] === instances[1] && instances[3] === instances[1],
        "action_families_use_distinct_instances" =>
            instances[4] !== instances[1],
        "variants" => variants,
    )
end

function _file_fingerprint(path)
    isfile(path) || return Dict("path" => path, "sha256" => "missing")
    return Dict(
        "path" => path,
        "sha256" => bytes2hex(SHA.sha256(read(path))),
    )
end

function _dependency_record(package)
    return Dict(
        "version" => string(Base.pkgversion(package)),
        "source_path" => pkgdir(package),
    )
end

function _boundary_environment(revision_label, evidence_reason)
    project = something(Base.active_project(), "")
    manifest = isempty(project) ? "" : joinpath(dirname(project), "Manifest.toml")
    return Dict{String, Any}(
        "revision_label" => revision_label,
        "evidence_method" => "optimized_code_typed_fallback",
        "kaimon_unavailable_reason" => evidence_reason,
        "project" => _file_fingerprint(project),
        "manifest" => _file_fingerprint(manifest),
        "corepotts" => _dependency_record(CorePotts),
        "localmath" => _dependency_record(LocalMath),
        "kernelabstractions" => _dependency_record(KernelAbstractions),
    )
end

function lifecycle_runtime_boundary_report(;
        revision_label = "not_supplied",
        evidence_reason = "not_supplied",
    )
    owner = _owner_transfer_arguments()
    relationship = _relationship_boundary_arguments()
    proposal = (
        CorePotts.ProposalEvaluation(
            0.25f0, 0.0f0, 0.0f0, 0.0f0, true,
        ),
        1.0f0,
    )
    relationship_kernel =
        CorePotts._stage_lifecycle_relationships_backend_kernel!(
            KernelAbstractions.CPU(), 1,
        )
    empty_origins(count) = ntuple(_ -> Dict{String, String}(), count)
    return Dict{String, Any}(
        "schema_version" => 1,
        "profile" => "corepotts_lifecycle_runtime_boundaries",
        "environment" => _boundary_environment(
            revision_label, evidence_reason,
        ),
        "owner_transfer" => _host_boundary_record(
            CorePotts._stage_owner_change!,
            (
                "execution_mode", "recipe", "state", "tracker_source",
                "linear_index", "new_owner",
            ),
            owner,
            (
                "host lifecycle execution contract",
                "program shape, prepared tracker plan, and lifecycle ownership rules",
                "staged ownership/kinds/trackers/state and transaction status",
                "staged ownership, parameters, and descriptor state",
                "accepted lattice site",
                "accepted replacement owner",
            ),
            (
                Dict{String, String}(),
                Dict(
                    "shape" => "program.domain.shape",
                    "tracker_plan" => "program.lifecycle_tracker_plan prepared at initialization",
                    "ownership_rules" => "program.lifecycle_plan.ownership_rules",
                ),
                Dict(
                    "staged_ownership" => "lifecycle workspace staged ownership",
                    "staged_cell_kinds" => "lifecycle workspace staged cell kinds",
                    "staged_trackers" => "lifecycle workspace staged tracker values",
                    "staged_descriptor_state" => "lifecycle workspace staged descriptor state",
                    "status" => "lifecycle transaction status",
                ),
                Dict{String, String}(),
                Dict{String, String}(),
                Dict{String, String}(),
            );
            role = "changed prepared owner-transfer boundary",
            signature = "_stage_owner_change!",
        ),
        "relationship_staging" => _kernel_boundary_record(
            relationship_kernel,
            ("recipe", "state", "cadence", "action"),
            relationship,
            (
                "prepared lifecycle descriptors and relationship rules",
                "selected request order and staged relationship transaction state",
                "lifecycle due counters",
                "bounded backend relationship action family",
            ),
            (
                Dict(
                    "descriptors" => "program.lifecycle_plan.descriptors",
                    "relationship_rules" => "program.lifecycle_plan.relationship_rules",
                ),
                Dict(
                    "descriptor" => "lifecycle workspace request descriptors",
                    "anchor" => "lifecycle workspace request anchors",
                    "selection" => "lifecycle workspace selected request order",
                    "staged_cell_kinds" => "lifecycle workspace staged cell kinds",
                    "staged_relationships" => "lifecycle workspace staged relationships",
                    "status" => "lifecycle transaction status",
                ),
                Dict("counters" => "backend lifecycle cadence counters"),
                Dict{String, String}(),
            );
            role = "changed prepared relationship-staging boundary",
            signature = "_stage_lifecycle_relationships_backend_kernel!",
        ),
        "relationship_specialization" =>
            _relationship_specialization_report(relationship_kernel),
        "unchanged_proposal_leaf" => _host_boundary_record(
            CorePotts._proposal_acceptance_result,
            ("evaluation", "temperature"),
            proposal,
            (
                "compiled proposal energy, drive, modifier, and constraint result",
                "compiled runtime temperature",
            ),
            empty_origins(2);
            role = "unchanged shared device-reachable proposal leaf control",
            signature = "_proposal_acceptance_result",
        ),
    )
end

function emit_lifecycle_runtime_boundary_report(
        report = lifecycle_runtime_boundary_report(); io::IO = stdout,
    )
    TOML.print(io, report; sorted = true)
    return nothing
end

function _boundary_argument(name, default)
    prefix = "--$name="
    argument = findfirst(startswith(prefix), ARGS)
    return argument === nothing ? default :
        split(ARGS[argument], "="; limit = 2)[2]
end

function _main_lifecycle_runtime_boundaries()
    emit_lifecycle_runtime_boundary_report(lifecycle_runtime_boundary_report(
        ; revision_label = _boundary_argument("revision-label", "not_supplied"),
        evidence_reason = _boundary_argument(
            "evidence-reason", "not_supplied",
        ),
    ))
end

abspath(PROGRAM_FILE) == (@__FILE__) &&
    _main_lifecycle_runtime_boundaries()
