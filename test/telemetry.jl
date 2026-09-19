module CorePottsTestTelemetry

using ParallelTestRunner
using TOML

struct TelemetryRecord <: ParallelTestRunner.AbstractTestRecord
    base::ParallelTestRunner.TestRecord
    process_id::Int
end

function _telemetry_directory()
    directory = get(ENV, "COREPOTTS_TELEMETRY_DIR", "")
    isempty(directory) && return nothing
    mkpath(directory)
    return directory
end

function _safe_name(name)
    return replace(string(name), r"[^A-Za-z0-9_.-]" => "-")
end

function record(name, values::AbstractDict)
    directory = _telemetry_directory()
    directory === nothing && return nothing
    path = joinpath(
        directory,
        string(_safe_name(name), "-", getpid(), "-", time_ns(), ".toml"),
    )
    open(path, "w") do io
        TOML.print(io, Dict("measurement" => merge(
            Dict(
                "name" => string(name),
                "process_id" => getpid(),
                "thread_count" => Threads.nthreads(),
            ),
            Dict(string(key) => value for (key, value) in values),
        )))
    end
    return path
end

function record_duration(name, started_ns; values = Dict{String,Any}())
    seconds = (time_ns() - started_ns) / 1.0e9
    return record(name, merge(Dict("elapsed_seconds" => seconds), values))
end

function ParallelTestRunner.execute(
    ::Type{TelemetryRecord}, mod::Module, expression, name, start_time, custom_args,
)
    base = ParallelTestRunner.execute(
        ParallelTestRunner.TestRecord,
        mod,
        expression,
        name,
        start_time,
        custom_args,
    )
    record(
        "fixture-$(name)",
        Dict(
            "kind" => "parallel_test_runner_fixture",
            "fixture" => name,
            "execution_seconds" => base.time,
            "compilation_seconds" => base.compile_time,
            "gc_seconds" => base.gctime,
            "allocated_bytes" => Int(base.bytes),
            "maximum_rss_bytes" => Int(base.rss),
            "scheduled_total_seconds" => base.total_time,
        ),
    )
    return TelemetryRecord(base, getpid())
end

end
