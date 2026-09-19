using TOML

length(ARGS) >= 2 || error("usage: run-phase.jl PHASE COMMAND [ARG...]")

phase = first(ARGS)
command = Cmd(ARGS[2:end])
directory = get(ENV, "COREPOTTS_TELEMETRY_DIR", "")
isempty(directory) && error("COREPOTTS_TELEMETRY_DIR is required")
mkpath(directory)

started_ns = time_ns()
process = run(ignorestatus(command))
elapsed_seconds = (time_ns() - started_ns) / 1.0e9

measurement = Dict{String,Any}(
    "kind" => "ci_phase",
    "name" => phase,
    "elapsed_seconds" => elapsed_seconds,
    "success" => success(process),
    "exit_code" => process.exitcode,
    "julia_version" => string(VERSION),
    "architecture" => string(Sys.ARCH),
    "kernel" => string(Sys.KERNEL),
    "thread_count" => Threads.nthreads(),
)
for variable in (
    "GITHUB_JOB",
    "GITHUB_RUN_ID",
    "GITHUB_RUN_ATTEMPT",
    "GITHUB_SHA",
    "RUNNER_ARCH",
    "RUNNER_NAME",
    "RUNNER_OS",
    "RUNNER_TRACKING_ID",
    "LOCALMATH_REF",
)
    haskey(ENV, variable) && (measurement[lowercase(variable)] = ENV[variable])
end

path = joinpath(
    directory,
    string(
        "phase-",
        replace(phase, r"[^A-Za-z0-9_.-]" => "-"),
        "-",
        time_ns(),
        ".toml",
    ),
)
open(path, "w") do io
    TOML.print(io, Dict("measurement" => measurement))
end

exit(process.exitcode)
