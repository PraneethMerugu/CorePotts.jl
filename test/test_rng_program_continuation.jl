@testset "qualified RNG program continuation" begin
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
        program = test_program(engine; scalar_type = Float32)
        runtime = CorePotts.initialize_program(
            program, test_initial(Float32), Float32[],
            UInt64(0x7125), UInt32(3); repeat = UInt32(9)
        )
        CorePotts.advance_mcs!(runtime)
        checkpoint = CorePotts.program_checkpoint(runtime)
        # A correctly checksummed older RNG contract is still incompatible.
        core = checkpoint.extensions.CorePotts
        old_extensions = merge(
            checkpoint.extensions, (
                CorePotts = merge(
                    core, (
                        rng = (
                            contract_version = v"2.0.0",
                            lowering_identity = :philox4x32x10_semantic_address_fisher_yates_v2,
                        ),
                    )
                ),
            )
        )
        old_payload = (
            checkpoint.schema, checkpoint.program_fingerprint,
            checkpoint.snapshot, checkpoint.parameters, checkpoint.seed,
            checkpoint.replica, checkpoint.repeat, checkpoint.accepted,
            checkpoint.rejected, checkpoint.null_attempts, checkpoint.constraint_rejections,
            checkpoint.energy_rejections, checkpoint.retired_cells, old_extensions,
        )
        old = CorePotts.ProgramCheckpoint(
            old_payload...,
            CorePotts._program_checkpoint_checksum(old_payload...)
        )
        rejection = try
            CorePotts.restore_program_checkpoint(program, old)
            nothing
        catch error
            error
        end
        @test rejection isa ArgumentError
        @test occursin("RNG contract", sprint(showerror, rejection))
        @test CorePotts.program_checkpoint(runtime).checksum == checkpoint.checksum
        restored = CorePotts.restore_program_checkpoint(program, checkpoint)
        for _ in 1:3
            CorePotts.advance_mcs!(runtime)
            CorePotts.advance_mcs!(restored)
            @test !CorePotts.program_failed(runtime)
            @test !CorePotts.program_failed(restored)
            @test CorePotts.program_checkpoint(runtime).checksum ==
                CorePotts.program_checkpoint(restored).checksum
        end
    end
end

include(joinpath(@__DIR__, "backend_conformance", "localmath_execution.jl"))

@testset "compiled explicit draws preserve CPU continuation" begin
    for branch in (:explicit_draw, :explicit_uniform)
        result = run_localmath_checkerboard_vertical(
            identity; backend_name = :cpu, mcs_count = 4, branch
        )
        @test result.committed_mcs == 4
        @test result.accepted > 0
        @test (result.constraint_rejections > 0) == (branch === :explicit_draw)
    end
end
