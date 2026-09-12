module DownstreamCorePottsExtension

import CorePotts.CompilerSPI:
    AbstractTrackerDescriptor,
    AcceptedCommitTrackerVisibility,
    ClaimedOwnerExclusiveTrackerConcurrency,
    ConstantTrackerCost,
    DenseOwnerScalarStorage,
    DenseOwnerValueStorage,
    LatticeLinearTrackerCost,
    OwnerValueDelta,
    OwnershipTrackerSource,
    PersistTrackerCheckpoint,
    OldNewOwnerUpdateBound,
    TrackerContract,
    TrackerSupport,
    tracker_contract,
    tracker_ownership_delta,
    tracker_rebuild,
    tracker_recompute
import CorePotts.BackendSPI:
    CPUProgramBackend,
    SequentialProgramEngine,
    program_backend_name
import StaticArrays: SArray, SVector

struct TripleOccupancyTracker <: AbstractTrackerDescriptor end
struct InvalidDeltaTracker <: AbstractTrackerDescriptor end
struct NonfiniteDeltaTracker <: AbstractTrackerDescriptor end
struct InvalidOwnerValueTracker <: AbstractTrackerDescriptor end
struct NonconcreteOwnerValueTracker <: AbstractTrackerDescriptor end
struct InvalidScalarValueTracker <: AbstractTrackerDescriptor end

tracker_contract(::TripleOccupancyTracker) = TrackerContract(
    Val(:triple_occupancy),
    OwnershipTrackerSource(),
    DenseOwnerScalarStorage{Int32}(),
    AcceptedCommitTrackerVisibility(),
    ClaimedOwnerExclusiveTrackerConcurrency(),
    OldNewOwnerUpdateBound(),
    PersistTrackerCheckpoint(),
    TrackerSupport(true, true, true, true),
    ConstantTrackerCost(),
    LatticeLinearTrackerCost(),
)

tracker_contract(::InvalidDeltaTracker) = TrackerContract(
    Val(:invalid_delta),
    OwnershipTrackerSource(),
    DenseOwnerScalarStorage{Int32}(),
    AcceptedCommitTrackerVisibility(),
    ClaimedOwnerExclusiveTrackerConcurrency(),
    OldNewOwnerUpdateBound(),
    PersistTrackerCheckpoint(),
    TrackerSupport(true, true, true, true),
    ConstantTrackerCost(),
    LatticeLinearTrackerCost(),
)

tracker_contract(::NonfiniteDeltaTracker) = TrackerContract(
    Val(:nonfinite_delta), OwnershipTrackerSource(),
    DenseOwnerScalarStorage{Float64}(), AcceptedCommitTrackerVisibility(),
    ClaimedOwnerExclusiveTrackerConcurrency(), OldNewOwnerUpdateBound(),
    PersistTrackerCheckpoint(), TrackerSupport(true, true, true, true),
    ConstantTrackerCost(), LatticeLinearTrackerCost(),
)

tracker_contract(::InvalidOwnerValueTracker) = TrackerContract(
    Val(:invalid_owner_value), OwnershipTrackerSource(),
    DenseOwnerValueStorage{SVector{2, Int32}}(),
    AcceptedCommitTrackerVisibility(),
    ClaimedOwnerExclusiveTrackerConcurrency(), OldNewOwnerUpdateBound(),
    PersistTrackerCheckpoint(), TrackerSupport(true, true, true, true),
    ConstantTrackerCost(), LatticeLinearTrackerCost(),
)

tracker_contract(::NonconcreteOwnerValueTracker) = TrackerContract(
    Val(:nonconcrete_owner_value), OwnershipTrackerSource(),
    DenseOwnerValueStorage{SArray{Tuple{2}, Float32}}(),
    AcceptedCommitTrackerVisibility(),
    ClaimedOwnerExclusiveTrackerConcurrency(), OldNewOwnerUpdateBound(),
    PersistTrackerCheckpoint(), TrackerSupport(true, true, true, true),
    ConstantTrackerCost(), LatticeLinearTrackerCost(),
)

tracker_contract(::InvalidScalarValueTracker) = TrackerContract(
    Val(:invalid_scalar_value), OwnershipTrackerSource(),
    DenseOwnerScalarStorage{SVector{2, Float32}}(),
    AcceptedCommitTrackerVisibility(),
    ClaimedOwnerExclusiveTrackerConcurrency(), OldNewOwnerUpdateBound(),
    PersistTrackerCheckpoint(), TrackerSupport(true, true, true, true),
    ConstantTrackerCost(), LatticeLinearTrackerCost(),
)

function tracker_rebuild(::TripleOccupancyTracker, source, cell_kinds)
    values = zeros(Int32, length(cell_kinds))
    for owner in source.ownership
        owner > 0 && (values[Int(owner)] += Int32(3))
    end
    return values
end

tracker_recompute(
    tracker::TripleOccupancyTracker, source, cell_kinds
) = tracker_rebuild(tracker, source, cell_kinds)

tracker_rebuild(::InvalidDeltaTracker, source, cell_kinds) =
    zeros(Int32, length(cell_kinds))
