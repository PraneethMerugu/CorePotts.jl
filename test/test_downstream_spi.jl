module DownstreamCorePottsExtension

import CorePotts.CompilerSPI:
    AbstractTrackerDescriptor,
    AcceptedCommitTrackerVisibility,
    ClaimedOwnerExclusiveTrackerConcurrency,
    ConstantTrackerCost,
    DenseOwnerScalarStorage,
    LatticeLinearTrackerCost,
    OwnerScalarDelta,
    OwnershipTrackerSource,
    PersistTrackerCheckpoint,
    SourceTargetOwnerUpdateBound,
    TrackerContract,
    TrackerSupport,
    tracker_contract,
    tracker_proposal_delta,
    tracker_rebuild,
    tracker_recompute
import CorePotts.BackendSPI:
    CPUProgramBackend,
    SequentialProgramEngine,
    program_backend_name

struct TripleOccupancyTracker <: AbstractTrackerDescriptor end

tracker_contract(::TripleOccupancyTracker) = TrackerContract(
    Val(:triple_occupancy),
    OwnershipTrackerSource(),
    DenseOwnerScalarStorage{Int32}(),
    AcceptedCommitTrackerVisibility(),
    ClaimedOwnerExclusiveTrackerConcurrency(),
    SourceTargetOwnerUpdateBound(),
    PersistTrackerCheckpoint(),
    TrackerSupport(true, true, true, true),
    ConstantTrackerCost(),
    LatticeLinearTrackerCost(),
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

tracker_proposal_delta(
    ::TripleOccupancyTracker, source, target,
    old_owner::Int32, new_owner::Int32,
) = OwnerScalarDelta(Int32(3))

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
    )
    @test CorePotts.CompilerSPI.tracker_rebuild(
        tracker, source, Int16[2, 2]
    ) == Int32[6, 3]
    @test CorePotts.CompilerSPI.tracker_recompute(
        tracker, source, Int16[2, 2]
    ) == Int32[6, 3]
    @test CorePotts.CompilerSPI.tracker_proposal_delta(
        tracker, source, CartesianIndex(1, 1), Int32(1), Int32(2)
    ) == CorePotts.CompilerSPI.OwnerScalarDelta(Int32(3))
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
