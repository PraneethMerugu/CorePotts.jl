isdefined(@__MODULE__, :CellStageIncrement) || include("fixtures/cell_stage_support.jl")

@testset "cell stages execute once per active identity" begin
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
        @testset "$(nameof(typeof(engine)))" begin
            runtime, handles = cell_stage_runtime(engine)
            before = CorePotts.program_snapshot(runtime)
            CorePotts.advance_mcs!(runtime)
            after = CorePotts.program_snapshot(runtime)
            @test !CorePotts.program_failed(runtime)
            @test after.ownership == before.ownership
            @test CorePotts.state_block(after.descriptor_state, handles[1]).values == Float32[2, 2, 0, 1, 1, 1]
            @test after.cell_kinds == Int16[2, 2, 0]
            @test count(==(1), before.ownership) != count(==(2), before.ownership)

            for value in (1.0f0, StaticArrays.SVector(1.0f0, 3.0f0), (; count = Int32(1), signal = StaticArrays.SVector(2.0f0, 4.0f0)))
                swapped, refs = cell_stage_runtime(engine; initial_value = value, swap = true)
                entry = CorePotts.program_snapshot(swapped)
                CorePotts.advance_mcs!(swapped)
                result = CorePotts.program_snapshot(swapped)
                @test !CorePotts.program_failed(swapped)
                @test CorePotts.state_block(result.descriptor_state, refs[1]).values[1:2] == CorePotts.state_block(entry.descriptor_state, refs[2]).values[1:2]
                @test CorePotts.state_block(result.descriptor_state, refs[2]).values[1:2] == CorePotts.state_block(entry.descriptor_state, refs[1]).values[1:2]
                @test CorePotts.state_block(result.descriptor_state, refs[1]).values[3:6] == CorePotts.state_block(entry.descriptor_state, refs[1]).values[3:6]
            end
            for capacity in (0, 4)
                empty_runtime, refs = cell_stage_runtime(engine; empty = true, bank_capacity = capacity)
                restored = CorePotts.restore_program_checkpoint(empty_runtime.program, CorePotts.program_checkpoint(empty_runtime))
                CorePotts.advance_mcs!(empty_runtime)
                CorePotts.advance_mcs!(restored)
                @test !CorePotts.program_failed(empty_runtime)
                @test all(==(1.0f0), CorePotts.state_block(CorePotts.program_snapshot(empty_runtime).descriptor_state, refs[1]).values)
                @test CorePotts.state_block(CorePotts.program_snapshot(restored).descriptor_state, refs[1]).values == CorePotts.state_block(CorePotts.program_snapshot(empty_runtime).descriptor_state, refs[1]).values
                if engine isa CorePotts.CheckerboardProgramEngine
                    queue = CorePotts._inspect_checkerboard_execution(empty_runtime.engine_workspace).identity.queue_policy
                    @test queue.before_lifecycle_submissions_per_mcs == 0
                    @test queue.after_lifecycle_submissions_per_mcs == 0
                end
            end
        end
    end
end

@testset "cell stages reject incompatible state domains before initialization" begin
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
        @test_throws ArgumentError cell_stage_runtime(engine; bank_capacity = 2)
        @test_throws ArgumentError cell_stage_runtime(engine; foreign_source = true)
        for read_condition in (false, true)
            @test_throws ArgumentError cell_stage_runtime(engine; read_condition, declare_read = false)
            for declare_read in (false, true)
                @test_throws ArgumentError cell_stage_runtime(engine; read_condition, declare_read, foreign_source = true)
                @test_throws ArgumentError cell_stage_runtime(engine; read_condition, declare_read, source_domain = :site)
            end
        end
        for domain in (:site, :model, :unrelated)
            @test_throws ArgumentError cell_stage_runtime(engine; schema_domain = domain)
            @test_throws ArgumentError cell_stage_runtime(engine; schema_domain = domain, empty = true, bank_capacity = 0)
        end
    end
end
