using Test
import CorePotts
include("fixtures/history_sample_support.jl")

@testset "ownership-change policies reject model state and model history" begin
    C = CorePotts
    fixture = _initial_history_program(C.SequentialProgramEngine())
    for handle in (fixture.source, fixture.initial_history)
        @test_throws r"ownership-change policies require lattice-shaped site state" test_program(
            C.SequentialProgramEngine(); descriptor_plan = fixture.program.descriptor_plan,
            stage_plan = fixture.program.stage_plan, ownership_change_handles = (handle,),
            scalar_type = Float32,
        )
    end
end

test_initial_history_capture((CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine()))

test_history_initialization_failure()

@testset "history reads select bounded whole samples without copying" begin
    @test_throws r"history.*dimensions.*Int32" _history_sample_fixture(:cell, (0,), Int64(typemax(Int32)) + 1)
    for (domain, shape) in ((:model, ()), (:cell, (3,)), (:site, (2, 3)), (:cell, (0,)))
        fixture = _history_sample_fixture(domain, shape, 257)
        (; layout, source, history, descriptor) = fixture
        descriptors = (descriptor,)
        source_entry = CorePotts.CompilerSPI.history_source(descriptors, layout, history)
        @test source_entry.handle == source
        state = CorePotts.allocate_auxiliary_state(
            layout, map(layout.entries) do entry
                values = zeros(Float32, entry.schema.shape)
                if entry.schema.domain === :history
                    for sample in 1:257
                        fill!(selectdim(values, ndims(values), sample), sample)
                    end
                end
                values
            end
        )
        for lag in (0, 1, 256)
            projected = CorePotts.CompilerSPI.history_sample_handle(descriptors, layout, history, lag)
            @test CorePotts.CompilerSPI.state_read_source(descriptors, layout, projected).handle == source
            values = CorePotts.state_block(state, projected).values
            @test size(values) == shape
            @test all(==(Float32(257 - lag)), values)
            if !isempty(values)
                @test values.storage === CorePotts.state_block(state, history).values.storage
            end
        end
        for lag in (true, -1, 257)
            @test_throws ArgumentError CorePotts.CompilerSPI.history_sample_handle(descriptors, layout, history, lag)
        end
        @test_throws ArgumentError CorePotts.CompilerSPI.history_source((), layout, history)
        @test_throws ArgumentError CorePotts.CompilerSPI.history_source((:not_a_descriptor,), layout, history)
        @test_throws ArgumentError CorePotts.CompilerSPI.history_source((descriptor, descriptor), layout, history)
        projected = CorePotts.CompilerSPI.history_sample_handle(descriptors, layout, history, 0)
        invalid = CorePotts.StateHandle(CorePotts.handle_representation(history), history.bank, history.slot, Int(history.location.offset) + prod(CorePotts.handle_shape(history)) + 1, shape)
        @test_throws ArgumentError CorePotts._history_read_source(descriptors, layout, invalid)
        invalid_slot = CorePotts.StateHandle(CorePotts.handle_representation(history), history.bank, history.slot + 1, Int(projected.location.offset), shape)
        @test_throws ArgumentError CorePotts._history_read_source(descriptors, layout, invalid_slot)
    end
end

@testset "history projections are read-only at complete program admission" begin
    C = CorePotts
    for engine in (C.SequentialProgramEngine(), C.CheckerboardProgramEngine())
        @test _history_feedback_program(engine).program isa C.CompiledPottsProgram
        @test_throws r"canonical layout handle" _history_feedback_program(engine; extra_write = true)
        @test_throws r"canonical layout handle" _history_feedback_program(engine; projected_target = true)
        @test_throws r"canonical layout handle" _history_feedback_program(engine; ownership_write = true)
        @test_throws r"canonical layout handle" _history_feedback_program(engine; lifecycle_write = true)
        fixture = _history_sample_fixture(:model, (), 3)
        forged = C.StateHandle(C.handle_representation(fixture.history), fixture.history.bank, fixture.history.slot + 1, 1, ())
        @test_throws r"declared history sample" _history_feedback_program(engine; constraint_read = forged)
    end
end

test_history_feedback((CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine()))
