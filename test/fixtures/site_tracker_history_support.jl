using Test
import CorePotts
isdefined(@__MODULE__, :site_sum_runtime) || include("site_sum_support.jl")
isdefined(@__MODULE__, :_history_sample_fixture) || include("history_sample_support.jl")

function scheduled_history_tracker_runtime(
        engine; cadence = CorePotts.PeriodicMCSCadence, cadence_value = 2,
        constraint = CorePotts.LiteralExpression(false), initial_samples = nothing, absolute_tolerance = 0.0f0,
        quantity = Val(:site_sum), tracker_builder = nothing, backend = CorePotts.CPUProgramBackend()
    )
    C = CorePotts
    (; layout, source, history, descriptor) = _history_sample_fixture(:site, (6, 6), 2)
    sampling = C.CompiledStageDescriptor(
        descriptor.condition, descriptor.value,
        C.ShiftAppendEffect(history, source, 3; cadence, cadence_value), descriptor.stage,
        descriptor.access, descriptor.support, descriptor.source_handle, descriptor.buffer_slot
    )
    stage_plan = C.StageExecutionPlan(
        (),
        (C.StageDescriptorGroup([scheduled_site_sum_assignment(source)]), C.StageDescriptorGroup([sampling])),
        (), 0, 1, "scheduled-history-site-trackers"
    )
    reads = (source, C.history_sample_handle(stage_plan, layout, history, 0), C.history_sample_handle(stage_plan, layout, history, 1))
    keys = ntuple(index -> C.QualifiedTrackerKey(quantity, index), 3)
    descriptors = map(keys, reads) do key, handle
        expression = C.OperationExpression(C.operation_callable(Val(:iteration_bound_state_value), v"1.0.0"), C.StateExpression(handle))
        tracker_builder === nothing ? C.SiteSumTracker(Float32, key, expression; absolute_tolerance) : tracker_builder(key, expression)
    end
    tracker_plan = C.TrackerExecutionPlan((C.OwnershipCountTracker(), C.DenseScalarTrackerGroup(collect(descriptors))), "history-site-trackers")
    reject = C.ProposalDescriptor(
        C.StaticEvaluator(constraint),
        C.ResourceAccess((), (), C.EmptyFootprint(), C.EmptyFootprint(), C.NoWriteAccess()),
        C.DescriptorSupport(true, true, true, true), (), (), C.ProposalConstraintRole(), 1
    )
    descriptor_plan = C.DescriptorExecutionPlan(
        (C.ProposalDescriptorGroup([reject], (), (), :unsplit),),
        layout, C.WorkspaceLayout(C.WorkspaceSchema[]), (), Any[:history_source], 0,
        "history-source-tracker-state", C.HamiltonianDomainResources(0, 0)
    )
    program = test_program(engine; descriptor_plan, stage_plan, tracker_plan, scalar_type = Float32, backend)
    ownership = fill(Int32(-1), 6, 6)
    ownership[1:2] .= 1
    ownership[3] = 2
    values = map(layout.entries) do entry
        if entry.schema.domain === :site
            return ones(Float32, 6, 6)
        end
        initial_samples === nothing || return copy(initial_samples)
        samples = fill(5.0f0, 6, 6, 2)
        samples[:, :, 2] .= 10.0f0
        return samples
    end
    initial = C.ProgramInitialState(
        ownership, Int16[2, 2, 0]; scalar_type = Float32,
        descriptor_state = C.allocate_auxiliary_state(layout, values)
    )
    runtime = C.initialize_program(program, initial, Float32[], UInt64(0x3826), UInt32(1))
    return (; runtime, source, history, reads, descriptors, keys)
end
