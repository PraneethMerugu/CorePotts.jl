#!/usr/bin/env julia

import CorePotts
import Statistics
import TOML

# Reuse the owning scientific fixture, not its test runner or an executor copy.
include(joinpath(@__DIR__, "..", "test", "fixtures", "compiled_program_support.jl"))
include(joinpath(@__DIR__, "..", "test", "fixtures", "site_sum_support.jl"))

function measurement(result)
    return Dict(
        "seconds" => result.time,
        "bytes" => result.bytes,
        "gc_seconds" => result.gctime,
        "compile_seconds" => result.compile_time,
        "recompile_seconds" => result.recompile_time,
    )
end

function observe_mcs!(runtime)
    return measurement(@timed CorePotts.advance_mcs!(runtime))
end

function check_completed_source_boundary(runtime, handles, key)
    C = CorePotts
    current = Float32(runtime.mcs + 1)
    @assert runtime.accepted == 0
    @assert all(==(current), C.state_block(runtime.descriptor_state, handles[1]).values)
    @assert C.program_tracker_values(runtime, key) == Float32[4current, 2current, 0]
    entry = Float32(runtime.mcs)
    for handle in handles[2:3]
        @assert C.state_block(runtime.descriptor_state, handle).values == Float32[4entry, 2entry, 0]
    end
    @assert C.state_block(runtime.descriptor_state, handles[4]).values == Int32[2, 1, 0]
    return nothing
end

function observe_engine(engine, count)
    construction = @timed site_sum_cell_read_runtime(
        engine; source_process = scheduled_site_sum_assignment
    )
    runtime, handles, key = construction.value
    first_mcs = observe_mcs!(runtime)
    check_completed_source_boundary(runtime, handles, key)
    # Compile the measurement harness and exercise both execution-bank parities
    # before collecting warm samples. Assertions stay outside measured regions.
    warmups = map(1:2) do _
        result = observe_mcs!(runtime)
        check_completed_source_boundary(runtime, handles, key)
        result
    end
    samples = map(1:count) do _
        result = observe_mcs!(runtime)
        check_completed_source_boundary(runtime, handles, key)
        result
    end
    return Dict(
        "engine" => string(nameof(typeof(engine))),
        "construction" => measurement(construction),
        "first_completed_mcs" => first_mcs,
        "harness_warmups" => warmups,
        "samples" => samples,
        "median_seconds" => Statistics.median([sample["seconds"] for sample in samples]),
        "median_bytes" => Statistics.median([sample["bytes"] for sample in samples]),
        "warm_compile_seconds" => sum(sample["compile_seconds"] for sample in samples),
        "warm_recompile_seconds" => sum(sample["recompile_seconds"] for sample in samples),
        "completed_mcs" => runtime.mcs,
    )
end

function main(arguments)
    count = isempty(arguments) ? 7 : parse(Int, only(arguments))
    count > 0 || throw(ArgumentError("the warm sample count must be positive"))
    report = Dict(
        "julia_version" => string(VERSION),
        "cpu_threads" => Threads.nthreads(),
        "lattice_shape" => [6, 6],
        "finite_cells" => 2,
        "source_writers" => 1,
        "shared_sum_readers" => 2,
        "scope" => "public completed MCS: rejected copy proposals, source publication, shared entry-state reads, maintained sum refresh, and settlement",
        "interpretation" => "diagnostic observations, not thresholds; engines share one process and previously compiled methods; first-call timings are not isolated cold-build comparisons",
        "engines" => [
            observe_engine(engine, count) for engine in
                (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
        ],
    )
    TOML.print(stdout, report; sorted = true)
    return nothing
end

main(ARGS)
