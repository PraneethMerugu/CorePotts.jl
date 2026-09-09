using CorePotts
using LocalMath
using Metal
using Test

Metal.functional() || error("the selected Metal witness is not functional")
Metal.allowscalar(false)

const COREPOTTS_METAL_WITNESSES = (
    "corepotts_program_adaptation.jl",
    "corepotts_rng_contract.jl",
    "corepotts_scheduled_draws.jl",
    "corepotts_feasibility.jl",
    "corepotts_stage_boundaries.jl",
    "corepotts_structured_transactions.jl",
    "corepotts_cell_stages.jl",
    "corepotts_history_ownership.jl",
    "corepotts_history_sampling.jl",
    "corepotts_stage_anchor_contexts.jl",
    "corepotts_cell_domain_boundaries.jl",
    "corepotts_lifecycle_value_conversion.jl",
    "corepotts_lifecycle_rule_composition.jl",
    "corepotts_lifecycle_scalar_retirement.jl",
    "corepotts_lifecycle_numeric_conversion.jl",
    "corepotts_lifecycle_integer_bounds.jl",
    "corepotts_lifecycle_product_conversion.jl",
    "corepotts_lifecycle_identity_capacity.jl",
    "corepotts_runtime_conformance.jl",
)

@testset "CorePotts Metal runner inventory" begin
    discovered = Set(
        filter(
            name -> endswith(name, ".jl") && name != "runtests.jl",
            readdir(@__DIR__),
        )
    )
    @test discovered == Set(COREPOTTS_METAL_WITNESSES)
end

foreach(include, COREPOTTS_METAL_WITNESSES)