tracker_recompute(
    tracker::InvalidDeltaTracker, source, cell_kinds
) = tracker_rebuild(tracker, source, cell_kinds)
tracker_rebuild(::NonfiniteDeltaTracker, source, cell_kinds) =
    zeros(Float64, length(cell_kinds))
tracker_recompute(tracker::NonfiniteDeltaTracker, source, cell_kinds) =
    tracker_rebuild(tracker, source, cell_kinds)

tracker_ownership_delta(
    ::TripleOccupancyTracker, target,
    old_owner::Int32, new_owner::Int32,
) = OwnerValueDelta(Int32(3))

tracker_ownership_delta(
    ::InvalidDeltaTracker, target,
    old_owner::Int32, new_owner::Int32,
) = OwnerValueDelta(Float32(1))
tracker_ownership_delta(
    ::NonfiniteDeltaTracker, target,
    old_owner::Int32, new_owner::Int32,
) = OwnerValueDelta(Inf)

function public_backend_probe()
    return (
        backend = program_backend_name(CPUProgramBackend()),
        engine = SequentialProgramEngine(),
    )
end

end


@testset "downstream extensions require only public SPIs" begin
    extension = DownstreamCorePottsExtension
    tracker = extension.TripleOccupancyTracker()
    contract = CorePotts.CompilerSPI.tracker_contract(tracker)
    @test contract.quantity == Val(:triple_occupancy)
    source = CorePotts.CompilerSPI.TrackerSourceView(
        reshape(Int32[1, 0, 2, 1], 2, 2), (2, 2), (false, false),
        CorePotts.CompilerSPI.HamiltonianDomainResources(0, 0),
        (), nothing,
    )
    @test CorePotts.CompilerSPI.tracker_rebuild(
        tracker, source, Int16[2, 2]
    ) == Int32[6, 3]
    @test CorePotts.CompilerSPI.tracker_recompute(
        tracker, source, Int16[2, 2]
    ) == Int32[6, 3]
    @test CorePotts.CompilerSPI.tracker_ownership_delta(
        tracker, CartesianIndex(1, 1), Int32(1), Int32(2)
    ) == CorePotts.CompilerSPI.OwnerValueDelta(Int32(3))

    @test_throws r"fixed-shape floating value" CorePotts.CompilerSPI.TrackerExecutionPlan(
        (extension.InvalidOwnerValueTracker(),),
        "invalid-integer-owner-value-storage",
    )
    @test_throws r"fixed-shape floating value" CorePotts.CompilerSPI.TrackerExecutionPlan(
        (extension.NonconcreteOwnerValueTracker(),),
        "nonconcrete-owner-value-storage",
    )
    @test_throws r"integer or floating scalar" CorePotts.CompilerSPI.TrackerExecutionPlan(
        (extension.InvalidScalarValueTracker(),),
        "invalid-structured-scalar-storage",
    )

    atomic_plan = CorePotts.CompilerSPI.TrackerExecutionPlan(
        (tracker, extension.InvalidDeltaTracker()),
        "downstream-atomic-tracker-test",
    )
    atomic_state = CorePotts.TrackerState((Int32[6, 3], Int32[0, 0]))
    before = deepcopy(atomic_state.values)
    @test_throws ArgumentError CorePotts.commit_tracker_updates!(
        atomic_state,
        atomic_plan,
        source,
        CartesianIndex(1, 1),
        Int32(1),
        Int32(2),
    )
    @test atomic_state.values == before

    overflow_state = CorePotts.TrackerState((Int32[typemax(Int32), 0],))
    overflow_before = deepcopy(overflow_state.values)
    @test_throws OverflowError CorePotts.commit_tracker_updates!(
        overflow_state,
        CorePotts.CompilerSPI.TrackerExecutionPlan(
            (tracker,), "downstream-overflow-tracker-test"),
        source, CartesianIndex(1, 1), Int32(0), Int32(1),
    )
    @test overflow_state.values == overflow_before

    nonfinite_state = CorePotts.TrackerState(([0.0, 0.0],))
    nonfinite_before = deepcopy(nonfinite_state.values)
    @test_throws ArgumentError CorePotts.commit_tracker_updates!(
        nonfinite_state,
        CorePotts.CompilerSPI.TrackerExecutionPlan(
            (extension.NonfiniteDeltaTracker(),),
            "downstream-nonfinite-tracker-test"),
        source, CartesianIndex(1, 1), Int32(0), Int32(1),
    )
    @test nonfinite_state.values == nonfinite_before

    backend = extension.public_backend_probe()
    @test backend.backend == :CPUBackend
    @test backend.engine isa CorePotts.BackendSPI.SequentialProgramEngine

    source_text = read(@__FILE__, String)
    module_text = only(match(
        r"module DownstreamCorePottsExtension(.*?)\nend\n\n\n@testset"s,
        source_text,
    ).captures)
    @test !occursin(r"CorePotts\._", module_text)
    @test !occursin(r"import CorePotts:(?!\.(?:CompilerSPI|BackendSPI))", module_text)
end
