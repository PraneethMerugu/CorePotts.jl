include(joinpath(@__DIR__, "fixtures", "scientific_geometry_oracle.jl"))

function geometry_gathered_proposal(runtime, target, new_owner::Int32, ::Type{T}) where {T}
    plan = runtime.program.tracker_plan
    moments = CorePotts.tracker_values(plan, runtime.trackers, Val(:cell_moments))
    old_owner = runtime.ownership[target]
    owners = (old_owner, new_owner)
    volumes = map(owners) do owner
        owner > 0 ? Int32(
                CorePotts.tracker_value(
                    plan, runtime.trackers, Val(:cell_volume), owner
                )
            ) : Int32(0)
    end
    moment_first = ntuple(2) do dimension
        map(owner -> owner > 0 ? moments.first[dimension, owner] : zero(T), owners)
    end
    moment_second = ntuple(4) do component
        map(owner -> owner > 0 ? moments.second[component, owner] : zero(T), owners)
    end
    return CorePotts._GatheredProposalContext(;
        source = target, target, target_linear = Int32(LinearIndices(runtime.ownership)[target]),
        old_owner, new_owner,
        old_kind = CorePotts.owner_kind(runtime, old_owner),
        new_kind = CorePotts.owner_kind(runtime, new_owner),
        volumes, semantic = Int32(1), mcs = Int64(1), color = Int32(1),
        trajectory_key = (UInt64(1), UInt64(0)), scalar_zero = zero(T), parameters = (),
        state_values = (), contact_sites = (), contact_owners = (), contact_kinds = (),
        reverse_contact_sites = (), reverse_contact_owners = (), reverse_contact_kinds = (),
        contact_ranges = ((), ()), tracker_values = (), bounded_tracker_samples = (),
        tracker_descriptors = (), bounded_tracker_descriptors = (),
        moment_first, moment_second, moment_descriptor = CorePotts.CellMomentsTracker{2, T}(),
        relationship_resources = (),
    )
end

function geometry_overlay_allocations(runtime, target, new_owner)
    CorePotts._cell_center(runtime, Int32(1); replaced_site = target, replacement_owner = new_owner)
    return @allocated CorePotts._cell_center(
        runtime, Int32(1);
        replaced_site = target, replacement_owner = new_owner
    )
end

function geometry_gathered_allocations(context, owner)
    CorePotts._gathered_cell_center(context, owner)
    return @allocated CorePotts._gathered_cell_center(context, owner)
end

function independent_spring_energy(ownership, first_owner, second_owner)
    first_center = independent_cell_center(ownership, first_owner)
    second_center = independent_cell_center(ownership, second_owner)
    first_center === nothing && return 0.0
    second_center === nothing && return 0.0
    distance = sqrt(
        sum(
            (first_center[index] - second_center[index])^2 for index in 1:2
        )
    )
    return 1.5 * (distance - 3.0)^2
end

@testset "gathered and runtime geometry preserve empty and asymmetric overlays" begin
    for T in (Float32, Float64)
        tracker_plan = CorePotts.TrackerExecutionPlan(
            (
                CorePotts.OwnershipCountTracker(), CorePotts.CellMomentsTracker{2, T}(),
            ),
            "geometry-overlay-trackers"
        )
        program = test_program(CorePotts.SequentialProgramEngine(); tracker_plan, scalar_type = T)
        ownership = zeros(Int32, 6, 6)
        ownership[1, 1] = ownership[2, 3] = ownership[4, 5] = 1
        ownership[6, 2] = 2
        runtime = CorePotts.initialize_program(
            program,
            CorePotts.ProgramInitialState(ownership, Int16[2, 2]; scalar_type = T),
            T[], UInt64(0x0e11), UInt32(1)
        )
        cases = (
            (CartesianIndex(4, 5), Int32(2)),
            (CartesianIndex(6, 2), Int32(0)),
            (CartesianIndex(1, 2), Int32(1)),
            (CartesianIndex(6, 1), Int32(1)),
            (CartesianIndex(2, 3), Int32(1)),
        )
        for (target, new_owner) in cases
            proposal = @inferred geometry_gathered_proposal(runtime, target, new_owner, T)
            changed = copy(ownership)
            changed[target] = new_owner
            for after in (false, true), owner in unique((proposal.old_owner, new_owner))
                context = CorePotts._GatheredAnchorEnergyContext(proposal, after, owner)
                expected_ownership = after ? changed : ownership
                expected_center = owner > 0 ? independent_cell_center(expected_ownership, owner) : nothing
                expected_length = owner > 0 ? independent_cell_length(expected_ownership, owner) : 0.0
                center = CorePotts._gathered_cell_center(context, owner)
                length = CorePotts._gathered_cell_elongation(context, owner)
                if expected_center === nothing
                    @test center === nothing
                else
                    @test all(isapprox.(center, expected_center; rtol = 32eps(T), atol = 32eps(T)))
                end
                @test isapprox(length, expected_length; rtol = 32eps(T), atol = 32eps(T))
                @test length isa T
                @test geometry_gathered_allocations(context, owner) == 0
                replaced_site = after ? target : nothing
                @test isequal(
                    center, CorePotts._cell_center(
                        runtime, owner;
                        replaced_site, replacement_owner = new_owner
                    )
                )
                @test isequal(
                    length, CorePotts._cell_length(
                        runtime, owner;
                        replaced_site, replacement_owner = new_owner
                    )
                )
            end
            @test runtime.ownership == ownership
            @test geometry_overlay_allocations(runtime, target, new_owner) == 0
        end
    end
