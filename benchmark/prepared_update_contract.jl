using Chairmarks
using CorePotts

include(joinpath(
    pkgdir(CorePotts), "test", "fixtures", "prepared_update_allocation_support.jl",
))

function timed_record(result)
    return (
        seconds = result.time,
        allocation_bytes = result.bytes,
        compile_seconds = result.compile_time,
        recompile_seconds = result.recompile_time,
    )
end

owner_construction = @timed prepared_owner_change_arguments()
owner_first = @timed execute_prepared_owner_change!(owner_construction.value)
owner_first.value || error("prepared owner-change benchmark failed")
owner_warm = @be prepared_owner_change_arguments() execute_prepared_owner_change!(_) evals=1 seconds=1

contribution_construction = @timed prepared_site_contribution_arguments()
contribution_first = @timed evaluate_prepared_site_contribution(
    contribution_construction.value,
)
contribution_first.value == -4.0f0 || error(
    "prepared contribution benchmark failed its numerical oracle",
)
contribution_warm = @be prepared_site_contribution_arguments() evaluate_prepared_site_contribution(_) evals=100 seconds=1

println("prepared_update_contract")
println((;
    julia = VERSION,
    corepotts = pkgversion(CorePotts),
    owner_construction = timed_record(owner_construction),
    owner_first = timed_record(owner_first),
    contribution_construction = timed_record(contribution_construction),
    contribution_first = timed_record(contribution_first),
))
println("owner_warm=")
display(owner_warm)
println("contribution_warm=")
display(contribution_warm)
