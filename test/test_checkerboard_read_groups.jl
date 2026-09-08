using Test
import CorePotts

_required_science_read(value) = ((value = Some(value), present = true),)

@testset "scientific decoding follows optional read declarations" begin
    for has_parameters in (false, true), has_contact in (false, true)
        parameters = has_parameters ?
            (parameters = _required_science_read((2.5, 7.5)),) : NamedTuple()
        contact_values = (
            (Int32(2),), (Int32(3),), (Int16(4),),
            (Int32(5),), (Int32(6),), (Int16(7),),
        )
        contact = has_contact ? NamedTuple{
                (
                    :sites, :owners, :kinds,
                    :reverse_sites, :reverse_owners, :reverse_kinds,
                ),
            }(
                map(_required_science_read, contact_values)
            ) : NamedTuple()
        # Distinct values expose accidental shifts across every optional group.
        groups = (
            core = (prefix = _required_science_read(-1),),
            parameters = parameters,
            contact = contact,
            trackers = (tracker = _required_science_read((11, 13)),),
            bounded_trackers = has_contact ?
                (
                    bounded = (
                        (value = Some(17), present = true),
                        (value = nothing, present = false),
                    ),
                ) : NamedTuple(),
            moments = NamedTuple(),
            relationships = NamedTuple(),
            state = (
                state = (
                    (value = Some(19), present = true),
                    (value = nothing, present = false),
                ),
            ),
        )
        declared, offsets = CorePotts._checkerboard_scientific_read_groups(groups)
        reads = values(declared)
        parameter_offset = CorePotts._checkerboard_read_offset(offsets, Val(:parameters))
        @test CorePotts._checkerboard_scientific_parameters(
            reads, Val(has_parameters), parameter_offset
        ) ==
            (has_parameters ? (2.5, 7.5) : ())
        contact_offset = CorePotts._checkerboard_read_offset(offsets, Val(:contact))
        @test CorePotts._checkerboard_scientific_contact(
            reads, Val(Int(has_contact)), contact_offset
        ) ==
            (has_contact ? contact_values : ((), (), (), (), (), ()))
        tracker_offset = CorePotts._checkerboard_read_offset(offsets, Val(:trackers))
        @test @inferred(
            CorePotts._checkerboard_scientific_tracker_values(
                reads, Val(1), tracker_offset
            )
        ) == ((11, 13),)
        bounded_offset = CorePotts._checkerboard_read_offset(offsets, Val(:bounded_trackers))
        bounded = CorePotts._checkerboard_scientific_tracker_gathers(
            reads, Val(Int(has_contact)), bounded_offset
        )
        @test bounded == values(groups.bounded_trackers)
        state_offset = CorePotts._checkerboard_read_offset(offsets, Val(:state))
        state = CorePotts._checkerboard_scientific_gathers(
            reads, Val(1), state_offset, Val(0)
        )
        @test only(state).sites == (19, 19)
    end
end

@testset "scientific read declarations reject ambiguous names" begin
    @test_throws ArgumentError CorePotts._checkerboard_scientific_read_groups(
        (
            first = (state = _required_science_read(1),),
            second = (state = _required_science_read(2),),
        )
    )
end
