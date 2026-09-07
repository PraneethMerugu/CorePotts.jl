module CompilerFlagshipBenchmark

    include(
        joinpath(
            @__DIR__, "..", "benchmark", "compiler_scaling", "corepotts_flagship.jl"
        )
    )

end

import TOML

@testset "compiler flagship benchmark uses canonical execution evidence" begin
    fixture = CompilerFlagshipBenchmark._flagship_fixture()
    runtime = CorePotts.initialize_program(
        fixture.program,
        fixture.initial,
        Float64[],
        UInt64(0x6c6d305f73656564),
        UInt32(1),
    )
    workspace = runtime.lifecycle_workspace
    CorePotts._reset_lifecycle_workspace!(workspace)
    CompilerFlagshipBenchmark._run_request_index!(runtime, workspace)
    @test CompilerFlagshipBenchmark._run_selection_phase!(runtime, workspace)
    @test CorePotts.lifecycle_request_count(workspace) == 0
    @test CorePotts._lifecycle_selected_count(workspace) == 0

    prepared_banks = runtime.engine_workspace.lifecycle_compaction.selection
    evidence = CompilerFlagshipBenchmark._cold_evidence_summary(prepared_banks)
    @test evidence["logical_stage_count"] == 1
    @test evidence["physical_bank_count"] == length(prepared_banks)
    @test evidence["operation_fact_count"] ==
        evidence["admitted_operation_fact_count"]

    for prepared in prepared_banks
        local_law = CompilerFlagshipBenchmark._flagship_stage_program(prepared)
        planning = LocalMath.inspect(local_law).planning
        core_launch_count = hasproperty(prepared, :publication) ? 1 : 0
        physical = CompilerFlagshipBenchmark._flagship_physical_evidence(prepared)
        @test physical.launch_count ==
            planning.base_provider_launch_count + core_launch_count
        @test length(physical.families) == physical.launch_count
    end

    timing = Dict(
        "compile_seconds" => 0.0,
        "elapsed_seconds" => 0.0,
        "recompile_seconds" => 0.0,
        "allocated_bytes" => 0,
        "gc_seconds" => 0.0,
    )
    output = IOBuffer()
    CompilerFlagshipBenchmark._emit_flagship_report(
        evidence, true, 0, 0,
        timing, timing, timing, timing,
        Dict("samples" => 0);
        io = output,
    )
    report = TOML.parse(String(take!(output)))
    @test report["schema_version"] == 2
    @test report["physical_launch_count"] ==
        length(report["physical_launch_families"])
    @test report["request_count"] == report["selected_count"] == 0
end
