using CorePotts
using LocalMath
using Metal
using Test

Metal.functional() || error("the selected Metal witness is not functional")
Metal.allowscalar(false)

const COREPOTTS_METAL_WITNESS_GROUPS = (
    "program-and-quantities" => (
        "corepotts_program_adaptation.jl",
        "corepotts_rng_contract.jl",
        "corepotts_scheduled_draws.jl",
        "corepotts_input_publication.jl",
        "corepotts_structured_owner_sums.jl",
        "corepotts_site_minimum.jl",
        "corepotts_site_tracker_lifecycle.jl",
        "corepotts_feasibility.jl",
    ),
    "state-and-history" => (
        "corepotts_stage_boundaries.jl",
        "corepotts_structured_transactions.jl",
        "corepotts_cell_stages.jl",
        "corepotts_history_ownership.jl",
        "corepotts_history_sampling.jl",
        "corepotts_history_lifecycle.jl",
        "corepotts_stage_anchor_contexts.jl",
        "corepotts_cell_domain_boundaries.jl",
    ),
    "lifecycle-and-conformance" => (
        "corepotts_lifecycle_value_conversion.jl",
        "corepotts_lifecycle_rule_composition.jl",
        "corepotts_lifecycle_relationship_staging.jl",
        "corepotts_lifecycle_scalar_retirement.jl",
        "corepotts_lifecycle_numeric_conversion.jl",
        "corepotts_lifecycle_integer_bounds.jl",
        "corepotts_lifecycle_product_conversion.jl",
        "corepotts_lifecycle_identity_capacity.jl",
        "corepotts_runtime_conformance.jl",
    ),
)

@testset "CorePotts Metal runner inventory" begin
    discovered = Set(
        filter(
            name -> endswith(name, ".jl") && name != "runtests.jl",
            readdir(@__DIR__),
        )
    )
    declared = collect(Iterators.flatten(last.(COREPOTTS_METAL_WITNESS_GROUPS)))
    @test length(first.(COREPOTTS_METAL_WITNESS_GROUPS)) ==
          length(unique(first.(COREPOTTS_METAL_WITNESS_GROUPS)))
    @test length(declared) == length(unique(declared))
    @test discovered == Set(declared)
end

length(ARGS) <= 1 || error("pass at most one Metal witness group")
selected_group = isempty(ARGS) ? nothing : only(ARGS)
selected_witnesses = if isnothing(selected_group)
    Iterators.flatten(last.(COREPOTTS_METAL_WITNESS_GROUPS))
else
    group_index = findfirst(group -> first(group) == selected_group, COREPOTTS_METAL_WITNESS_GROUPS)
    isnothing(group_index) && error(
        "unknown Metal witness group $(repr(selected_group)); expected one of " *
        join(first.(COREPOTTS_METAL_WITNESS_GROUPS), ", "),
    )
    last(COREPOTTS_METAL_WITNESS_GROUPS[group_index])
end

foreach(include, selected_witnesses)