end

@testset "cell length clamps negative covariance roundoff" begin
    for T in (Float32, Float64)
        covariance = (-eps(T), zero(T), zero(T), -eps(T))
        @test CorePotts._covariance_length(Val(2), covariance, T) === zero(T)
        @test_throws ArgumentError CorePotts._covariance_length(
            Val(3), ntuple(_ -> zero(T), 9), T
        )
    end
end

@testset "cell geometry matches independent global energy oracles" begin
    tracker_plan = CorePotts.TrackerExecutionPlan(
        (
            CorePotts.OwnershipCountTracker(),
            CorePotts.CellMomentsTracker{2, Float64}(),
        ),
        "scientific-geometry-trackers-v1",
    )
    program = test_program(
        CorePotts.SequentialProgramEngine(); tracker_plan
    )
    ownership = zeros(Int32, 6, 6)
    ownership[2:3, 2:3] .= 1
    ownership[4:5, 4:5] .= 2
    runtime = CorePotts.initialize_program(
        program,
        CorePotts.ProgramInitialState(
            ownership, Int16[2, 2]; scalar_type = Float64
        ),
        Float64[],
        UInt64(0x0e10),
        UInt32(1),
    )

    for owner in Int32(1):Int32(2)
        observed_center = CorePotts._cell_center(runtime, owner)
        expected_center = independent_cell_center(ownership, owner)
        @test all(isapprox.(observed_center, expected_center))
        @test CorePotts._cell_length(runtime, owner) ≈
            independent_cell_length(ownership, owner)
    end

    cases = (
        (CartesianIndex(2, 4), Int32(1)),
        (CartesianIndex(2, 2), Int32(0)),
        (CartesianIndex(3, 3), Int32(2)),
    )
    for (target_site, new_owner) in cases
        old_owner = ownership[target_site]
        affected = unique(filter(>(0), (old_owner, new_owner)))
        core_elongation_delta = sum(affected; init = 0.0) do owner
            before = CorePotts._cell_length(runtime, owner)
            after = CorePotts._cell_length(
                runtime,
                owner;
                replaced_site = target_site,
                replacement_owner = new_owner,
            )
            (after - 4.0)^2 - (before - 4.0)^2
        end
        after_ownership = copy(ownership)
        after_ownership[target_site] = new_owner
        independent_elongation_delta = sum(affected; init = 0.0) do owner
            (independent_cell_length(after_ownership, owner) - 4.0)^2 -
                (independent_cell_length(ownership, owner) - 4.0)^2
        end
        @test core_elongation_delta ≈ independent_elongation_delta

        before_first = CorePotts._cell_center(runtime, Int32(1))
        before_second = CorePotts._cell_center(runtime, Int32(2))
        after_first = CorePotts._cell_center(
            runtime,
            Int32(1);
            replaced_site = target_site,
            replacement_owner = new_owner,
        )
        after_second = CorePotts._cell_center(
            runtime,
            Int32(2);
            replaced_site = target_site,
            replacement_owner = new_owner,
        )
        function spring(center_a, center_b)
            if center_a === nothing || center_b === nothing
                return 0.0
            end
            separation = sqrt(
                sum(
                    (center_a[index] - center_b[index])^2 for index in 1:2
                )
            )
            return 1.5 * (separation - 3.0)^2
        end
        core_spring_delta = spring(after_first, after_second) -
            spring(before_first, before_second)
        independent_delta = independent_spring_energy(
            after_ownership, Int32(1), Int32(2)
        ) - independent_spring_energy(ownership, Int32(1), Int32(2))
        @test core_spring_delta ≈ independent_delta
        @test runtime.ownership == ownership
    end
end
