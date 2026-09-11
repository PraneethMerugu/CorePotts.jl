include("fixtures/program_adaptation_support.jl")

@testset "same-backend adaptation retains independent trajectories" begin
    _test_program_adaptation_independence(Array)
    _test_lifecycle_adaptation_independence(Array)
end
